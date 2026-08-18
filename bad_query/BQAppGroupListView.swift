//
//  BQAppGroupListView.swift
//  bad_query
//
//  Lists installed apps by bundle ID; tapping enters the app's data container.
//

import SwiftUI


struct BQAppGroupListView: View {
    @Environment(BQFileSystemModel.self) private var model
    @EnvironmentObject private var states: AppState
    @State private var searchText = ""
    @State private var hasLoaded = false

    /// Resolved display names, keyed by bundle ID. Filled progressively by
    /// resolveNames() as bundle IDs appear in the container metadata.
    @State private var names: [String: String] = [:]
    /// Bundle IDs already handed to the resolver (hit or miss), so each ID is
    /// only queried once per view lifetime.
    @State private var requested: Set<String> = []

    private static let appRoot = "/var/mobile/Containers/Shared/AppGroup"

    private var apps: [BQAppEntry] {
        model.items.compactMap { item in
            guard item.isDirectory else { return nil }
            // subtitle is the bundle ID, set by resolveContainerMetadata
            let bundleId = item.subtitle ?? "(unknown)"
            return BQAppEntry(path: item.path, bundleId: bundleId, uuid: item.name)
        }
    }

    private var filteredApps: [BQAppEntry] {
        let base: [BQAppEntry]
        if searchText.isEmpty {
            base = apps
        } else {
            let q = searchText.lowercased()
            base = apps.filter {
                $0.bundleId.lowercased().contains(q)
                    || $0.uuid.lowercased().contains(q)
                    || (names[$0.bundleId]?.lowercased().contains(q) ?? false)
            }
        }
        // Sort by display name once resolved, falling back to bundle ID.
        return base.sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private func displayName(for app: BQAppEntry) -> String {
        names[app.bundleId] ?? app.bundleId
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
                    Label("No App Groups", systemImage: "app.dashed")
                } description: {
                    Text(model.lastError ?? "No App Groups are accessible.")
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
        .searchable(text: $searchText, prompt: "Filter by name or bundle ID")
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hasLoaded = false
                    loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .onAppear { loadApps() }
            }
        }
        .onAppear { loadApps() }
        // Bundle IDs stream in progressively as resolveContainerMetadata
        // parses each container's metadata plist — resolve names for any
        // new IDs as they appear.
        .onChange(of: model.items) { _, _ in resolveNames() }
        .onChange(of: states.referesh_appgs) { _, val in
            val ? loadApps() : ()
            states.referesh_appgs = false
        }
    }

    /// Kick off display-name resolution for any bundle IDs we haven't
    /// queried yet. Each lookup is an lsd XPC round-trip (via LSApplicationProxy),
    /// so the batch runs detached and publishes results in one MainActor hop.
    private func resolveNames() {
        let pending = apps.map(\.bundleId).filter { $0 != "(unknown)" && !requested.contains($0) }
        guard !pending.isEmpty else { return }
        requested.formUnion(pending)
        Task.detached(priority: .utility) {
            let resolved = appNames(for: pending)
            guard !resolved.isEmpty else { return }
            await MainActor.run {
                for (id, name) in resolved { names[id] = name }
            }
        }
    }

    public func loadApps() {
        guard !hasLoaded else { return }
        hasLoaded = true

        model.load(Self.appRoot, allowMHA: model.useMHAHelper)
    }

    @ViewBuilder
    private func appRow(_ app: BQAppEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: app))
                    .font(.body)
                    .lineLimit(1)
                if names[app.bundleId] != nil {
                    Text(app.bundleId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(app.uuid)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}
