//
//  BQPosterView.swift
//  bad_query
//
//  PosterBoard wallpaper UI — import .tendies/.zip packs and apply them.
//

import SwiftUI
import UniformTypeIdentifiers
import SafariServices

struct BQPosterView: View {
    @EnvironmentObject var state: AppState
    @Environment(BQFileSystemModel.self) private var model

    @State private var showImporter = false
    @State private var showBrowser = false
    @State private var busy = false
    @State private var posterFiles: [URL] = []
    @State private var resultAlert: ResultAlert?

    struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let body: String
        var actionLabel: String? = nil
        var action: (() -> Void)? = nil
    }

    var body: some View {
        List {
            Section {
                Button {
                    apply()
                } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text("Apply")
                    }
                }
                .disabled(posterFiles.isEmpty || busy)

                Button {
                    reset()
                } label: {
                    Text("Reset")
                }
                .disabled(busy)
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Tendies", systemImage: "square.and.arrow.down")
                }
                .disabled(busy)

                Button {
                    showBrowser = true
                } label: {
                    Label("Browse Wallpapers", systemImage: "photo.grid")
                }
                .disabled(busy)
            } footer: {
                Text("Pick one or more .tendies (or .zip) wallpaper packs, or browse and download from the community library.")
            }

            if !posterFiles.isEmpty {
                Section {
                    ForEach(posterFiles, id: \.self) { url in
                        Text(url.lastPathComponent)
                    }
                    .onDelete { offsets in
                        posterFiles.remove(atOffsets: offsets)
                    }
                } header: {
                    Label("Imported", systemImage: "document.on.document")
                }
            }
        }
        .navigationTitle("PosterBoard")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    // Security-scoped URLs from fileImporter are only valid
                    // during the callback. Copy to temp dir for persistent access.
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                        posterFiles.append(dest)
                    } else {
                        // Fallback: try the original URL (may work on jailbroken devices)
                        posterFiles.append(url)
                    }
                }
            case .failure:
                break
            }
        }
        .alert(item: $resultAlert) { alert in
            if let action = alert.action, let label = alert.actionLabel {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.body),
                    primaryButton: .default(Text(label), action: action),
                    secondaryButton: .cancel()
                )
            } else {
                return Alert(title: Text(alert.title), message: Text(alert.body))
            }
        }
        .sheet(isPresented: $showBrowser) {
            NavigationStack {
                BQWallpaperBrowserView { url in
                    posterFiles.append(url)
                }
            }
        }
    }

    private func apply() {
        busy = true
        Task { @MainActor in
            do {
                let count = try await BQPoster.apply(at: posterFiles, model: model)
                busy = false
                resultAlert = ResultAlert(
                    title: "Successfully applied PosterBoard!",
                    body: "Respring your device for changes to take effect.",
                    actionLabel: "Respring",
                    action: { state.respring() }
                )
            } catch {
                busy = false
                resultAlert = ResultAlert(
                    title: "Failed to apply PosterBoard!",
                    body: error.localizedDescription
                )
            }
        }
    }

    private func reset() {
        busy = true
        Task { @MainActor in
            do {
                try await BQPoster.reset(model: model)
                busy = false
                resultAlert = ResultAlert(
                    title: "Successfully reverted PosterBoard!",
                    body: "Respring your device for changes to take effect.",
                    actionLabel: "Respring",
                    action: { state.respring() }
                )
            } catch {
                busy = false
                resultAlert = ResultAlert(
                    title: "Failed to revert PosterBoard!",
                    body: error.localizedDescription
                )
            }
        }
    }
}
