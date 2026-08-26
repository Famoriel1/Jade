//
//  BQFileSystem.swift
//  bad_query
//
//  File manager engine built on top of the bad_query sandbox escape.
//

import Foundation
import Observation
import UIKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - FSItem

struct FSItem: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
    var typeKnown: Bool
    var size: Int64?
    var modified: Date?
    var subtitle: String?

    var id: String { path }

    /// Sentinel used to pre-allocate a buffer for concurrent stat fills.
    static let empty = FSItem(path: "", name: "", isDirectory: false,
                              typeKnown: false, size: nil, modified: nil, subtitle: nil)
}

// MARK: - Errors

enum BQError: LocalizedError {
    case extensionFailed(Int64)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .extensionFailed(let code):
            switch code {
            case -255: return "Path is not absolute"
            case -254: return "Path does not exist"
            case -1: return "Failed to resolve containermanager functions"
            case -2: return "Failed to create container query"
            case -3: return "containermanagerd refused the query (unsupported path?)"
            case -4: return "Kernel refused the sandbox extension"
            case -5: return "Internal error building the query"
            default: return "Unknown bad_query error (\(code))"
            }
        case .io(let message):
            return message
        }
    }
}

// MARK: - Preview

enum PreviewContent {
    case loading
    case text(String)
    case image(UIImage)
    case hex(String)
    case unreadable(String)
}

enum PreviewLoader {
    nonisolated static let maxBytes = 4 * 1024 * 1024

    nonisolated static func load(path: String) -> PreviewContent {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .unreadable("Could not read this file. The sandbox extension may not cover it.")
        }
        if data.isEmpty { return .text("(empty file)") }
        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data

        if let plist = try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return .text(text + (truncated ? "\n\n(truncated)" : ""))
        }
        if let object = try? JSONSerialization.jsonObject(with: slice, options: []),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return .text(text)
        }
        if let image = UIImage(data: slice) { return .image(image) }
        if let text = String(data: slice, encoding: .utf8) {
            return .text(text + (truncated ? "\n\n(truncated)" : ""))
        }
        let dump = hexDump(data.prefix(8192))
        return .hex(data.count > 8192 ? dump + "\n…" : dump)
    }

    nonisolated static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." }
            let paddedHex = hex + String(repeating: " ", count: max(0, 47 - hex.count))
            lines.append(String(format: "%08x", offset) + "  " + paddedHex + "  |" + String(ascii) + "|")
            offset = end
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Model

struct ResolvedMeta: Sendable {
    let path: String
    let identifier: String
}

/// Outcome of an off-main-actor directory listing (enumerate + stat).
private struct ListingOutcome: Sendable {
    let items: [FSItem]
    let error: String?
}

/// Result of activating a single bad_query extension off the main thread.
private struct ExtensionActivation: Sendable {
    let path: String
    let handle: Int64
}

@MainActor
@Observable
final class BQFileSystemModel {
    // Browsing state
    var items: [FSItem] = []
    var isLoading = false
    var isScanning = false
    var usedInodeScan = false
    var statusMessage = "Ready"
    var lastError: String?
    var copiedItemPath: String?
    var pendingShare: PendingShare?
    var log: [String] = []
    var maxInode: Int64 = 300_000
    var activeExtensions: [String: Int64] = [:]

    /// Includes MHA leases cached in the ObjC layer (BQMCMIntegration).
    var extensionCount: Int { activeExtensions.count + Int(BQMCMActiveLeaseCount()) }

    /// When true, app-data containers are accessed via MobileHouseArrest (class 2)
    /// instead of the path-traversal route. Only effective when the app's signed
    /// code identifier is com.apple.mobile.MobileHouseArrest.
    var useMHAHelper: Bool = BQFileSystemModel.isMobileHouseArrest

    /// True iff the process signed-code-identifier equals the MHA identity.
    /// Uses SecTaskCopySigningIdentifier (not Bundle.main.bundleIdentifier),
    /// which is what containermanagerd actually checks — a dev-signed app with
    /// the right bundle ID but wrong CodeDirectory identifier is rejected.
    static var isMobileHouseArrest: Bool { BQMCMIsMobileHouseArrest() }

    /// App Group owned by this app, used as the "sacrifice" route on iOS 26.
    nonisolated static let appGroupIdentifier = "group.com.jason.bqtools"

