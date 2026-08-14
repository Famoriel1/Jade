//
//  id2name.swift
//  bad_query
//
//  Resolves an app's display name from its bundle identifier.
//
//  Two routes, tried in order:
//  1. LSApplicationProxy (private API, bridging-header helper) — properly
//     localized names, but on recent iOS versions it is entitlement-gated and
//     only returns a handful of Apple apps for unentitled processes.
//  2. Filesystem fallback — scan /var/containers/Bundle/Application (and
//     /Applications) for .app/Info.plist via bad_query sandbox extensions and
//     read CFBundleDisplayName / CFBundleName. Works for every installed app.
//
//  Results are cached in memory and on disk (Documents/bundle_name_cache.plist)
//  so the container scan runs at most once per install set change.
//

import Foundation

/// Serial queue guarding LaunchServices queries, the name cache, and the
/// one-shot bundle-container scan. Each LS miss is an lsd XPC round-trip and
/// the fallback scan issues hundreds of bad_query calls — keep them off the
/// caller's thread and serialized.
private let resolverQueue = DispatchQueue(label: "bq.id2name.resolver")

/// bundle ID → display name. Only hits are cached, so apps installed after a
/// failed lookup can still resolve on the next rebuild.
private var nameCache: [String: String] = [:]

private var diskCacheLoaded = false
private var bundleScanDone = false

/// Synchronous, cached lookup of an app's display name.
/// Returns nil for unknown or non-app identifiers (e.g. plugin/daemon containers).
/// Safe to call from any thread. The first LS miss triggers the one-shot
/// bundle-container scan, which can take a few seconds.
@discardableResult
func appName(for bundleID: String) -> String? {
    resolverQueue.sync { resolveLocked(bundleID) }
}

/// Batch-resolve display names — meant to be invoked from a detached task.
/// Returns a dictionary of bundle ID → name (missing entries = unresolved).
func appNames(for bundleIDs: [String]) -> [String: String] {
    resolverQueue.sync {
        var result: [String: String] = [:]
        for id in bundleIDs {
            if let name = resolveLocked(id) {
                result[id] = name
            }
        }
        return result
    }
}

// MARK: - Resolution pipeline (resolverQueue only)

private func resolveLocked(_ bundleID: String) -> String? {
    if let cached = nameCache[bundleID] { return cached }

    // 1. LaunchServices + direct filesystem access (AppNameForBundleID).
    //    Under MHA identity the process can read /var/containers/Bundle and
    //    /Applications directly; under sandbox the direct read fails and we
    //    fall through to the bad_query-backed scan below.
    if let name = AppNameForBundleID(bundleID), !name.isEmpty {
        nameCache[bundleID] = name
        return name
    }

    // 2. Filesystem fallback via bad_query. Restore the persisted map first —
    //    a hit there avoids the container scan entirely.
    loadDiskCacheLocked()
    if let cached = nameCache[bundleID] { return cached }

    if !bundleScanDone {
        bundleScanDone = true
        let found = scanBundleContainers()
        for (id, name) in found where nameCache[id] == nil {
            nameCache[id] = name
        }
        saveDiskCacheLocked()
    }
    return nameCache[bundleID]
}

// MARK: - Disk cache

private var diskCacheURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("bundle_name_cache.plist")
}

private func loadDiskCacheLocked() {
    guard !diskCacheLoaded else { return }
    diskCacheLoaded = true
    if let dict = NSDictionary(contentsOf: diskCacheURL) as? [String: String] {
        for (id, name) in dict where nameCache[id] == nil {
            nameCache[id] = name
        }
    }
}

private func saveDiskCacheLocked() {
    (nameCache as NSDictionary).write(to: diskCacheURL, atomically: true)
}

// MARK: - Bundle container scan

/// Enumerate bundle containers and build bundleID → display name from each
/// .app/Info.plist. /Applications holds system apps as <Name>.app directly;
/// /var/containers/Bundle/Application holds user apps as <UUID>/<Name>.app.
private func scanBundleContainers() -> [String: String] {
    var map: [String: String] = [:]
    for root in ["/var/containers/Bundle/Application", "/Applications"] {
        guard let entries = listDirectory(root) else { continue }
        for entry in entries {
            let dir = root + "/" + entry
            if entry.hasSuffix(".app") {
                if let (bid, name) = readAppInfo(dir + "/Info.plist") {
                    map[bid] = name
                }
                continue
            }
            guard let children = listDirectory(dir) else { continue }
            for child in children where child.hasSuffix(".app") {
                if let (bid, name) = readAppInfo(dir + "/" + child + "/Info.plist") {
                    map[bid] = name
                }
            }
        }
    }
    return map
}

/// List a directory, falling back to a one-shot bad_query extension when the
/// sandbox denies access. The extension is released immediately after use —
/// bad_query extensions are per-path and each active one adds kernel audit
/// overhead to every syscall, so they must not accumulate.
private func listDirectory(_ path: String) -> [String]? {
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
        return entries
    }
    let handle = BQFileSystemModel.rawBadQuery(path: path)
    guard handle > 0 else { return nil }
    defer { bad_query_release(handle) }
    return try? FileManager.default.contentsOfDirectory(atPath: path)
}

/// Read a .app/Info.plist and extract (bundleID, displayName), activating a
/// one-shot bad_query extension when the plain read is denied.
private func readAppInfo(_ plistPath: String) -> (String, String)? {
    func parse(_ data: Data?) -> (String, String)? {
        guard let data,
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String
        else { return nil }
        let display = plist["CFBundleDisplayName"] as? String
        let bundle = plist["CFBundleName"] as? String
        guard let name = (display.flatMap { $0.isEmpty ? nil : $0 }) ?? bundle,
              !name.isEmpty
        else { return nil }
        return (bid, name)
    }
    if let direct = parse(FileManager.default.contents(atPath: plistPath)) {
        return direct
    }
    let handle = BQFileSystemModel.rawBadQuery(path: plistPath)
    guard handle > 0 else { return nil }
    defer { bad_query_release(handle) }
    return parse(FileManager.default.contents(atPath: plistPath))
}
