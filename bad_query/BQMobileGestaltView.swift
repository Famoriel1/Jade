//
//  BQMobileGestaltView.swift
//  bad_query
//
//  MobileGestalt tweaking UI, ported from mond ContentView.
//  Uses bad_query sandbox escape for file access.
//

import SwiftUI

struct BQMobileGestaltView: View {
    @State private var model = BQMobileGestaltModel()

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded {
                    ContentUnavailableView {
                        Label("MobileGestalt Editor", systemImage: "gearshape.2")
                    } description: {
                        Text(model.statusMessage)
                    } actions: {
                        Button("Load MobileGestalt") {
                            model.load()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    gestaltList
                }
            }
            .navigationTitle("MobileGestalt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.loaded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                model.load()
                            } label: {
                                Label("Reload", systemImage: "arrow.clockwise")
                            }
                            Button {
                                model.grantExtension(for: model.gestaltPath)
                            } label: {
                                Label("Refresh Extension", systemImage: "key.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert(item: $model.alertInfo) { info in
                if let actionLabel = info.actionLabel {
                    Alert(
                        title: Text(info.title),
                        message: Text(info.body),
                        primaryButton: .default(Text(actionLabel)) {
                            info.action?()
                        },
                        secondaryButton: .cancel()
                    )
                } else {
                    Alert(
                        title: Text(info.title),
                        message: Text(info.body),
                        dismissButton: .cancel()
                    )
                }
            }
        }
    }

    // MARK: - Gestalt List

