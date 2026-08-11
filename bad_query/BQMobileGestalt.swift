//
//  BQMobileGestalt.swift
//  bad_query
//
//  MobileGestalt.plist tweaking engine built on the bad_query sandbox escape.
//  Ported from mond's ContentView logic, using bad_query for sandbox access.
//

import Foundation
import Observation
import SwiftUI
import UIKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Alert Info

struct MGAlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    var actionLabel: String?
    var action: (() -> Void)?
}

// MARK: - Toggle Info Type

enum MGToggleInfoType {
    case info
    case warning
}

// MARK: - Model

@MainActor
@Observable
final class BQMobileGestaltModel {
    // Gestalt state
    var mgDict: NSMutableDictionary = [:]
    var gestaltPath: String = ""
    var hasExtension: Bool = false
    var isValid: Bool = false
    var isEmpty: Bool = false
    var ogSubtype: Int = 0
    var ogDeviceName: String = ""
    var subtype: Int = 0
    var enableDeviceName: Bool = false
    var lastReadFormat: PropertyListSerialization.PropertyListFormat = .binary
    var productType: String = ""
    var loaded: Bool = false

    // UI state
    var statusMessage: String = "Tap Load to begin"
    var lastError: String?
    var log: [String] = []
    var alertInfo: MGAlertInfo?
    var extensionHandle: Int64 = 0
    var isApplying = false

    // Paths
    static let systemGroupRoot = "/var/containers/Shared/SystemGroup"
    static let gestaltContainerName = "systemgroup.com.apple.mobilegestaltcache"
    static let gestaltRelativePath = "Library/Caches/com.apple.MobileGestalt.plist"

    var backupURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("GestaltBackups")
        return dir.appendingPathComponent("SavedGestalt.plist")
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func appendLog(_ message: String) {
        log.append("[\(Self.logFormatter.string(from: Date()))] \(message)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Path Discovery

    /// Scan SystemGroup containers to find the MobileGestalt cache plist.
    func discoverGestaltPath() -> String? {
        // Try hardcoded path first
        let knownPath = "\(Self.systemGroupRoot)/\(Self.gestaltContainerName)/\(Self.gestaltRelativePath)"
        if FileManager.default.fileExists(atPath: knownPath) {
            appendLog("gestalt found at hardcoded path")
            return knownPath
        }

        // Scan SystemGroup root
        guard grantExtension(for: Self.systemGroupRoot) else {
            appendLog("cannot scan SystemGroup root - no extension")
            return nil
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: Self.systemGroupRoot) else {
            appendLog("cannot list SystemGroup root")
            return nil
        }

        for entry in entries where entry.contains("mobilegestaltcache") {
            let candidate = "\(Self.systemGroupRoot)/\(entry)/\(Self.gestaltRelativePath)"
            if FileManager.default.fileExists(atPath: candidate) {
                appendLog("gestalt found via scan: \(entry)")
                return candidate
            }
        }

        appendLog("gestalt container not found in SystemGroup")
        return nil
    }

    // MARK: - Sandbox Extension

    @discardableResult
    func grantExtension(for path: String) -> Bool {
        if path == gestaltPath && extensionHandle > 0 {
            hasExtension = true
            return true
        }

        var cPath = path.utf8CString.map { Int8($0) }
        var handle = bad_query(&cPath, true, nil, false)
        var route = "system"

        if handle < 0 {
            // Fallback: App Group sacrifice route (iOS 26)
            var cGroup = BQFileSystemModel.appGroupIdentifier.utf8CString.map { Int8($0) }
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
            extensionHandle = handle
            hasExtension = true
            appendLog("extension \(handle) acquired (\(route) route) for \(path)")
            statusMessage = "Sandbox extension active"
            return true
        } else {
            hasExtension = false
            lastError = "bad_query returned \(handle) for \(path)"
            appendLog("extension failed (\(handle)) for \(path)")
            return false
        }
    }

    // MARK: - Load

    func load() {
        // Discover path
        guard let path = discoverGestaltPath() else {
            alertInfo = MGAlertInfo(title: "Not Found", body: "MobileGestalt.plist was not found. This tool requires iOS 27 for SystemGroup access, or iOS 26 with App Group sacrifice.")
            statusMessage = "Gestalt plist not found"
            return
        }
        gestaltPath = path

        // Get sandbox extension for the container
        let containerPath = String(path.prefix(path.range(of: "/Library/")?.lowerBound.utf16Offset(in: path) ?? path.count))
        guard grantExtension(for: containerPath) else {
            alertInfo = MGAlertInfo(title: "Sandbox Escape Failed", body: "Could not get a sandbox extension for the MobileGestalt container (error \(extensionHandle)). The container may not be accessible on this iOS version.")
            statusMessage = "Extension failed"
            return
        }

        do {
            let url = URL(fileURLWithPath: path)

            // Validate
            let rawData = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            isValid = (try? PropertyListSerialization.propertyList(from: rawData, options: [], format: &format)) != nil
            isEmpty = rawData.isEmpty || (rawData.count < 10)
            lastReadFormat = format

            // Load plist
            mgDict = try NSMutableDictionary(contentsOf: url, error: ())
            loaded = true

            // Create backup
            let backupDir = backupURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: url, to: backupURL)
                appendLog("backup created at \(backupURL.path)")
            }

            // Get original values from backup
            let savedDict = try NSMutableDictionary(contentsOf: backupURL, error: ())
            let ogCacheExtra = savedDict["CacheExtra"] as? NSMutableDictionary ?? [:]
            let ogArtwork = ogCacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? [:]

            guard let ogSub = ogArtwork["ArtworkDeviceSubType"] as? Int else {
                lastError = "Failed to get ArtworkDeviceSubType from backup"
                appendLog("error: no ArtworkDeviceSubType in backup")
                return
            }
            ogSubtype = ogSub
            subtype = ogSub

            guard let ogName = ogArtwork["ArtworkDeviceProductDescription"] as? String else {
                lastError = "Failed to get ArtworkDeviceProductDescription from backup"
                appendLog("error: no ArtworkDeviceProductDescription in backup")
                return
            }
            ogDeviceName = ogName

            // Get current values
            let cacheExtra = mgDict["CacheExtra"] as? NSMutableDictionary ?? [:]
            let artwork = cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? [:]
            subtype = artwork["ArtworkDeviceSubType"] as? Int ?? ogSub
            let currentName = artwork["ArtworkDeviceProductDescription"] as? String ?? ogName
            enableDeviceName = (currentName != ogName)

            if let pt = cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String, !pt.isEmpty {
                productType = pt
            } else {
                productType = machineName()
            }

            statusMessage = "MobileGestalt loaded"
            appendLog("gestalt loaded — subtype=\(ogSub), device=\(ogName)")
        } catch {
            lastError = "Failed to load: \(error.localizedDescription)"
            alertInfo = MGAlertInfo(title: "Failed to load MobileGestalt!", body: "Restart the app and try again. Check logs for details.")
            appendLog("load error: \(error)")
        }
    }

