//
//  BQPoster.swift
//  bad_query
//
//  PosterBoard wallpaper engine — applies .tendies/.zip wallpaper packs
//  to PosterBoard's descriptor store via the bad_query sandbox escape.
//  Ported from mond's pb module, adapted to use BQFileSystemModel.
//

import Foundation

enum BQPosterError: LocalizedError {
    case containerNotFound
    case notZip(URL)
    case noDescriptors(URL)
    case unzipFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .containerNotFound:
            return "Could not find the PosterBoard container."
        case .notZip(let url):
            return "\(url.lastPathComponent) is not a valid tendies/zip archive."
        case .noDescriptors(let url):
            return "No descriptors found in \(url.lastPathComponent)."
        case .unzipFailed(let message):
            return "Failed to unzip: \(message)"
        }
    }
}

enum BQPoster {
    static let posterBoardBundleId = "com.apple.PosterBoard"
    static let collectionsExt = "com.apple.WallpaperKit.CollectionsPoster"
    static let photosExt = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    static let extVersion = "61"
    static let containerRoots = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Data/PluginKitPlugin",
    ]

    private static var fm: FileManager { FileManager.default }

    // MARK: - Container discovery

    /// Find the PosterBoard data container by scanning container roots for the
    /// matching bundle ID in metadata plists.
    @MainActor
    static func findPosterBoardContainer(model: BQFileSystemModel) async throws -> URL {
        for root in containerRoots {
            print("(pb) findContainer: scanning \(root)")
            // Wait for the scan to complete — model.load is fire-and-forget,
            // but performLoad awaits the full scan (readdir or inode scan).
            await model.performLoad(root, allowMHA: false)
            print("(pb) findContainer: scan done, \(model.items.count) items")

            for child in model.items.filter(\.isDirectory).map(\.path) {
                let childUrl = URL(fileURLWithPath: child, isDirectory: true)

                let hidden = childUrl.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if let id = readMetaKey(at: hidden, key: "MCMMetadataIdentifier", model: model), id == posterBoardBundleId {
                    print("(pb) findContainer: found via hidden plist at \(childUrl.path)")
                    return childUrl
                }

                let plain = childUrl.appendingPathComponent("com.apple.mobile_container_manager.metadata.plist")
                if let id = readMetaKey(at: plain, key: "MCMMetadataIdentifier", model: model), id == posterBoardBundleId {
                    print("(pb) findContainer: found via plain plist at \(childUrl.path)")
                    return childUrl
                }
            }
            print("(pb) findContainer: not found in \(root)")
        }
        throw BQPosterError.containerNotFound
    }

    private static func readMetaKey(at url: URL, key: String, model: BQFileSystemModel) -> String? {
        let path = url.path
        model.ensureExtension(for: path)

        guard let data = fm.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist[key] as? String
    }

    // MARK: - Path helpers

    static func posterExtensionsRoot(container: URL) -> URL {
        container
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("PRBPosterExtensionDataStore")
            .appendingPathComponent(extVersion)
            .appendingPathComponent("Extensions")
    }

    static func descriptorsUrl(container: URL, ext: String) -> URL {
        posterExtensionsRoot(container: container)
            .appendingPathComponent(ext)
            .appendingPathComponent("descriptors")
    }

    // MARK: - Apply / Reset

    /// Apply one or more .tendies/.zip wallpaper packs to PosterBoard.
    /// Returns the number of descriptors written.
    @MainActor
    static func apply(at urls: [URL], model: BQFileSystemModel) async throws -> Int {
        print("(pb) apply: starting with \(urls.count) file(s)")
        let container = try await findPosterBoardContainer(model: model)
        print("(pb) apply: container = \(container.path)")
        var written = 0

        for url in urls {
            print("(pb) apply: processing \(url.lastPathComponent)")
            let unzipDir = try unzip(url)
            defer { try? fm.removeItem(at: unzipDir) }

            let descriptors = try findDescriptors(in: unzipDir)
            guard !descriptors.isEmpty else { throw BQPosterError.noDescriptors(url) }

            for (ext, folders) in descriptors {
                print("(pb) apply: ext=\(ext), \(folders.count) folder(s)")
                for folder in folders {
                    guard folder.lastPathComponent != "__MACOSX" else { continue }
                    print("(pb) apply: randomizing id in \(folder.lastPathComponent)")
                    randomizeId(in: folder)
                    print("(pb) apply: writing descriptor to container")
                    try writeDescriptor(at: folder, container: container, ext: ext, model: model)
                    written += 1
                    print("(pb) apply: wrote descriptor #\(written)")
                }
            }
        }

        print("(pb) apply: done, \(written) descriptor(s) written")
        return written
    }

    /// Remove all installed descriptors, reverting PosterBoard to defaults.
    @MainActor
    static func reset(model: BQFileSystemModel) async throws {
        let container = try await findPosterBoardContainer(model: model)
        let root = posterExtensionsRoot(container: container)

        guard fm.fileExists(atPath: root.path) else { return }

        // Ensure extension on the root so we can list and delete
        model.ensureExtension(for: root.path)

        for ext in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let descPath = root.appendingPathComponent(ext).appendingPathComponent("descriptors")
            guard fm.fileExists(atPath: descPath.path) else { continue }

            model.ensureExtension(for: descPath.path)
            for item in (try? fm.contentsOfDirectory(atPath: descPath.path)) ?? [] {
                let itemPath = descPath.appendingPathComponent(item)
                model.ensureExtension(for: itemPath.path)
                try? fm.removeItem(at: itemPath)
            }
        }
    }

    // MARK: - ZIP extraction (no ZIPFoundation — uses libcompression)

    private static func unzip(_ url: URL) throws -> URL {
        guard let data = try? Data(contentsOf: url), data.count >= 4,
              data[0] == 0x50, data[1] == 0x4B else {
            throw BQPosterError.notZip(url)
        }

        let dest = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let extracted = try extractZip(data: data, to: dest)
        if extracted == 0 {
            throw BQPosterError.unzipFailed("ZIP contained 0 extractable entries (possible ZIP64 or corrupted CD)")
        }
        return dest
    }

    /// ZIP extractor using the ZIP Central Directory. Supports standard and
    /// ZIP64 archives. Reads stored (method 0) and deflated (method 8) entries
    /// via libcompression. Returns the number of files extracted.
    private static func extractZip(data: Data, to dest: URL) throws -> Int {
        // Find End of Central Directory record (EOCD)
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= 22 else { throw BQPosterError.unzipFailed("file too small") }

        // Search backwards for EOCD signature
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65536)
        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data[i] == eocdSig[0] && data[i+1] == eocdSig[1] &&
               data[i+2] == eocdSig[2] && data[i+3] == eocdSig[3] {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw BQPosterError.unzipFailed("EOCD not found") }

        // Parse EOCD
        var cdEntryCount = Int(data.subdata(in: eocdOffset+10..<eocdOffset+12).withUnsafeBytes {
            $0.load(as: UInt16.self).littleEndian
        })
        var cdOffset = Int(data.subdata(in: eocdOffset+16..<eocdOffset+20).withUnsafeBytes {
            Int($0.load(as: UInt32.self).littleEndian)
        })

        // Handle ZIP64: if entry count or CD offset are sentinel values,
        // read the actual values from the ZIP64 EOCD record.
        if cdEntryCount == 0xFFFF || cdOffset == 0xFFFFFFFF {
            // The ZIP64 EOCD locator sits immediately before the regular EOCD.
            let locatorOffset = eocdOffset - 20
            if locatorOffset >= 0 && locatorOffset + 20 <= data.count,
               data[locatorOffset] == 0x50, data[locatorOffset+1] == 0x4B,
               data[locatorOffset+2] == 0x06, data[locatorOffset+3] == 0x07 {
                let zip64EocdOffset = Int(data.subdata(in: locatorOffset+8..<locatorOffset+16).withUnsafeBytes {
                    Int($0.load(as: UInt64.self).littleEndian)
                })
                if zip64EocdOffset >= 0 && zip64EocdOffset + 56 <= data.count,
                   data[zip64EocdOffset] == 0x50, data[zip64EocdOffset+1] == 0x4B,
                   data[zip64EocdOffset+2] == 0x06, data[zip64EocdOffset+3] == 0x06 {
                    if cdEntryCount == 0xFFFF {
                        cdEntryCount = Int(data.subdata(in: zip64EocdOffset+32..<zip64EocdOffset+40).withUnsafeBytes {
                            Int($0.load(as: UInt64.self).littleEndian)
                        })
                    }
                    if cdOffset == 0xFFFFFFFF {
                        cdOffset = Int(data.subdata(in: zip64EocdOffset+48..<zip64EocdOffset+56).withUnsafeBytes {
                            Int($0.load(as: UInt64.self).littleEndian)
                        })
                    }
                    print("(pb) ZIP64 detected: \(cdEntryCount) entries, CD at offset \(cdOffset)")
                }
            }
        }

        print("(pb) ZIP: \(cdEntryCount) entries, CD at offset \(cdOffset), file size=\(data.count)")

        // Parse Central Directory entries
        var extractedCount = 0
        var offset = cdOffset
        for _ in 0..<cdEntryCount {
            guard offset + 46 <= data.count else {
                print("(pb) ZIP: stopped — bounds check failed at offset \(offset)")
                break
            }
            // Check CD signature
            guard data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x01, data[offset+3] == 0x02 else {
                print("(pb) ZIP: stopped — bad CD signature at offset \(offset)")
                break
            }

            let method = data.subdata(in: offset+10..<offset+12).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            }
            var compressedSize = Int(data.subdata(in: offset+20..<offset+24).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })
            var uncompressedSize = Int(data.subdata(in: offset+24..<offset+28).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })
            let nameLen = Int(data.subdata(in: offset+28..<offset+30).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            })
            let extraLen = Int(data.subdata(in: offset+30..<offset+32).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            })
            let commentLen = Int(data.subdata(in: offset+32..<offset+34).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            })
            var localHeaderOffset = Int(data.subdata(in: offset+42..<offset+46).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })

            // Read filename
            let nameData = data.subdata(in: offset+46..<offset+46+nameLen)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            // Parse ZIP64 extra field (header ID 0x0001) for actual sizes/offset
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                let extraStart = offset + 46 + nameLen
                let extraEnd = extraStart + extraLen
                var ep = extraStart
                while ep + 4 <= extraEnd {
                    let fieldId = data.subdata(in: ep..<ep+2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                    let fieldSize = Int(data.subdata(in: ep+2..<ep+4).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
                    ep += 4
                    if fieldId == 0x0001 && ep + fieldSize <= extraEnd {
                        var fp = ep
                        if uncompressedSize == 0xFFFFFFFF && fp + 8 <= extraEnd {
                            uncompressedSize = Int(data.subdata(in: fp..<fp+8).withUnsafeBytes { Int($0.load(as: UInt64.self).littleEndian) })
                            fp += 8
                        }
                        if compressedSize == 0xFFFFFFFF && fp + 8 <= extraEnd {
                            compressedSize = Int(data.subdata(in: fp..<fp+8).withUnsafeBytes { Int($0.load(as: UInt64.self).littleEndian) })
                            fp += 8
                        }
                        if localHeaderOffset == 0xFFFFFFFF && fp + 8 <= extraEnd {
                            localHeaderOffset = Int(data.subdata(in: fp..<fp+8).withUnsafeBytes { Int($0.load(as: UInt64.self).littleEndian) })
                            fp += 8
                        }
                        break
                    }
                    ep += fieldSize
                
                }
            }

            // Move to next CD entry
            offset += 46 + nameLen + extraLen + commentLen

            guard !name.isEmpty else { continue }

            // Security: prevent path traversal — reject absolute paths and
            // ".." components. (We don't use standardizedFileURL prefix
            // comparison because iOS resolves /var → /private/var inconsistently
            // for existing vs non-existing paths, causing false positives.)
            guard !name.hasPrefix("/"),
                  !name.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
                print("(pb) ZIP: skipping path-traversal entry: \(name)")
                continue
            }

            let isDirectory = name.hasSuffix("/")
            let outputPath = dest.appendingPathComponent(name)

            if isDirectory {
                try? fm.createDirectory(at: outputPath, withIntermediateDirectories: true)
                continue
            }

            // Read local file header to find actual data offset
            guard localHeaderOffset + 30 <= data.count else {
                print("(pb) ZIP: skipping \(name) — local header out of bounds")
                continue
            }
            guard data[localHeaderOffset] == 0x50, data[localHeaderOffset+1] == 0x4B,
                  data[localHeaderOffset+2] == 0x03, data[localHeaderOffset+3] == 0x04 else {
                print("(pb) ZIP: skipping \(name) — bad local header signature")
                continue
            }

            let localNameLen = Int(data.subdata(in: localHeaderOffset+26..<localHeaderOffset+28).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            })
            let localExtraLen = Int(data.subdata(in: localHeaderOffset+28..<localHeaderOffset+30).withUnsafeBytes {
                $0.load(as: UInt16.self).littleEndian
            })
            let dataOffset = localHeaderOffset + 30 + localNameLen + localExtraLen

            guard dataOffset + compressedSize <= data.count else {
                print("(pb) ZIP: skipping \(name) — data out of bounds")
                continue
            }
            let compressedData = data.subdata(in: dataOffset..<dataOffset+compressedSize)

            // Create parent directories
            let parentDir = outputPath.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Decompress based on method
            let outputData: Data
            switch method {
            case 0: // Stored (no compression)
                outputData = compressedData
            case 8: // Deflate
                outputData = try inflate(compressedData, expectedSize: uncompressedSize)
            default:
                print("(pb) ZIP: skipping \(name) — unsupported method \(method)")
                continue
            }

            try outputData.write(to: outputPath)
            extractedCount += 1
        }

        print("(pb) ZIP: extracted \(extractedCount)/\(cdEntryCount) files")
        return extractedCount
    }

    /// Inflate raw DEFLATE data using libz (via bq_inflate_raw).
    /// ZIP stores raw deflate (RFC 1951) without a zlib wrapper, so we
    /// use inflateInit2 with windowBits = -15 for raw mode.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        let result: Data? = data.withUnsafeBytes { srcBuf -> Data? in
            guard let srcPtr = srcBuf.baseAddress else { return nil }
            var outSize: Int = 0
            guard let outPtr = bq_inflate_raw(srcPtr.assumingMemoryBound(to: UInt8.self),
                                               data.count, expectedSize, &outSize) else {
                return nil
            }
            let result = Data(bytes: outPtr, count: outSize)
            free(outPtr)
            return result
        }

        guard let result = result, !result.isEmpty else {
            throw BQPosterError.unzipFailed("deflate decompression failed")
        }
        return result
    }

    // MARK: - Descriptor discovery

    private static func findDescriptors(in root: URL) throws -> [String: [URL]] {
        var result: [String: [URL]] = [:]

        let top = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        print("(pb) findDescriptors: top-level = \(top.map { $0.lastPathComponent })")

        // Layout 1: "container/" mirrors the PosterBoard Extensions structure
        if let container = top.first(where: { $0.lastPathComponent.lowercased() == "container" }) {
            let extDir = posterExtensionsRoot(container: container)
            print("(pb) findDescriptors: container layout, extDir exists=\(fm.fileExists(atPath: extDir.path))")

            if fm.fileExists(atPath: extDir.path) {
                for ext in try fm.contentsOfDirectory(at: extDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let d = ext.appendingPathComponent("descriptors")
                    if fm.fileExists(atPath: d.path) {
                        result[ext.lastPathComponent, default: []].append(contentsOf: descriptorFolders(in: d))
                    }
                }
                print("(pb) findDescriptors: layout 1 found \(result.count) extensions")
                return result
            }
        }

        // Layout 2: top-level "descriptors/" or "video-descriptors/" folders
        for dir in top {
            switch dir.lastPathComponent.lowercased() {
            case "video-descriptor", "video-descriptors":
                result[photosExt, default: []].append(contentsOf: descriptorFolders(in: dir))
            case "descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors":
                result[collectionsExt, default: []].append(contentsOf: descriptorFolders(in: dir))
            default:
                continue
            }
        }

        if !result.isEmpty {
            print("(pb) findDescriptors: layout 2 found \(result.count) extensions")
            return result
        }

        // Layout 3: deep search for descriptor-like directories
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var checked = 0
            for case let dir as URL in enumerator {
                guard dir.lastPathComponent != "__MACOSX",
                      (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                checked += 1

                if isDescriptorContainer(dir) {
                    let ext = dir.lastPathComponent.lowercased().hasPrefix("video") ? photosExt : collectionsExt
                    result[ext, default: []].append(contentsOf: descriptorFolders(in: dir))
                } else if isDescriptor(dir) {
                    let ext = dir.lastPathComponent.lowercased().hasPrefix("video") ? photosExt : collectionsExt
                    result[ext, default: []].append(dir)
                }
            }
            print("(pb) findDescriptors: layout 3 checked \(checked) dirs, found \(result.count) extensions")
        }

        if result.isEmpty {
            print("(pb) findDescriptors: WARNING — no descriptors found in any layout!")
        }
        return result
    }

    private static func descriptorFolders(in dir: URL) -> [URL] {
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return []
        }
        return children.filter { $0.lastPathComponent != "__MACOSX" }
    }

    private static func isDescriptorContainer(_ dir: URL) -> Bool {
        switch dir.lastPathComponent.lowercased() {
        case "descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors",
             "video-descriptor", "video-descriptors":
            return true
        default:
            return false
        }
    }

    private static func isDescriptor(_ dir: URL) -> Bool {
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return false
        }
        return children.contains { $0.lastPathComponent == "com.apple.posterkit.provider.descriptor.identifier" }
    }

    // MARK: - Write

    @MainActor
    private static func writeDescriptor(at src: URL, container: URL, ext: String, model: BQFileSystemModel) throws {
        let destDir = descriptorsUrl(container: container, ext: ext)
        let destUrl = destDir.appendingPathComponent(UUID().uuidString)
        print("(pb) write: destDir = \(destDir.path)")
        print("(pb) write: destUrl = \(destUrl.path)")

        // Activate extension for destDir (may already exist from prior runs)
        let h1 = model.ensureExtension(for: destDir.path)
        print("(pb) write: ext destDir=\(h1)")

        if !fm.fileExists(atPath: destDir.path) {
            print("(pb) write: creating destDir")
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            // Re-activate after creation (force bypasses stale cache)
            _ = model.ensureExtension(for: destDir.path, force: true)
        }
        if fm.fileExists(atPath: destUrl.path) {
            try? fm.removeItem(at: destUrl)
        }

        // copyDescriptorTree will create destUrl and activate its extension
        // after creation, so no need to pre-activate here.
        print("(pb) write: copying tree from \(src.lastPathComponent)")
        try copyDescriptorTree(at: src, to: destUrl, model: model)
        print("(pb) write: done")
    }

    @MainActor
    private static func copyDescriptorTree(at src: URL, to dst: URL, model: BQFileSystemModel) throws {
        // Create directory FIRST, then activate extension on it (force=true to
        // bypass any stale cached handle from before the directory existed).
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let h = model.ensureExtension(for: dst.path, force: true)
        print("(pb) copy: dst=\(dst.lastPathComponent), ext handle=\(h)")

        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        print("(pb) copy: \(children.count) children in \(src.lastPathComponent)")
        for child in children {
            let dest = dst.appendingPathComponent(child.lastPathComponent)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDir)

            if isDir.boolValue {
                try copyDescriptorTree(at: child, to: dest, model: model)
            } else {
                // Only authorize the parent directory (dst), NOT the file path.
                // bad_query extensions for non-existent paths don't grant create
                // permission. The parent directory's extension allows child creation.
                // (This matches createItem's pattern in BQFileSystem.swift.)
                guard let data = fm.contents(atPath: child.path) else {
                    print("(pb) copy: WARNING — could not read \(child.lastPathComponent)")
                    continue
                }
                if !fm.createFile(atPath: dest.path, contents: data) {
                    print("(pb) copy: ERROR creating \(dest.lastPathComponent)")
                    throw BQPosterError.unzipFailed("failed to create \(dest.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - ID randomization

    private static func randomizeId(in url: URL) {
        let id = Int.random(in: 9999...99999)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        for case let file as URL in enumerator {
            switch file.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try? String(id).data(using: .utf8)?.write(to: file)
            case "com.apple.posterkit.provider.contents.userInfo":
                setPlistVal(key: "wallpaperRepresentingIdentifier", value: id, at: file)
            case "Wallpaper.plist":
                setPlistVal(key: "identifier", value: id, at: file)
            default:
                break
            }
        }
    }

    private static func setPlistVal(key: String, value: Any, at file: URL) {
        guard let data = fm.contents(atPath: file.path),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
        plist[key] = value
        guard let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? updated.write(to: file)
    }
}
