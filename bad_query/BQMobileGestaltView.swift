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
        .onAppear {
            if !model.loaded {model.load()}
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

            // Advanced
            Section {
                NavigationLink {
                    AdvancedGestaltEditor(model: model)
                } label: {
                    Label("Advanced Field Editor", systemImage: "slider.horizontal.3")
                }
            } header: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
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

// MARK: - Advanced Field Editor Types

enum PlistSection: Hashable {
    case cacheExtra
    case topLevel
}

struct PlistKey: Hashable {
    let section: PlistSection
    let key: String
}

enum FieldEditorRoute: Identifiable, Hashable {
    case edit(PlistKey)
    case addCacheExtra

    var id: Self { self }
}

enum AddFieldError: LocalizedError {
    case emptyKey
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Key cannot be empty."
        case .duplicateKey(let key):
            return "Key \"\(key)\" already exists."
        }
    }
}

enum GestaltValueType: String, CaseIterable {
    case bool = "Bool"
    case integer = "Integer"
    case string = "String"
}

struct PlistValueInfo {
    let display: String
    let searchText: String

    static func info(for value: Any?) -> PlistValueInfo {
        guard let value else {
            return PlistValueInfo(display: "—", searchText: "")
        }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            let b = n.boolValue
            return PlistValueInfo(display: b ? "true" : "false",
                                  searchText: b ? "true" : "false")
        }
        if let data = value as? Data {
            return PlistValueInfo(display: "Data (\(data.count) bytes)",
                                  searchText: "data")
        }
        if let dict = value as? [String: Any] {
            return PlistValueInfo(display: "Dict (\(dict.count) keys)",
                                  searchText: "dictionary")
        }
        if let arr = value as? [Any] {
            return PlistValueInfo(display: "Array (\(arr.count) items)",
                                  searchText: "array")
        }
        let str = "\(value)"
        return PlistValueInfo(display: str, searchText: str)
    }
}

// MARK: - Advanced Gestalt Editor

struct AdvancedGestaltEditor: View {
    @Bindable var model: BQMobileGestaltModel

    @State private var searchText = ""
    @State private var activeEditor: FieldEditorRoute?

    private var cacheExtraKeys: [String] {
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
        let keys = cacheExtra?.allKeys as? [String] ?? []
        return filtered(keys, section: .cacheExtra)
    }

    private var topLevelKeys: [String] {
        let keys = (model.mgDict.allKeys as? [String] ?? [])
            .filter { $0 != "CacheExtra" }
        return filtered(keys, section: .topLevel)
    }

    var body: some View {
        List {
            if model.loaded {
                KeySection(
                    title: "CacheExtra",
                    keys: cacheExtraKeys,
                    value: { value(for: PlistKey(section: .cacheExtra, key: $0)) },
                    select: { activeEditor = .edit(PlistKey(section: .cacheExtra, key: $0)) }
                )

                KeySection(
                    title: "Top Level",
                    keys: topLevelKeys,
                    value: { value(for: PlistKey(section: .topLevel, key: $0)) },
                    select: { activeEditor = .edit(PlistKey(section: .topLevel, key: $0)) }
                )
            }
        }
        .navigationTitle("Advanced Field Editor")
        .searchable(text: $searchText, prompt: "Search key or value")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    activeEditor = .addCacheExtra
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add CacheExtra Field")
                .disabled(!model.loaded || model.isApplying)

                Button("Save") { model.apply() }
                    .fontWeight(.semibold)
                    .disabled(!model.isDirty || model.isApplying)
            }
        }
        .sheet(item: $activeEditor) { editor in
            Group {
                switch editor {
                case .edit(let key):
                    ValueEditor(
                        key: key.key,
                        initialValue: value(for: key),
                        save: { update($0, for: key) },
                        delete: key.section == .cacheExtra
                            ? { deleteCacheExtraField(key.key) }
                            : nil
                    )
                case .addCacheExtra:
                    AddCacheExtraFieldEditor(save: addCacheExtraField)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func filtered(_ keys: [String], section: PlistSection) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return keys }

        return keys.filter { key in
            let reference = PlistKey(section: section, key: key)
            let info = PlistValueInfo.info(for: value(for: reference))
            return key.localizedCaseInsensitiveContains(query)
                || info.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private func value(for key: PlistKey) -> Any? {
        switch key.section {
        case .cacheExtra:
            let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
            return cacheExtra?[key.key]
        case .topLevel:
            return model.mgDict[key.key]
        }
    }

    private func update(_ value: Any, for key: PlistKey) {
        switch key.section {
        case .cacheExtra:
            let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
                ?? NSMutableDictionary()
            model.mgDict["CacheExtra"] = cacheExtra
            cacheExtra[key.key] = value
        case .topLevel:
            model.mgDict[key.key] = value
        }
        model.isDirty = true
    }

    private func addCacheExtraField(key: String, value: Any) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw AddFieldError.emptyKey
        }
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
            ?? NSMutableDictionary()
        model.mgDict["CacheExtra"] = cacheExtra
        guard cacheExtra[normalizedKey] == nil else {
            throw AddFieldError.duplicateKey(normalizedKey)
        }
        cacheExtra[normalizedKey] = value
        model.isDirty = true
    }

    private func deleteCacheExtraField(_ key: String) {
        let cacheExtra = model.mgDict["CacheExtra"] as? NSMutableDictionary
        cacheExtra?.removeObject(forKey: key)
        model.isDirty = true
    }
}

