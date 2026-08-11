//
//  BQAppListView.swift
//  bad_query
//
//  Lists installed apps by bundle ID; tapping enters the app's data container.
//

import SwiftUI

struct BQAppEntry: Identifiable, Hashable {
    let path: String
    let bundleId: String
    let uuid: String
    var id: String { path }
}

struct BQAppListView: View {
    @Environment(BQFileSystemModel.self) private var model
    @State private var searchText = ""
    @State private var hasLoaded = false

    private static let appRoot = "/var/mobile/Containers/Data/Application"

    private var apps: [BQAppEntry] {
        model.items.compactMap { item in
            guard item.isDirectory else { return nil }
            // subtitle is the bundle ID, set by resolveContainerMetadata
            let bundleId = item.subtitle ?? "(unknown)"
            return BQAppEntry(path: item.path, bundleId: bundleId, uuid: item.name)
        }
    }

    private var filteredApps: [BQAppEntry] {
        guard !searchText.isEmpty else { return apps }
        let q = searchText.lowercased()
        return apps.filter {
            $0.bundleId.lowercased().contains(q) || $0.uuid.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if model.isLoading && apps.isEmpty {
                HStack {
                    ProgressView()
                    Text("Resolving app containers…")
                        .foregroundStyle(.secondary)
                }
            } else if filteredApps.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "app.dashed")
                } description: {
                    Text(model.lastError ?? "No app containers accessible.")
                } actions: {
                    Button("Retry") {
                        hasLoaded = false
                        loadApps()
                    }
                }
            } else {
                ForEach(filteredApps) { app in
                    NavigationLink {
                        BQDirectoryView(path: app.path)
                    } label: {
                        appRow(app)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Filter by bundle ID")
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hasLoaded = false
                    loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { loadApps() }
    }

    private func loadApps() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // App containers live across a wide inode range; raise the scan ceiling
        // so apps with high-inode UUID directories (e.g. WeChat) are included.
        model.maxInode = 1_500_000
        model.load(Self.appRoot, allowMHA: false)
    }

    @ViewBuilder
    private func appRow(_ app: BQAppEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.bundleId)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.uuid)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}
