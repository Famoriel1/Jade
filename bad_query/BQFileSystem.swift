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

struct FSItem: Identifiable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var typeKnown: Bool
    var size: Int64?
    var modified: Date?
    var subtitle: String?

    var id: String { path }
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

    var extensionCount: Int { activeExtensions.count }

    /// When true, app-data containers are accessed via MobileHouseArrest (class 2)
    /// instead of the path-traversal route. Only effective when the app's bundle
    /// identifier is com.apple.mobile.MobileHouseArrest.
    var useMHAHelper = false

    /// MHA extensions keyed by container root path. Values are object pointers
    /// that must be released via bad_query_mha_release (not bad_query_release).
    var mhaExtensions: [String: Int64] = [:]

    static var isMobileHouseArrest: Bool {
        Bundle.main.bundleIdentifier == "com.apple.mobile.MobileHouseArrest"
    }

    /// App Group owned by this app, used as the "sacrifice" route on iOS 26.
    static let appGroupIdentifier = "group.com.jason.bqtools"

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
    func ensureExtension(for path: String, allowMHA: Bool = true) -> Int64 {
        // Try MHA route first when enabled (and not opted out by caller)
        if allowMHA, useMHAHelper, let mhaHandle = ensureMHAExtension(for: path) {
            return mhaHandle
        }

        if let existing = activeExtensions[path] { return existing }
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

    /// Try to activate an MHA extension for a path inside an app-data container.
    /// Returns the object handle if an MHA extension is (already) active, nil otherwise.
    private func ensureMHAExtension(for path: String) -> Int64? {
        let appPrefix = "/var/mobile/Containers/Data/Application/"
        guard path.hasPrefix(appPrefix) else { return nil }

        // Extract the container root (UUID immediately after the prefix)
        let rest = String(path.dropFirst(appPrefix.count))
        let uuid = rest.split(separator: "/").first.map(String.init) ?? rest
        let containerRoot = appPrefix + uuid

        // Already have an MHA extension for this container?
        if let existing = mhaExtensions[containerRoot] {
            return existing > 0 ? existing : nil
        }

        // Read the container metadata to resolve the bundle ID
        let metaPath = containerRoot + "/.com.apple.mobile_container_manager.metadata.plist"
        guard let data = FileManager.default.contents(atPath: metaPath),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleId = plist["MCMMetadataIdentifier"] as? String
        else {
            mhaExtensions[containerRoot] = -1  // cache the failure
            return nil
        }

        // Query the container via MHA (class 2)
        var pathBuf = [CChar](repeating: 0, count: 1024)
        let handle = bundleId.withCString { ptr in
            bad_query_mha(ptr, &pathBuf, 1024)
        }

        if handle > 0 {
            mhaExtensions[containerRoot] = handle
            let resolvedRoot = String(cString: pathBuf)
            appendLog("MHA extension active for \(bundleId) → \(resolvedRoot)")
            statusMessage = "MHA: \(bundleId)"
            return handle
        } else {
            mhaExtensions[containerRoot] = -1
            appendLog("MHA failed (\(handle)) for \(bundleId)")
            return nil
        }
    }

    func releaseAllExtensions() {
        for (path, handle) in activeExtensions {
            bad_query_release(handle)
            appendLog("released extension \(handle) (\(path))")
        }
        activeExtensions.removeAll()

        for (root, handle) in mhaExtensions where handle > 0 {
            bad_query_mha_release(handle)
            appendLog("released MHA extension \(handle) (\(root))")
        }
        mhaExtensions.removeAll()
        statusMessage = "All sandbox extensions released"
    }

    // MARK: Listing

    func load(_ path: String, allowMHA: Bool = true) {
        Task { await performLoad(path, allowMHA: allowMHA) }
    }

    func performLoad(_ path: String, allowMHA: Bool = true) async {
        isLoading = true
        lastError = nil
        usedInodeScan = false
        items = []

        let handle = ensureExtension(for: path, allowMHA: allowMHA)
        var names: [String]?
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            appendLog("readdir failed for \(path): \(error.localizedDescription)")
        }

        if let names {
            items = names
                .map { makeItem(parent: path, name: $0) }
                .sorted(by: Self.itemOrder)
            statusMessage = "\(items.count) items"
            await resolveContainerMetadata(for: path)
        } else {
            let reason = handle > 0
                ? "directory not readable"
                : (BQError.extensionFailed(handle).errorDescription ?? "unknown")
            statusMessage = "Listing failed (\(reason)) — trying inode scan"
            await inodeScan(path, maxInode: maxInode)
        }
        isLoading = false
    }

    func inodeScan(_ path: String, maxInode: Int64) async {
        self.maxInode = maxInode
        isScanning = true
        usedInodeScan = true
        appendLog("inode scan of \(path) (max inode \(maxInode))…")

        let found: [String]? = await Task.detached(priority: .userInitiated) {
            var cPath = path.utf8CString.map { Int8($0) }
            guard let raw = bad_query_list(&cPath, maxInode) else { return nil }
            defer { free(raw) }
            return String(cString: raw).split(separator: "\n").map(String.init)
        }.value

        isScanning = false
        guard let found, !found.isEmpty else {
            lastError = "Inode scan failed: statfs refused for this path."
            statusMessage = "Inode scan failed"
            return
        }
        items = found
            .map { makeItem(parent: path, name: lastComponent($0), fullPath: $0) }
            .sorted(by: Self.itemOrder)
        statusMessage = "\(items.count) items (inode scan)"
        await resolveContainerMetadata(for: path)
    }

    private static func itemOrder(_ lhs: FSItem, _ rhs: FSItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func makeItem(parent: String, name: String, fullPath: String? = nil) -> FSItem {
        let full = fullPath ?? parent + "/" + name
        var item = FSItem(path: full, name: name, isDirectory: false, typeKnown: false,
                          size: nil, modified: nil, subtitle: nil)
        var st = stat()
        let result = full.withCString { lstat($0, &st) }
        if result == 0 {
            item.typeKnown = true
            item.isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            item.size = item.isDirectory ? nil : Int64(st.st_size)
            item.modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }
        return item
    }

    private func resolveContainerMetadata(for parent: String) async {
        guard Self.containerRoots.contains(parent) else { return }
        let paths = items.map(\.path)
        guard !paths.isEmpty else { return }

        // Ensure sandbox extensions on the main actor (ensureExtension is
        // @MainActor-isolated). Each container needs its own extension for
        // the metadata plist file.
        for p in paths {
            ensureExtension(for: p, allowMHA: false)
            ensureExtension(for: p + "/.com.apple.mobile_container_manager.metadata.plist", allowMHA: false)
        }

        // Read and parse metadata plists concurrently in the background.
        let resolved = await Task.detached(priority: .userInitiated) {
            var results: [ResolvedMeta] = []
            for containerPath in paths {
                let metaPath = containerPath + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let data = FileManager.default.contents(atPath: metaPath),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                      let identifier = plist["MCMMetadataIdentifier"] as? String
                else { continue }
                results.append(ResolvedMeta(path: containerPath, identifier: identifier))
            }
            return results
        }.value
        for meta in resolved {
            if let index = items.firstIndex(where: { $0.path == meta.path }) {
                items[index].subtitle = meta.identifier
            }
        }
        if !resolved.isEmpty {
            appendLog("resolved \(resolved.count) container identifiers")
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
