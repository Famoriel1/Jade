//
//  BQWallpaperBrowserView.swift
//  bad_query
//
//  Browse and download .tendies wallpaper packs from the community repo.
//

import SwiftUI

struct BQWallpaperBrowserView: View {
    @State private var wallpapers: [BQWallpaper] = []
    @State private var selectedType: BQWallpaper.WallpaperType = .custom
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var downloadingIds: Set<Int> = []
    @State private var downloadedIds: Set<Int> = []
    @State private var downloadedFiles: [URL] = []
    @State private var resultAlert: ResultAlert?
    @State private var searchText = ""

    /// Callback invoked when wallpapers are downloaded — the parent adds
    /// them to the import list.
    var onDownloaded: ((URL) -> Void)? = nil

    struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let body: String
        var actionLabel: String? = nil
        var action: (() -> Void)? = nil
    }

    private var filteredWallpapers: [BQWallpaper] {
        guard !searchText.isEmpty else { return wallpapers }
        let q = searchText.lowercased()
        return wallpapers.filter {
            $0.name.lowercased().contains(q) ||
            ($0.authors ?? "").lowercased().contains(q) ||
            ($0.description ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                BQWallpaperTypePicker(selected: $selectedType)
                    .padding(.horizontal, 12)

                if wallpapers.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Wallpapers",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(loadError ?? "Pull to refresh or try another category.")
                    )
                    .frame(minHeight: 200)
                }

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(filteredWallpapers) { wallpaper in
                        wallpaperCard(wallpaper)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Browse Wallpapers")
        .searchable(text: $searchText, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !downloadedFiles.isEmpty {
                    Button("Done (\(downloadedFiles.count))") {
                        for url in downloadedFiles {
                            onDownloaded?(url)
                        }
                        downloadedFiles.removeAll()
                    }
                }
            }
        }
        .refreshable {
            BQWallpaperAPI.clearCache()
            await loadWallpapers()
        }
        .task {
            await loadWallpapers()
        }
        .onChange(of: selectedType) { _, _ in
            Task { await loadWallpapers() }
        }
        .alert(item: $resultAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.body))
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    @ViewBuilder
    private func wallpaperCard(_ wallpaper: BQWallpaper) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                previewImage(wallpaper)

                if let contest = wallpaper.contest {
                    Text(contest)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let authors = wallpaper.authors, !authors.isEmpty {
                    Text(authors)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let desc = wallpaper.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            downloadButton(wallpaper)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func previewImage(_ wallpaper: BQWallpaper) -> some View {
        WallpaperPreviewCell(wallpaper: wallpaper)
    }

    @ViewBuilder
    private func downloadButton(_ wallpaper: BQWallpaper) -> some View {
        let isDownloading = downloadingIds.contains(wallpaper.id)
        let isDownloaded = downloadedIds.contains(wallpaper.id)

        Button {
            Task { await download(wallpaper) }
        } label: {
            HStack {
                Spacer()
                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(isDownloaded ? "Downloaded" : (isDownloading ? "Downloading" : "Download"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(isDownloaded ? Color.green.opacity(0.1) : Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(isDownloading || isDownloaded)
    }

    private func loadWallpapers() async {
        isLoading = true
        loadError = nil
        do {
            wallpapers = try await BQWallpaperAPI.fetchWallpapers(type: selectedType)
        } catch {
            loadError = error.localizedDescription
            wallpapers = []
        }
        isLoading = false
    }

    private func download(_ wallpaper: BQWallpaper) async {
        downloadingIds.insert(wallpaper.id)
        do {
            let url = try await BQWallpaperAPI.downloadTendies(wallpaper)
            downloadedFiles.append(url)
            downloadedIds.insert(wallpaper.id)
            onDownloaded?(url)
        } catch {
            resultAlert = ResultAlert(
                title: "Download Failed",
                body: error.localizedDescription
            )
        }
        downloadingIds.remove(wallpaper.id)
    }
}

// MARK: - Preview Cell (async GIF/image load)

struct WallpaperPreviewCell: View {
    let wallpaper: BQWallpaper
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .font(.title)
                    }
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .task {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        do {
            let previewURL = try await BQWallpaperAPI.previewURL(for: wallpaper)
            let (data, response) = try await URLSession.shared.data(from: previewURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                loadFailed = true
                return
            }
            if let img = UIImage(data: data) {
                image = img
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - Type Picker

struct BQWallpaperTypePicker: View {
    @Binding var selected: BQWallpaper.WallpaperType

    var body: some View {
        Picker("Type", selection: $selected) {
            ForEach(BQWallpaper.WallpaperType.allCases, id: \.self) { type in
                Label(type.displayName, systemImage: type.iconName)
                    .tag(type)
            }
        }
        .pickerStyle(.segmented)
    }
}