    // MARK: - Apply

    func apply() {
        isApplying = true
        do {
            let cacheExtra = mgDict["CacheExtra"] as? NSMutableDictionary ?? NSMutableDictionary()
            mgDict["CacheExtra"] = cacheExtra

            if !productType.isEmpty {
                cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] = productType
            }

            let artwork = cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? NSMutableDictionary()
            cacheExtra["oPeik/9e8lQWMszEjbPzng"] = artwork
            artwork["ArtworkDeviceSubType"] = subtype
            if enableDeviceName {
                artwork["ArtworkDeviceProductDescription"] = customDeviceName
            }

            let data = try PropertyListSerialization.data(fromPropertyList: mgDict, format: lastReadFormat, options: 0)
            try write(data)

            statusMessage = "Tweaks applied — reboot to take effect"
            appendLog("applied gestalt tweaks (\(data.count) bytes)")
            alertInfo = MGAlertInfo(
                title: "Successfully applied Gestalt tweaks!",
                body: "Reboot your device for changes to take effect.",
                actionLabel: "Reboot",
                action: { self.respring() }
            )
        } catch {
            appendLog("apply error: \(error)")
            alertInfo = MGAlertInfo(title: "Failed to apply MobileGestalt!", body: "Check logs for error information.")
        }
        isApplying = false
    }

    // MARK: - Revert

    func revert() {
        do {
            let backupData = try Data(contentsOf: backupURL)
            try write(backupData)
            statusMessage = "Reverted — reboot to take effect"
            appendLog("reverted gestalt from backup")
            alertInfo = MGAlertInfo(title: "Successfully reverted Gestalt tweaks!", body: "Reboot your device for changes to take effect.")
            // Reload current values
            load()
        } catch {
            appendLog("revert error: \(error)")
            alertInfo = MGAlertInfo(title: "Failed to revert MobileGestalt!", body: "Check logs for error information.")
        }
    }

    // MARK: - Write (in-place fd overwrite, same inode)

    private func write(_ data: Data) throws {
        let targetPath = gestaltPath

        // Read original for rollback
        let original = FileManager.default.contents(atPath: targetPath)

        // Open the original file in-place (O_NOFOLLOW prevents symlink hijacking)
        let fd = targetPath.withCString { path in
            open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw BQError.io("Failed to open plist for in-place write (errno=\(errno))")
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
            throw BQError.io("Failed to write plist in-place (errno=\(errno))")
        }

        // Verify
        if let verification = FileManager.default.contents(atPath: targetPath),
           verification != data {
            throw BQError.io("Post-write verification failed")
        }

        appendLog("wrote \(data.count) bytes in-place to \(targetPath)")
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

    // MARK: - Device Name Persistence

    /// Stored in UserDefaults so the custom name persists across launches.
    var customDeviceName: String {
        get { UserDefaults.standard.string(forKey: "mg_devicename") ?? ogDeviceName }
        set { UserDefaults.standard.set(newValue, forKey: "mg_devicename") }
    }

    // MARK: - cache_data_offset

    func cacheDataOffset(_ key: String) -> Int {
        guard let cacheKeys = mgDict["CacheKeys"] as? [String] else { return -1 }
        guard let index = cacheKeys.firstIndex(of: key) else { return -1 }
        return index * MemoryLayout<Int>.size
    }

    // MARK: - Bindings

    func keyBinding<T: Equatable>(
        _ keys: [String],
        type: T.Type = Int.self,
        defaultVal: T? = 0,
        onVal: T? = 1
    ) -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            if let value = cacheExtra[keys.first!] as? T, let onVal {
                return value == onVal
            }
            return false
        }, set: { [weak self] enabled in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            for key in keys {
                if enabled {
                    cacheExtra[key] = onVal
                } else {
                    cacheExtra.removeObject(forKey: key)
                }
            }
        })
    }

    func trollpadBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            return (cacheExtra["uKc7FPnEO++lVhHWHFlGbQ"] as? Int) == 1
        }, set: { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.alertInfo = MGAlertInfo(
                    title: "Warning!",
                    body: "This is a very dangerous tweak! If you use an alphanumeric passcode, DO NOT USE THIS! Do not turn off \"Show Dock In Stage Manager\" or your device will BOOTLOOP in landscape! You may experience general instability or data loss."
                )
            }
            guard let cacheData = self.mgDict["CacheData"] as? NSMutableData,
                  let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            let valueOff = self.cacheDataOffset("mtrAoWJ3gsq+I90ZnQ0vQw")
            let keys = [
                "uKc7FPnEO++lVhHWHFlGbQ",
                "mG0AnH/Vy1veoqoLRAIgTA",
                "UCG5MkVahJxG1YULbbd5Bg",
                "ZYqko/XM5zD3XBfN5RmaXA",
                "nVh/gwNpy7Jv1NOk00CMrw",
                "qeaj75wk3HF4DwQ8qbIi7g",
            ]
            cacheData.mutableBytes.storeBytes(of: enabled ? 3 : 1, toByteOffset: valueOff, as: Int.self)
            for key in keys {
                if enabled {
                    cacheExtra[key] = 1
                } else {
                    cacheExtra.removeObject(forKey: key)
                }
            }
        })
    }

    func regionRestrictBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            return (cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String) == "US" &&
                   (cacheExtra["zHeENZu+wbg7PUprwNwBWg"] as? String) == "LL/A"
        }, set: { [weak self] enabled in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            if enabled {
                self.alertInfo = MGAlertInfo(
                    title: "Warning!",
                    body: "Do not use this to bypass region restrictions that would violate local laws. We are not responsible for any illegal activities."
                )
                cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] = "US"
                cacheExtra["zHeENZu+wbg7PUprwNwBWg"] = "LL/A"
            } else {
                cacheExtra.removeObject(forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                cacheExtra.removeObject(forKey: "zHeENZu+wbg7PUprwNwBWg")
            }
        })
    }

    func internalBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheData = self.mgDict["CacheData"] as? NSMutableData else { return false }
            let off = self.cacheDataOffset("EqrsVvjcYDdxHBiQmGhAWw")
            guard off >= 0, off < cacheData.length else { return false }
            return cacheData.bytes.load(fromByteOffset: off, as: Int.self) == 1
        }, set: { [weak self] enabled in
            guard let self, let cacheData = self.mgDict["CacheData"] as? NSMutableData else { return }
            let offsets = [
                self.cacheDataOffset("EqrsVvjcYDdxHBiQmGhAWw"),
                self.cacheDataOffset("Oji6HRoPi7rH7HPdWVakuw"),
                self.cacheDataOffset("LBJfwOEzExRxzlAnSuI7eg"),
            ]
            for off in offsets where off >= 0 && off < cacheData.length {
                cacheData.mutableBytes.storeBytes(of: enabled ? 1 : 0, toByteOffset: off, as: Int.self)
            }
        })
    }

    // MARK: - Device Helpers

    func machineName() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        let mirror = Mirror(reflecting: sysInfo.machine)
        return mirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }
    }

    func doubleSystemVersion() -> Double {
        Double(UIDevice.current.systemVersion) ?? 0
    }

    func hasHomeButton() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let bottom = scene?.windows.first?.safeAreaInsets.bottom ?? 0
        return bottom == 0
    }

    func isDeviceGood() -> Bool {
        let supported: [String] = [
            "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
            "iPhone16,1", "iPhone16,2",
            "iPhone17,3", "iPhone17,4", "iPhone17,1", "iPhone17,2",
            "iPhone18,3", "iPhone18,1", "iPhone18,2", "iPhone17,5",
        ]
        return supported.contains(machineName()) && doubleSystemVersion() < 19.0
    }

    // MARK: - Respring

    func respring() {
        guard let url = URL(string: "shortcuts://run-shortcut?name=reboot"), UIApplication.shared.canOpenURL(url) else {
                print("Can't Open URL: \("shortcuts://run-shortcut?name=reboot")")
                return
            }
            UIApplication.shared.open(url, options: [:]) { success in
                if !success { print("No shortcut") }
            }
    }
}