// MARK: - Key Section

struct KeySection: View {
    let title: String
    let keys: [String]
    let value: (String) -> Any?
    let select: (String) -> Void

    var body: some View {
        if !keys.isEmpty {
            Section(title) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        select(key)
                    } label: {
                        HStack {
                            Text(key)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(PlistValueInfo.info(for: value(key)).display)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Value Editor

struct ValueEditor: View {
    let key: String
    let initialValue: Any?
    let save: (Any) -> Void
    let delete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var valueType: GestaltValueType = .integer
    @State private var boolValue = false
    @State private var intValue: Int = 0
    @State private var stringValue: String = ""
    @State private var isComplex = false
    @State private var complexDisplay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Value") {
                    if isComplex {
                        Text(complexDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Type", selection: $valueType) {
                            ForEach(GestaltValueType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        switch valueType {
                        case .bool:
                            Toggle("Enabled", isOn: $boolValue)
                        case .integer:
                            TextField("Value", value: $intValue, format: .number)
                                .keyboardType(.numberPad)
                        case .string:
                            TextField("Value", text: $stringValue)
                                .autocorrectionDisabled()
                        }
                    }
                }

                if let delete {
                    Section {
                        Button("Delete Field", role: .destructive) {
                            delete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Edit Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveValue() }
                        .disabled(isComplex)
                }
            }
        }
        .onAppear { configureForInitialValue() }
    }

    private func configureForInitialValue() {
        guard let v = initialValue else {
            valueType = .integer
            intValue = 0
            return
        }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            valueType = .bool
            boolValue = n.boolValue
        } else if let i = v as? Int {
            valueType = .integer
            intValue = i
        } else if let n = v as? NSNumber {
            valueType = .integer
            intValue = n.intValue
        } else if let s = v as? String {
            valueType = .string
            stringValue = s
        } else if let data = v as? Data {
            isComplex = true
            complexDisplay = "Data (\(data.count) bytes) — not editable here"
        } else if let dict = v as? [String: Any] {
            isComplex = true
            complexDisplay = "Dictionary (\(dict.count) keys) — not editable here"
        } else if let arr = v as? [Any] {
            isComplex = true
            complexDisplay = "Array (\(arr.count) items) — not editable here"
        } else {
            isComplex = true
            complexDisplay = "\(v)"
        }
    }

    private func saveValue() {
        let value: Any
        switch valueType {
        case .bool:
            value = boolValue ? 1 : 0
        case .integer:
            value = intValue
        case .string:
            value = stringValue
        }
        save(value)
        dismiss()
    }
}

// MARK: - Add CacheExtra Field Editor

struct AddCacheExtraFieldEditor: View {
    let save: (String, Any) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var valueType: GestaltValueType = .integer
    @State private var boolValue = true
    @State private var intValue = 1
    @State private var stringValue = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Key", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Value") {
                    Picker("Type", selection: $valueType) {
                        ForEach(GestaltValueType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    switch valueType {
                    case .bool:
                        Toggle("Enabled", isOn: $boolValue)
                    case .integer:
                        TextField("Value", value: $intValue, format: .number)
                            .keyboardType(.numberPad)
                    case .string:
                        TextField("Value", text: $stringValue)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Add CacheExtra Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addField() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func addField() {
        let value: Any
        switch valueType {
        case .bool:
            value = boolValue ? 1 : 0
        case .integer:
            value = intValue
        case .string:
            value = stringValue
        }
        do {
            try save(key, value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
