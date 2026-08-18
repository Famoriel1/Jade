//
//  BQSettingsView.swift
//  Jade
//
//  Created by Jason on 2026/8/18.
//

import SwiftUI

struct BQSettingsView: View {
    @Environment(BQFileSystemModel.self) private var model
    @EnvironmentObject var state: AppState
    
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $model.useMHAHelper) {
                        Label("Use MobileHouseArrest", systemImage: "lock.open")
                    }
                    .disabled(!BQFileSystemModel.isMobileHouseArrest)
                    .onChange(of: model.useMHAHelper) { _, _ in
                        model.appendLog("MHA helper \(model.useMHAHelper ? "enabled" : "disabled")")
                    }
                } header: {
                    Text("MobileHouseArrest Helper")
                } footer: {
                    if !BQFileSystemModel.isMobileHouseArrest {
                        Text("MobileHouseArrest Helper is not avaliable when the Bundle ID of this app is not equals to com.apple.mobile.MobileHouseArrest.")
                    } else {
                        Text("MobileHouseArrest Helper gives you another way to browse files & folders on your device. Default is enabled.")
                    }
                }
                Section("Sandbox Escape") {
                    HStack {
                        Label("Active Extensions", systemImage: "key.fill")
                        Spacer()
                        Text("\(model.extensionCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    Button {
                        state.show_log = true
                    } label: {
                        Label("Activity Log", systemImage: "text.alignleft")
                    }
                    Button {
                        model.releaseAllExtensions()
                    } label: {
                        Label("Release All Extensions", systemImage: "xmark.shield")
                    }
                    .disabled(model.extensionCount == 0)
                }
                Section("Utilities") {
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
            }
            .navigationTitle("Settings")
        }
    }
}