    /// Call bad_query directly without touching main-actor state. bad_query is a
    /// stateless C function (dlopen + XPC + Mach IPC), safe to call concurrently
    /// from background tasks — the same way inodeScan already calls
    /// bad_query_list_range concurrently.
    nonisolated static func rawBadQuery(path: String) -> Int64 {
        var cPath = path.utf8CString.map { Int8($0) }
        var handle = bad_query(&cPath, true, nil, false)
        if handle < 0 {
            var cGroup = appGroupIdentifier.utf8CString.map { Int8($0) }
            var fallback = bad_query(&cPath, true, &cGroup, true)
            if fallback < 0 {
                fallback = bad_query(&cPath, true, &cGroup, false)
            }
            if fallback > 0 { handle = fallback }
        }
        return handle
    }

    /// Determine a reasonable max inode for automatic inode-scan fallbacks on
    /// subdirectories. Uses statfs to avoid scanning beyond the filesystem's
    /// actual inode capacity; falls back to 300k if statfs is unavailable or
    /// reports an absurdly large value (APFS can report billions).
    nonisolated static func autoScanMaxInode(path: String) -> Int64 {
        var sfs = statfs()
        guard path.withCString({ statfs($0, &sfs) }) == 0 else { return 300_000 }
        let files = Int64(sfs.f_files)
        if files > 0 && files < 300_000 { return files }
        return 300_000
    }

    /// Per-container-root inode scan ceiling. Application needs 1.5M because
    /// app UUID directories are spread across a wide inode range (e.g. WeChat).
    /// Other container roots have fewer entries in a narrower range, so 300k
    /// is sufficient and avoids wasting time on 1.2M extra fsgetpath misses.
    /// Non-container paths use statfs-capped autoScanMaxInode.
    static func defaultMaxInode(for path: String) -> Int64 {
        if path == "/var/mobile/Containers/Data/Application" { return 1_500_000 }
        if Self.containerRoots.contains(path) { return 300_000 }
        return autoScanMaxInode(path: path)
    }

    struct QuickAccess: Identifiable {
        var id: String { path }
        let title: String
        let path: String
        let note: String
    }

    static let quickAccess: [QuickAccess] = [
        QuickAccess(title: "Application Containers",
                    path: "/var/mobile/Containers/Data/Application",
                    note: "One sandbox per app, keyed by UUID"),
        QuickAccess(title: "InternalDaemon Containers",
                    path: "/var/mobile/Containers/Data/InternalDaemon",
                    note: "System daemon sandboxes"),
        QuickAccess(title: "PluginKitPlugin Containers",
                    path: "/var/mobile/Containers/Data/PluginKitPlugin",
                    note: "App extension plugin sandboxes"),
        QuickAccess(title: "App Groups",
                    path: "/var/mobile/Containers/Shared/AppGroup",
                    note: "Shared group containers (App Group sacrifice on iOS 26)"),
        QuickAccess(title: "System Data Containers",
                    path: "/var/containers/Data/System",
                    note: "iOS 27 only"),
        QuickAccess(title: "System Groups",
                    path: "/var/containers/Shared/SystemGroup",
                    note: "iOS 27 only"),
    ]