    private var gestaltList: some View {
        List {
            // Warnings
            if !model.isValid || model.isEmpty {
                Section {
                    if model.isEmpty {
                        warningRow(
                            title: "Do not reboot!",
                            text: "MobileGestalt.plist is empty."
                        )
                    }
                    if !model.isValid {
                        warningRow(
                            title: "Do not reboot!",
                            text: "MobileGestalt.plist is invalid."
                        )
                    }
                } header: {
                    Label("Warning", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("Rebooting now might cause a bootloop. Try 'Revert Tweaks'.")
                }
            }

            // Apply / Revert
            Section {
                Button {
                    model.apply()
                } label: {
                    Label("Apply Tweaks", systemImage: "checkmark.circle.fill")
                }
                .disabled(model.isApplying)

                Button(role: .destructive) {
                    model.revert()
                } label: {
                    Label("Revert Tweaks", systemImage: "arrow.uturn.backward")
                }
            } footer: {
                Text("**WARNING:** These tweaks can break features or softbrick your device!")
            }

            // Device Artwork
            Section {
                Picker(selection: $model.subtype) {
                    Text("Original (\(model.ogSubtype))").tag(model.ogSubtype)
                    if model.isDeviceGood() {
                        Text("Disable Dynamic Island").tag(2436)
                    }
                    Text("iPhone 14 Pro").tag(2436)
                    Text("iPhone 14 Pro Max").tag(2796)
                    Text("iPhone 15 Pro Max").tag(2976)
                    if model.doubleSystemVersion() >= 18.0 {
                        Text("iPhone 16 Pro").tag(2622)
                        Text("iPhone 16 Pro Max").tag(2868)
                    }
                    if model.doubleSystemVersion() >= 26.0 {
                        Text("iPhone Air").tag(2736)
                    }
                    if model.hasHomeButton() {
                        Text("iPhone X Gestures").tag(2436)
                    }
                } label: {
                    HStack {
                        Text("Subtype")
                        Spacer()
                    }
                }

                Toggle("Custom Device Name", isOn: $model.enableDeviceName)

                if model.enableDeviceName {
                    TextField("Device Name", text: Binding(
                        get: { model.customDeviceName },
                        set: { model.customDeviceName = $0 }
                    ))
                }
            } header: {
                Label("Device Artwork", systemImage: "paintbrush.pointed")
            }

            // Software Features
            Section {
                MGToggle(text: "Dynamic Island", minVersion: 19.0, isOn: model.keyBinding(["YlEtTtHlNesRBMal1CqRaA"]))
                MGToggle(text: "Always On Display", minVersion: 18.0, isOn: model.keyBinding(["j8/Omm6s1lsmTDFsXjsBfA", "2OOJf1VhaM7NxfRok3HbWQ"]))
                MGToggle(text: "AOD Vibrancy", minVersion: 18.0, isOn: model.keyBinding(["ykpu7qyhqFweVMKtxNylWA"]))
                MGToggle(text: "Charge Limit", minVersion: 17.0, isOn: model.keyBinding(["37NVydb//GP/GrhuTN+exg"]))
                MGToggle(text: "Boot Chime", isOn: model.keyBinding(["QHxt+hGLaBPbQJbXiUJX3w"]))
                MGToggle(text: "Liquid Glass LPM", minVersion: 19.0, isOn: model.keyBinding(["SAGvsp6O6kAQ4fEfDJpC4Q"]))
            } header: {
                Label("Software Features", systemImage: "gearshape")
            }

            // Hardware Features
            Section {
                MGToggle(text: "Camera Control", minVersion: 18.0, isOn: model.keyBinding(["CwvKxM2cEogD3p+HYgaW0Q", "oOV1jhJbdV3AddkcCg0AEA"]))
                MGToggle(text: "Action Button", minVersion: 17.0, isOn: model.keyBinding(["cT44WE1EohiwRzhsZ8xEsw"]))
                MGToggle(text: "Crash Detection", isOn: model.keyBinding(["HCzWusHQwZDea6nNhaKndw"]))
                if model.hasHomeButton() {
                    MGToggle(text: "Tap to Wake", isOn: model.keyBinding(["yZf3GTRMGTuwSV/lD7Cagw"]))
                }
                MGToggle(text: "Pulse Width Modulation", minVersion: 19.0, isOn: model.keyBinding(["6IejgN+1Fmu5/QrZFOIeNw"]))
            } header: {
                Label("Hardware Features", systemImage: "iphone")
            }

            // Eligibility
            Section {
                MGToggle(text: "Security Research Device UI", minVersion: 26.0, isOn: model.keyBinding(["XYlJKKkj2hztRP1NWWnhlw"]))

                MGToggle(
                    text: "Disable Region Restrictions",
                    infoType: .info,
                    infoMessage: "This tweak may be broken or have no effect on some iOS versions or devices.",
                    isOn: model.regionRestrictBinding()
                )

                MGToggle(
                    text: "Apple Intelligence",
                    infoType: .info,
                    infoMessage: "Apple Intelligence activation is currently broken and may not work.",
                    minVersion: 18.1,
                    isOn: model.keyBinding(["A62OafQ85EJAiiqKn4agtg"])
                )

                HStack(spacing: 10) {
                    Picker("Spoofing", selection: $model.productType) {
                        Text("Default").tag(model.machineName())
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            if model.doubleSystemVersion() >= 17.4 {
                                Text("iPad Pro 11\" (M4)").tag("iPad16,3")
                                Text("iPad Pro 11\" (M4, Cellular)").tag("iPad16,4")
                            }
                            Text("iPad Pro 11\" (4th Gen)").tag("iPad14,3")
                            Text("iPad Pro 11\" (4th Gen, Cellular)").tag("iPad14,4")
                        } else {
                            Text("iPhone 15 Pro").tag("iPhone16,1")
                            Text("iPhone 15 Pro Max").tag("iPhone16,2")
                            if model.doubleSystemVersion() >= 18.0 {
                                Text("iPhone 16").tag("iPhone17,3")
                                Text("iPhone 16 Plus").tag("iPhone17,4")
                                Text("iPhone 16 Pro").tag("iPhone17,1")
                                Text("iPhone 16 Pro Max").tag("iPhone17,2")
                            }
                            if model.doubleSystemVersion() >= 19.0 {
                                Text("iPhone 17").tag("iPhone18,3")
                                Text("iPhone 17 Pro").tag("iPhone18,1")
                                Text("iPhone 17 Pro Max").tag("iPhone18,2")
                                Text("iPhone Air").tag("iPhone18,4")
                            }
                        }
                    }
                }
            } header: {
                Label("Eligibility", systemImage: "checklist")
            }

            // iPadOS Features
            Section {
                MGToggle(text: "Allow Installing iPadOS Apps", isOn: model.keyBinding(["9MZ5AdH43csAUajl/dU+IQ"], type: [Int].self, defaultVal: [1], onVal: [1, 2]))
                MGToggle(text: "Apple Pencil Settings", isOn: model.keyBinding(["yhHcB0iH0d1XzPO/CFd3ow"]))

                if UIDevice.current.userInterfaceIdiom == .pad {
                    MGToggle(text: "Stage Manager", isOn: model.keyBinding(["qeaj75wk3HF4DwQ8qbIi7g"]))
                }
                MGToggle(
                    text: "iPadOS UI",
                    infoType: .warning,
                    infoMessage: "Very dangerous! If you use an alphanumeric passcode, DO NOT USE THIS! Do not turn off \"Show Dock In Stage Manager\" or your device will BOOTLOOP in landscape!",
                    isOn: model.trollpadBinding()
                )
                .disabled({
                    let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
                    return (cacheExtra?["+3Uf0Pm5F8Xy7Onyvko0vA"] as? String) != "iPhone"
                }())
            } header: {
                Label("iPadOS Features", systemImage: "ipad")
            }

            // Internal
            Section {
                MGToggle(text: "Internal Storage", isOn: model.keyBinding(["LBJfwOEzExRxzlAnSuI7eg"]))
                MGToggle(text: "Internal Features", isOn: model.internalBinding())
                MGToggle(text: "Metal HUD in All Apps", isOn: model.keyBinding(["EqrsVvjcYDdxHBiQmGhAWw"]))
            } header: {
                Label("Internal", systemImage: "ant")
            }

            // Session
            Section {
                HStack {
                    Label("Sandbox Extension", systemImage: "key.fill")
                    Spacer()
                    Text(model.hasExtension ? "Active" : "None")
                        .foregroundStyle(model.hasExtension ? .green : .secondary)
                        .font(.caption)
                }
                HStack {
                    Label("Gestalt Path", systemImage: "doc.text")
                    Spacer()
                    Text(model.gestaltPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    model.appendLog("---")
                } label: {
                    Label("View Logs", systemImage: "text.alignleft")
                }
            } header: {
                Text("Session")
            }
        }
        .onAppear {
            if !model.loaded {
                model.load()
            }
        }
    }

    // MARK: - Warning Row

    private func warningRow(title: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - MGToggle

struct MGToggle: View {
    let text: String
    var infoType: MGToggleInfoType?
    var infoMessage: String?
    var minVersion: Double = 0
    @Binding var isOn: Bool

    @State private var showingInfo = false

    var body: some View {
        Toggle(text, isOn: $isOn)
            .disabled(minVersion > 0 && currentVersion() < minVersion)
    }

    private func currentVersion() -> Double {
        Double(UIDevice.current.systemVersion) ?? 0
    }
}
