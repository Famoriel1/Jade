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

    /// Resolved display names, keyed by bundle ID. Filled progressively by
    /// resolveNames() as bundle IDs appear in the container metadata.
    @State private var names: [String: String] = [:]
    /// Bundle IDs already handed to the resolver (hit or miss), so each ID is
    /// only queried once per view lifetime.
    @State private var requested: Set<String> = []

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
                    .contextMenu {
                        Button {
                            openApp(app.bundleId)
                        } label: {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Filter by name or bundle ID")
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
                .onAppear { loadApps() }
            }
        }
        .onAppear { loadApps() }
        // Bundle IDs stream in progressively as resolveContainerMetadata
        // parses each container's metadata plist — resolve names for any
        // new IDs as they appear.
        .onChange(of: model.items) { _, _ in resolveNames() }
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

    private func loadApps() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if model.useMHAHelper {
            loadAppsViaMHA()
        } else {
            // MHA 关闭：bad_query inode scan 发现 + bad_query 访问
            model.load(Self.appRoot, allowMHA: false)
        }
    }

    /// MHA 开启时的 app 发现与访问。
    ///
    /// 参考：
    /// - SandboxEscape-Usage-Manual.md §7 (iOS 26 app discovery)
    /// - AppsManager-Fix-Report.md §3 (3-hook fallback strategy)
    /// - AppsManager-Fix-Report.md §6.2 Hook 2 field 2 (display name resolution)
    ///
    /// 三级发现策略（按优先级）：
    /// 1. csstore 解析 — 激活 com.apple.lsd class-10 容器，解析
    ///    com.apple.LaunchServices-*-v2.csstore 提取候选 bundle ID。
    ///    iOS 26 上 MCMEnumerateIdentifiersForClass 返回近空，csstore 是主要方案。
    /// 2. MCMEnumerateIdentifiersForClass(2) — 直接枚举 class-2 容器标识符。
    ///    iOS 26 通常近空，但可能补充 csstore 未覆盖的系统应用。
    /// 3. inode scan 回退 — bad_query 扫 /var/mobile/Containers/Data/Application。
    ///    当 csstore + enum 结果太少时回退到此 proven route。
    ///
    /// 对每个 bundle ID 用 BQMCMDataContainerPathQuery（仅查路径，不激活 token）
    /// 解析 data container 路径。实际 sandbox extension 在用户点击进入容器时
    /// 由 ensureMHAExtension 按需激活。
    ///
    /// 显示名解析（AppsManager-Fix-Report.md Hook 2 field 2 三级回退）：
    ///   LSApplicationProxy.localizedName → MCM metadata plist → bundleId
    /// MHA 身份下 LSApplicationProxy 可用（per project memory）。
    /// bundle 目录的 Info.plist 不可读（Manual §10.2），改用 data container 的
    /// .com.apple.mobile_container_manager.metadata.plist 中的 MCMMetadataDisplayName。
    ///
    /// 注意：不扫描 /var/containers/Bundle/Application — MCM 不签发该路径的
    /// extension（SandboxEscape-Usage-Manual.md §10.2）。
    private func loadAppsViaMHA() {
        model.isLoading = true
        model.lastError = nil
        model.items = []

        Task.detached(priority: .userInitiated) {
            // bundleId → dataPath（去重）
            var discovered: [String: String] = [:]

            // Tier 1: csstore 解析（SandboxEscape-Usage-Manual.md §7.2）
            // 激活 com.apple.lsd class-10 容器，mmap csstore 提取候选 bundle ID
            let csstoreIDs = BQMCMLaunchServicesStoreIdentifiers()
            await MainActor.run {
                self.model.appendLog("csstore: \(csstoreIDs.count) candidates")
            }
            for bid in csstoreIDs {
                if discovered[bid] != nil { continue }
                // §7.3：用 BQMCMDataContainerPathQuery 验证候选是否有真实 class-2 容器
                // 仅查路径不激活 token，避免 iOS 26 token 激活失败
                if let path = BQMCMDataContainerPathQuery(bid, nil) {
                    discovered[bid] = path
                }
            }

            // Tier 2: MCMEnumerateIdentifiersForClass(2)（补充）
            // iOS 26 通常近空，但可能包含 csstore 未覆盖的应用
            if discovered.count < 20 {
                let enumIDs = BQMCMEnumerateIdentifiersForClass(2, 10000, nil)
                await MainActor.run {
                    self.model.appendLog("MCMEnumerate(2): \(enumIDs.count) identifiers")
                }
                for bid in enumIDs where discovered[bid] == nil {
                    if let path = BQMCMDataContainerPathQuery(bid, nil) {
                        discovered[bid] = path
                    }
                }
            }

            // Tier 3: csstore + enum 结果太少 → 回退 inode scan（proven route）
            // inode scan 发现 + MHA 访问（allowMHA: true 让 ensureMHAExtension
            // 在用户点击容器时用 MHA 激活 lease）
            if discovered.count < 5 {
                await MainActor.run {
                    self.model.appendLog("MHA discovery found \(discovered.count) apps, falling back to inode scan")
                    // 重置 hasLoaded 让 inode scan 的结果不被阻止
                    // model.load 内部会设置 isLoading 和 items
                    self.model.load(Self.appRoot, allowMHA: true)
                }
                return
            }

            // 预解析显示名（AppsManager-Fix-Report.md Hook 2 field 2）
            // 在后台线程同步解析，使名称与列表同时出现
            let bundleIds = Array(discovered.keys)
            var resolvedNames = appNames(for: bundleIds)

            // 回退：读 data container 的 MCM metadata plist 取 MCMMetadataDisplayName
            // MHA 下 bundle 目录 Info.plist 不可读（Manual §10.2），但 data container
            // 的 metadata plist 可通过 bad_query 一次性扩展读取
            for bid in bundleIds where resolvedNames[bid] == nil {
                guard let rawPath = discovered[bid] else { continue }
                let dataPath = rawPath.hasPrefix("/private/var/")
                    ? String(rawPath.dropFirst("/private".count))
                    : rawPath
                if let name = Self.readMCMDisplayName(dataPath: dataPath) {
                    resolvedNames[bid] = name
                }
            }

            // 构建 FSItems
            var items: [FSItem] = []
            for (bid, rawPath) in discovered {
                // Normalize /private/var/... → /var/...
                let path = rawPath.hasPrefix("/private/var/")
                    ? String(rawPath.dropFirst("/private".count))
                    : rawPath
                let uuid = (path as NSString).lastPathComponent
                items.append(FSItem(
                    path: path,
                    name: uuid,
                    isDirectory: true,
                    typeKnown: true,
                    size: nil,
                    modified: nil,
                    subtitle: bid
                ))
            }

            await MainActor.run {
                self.model.items = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.model.statusMessage = "\(items.count) apps (MHA)"
                self.model.isLoading = false
                self.model.appendLog("MHA discovery complete: \(items.count) apps, \(resolvedNames.count) names resolved")
                // 预填充已解析的名称，名称与列表同时显示
                for (id, name) in resolvedNames {
                    self.names[id] = name
                }
                self.requested = Set(bundleIds)
            }
        }
    }

    /// 从 data container 的 MCM metadata plist 读取显示名。
    ///
    /// 对应 AppsManager-Fix-Report.md Hook 2 field 2 的 Info.plist 回退：
    /// MHA 下 bundle 目录不可读（Manual §10.2），改读 data container 中的
    /// .com.apple.mobile_container_manager.metadata.plist 的 MCMMetadataDisplayName。
    /// 使用一次性 bad_query 扩展（用完立即释放，避免 200+ 扩展拖慢 syscall）。
    nonisolated private static func readMCMDisplayName(dataPath: String) -> String? {
        let metaPath = dataPath + "/.com.apple.mobile_container_manager.metadata.plist"
        // 先直接读（MHA lease 可能已激活）
        if let name = parseMCMDisplayName(FileManager.default.contents(atPath: metaPath)) {
            return name
        }
        // bad_query 一次性扩展回退
        let handle = BQFileSystemModel.rawBadQuery(path: metaPath)
        guard handle > 0 else { return nil }
        defer { bad_query_release(handle) }
        return parseMCMDisplayName(FileManager.default.contents(atPath: metaPath))
    }

    nonisolated private static func parseMCMDisplayName(_ data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let name = plist["MCMMetadataDisplayName"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    private func openApp(_ bundleId: String) {
        guard let workspace = LSApplicationWorkspace.defaultWorkspace() as? LSApplicationWorkspace else {
            return
        }
        let success = workspace.openApplication(withBundleID: bundleId)
        if !success {
            print("[openApp] failed to open \(bundleId)")
        }
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