    private static let containerRoots: Set<String> = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/containers/Data/System",
        "/var/containers/Shared/SystemGroup",
    ]

    /// Maps container root path prefix → (MCM container class, isGroup).
    /// Covers all container types MHA can resolve. Used by ensureMHAExtension
    /// to route activation by path, and by mhaEnumerateContainers to pick the
    /// right class for identifier enumeration.
    private static let containerClassMap: [(prefix: String, containerClass: UInt64, group: Bool)] = [
        ("/var/mobile/Containers/Data/Application", 2, false),
        ("/var/mobile/Containers/Shared/AppGroup", 7, true),
        ("/var/mobile/Containers/Data/PluginKitPlugin", 4, false),
        ("/var/mobile/Containers/Data/VPNPlugin", 6, false),
        ("/var/mobile/Containers/Data/InternalDaemon", 10, false),
        ("/var/containers/Data/System", 12, false),
        ("/var/containers/Shared/SystemGroup", 13, true),
        ("/var/mobile/Containers/Data/Protected", 15, false),
    ]

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func appendLog(_ message: String) {
        log.append("[\(Self.logFormatter.string(from: Date()))] \(message)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: Sandbox extensions

    @discardableResult
    func ensureExtension(for path: String, allowMHA: Bool = true, force: Bool = false) -> Int64 {
        // Try MHA route first when enabled (and not opted out by caller).
        // MHA leases are cached in the ObjC layer (BQMCMIntegration), so a
        // repeat call for the same container is a cheap dictionary lookup.
        if allowMHA, useMHAHelper, ensureMHAExtension(for: path) {
            return 1  // MHA success sentinel — path is sandbox-extended via lease
        }

        // bad_query's path-traversal extension is per-path (not recursive).
        // Cache by the full path, but skip re-activating if the container root
        // already has an extension — the per-file extension is still needed for
        // actual file access, but we avoid redundant syscalls for paths we've
        // already activated.
        // Use force=true to bypass cache (e.g. after creating a directory that
        // didn't exist when the extension was first activated).
        if !force, let existing = activeExtensions[path] { return existing }
        if force { activeExtensions.removeValue(forKey: path) }
        var cPath = path.utf8CString.map { Int8($0) }
        var handle = bad_query(&cPath, true, nil, false)
        var route = "system"
        if handle < 0 {
            // Fallback: route through our own App Group. This is the
            // required route for App Group containers on iOS 26.
            var cGroup = Self.appGroupIdentifier.utf8CString.map { Int8($0) }
            var fallback = bad_query(&cPath, true, &cGroup, true)
            if fallback < 0 {
                fallback = bad_query(&cPath, true, &cGroup, false)
            }
            if fallback > 0 {
                handle = fallback
                route = "app group"
            }
        }
        if handle > 0 {
            activeExtensions[path] = handle
            appendLog("extension \(handle) consumed (\(route) route) for \(path)")
            statusMessage = "Extension active: \(lastComponent(path))"
        } else {
            appendLog("extension failed (\(handle)) for \(path)")
        }
        return handle
    }

    /// Try to activate an MHA lease for the container that contains `path`.
    /// Handles all container classes (2/4/6/7/10/12/13/15), not just app data.
    /// Returns true if the container root is now sandbox-extended (either
    /// freshly activated or already cached in the ObjC layer).
    ///
    /// The container class is determined from the path prefix via
    /// containerClassMap. The identifier (bundle ID / group ID) is read from
    /// the container's MCM metadata plist. Leases are cached by (class,
    /// identifier) in BQMCMIntegration, so a repeat call for the same
    /// container is a cheap dictionary lookup.
    private func ensureMHAExtension(for path: String) -> Bool {
        // Normalize /private/var/... → /var/... for prefix matching.
        // MCM returns /private/... paths, but the codebase uses /var/...
        let normalizedPath = path.hasPrefix("/private/var/")
            ? String(path.dropFirst("/private".count)) : path

        // Find which container type this path belongs to
        for (prefix, containerClass, group) in Self.containerClassMap {
            let prefixWithSlash = prefix + "/"
            guard normalizedPath == prefix || normalizedPath.hasPrefix(prefixWithSlash) else {
                continue
            }
            // For the root itself, MHA can't activate (no single identifier).
            // Container roots are handled by mhaEnumerateContainers instead.
            if normalizedPath == prefix { return false }

            // Extract the container root (UUID immediately after the prefix)
            let rest = String(normalizedPath.dropFirst(prefixWithSlash.count))
            let uuid = rest.split(separator: "/").first.map(String.init) ?? rest
            let containerRoot = prefixWithSlash + uuid

            // Fast path: a lease for this root is already active.
            if BQMCMPathHasActiveLease(containerRoot) { return true }

            // Read the container metadata to resolve the identifier
            let metaPath = containerRoot + "/.com.apple.mobile_container_manager.metadata.plist"
            guard let data = FileManager.default.contents(atPath: metaPath),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  let identifier = plist["MCMMetadataIdentifier"] as? String,
                  BQMCMSafeIdentifier(identifier)
            else { return false }

            var error: NSString?
            let resolvedRoot = BQMCMActivate(containerClass, identifier, group, &error)
            if let resolvedRoot {
                appendLog("MHA lease active (class \(containerClass)) for \(identifier) → \(resolvedRoot)")
                statusMessage = "MHA: \(identifier)"
                return true
            } else {
                let reason = error.map { String($0) } ?? "unknown"
                appendLog("MHA failed (class \(containerClass)) for \(identifier): \(reason)")
                return false
            }
        }
        return false
    }

    func releaseAllExtensions() {
        let badQueryCount = activeExtensions.count
        for (_, handle) in activeExtensions {
            bad_query_release(handle)
        }
        activeExtensions.removeAll()

        let mhaCount = Int(BQMCMActiveLeaseCount())
        BQMCMReleaseAllLeases()

        // Clear scan caches so the next visit does a fresh scan (user explicitly
        // released everything, likely to pick up newly installed apps).
        inodeScanCache.removeAll()
        inodeRangeCache.removeAll()
        containerBundleCache.removeAll()
        appendLog("released \(badQueryCount + mhaCount) extension(s)")
        statusMessage = "All sandbox extensions released"
    }

    /// Release only the metadata-plist extensions activated by
    /// resolveContainerMetadata. These are only needed when browsing a
    /// container root (to show app bundle IDs); deeper directories don't
    /// need them, and each active extension slows down kernel syscalls.
    func releaseMetadataExtensions() {
        let suffix = ".com.apple.mobile_container_manager.metadata.plist"
        let toRelease = activeExtensions.filter { $0.key.hasSuffix(suffix) }
        guard !toRelease.isEmpty else { return }
        for (key, handle) in toRelease {
            activeExtensions.removeValue(forKey: key)
            bad_query_release(handle)
        }
        containerBundleCache.removeAll()
        appendLog("released \(toRelease.count) metadata extensions")
    }

    // MARK: Listing

    func load(_ path: String, allowMHA: Bool = true, scanMaxInode: Int64? = nil) {
        Task { await performLoad(path, allowMHA: allowMHA, scanMaxInode: scanMaxInode) }
    }

    func performLoad(_ path: String, allowMHA: Bool = true, scanMaxInode: Int64? = nil) async {
        isLoading = true
        lastError = nil
        usedInodeScan = false
        items = []

        // When entering a non-container-root directory, release the metadata
        // plist extensions that resolveContainerMetadata activated for the
        // Apps list. Each active sandbox extension adds kernel auditing
        // overhead to every syscall — 200+ metadata extensions can slow
        // fsgetpath by ~20×, turning a 0.2s inode scan into a 4s one.
        if !Self.containerRoots.contains(path) {
            releaseMetadataExtensions()
        }

        let handle = ensureExtension(for: path, allowMHA: allowMHA)

        // Enumerate + stat off the main actor so the UI stays responsive even
        // for directories with hundreds of entries.
        let outcome = await Task.detached(priority: .userInitiated) { () -> ListingOutcome in
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: path)
                let fullPaths = names.map { path + "/" + $0 }
                return ListingOutcome(items: Self.statItems(paths: fullPaths), error: nil)
            } catch {
                return ListingOutcome(items: [], error: error.localizedDescription)
            }
        }.value

        if outcome.error == nil {
            items = outcome.items.sorted(by: Self.itemOrder)
            statusMessage = "\(items.count) items"
            await resolveContainerMetadata(for: path)
        } else {
            appendLog("readdir failed for \(path): \(outcome.error ?? "")")
            let reason = handle > 0
                ? "directory not readable"
                : (BQError.extensionFailed(handle).errorDescription ?? "unknown")
            statusMessage = "Listing failed (\(reason)) — trying inode scan"
            // Each container root has its own appropriate inode ceiling.
            // Application needs 1.5M (many apps with high-inode UUIDs);
            // other container roots use a smaller default. Subdirectories
            // use statfs-capped autoScanMaxInode.
            let scanMax = scanMaxInode ?? Self.defaultMaxInode(for: path)
            await inodeScan(path, maxInode: scanMax)
        }
        isLoading = false
    }

    /// Cache of container-root inode scan results: path → discovered subpaths.
    /// containerRoots contents change infrequently (only on app install/uninstall),
    /// so caching avoids re-scanning 1.5M inodes on every visit.
    private var inodeScanCache: [String: [String]] = [:]

    /// Discovered inode range per container root: path → (minInode, maxInode).
    /// Used for adaptive rescans — only probe the known range ± a margin instead
    /// of re-scanning the full [1, maxInode] range.
    private var inodeRangeCache: [String: (min: Int64, max: Int64)] = [:]

    func inodeScan(_ path: String, maxInode: Int64) async {
        isScanning = true
        usedInodeScan = true
        let isContainerRoot = Self.containerRoots.contains(path)

        // Fast path: use cached scan results if available. containerRoots
        // contents change infrequently (only on app install/uninstall), so
        // we can skip the 1.5M-inode probe entirely on subsequent visits.
        if let cached = inodeScanCache[path], !cached.isEmpty {
            appendLog("inode scan cache hit for \(path) (\(cached.count) paths)")
            let items = await Task.detached(priority: .userInitiated) {
                Self.statItems(paths: cached)
            }.value
            self.items = items.sorted(by: Self.itemOrder)
            isScanning = false
            statusMessage = "\(items.count) items (cached)"
            if isContainerRoot {
                await resolveContainerMetadata(for: path)
            }
            return
        }

        appendLog("inode scan of \(path) (max inode \(maxInode))…")

        // Adaptive scan: if we have a previously-discovered inode range,
        // scan that range ± a 50k margin first. This covers newly
        // installed/uninstalled apps without re-probing 1.5M inodes.
        // If the adaptive scan finds results, skip the full scan.
        if let range = inodeRangeCache[path] {
            let margin: Int64 = 50_000
            let adaptStart = max(1, range.min - margin)
            let adaptEnd = min(maxInode, range.max + margin)
            appendLog("adaptive scan [\(adaptStart), \(adaptEnd)]…")
            let adaptPaths = await scanInodeRange(path: path, start: adaptStart, end: adaptEnd)

            if !adaptPaths.isEmpty {
                // Adaptive scan found results — use them directly.
                inodeScanCache[path] = adaptPaths
                let items = await Task.detached(priority: .userInitiated) {
                    Self.statItems(paths: adaptPaths)
                }.value
                self.items = items.sorted(by: Self.itemOrder)
                isScanning = false
                statusMessage = "\(items.count) items (adaptive scan)"
                if isContainerRoot {
                    await resolveContainerMetadata(for: path)
                }
                return
            }
        }

        // Full scan: no cache, no adaptive range. Split into two phases so
        // partial results appear quickly.
        let quickMax: Int64 = min(20_000, maxInode)
        let quickPaths = await scanInodeRange(path: path, start: 1, end: quickMax)

        if !quickPaths.isEmpty {
            let quickItems = await Task.detached(priority: .userInitiated) {
                Self.statItems(paths: quickPaths)
            }.value
            self.items = quickItems.sorted(by: Self.itemOrder)
            statusMessage = "\(items.count) items (scanning more…)"
            if isContainerRoot {
                await resolveContainerMetadata(for: path)
            }
        }

        let restPaths = maxInode > quickMax
            ? await scanInodeRange(path: path, start: quickMax + 1, end: maxInode)
            : []

        isScanning = false

        let allPaths = quickPaths + restPaths
        guard !allPaths.isEmpty else {
            lastError = "Inode scan failed: statfs refused for this path."
            statusMessage = "Inode scan failed"
            return
        }

        // Record the discovered inode range for future adaptive scans.
        // Done off the main actor — lstat on 200+ paths would block the UI.
        if isContainerRoot {
            let range = await Task.detached(priority: .userInitiated) { () -> (min: Int64, max: Int64)? in
                var minInode: Int64 = .max
                var maxInode: Int64 = 0
                for p in allPaths {
                    var st = stat()
                    if p.withCString({ lstat($0, &st) }) == 0 {
                        let ino = Int64(st.st_ino)
                        if ino < minInode { minInode = ino }
                        if ino > maxInode { maxInode = ino }
                    }
                }
                guard minInode <= maxInode else { return nil }
                return (min: minInode, max: maxInode)
            }.value
            if let range {
                inodeRangeCache[path] = range
                appendLog("recorded inode range [\(range.min), \(range.max)] for \(path)")
            }
            inodeScanCache[path] = allPaths
        }

        if !restPaths.isEmpty {
            let allItems = await Task.detached(priority: .userInitiated) {
                Self.statItems(paths: allPaths)
            }.value
            guard !allItems.isEmpty else {
                self.items = []
                statusMessage = "0 items (inode scan)"
                return
            }
            self.items = allItems.sorted(by: Self.itemOrder)
        }

        statusMessage = "\(items.count) items (inode scan)"
        if isContainerRoot {
            await resolveContainerMetadata(for: path)
        }
    }

    /// Scan a subrange of inodes [start, end] in parallel chunks. fsgetpath is
    /// a stateless syscall, so concurrent bad_query_list_range calls are safe.
    private func scanInodeRange(path: String, start: Int64, end: Int64) async -> [String] {
        if start > end { return [] }
        let chunkSize: Int64 = 4096
        let chunks: [(Int64, Int64)] = stride(from: start, through: end, by: Int(chunkSize)).map {
            s in (s, min(s + chunkSize - 1, end))
        }
        let pathCopy = path
        return await withTaskGroup(of: [String]?.self) { group in
            for (s, e) in chunks {
                group.addTask {
                    var cPath = pathCopy.utf8CString.map { Int8($0) }
                    guard let raw = bad_query_list_range(&cPath, s, e) else {
                        return nil
                    }
                    defer { free(raw) }
                    return String(cString: raw).split(separator: "\n").map(String.init)
                }
            }
            var merged: [String] = []
            for await result in group {
                if let batch = result { merged.append(contentsOf: batch) }
            }
            return merged
        }
    }

    private static func itemOrder(_ lhs: FSItem, _ rhs: FSItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Stat a batch of paths into FSItems off the main actor. For large
    /// directories (> 64 entries) the lstat syscalls are parallelised with
    /// `concurrentPerform`; small directories stay serial to avoid GCD
    /// dispatch overhead. The pre-allocated buffer is filled through an
    /// unsafe mutable buffer pointer so each iteration writes a distinct
    /// index without triggering CoW.
    nonisolated static func statItems(paths: [String]) -> [FSItem] {
        let count = paths.count
        guard count > 0 else { return [] }
        if count > 64 {
            var items = [FSItem](repeating: .empty, count: count)
            items.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: count) { i in
                    buffer[i] = statItem(path: paths[i])
                }
            }
            return items
        }
        return paths.map { statItem(path: $0) }
    }

    /// Stat a single path into an FSItem (name derived from the path).
    nonisolated static func statItem(path: String) -> FSItem {
        let name = (path as NSString).lastPathComponent
        var item = FSItem(path: path, name: name, isDirectory: false, typeKnown: false,
                          size: nil, modified: nil, subtitle: nil)
        var st = stat()
        if path.withCString({ lstat($0, &st) }) == 0 {
            item.typeKnown = true
            item.isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            item.size = item.isDirectory ? nil : Int64(st.st_size)
            item.modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }
        return item
    }

    /// Cache of container path → bundle ID, so we don't re-read metadata plists
    /// when items are rebuilt (e.g. Phase 2 of inodeScan replaces self.items).
    private var containerBundleCache: [String: String] = [:]

    private func resolveContainerMetadata(for parent: String) async {
        guard Self.containerRoots.contains(parent) else { return }
        let paths = items.map(\.path)
        guard !paths.isEmpty else { return }

        // Each metadata plist needs its own extension (bad_query extensions are
        // per-path, not recursive). Activate them concurrently off the main
        // thread — each bad_query call is an expensive syscall (dlopen + XPC +
        // Mach IPC), and running them serially on the main actor blocks the UI
        // with 200+ app containers.
        let metaPaths = paths.map { $0 + "/.com.apple.mobile_container_manager.metadata.plist" }
        let uncached = metaPaths.filter { activeExtensions[$0] == nil }
        if !uncached.isEmpty {
            let handles: [ExtensionActivation] = await withTaskGroup(of: ExtensionActivation.self) { group in
                for mp in uncached {
                    group.addTask { ExtensionActivation(path: mp, handle: Self.rawBadQuery(path: mp)) }
                }
                var results: [ExtensionActivation] = []
                for await result in group { results.append(result) }
                return results
            }
            var activated = 0
            for entry in handles where entry.handle > 0 {
                activeExtensions[entry.path] = entry.handle
                activated += 1
            }
            if activated > 0 { appendLog("activated \(activated) metadata extensions") }
        }

        // Apply cached bundle IDs immediately (no I/O), then only read plists
        // for containers we haven't resolved yet.
        var resolved = 0
        var toResolve: [String] = []
        for containerPath in paths {
            if let id = containerBundleCache[containerPath] {
                if let index = items.firstIndex(where: { $0.path == containerPath }) {
                    items[index].subtitle = id
                }
                resolved += 1
            } else {
                toResolve.append(containerPath)
            }
        }

        guard !toResolve.isEmpty else {
            if resolved > 0 { appendLog("resolved \(resolved) container identifiers (cached)") }
            return
        }

        // Read and parse each uncached metadata plist concurrently, updating
        // the UI progressively — each resolved identifier is written to its
        // item and cache immediately as it completes, so bundle IDs appear
        // one by one instead of all-at-once after a long wait.
        await withTaskGroup(of: ResolvedMeta?.self) { group in
            for containerPath in toResolve {
                group.addTask {
                    let metaPath = containerPath + "/.com.apple.mobile_container_manager.metadata.plist"
                    guard let data = FileManager.default.contents(atPath: metaPath),
                          let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                          let identifier = plist["MCMMetadataIdentifier"] as? String
                    else { return nil }
                    return ResolvedMeta(path: containerPath, identifier: identifier)
                }
            }
            for await result in group {
                guard let meta = result else { continue }
                containerBundleCache[meta.path] = meta.identifier
                if let index = items.firstIndex(where: { $0.path == meta.path }) {
                    items[index].subtitle = meta.identifier
                }
                resolved += 1
            }
            if resolved > 0 {
                appendLog("resolved \(resolved) container identifiers")
            }
        }
    }

    // MARK: File operations

    func createItem(named rawName: String, isDirectory: Bool, in parent: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            lastError = "Invalid name."
            return
        }
        let destination = parent + "/" + name
        ensureExtension(for: parent)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
            } else {
                guard FileManager.default.createFile(atPath: destination, contents: nil) else {
                    throw BQError.io("FileManager.createFile failed")
                }
            }
            appendLog("created \(isDirectory ? "folder" : "file") \(destination)")
            load(parent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ item: FSItem) {
        let parent = parentPath(item.path)
        ensureExtension(for: parent)
        ensureExtension(for: item.path)
        do {
            try FileManager.default.removeItem(atPath: item.path)
            appendLog("deleted \(item.path)")
            load(parent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(_ item: FSItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            lastError = "Invalid name."
            return
        }
        let parent = parentPath(item.path)
        let destination = parent + "/" + name
        ensureExtension(for: parent)
        do {
            try FileManager.default.moveItem(atPath: item.path, toPath: destination)
            appendLog("renamed \(item.name) → \(name)")
            load(parent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copy(_ item: FSItem) {
        copiedItemPath = item.path
        statusMessage = "Copied \(item.name) — use Paste Here in the menu"
    }

    func paste(into parent: String) {
        guard let source = copiedItemPath else { return }
        ensureExtension(for: parent)
        ensureExtension(for: parentPath(source))
        ensureExtension(for: source)
        var destination = parent + "/" + lastComponent(source)
        if FileManager.default.fileExists(atPath: destination) {
            destination = parent + "/" + lastComponent(source) + " copy"
        }
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            appendLog("pasted \(source) → \(destination)")
            load(parent)
        } catch {
            // Fall back to a plain data copy for regular files.
            if let data = FileManager.default.contents(atPath: source),
               (try? data.write(to: URL(fileURLWithPath: destination))) != nil {
                appendLog("pasted (data copy) → \(destination)")
                load(parent)
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    func export(_ item: FSItem) {
        if let size = item.size, size > 512 * 1024 * 1024 {
            lastError = "File is too large to export in memory."
            return
        }
        ensureExtension(for: parentPath(item.path))
        ensureExtension(for: item.path)
        guard let data = FileManager.default.contents(atPath: item.path) else {
            lastError = "Could not read \(item.name)."
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad_query_export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(item.name)
            try? FileManager.default.removeItem(at: destination)
            try data.write(to: destination)
            appendLog("exported \(item.name) (\(data.count) bytes)")
            pendingShare = PendingShare(url: destination)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importFile(from source: URL, toDestinationPath destination: String) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else {
            lastError = "Could not read the selected file."
            return
        }
        let parent = parentPath(destination)
        ensureExtension(for: parent)
        ensureExtension(for: destination)
        do {
            try data.write(to: URL(fileURLWithPath: destination))
            appendLog("wrote \(data.count) bytes → \(destination)")
            load(parent)
        } catch {
            lastError = error.localizedDescription
        }
    }
// MARK: Recursive Mirror

func mirrorEverything(from sourcePath: String) {
    guard !sourcePath.isEmpty else {
        lastError = "No source directory selected."
        return
    }

    let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )[0]

    let mirrorRoot = documents.appendingPathComponent(
        "Mirror",
        isDirectory: true
    )

    let sourceName = (sourcePath as NSString).lastPathComponent
    let destinationRoot = mirrorRoot.appendingPathComponent(
        sourceName,
        isDirectory: true
    )

    do {
        try FileManager.default.createDirectory(
            at: mirrorRoot,
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(
            atPath: destinationRoot.path
        ) {
            try FileManager.default.removeItem(
                at: destinationRoot
            )
        }

        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )

        var copiedFiles = 0
        var copiedDirectories = 0
        var skipped = 0

        mirrorDirectory(
            source: sourcePath,
            destination: destinationRoot.path,
            copiedFiles: &copiedFiles,
            copiedDirectories: &copiedDirectories,
            skipped: &skipped
        )

        statusMessage =
            "Mirror complete: \(copiedFiles) files, " +
            "\(copiedDirectories) folders, \(skipped) skipped"

        appendLog(
            "mirror complete: \(copiedFiles) files, " +
            "\(copiedDirectories) folders, \(skipped) skipped"
        )

    } catch {
        lastError = "Mirror failed: \(error.localizedDescription)"
    }
}

private func mirrorDirectory(
    source: String,
    destination: String,
    copiedFiles: inout Int,
    copiedDirectories: inout Int,
    skipped: inout Int
) {
    // Use Jade's existing access mechanism.
    let handle = ensureExtension(for: source)

    guard handle > 0 || FileManager.default.fileExists(atPath: source) else {
        skipped += 1
        appendLog("mirror: no access to \(source)")
        return
    }

    let entries: [String]

    do {
        // No hidden-file filtering.
        entries = try FileManager.default.contentsOfDirectory(
            atPath: source
        )
    } catch {
        skipped += 1
        appendLog(
            "mirror: cannot enumerate \(source): \(error.localizedDescription)"
        )
        return
    }

    for name in entries {
        let sourceItem = (source as NSString)
            .appendingPathComponent(name)

        let destinationItem = (destination as NSString)
            .appendingPathComponent(name)

        // Get access to this exact path using Jade's existing mechanism.
        let itemHandle = ensureExtension(for: sourceItem)

        guard itemHandle > 0 ||
              FileManager.default.fileExists(atPath: sourceItem) else {
            skipped += 1
            appendLog("mirror: no access to \(sourceItem)")
            continue
        }

        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: sourceItem,
            isDirectory: &isDirectory
        ) else {
            skipped += 1
            continue
        }

        do {
            if isDirectory.boolValue {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: destinationItem),
                    withIntermediateDirectories: true
                )

                copiedDirectories += 1

                mirrorDirectory(
                    source: sourceItem,
                    destination: destinationItem,
                    copiedFiles: &copiedFiles,
                    copiedDirectories: &copiedDirectories,
                    skipped: &skipped
                )

            } else {
                let parent = (destinationItem as NSString)
                    .deletingLastPathComponent

                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )

                try FileManager.default.copyItem(
                    atPath: sourceItem,
                    toPath: destinationItem
                )

                copiedFiles += 1
            }

        } catch {
            skipped += 1

            appendLog(
                "mirror: failed \(sourceItem): " +
                "\(error.localizedDescription)"
            )
        }
    }
}
    // MARK: In-place Write

    /// Write data to a file in-place using fd overwrite, preserving the inode.
    /// Ported from BQMobileGestaltModel.write() — opens the original file with
    /// O_WRONLY | O_CLOEXEC | O_NOFOLLOW, truncates, writes, fsyncs, and rolls
    /// back to original data on failure. Post-write verification ensures the
    /// bytes on disk match exactly.
    func writeInPlace(at path: String, data: Data) throws {
        // Ensure sandbox extensions for both the file and its parent
        ensureExtension(for: parentPath(path))
        ensureExtension(for: path)

        // Read original for rollback
        let original = FileManager.default.contents(atPath: path)

        // Open the original file in-place (O_NOFOLLOW prevents symlink hijacking)
        let fd = path.withCString { p in
            open(p, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw BQError.io("Failed to open file for in-place write (errno=\(errno))")
        }
        defer { close(fd) }

        // Truncate, write, fsync — all on the same inode
        let success = ftruncate(fd, 0) == 0 &&
            lseek(fd, 0, SEEK_SET) == 0 &&
            writeAll(fd: fd, data: data) &&
            fsync(fd) == 0

        if !success {
            // Rollback to original on failure
            if let original {
                ftruncate(fd, 0)
                lseek(fd, 0, SEEK_SET)
                _ = writeAll(fd: fd, data: original)
                fsync(fd)
            }
            throw BQError.io("Failed to write file in-place (errno=\(errno))")
        }

        // Verify
        if let verification = FileManager.default.contents(atPath: path),
           verification != data {
            throw BQError.io("Post-write verification failed")
        }

        appendLog("wrote \(data.count) bytes in-place to \(path)")
        statusMessage = "Saved \(data.count) bytes"
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var ptr = buffer.baseAddress!
            var remaining = buffer.count
            while remaining > 0 {
                let written = Foundation.write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    // MARK: Helpers

    private func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    nonisolated deinit {
        // activeExtensions is MainActor-isolated; we cannot access it from a
        // nonisolated deinit. Release handles eagerly via releaseAllExtensions()
        // before the model is torn down, or rely on the kernel reclaiming them.
    }
}
