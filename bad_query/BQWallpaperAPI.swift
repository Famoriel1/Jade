//
//  BQWallpaperAPI.swift
//  bad_query
//
//  Fetches and downloads .tendies wallpaper packs from the
//  SerStars/nugget-wallpapers GitHub repository.
//

import Foundation

// MARK: - Models

struct BQWallpaper: Identifiable, Codable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var url: String
    var preview: String
    var authors: String?
    var contest: String?

    enum WallpaperType: String, CaseIterable, Codable {
        case custom
        case apple
        case template

        var displayName: String {
            switch self {
            case .custom: return "Custom"
            case .apple: return "Apple"
            case .template: return "Templates"
            }
        }

        var iconName: String {
            switch self {
            case .custom: return "sparkles"
            case .apple: return "applelogo"
            case .template: return "paintbrush"
            }
        }
    }

    var type: WallpaperType?
}

// MARK: - API

enum BQWallpaperAPI {
    /// GitHub repo that hosts the wallpaper manifests and files.
    private static let repoOwner = "SerStars"
    private static let repoName = "nugget-wallpapers"
    private static let defaultBranch = "main"

    /// Cached commit hash so we resolve to a stable raw URL. The repo uses
    /// raw.githubusercontent.com which doesn't follow redirects, so we need
    /// the exact commit SHA.
    private static var cachedHash: String?

    /// Resolve the base URL for raw file access. Uses the cached commit hash
    /// if available, otherwise falls back to the default branch name.
    static func baseURL() async -> URL {
        let hash = (try? await getCommitHash()) ?? defaultBranch
        return URL(string: "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/\(hash)/")!
    }

    /// Get the latest commit hash from the GitHub API for stable raw URLs.
    static func getCommitHash() async throws -> String {
        if let cachedHash { return cachedHash }
        let hash = try await fetchCommitHash()
        cachedHash = hash
        return hash
    }

    /// Fetch the commit hash from the GitHub API (uncached).
    private static func fetchCommitHash() async throws -> String {
        let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/commits/\(defaultBranch)")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // GitHub API requires a User-Agent
        request.setValue("BQTools", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return sha
    }

    /// Clear the cached commit hash so the next fetch re-resolves to HEAD.
    static func clearCache() {
        cachedHash = nil
    }

    /// Fetch the wallpaper manifest for a given type.
    static func fetchWallpapers(type: BQWallpaper.WallpaperType) async throws -> [BQWallpaper] {
        let base = await baseURL()
        let manifestURL = base.appendingPathComponent("wallpapers-\(type.rawValue).json")

        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.fileDoesNotExist)
        }

        var wallpapers = try JSONDecoder().decode([BQWallpaper].self, from: data)
        for i in wallpapers.indices {
            wallpapers[i].type = type
        }
        // Newest first (manifest is oldest-first)
        return wallpapers.reversed()
    }

    /// Get the download URL for a wallpaper's .tendies file.
    static func downloadURL(for wallpaper: BQWallpaper) async -> URL {
        let base = await baseURL()
        if wallpaper.url.hasPrefix("https://") {
            return URL(string: wallpaper.url)!
        }
        return base.appendingPathComponent(wallpaper.url)
    }

    /// Get the preview URL for a wallpaper (GIF thumbnail).
    static func previewURL(for wallpaper: BQWallpaper) async -> URL {
        let base = await baseURL()
        return base.appendingPathComponent(wallpaper.preview)
    }

    /// Download a .tendies file to the app's temporary directory.
    /// Returns the local URL of the downloaded file.
    static func downloadTendies(_ wallpaper: BQWallpaper) async throws -> URL {
        let url = try await downloadURL(for: wallpaper)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.fileDoesNotExist)
        }

        // Move to a named file so the import shows a meaningful filename.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(wallpaper.name + ".tendies")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
