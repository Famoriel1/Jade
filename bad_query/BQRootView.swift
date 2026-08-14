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
    @State private var showingLog = false
    @EnvironmentObject var state: AppState
    
    var body: some View {
        @Bindable var model = model
        return TabView {
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
                        Text("File browsing")
                    } footer: {
                        Text("iOS 26 needs the App Group sacrifice route for App Groups; iOS 27 reaches System containers directly.")
                    }
                    
                    Section("Session") {
                        HStack {
                            Label("Active Extensions", systemImage: "key.fill")
                            Spacer()
                            Text("\(model.extensionCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if BQFileSystemModel.isMobileHouseArrest {
                            Toggle(isOn: $model.useMHAHelper) {
                                Label("Use MobileHouseArrest", systemImage: "lock.open")
                            }
                            .onChange(of: model.useMHAHelper) { _, _ in
                                model.appendLog("MHA helper \(model.useMHAHelper ? "enabled" : "disabled")")
                            }
                        }
                        Button {
                            showingLog = true
                        } label: {
                            Label("Activity Log", systemImage: "text.alignleft")
                        }
                        Button {
                            model.releaseAllExtensions()
                        } label: {
                            Label("Release All Extensions", systemImage: "xmark.shield")
                        }
                        .disabled(model.extensionCount == 0)
                        Button {
                            openURL("https://www.icloud.com/shortcuts/b402f010cf264d2c987db5b3e3bcc526")
                        } label: {
                            Label("Get Reboot Shortcut", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            state.respring()
                        } label: {
                            Label("Respring", systemImage: "arrow.clockwise")
                        }
                        Button {
                            openURL("shortcuts://run-shortcut?name=reboot")
                        } label: {
                            Label("Reboot", systemImage: "power")
                        }
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
                .navigationTitle("Jade")
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
                .sheet(isPresented: $showingLog) {
                    BQLogView()
                }
            }
            .tabItem {
                Label("File", systemImage: "folder")
            }
            
            NavigationStack {
                BQAppListView()
            }
            .tabItem {
                Label("Apps", systemImage: "app.grid")
            }
            
            NavigationStack {
                BQMobileGestaltView()
            }
            .tabItem {
                Label("Gestalt", systemImage: "apps.iphone")
            }
            NavigationStack {
                BQPosterView()
            }
            .tabItem {
                Label("Poster", systemImage: "photo.on.rectangle.angled")
            }
        }
        .environment(model)
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
