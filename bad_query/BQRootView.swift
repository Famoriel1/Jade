//
//  BQRootView.swift
//  bad_query
//
//  Entry point for the bad_query system file manager.
//

import SwiftUI

func openURL(_ urlString: String) {
    guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
        return
    }
    UIApplication.shared.open(url, options: [:]) { success in
        if !success {  }
    }
}

struct BQRootView: View {
    @State private var model = BQFileSystemModel()
    @State private var root_selection: Int = 0
    @State private var apps_selection: Int = 0
    @EnvironmentObject var state: AppState
    
    var body: some View {
        @Bindable var model = model
        TabView(selection: $root_selection) {
            NavigationStack {
                List {
                    Section {
                        ForEach(BQFileSystemModel.quickAccess) { entry in
                            NavigationLink {
                                BQDirectoryView(path: entry.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                    Text(entry.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("Quick Paths")
                    } footer: {
                        Text("iOS 26 needs the App Group sacrifice route for App Groups; iOS 27 reaches System containers directly.")
                    }
                    
                    
                    if let error = model.lastError {
                        Section {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("File")

            }
            .tabItem {
                Label("File", systemImage: "folder")
            }
            .tag(0)
            
            TabView(selection: $apps_selection) {
                NavigationStack {
                    BQAppListView()
                }
                .tabItem {
                    Text("Apps")
                }
                .tag(0)
                
                NavigationStack {
                    BQAppGroupListView()
                }
                .tabItem {
                    Text("App Groups")
                }
                .tag(1)
            }
            .tabItem {
                Label("Apps", systemImage: "app.grid")
            }
            .tag(1)
            
            NavigationStack {
                BQMobileGestaltView()
            }
            .tabItem {
                Label("Gestalt", systemImage: "apps.iphone")
            }
            .tag(2)
            
            NavigationStack {
                BQPosterView()
            }
            .tabItem {
                Label("Poster", systemImage: "photo.on.rectangle.angled")
            }
            .tag(3)
            
            NavigationStack {
                BQSettingsView()
            }
            
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(4)
        }
        .environment(model)
        .environmentObject(state)
        .overlay(alignment: .bottom) {
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .lineLimit(1)
            }
        }
        .onChange(of: root_selection) { _, val in
            if val == 1 {
                state.referesh_apps = true
                state.referesh_appgs = true
            }
        }
        .sheet(isPresented: $state.show_log) {
            BQLogView()
                .environment(model)
        }
    }
}

struct BQLogView: View {
    @Environment(BQFileSystemModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.log.count) {
                    if let last = model.log.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
