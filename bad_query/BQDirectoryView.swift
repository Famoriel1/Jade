//
//  BQDirectoryView.swift
//  bad_query
//
//  Directory browser backed by the bad_query sandbox escape.
//

import SwiftUI
import UniformTypeIdentifiers

struct PendingShare: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct BQDirectoryView: View {
    @Environment(BQFileSystemModel.self) private var model
    let path: String
    var allowMHA: Bool = true

    @State private var showingImportTarget = false
    @State private var showingNewItem = false
    @State private var newItemIsDirectory = false
    @State private var newItemName = ""
    @State private var showingDelete: FSItem?
    @State private var showingRename: FSItem?
    @State private var renameText = ""
    @State private var showingScan = false
    @State private var scanInodeText = ""

    private static var visited: [String: Bool] = [:]
    @State private var loaded = false

    init(path: String) {
        self.path = path
        if let existing = Self.visited[path] {
            _loaded = State(initialValue: existing)
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isLoading && model.items.isEmpty {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Reading directory…")
                }
            } else if model.items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Here", systemImage: "folder")
                } description: {
                    Text(model.lastError ?? "This directory is empty or could not be listed.")
                } actions: {
                    Button("Retry") { model.load(path, allowMHA: allowMHA) }
                }
            } else {
                List {
                    ForEach(model.items) { item in
                        if item.isDirectory {
                            NavigationLink {
                                BQDirectoryView(path: item.path)
                            } label: {
                                BQRow(item: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    showingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    showingRename = item
                                    renameText = item.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                contextActions(for: item)
                            }
                        } else {
                            NavigationLink {
                                BQFilePreview(item: item)
                            } label: {
                                BQRow(item: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    showingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    showingRename = item
                                    renameText = item.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                contextActions(for: item)
                            }
                        }
                    }
                    .listRowSeparator(.visible)
                }
                .listStyle(.plain)
                .refreshable { await model.performLoad(path, allowMHA: allowMHA) }
            }
        }
        .navigationTitle(lastComponent(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .onAppear {
            model.load(path, allowMHA: allowMHA)
        }
        .onDisappear { Self.visited[path] = loaded }
        .confirmationDialog("Delete \(showingDelete?.name ?? "")?",
                            isPresented: Binding(get: { showingDelete != nil },
                                                 set: { if !$0 { showingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = showingDelete { model.delete(item) }
                showingDelete = nil
            }
        } message: {
            Text("This permanently deletes the item. There is no undo.")
        }
        .alert("New", isPresented: $showingNewItem) {
            TextField("Name", text: $newItemName)
            Button("Create") {
                model.createItem(named: newItemName, isDirectory: newItemIsDirectory, in: path)
                newItemName = ""
            }
            Button("Cancel", role: .cancel) { newItemName = "" }
        } message: {
            Text(newItemIsDirectory ? "New folder in \(shortPath)" : "New empty file in \(shortPath)")
        }
        .alert("Rename", isPresented: Binding(get: { showingRename != nil },
                                              set: { if !$0 { showingRename = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let item = showingRename { model.rename(item, to: renameText) }
                showingRename = nil
            }
            Button("Cancel", role: .cancel) { showingRename = nil }
        }
        .alert("Inode Scan", isPresented: $showingScan) {
            TextField("Max inode", text: $scanInodeText)
                .keyboardType(.numberPad)
            Button("Scan") {
                let maxInode = Int64(scanInodeText) ?? BQFileSystemModel.defaultMaxInode(for: path)
                Task { await model.inodeScan(path, maxInode: maxInode) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Brute-force enumerate children via fsgetpath. Slow; raise max inode if the directory looks incomplete.")
        }
        .fileImporter(isPresented: $showingImportTarget, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let source):
                model.importFile(from: source, toDestinationPath: path + "/" + source.lastPathComponent)
            case .failure(let error):
                model.lastError = error.localizedDescription
            }
        }
        .sheet(item: $model.pendingShare) { share in
            ShareSheetView(url: share.url)
        }
    }

    private var shortPath: String {
        path.count > 40 ? "…" + String(path.suffix(38)) : path
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingNewItem = true; newItemIsDirectory = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button { showingNewItem = true; newItemIsDirectory = false } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                Button { showingImportTarget = true } label: {
                    Label("Import File Here", systemImage: "square.and.arrow.down")
                }
                Divider()
                if model.copiedItemPath != nil {
                    Button { model.paste(into: path) } label: {
                        Label("Paste Here", systemImage: "doc.on.doc")
                    }
                }
                Button {
                    scanInodeText = String(BQFileSystemModel.defaultMaxInode(for: path))
                    showingScan = true
                } label: {
                    Label("Inode Scan…", systemImage: "magnifyingglass")
                }
                Divider()
                Button(role: .destructive) {
                    model.releaseAllExtensions()
                    model.load(path, allowMHA: allowMHA)
                } label: {
                    Label("Release All Extensions", systemImage: "xmark.shield")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func contextActions(for item: FSItem) -> some View {
        Button { model.copy(item) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button { model.export(item) } label: {
            Label("Export / Share", systemImage: "square.and.arrow.up")
        }
        Button {
            showingRename = item
            renameText = item.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            showingDelete = item
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Row

struct BQRow: View {
    let item: FSItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let size = item.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let modified = item.modified {
                    Text(modified, format: .dateTime.day().month().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var icon: String {
        if item.isDirectory { return "folder.fill" }
        let ext = item.name.lowercased().split(separator: ".").last.map(String.init) ?? ""
        if ["plist", "json", "xml", "yaml", "yml"].contains(ext) { return "doc.badge.gearshape" }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "svg"].contains(ext) { return "photo" }
        if ["sqlite", "db"].contains(ext) { return "cylinder.split.1x2" }
        if !item.typeKnown { return "questionmark.circle" }
        return "doc"
    }
}

// MARK: - Share sheet wrapper

struct ShareSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
            ShareLink(item: url) {
                Label("Share File", systemImage: "square.and.arrow.up")
                    .font(.title3)
            }
            Button("Close", role: .cancel) { dismiss() }
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }
}

// MARK: - Editable Content

enum EditableType: Sendable {
    case plainText
    case plist(format: PropertyListSerialization.PropertyListFormat)
    case json

    var displayName: String {
        switch self {
        case .plainText: return "Text"
        case .plist(let format):
            switch format {
            case .binary: return "Plist (Binary)"
            case .xml: return "Plist (XML)"
            case .openStep: return "Plist (OpenStep)"
            @unknown default: return "Plist"
            }
        case .json: return "JSON"
        }
    }
}

enum EditableLoader {
    nonisolated static let maxBytes = 4 * 1024 * 1024

    /// Load a file and return its content as editable text, plus type info.
    /// Returns nil if the file is not text-editable (image, binary, etc.)
    nonisolated static func loadEditable(path: String) -> (text: String, type: EditableType, truncated: Bool)? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        if data.isEmpty { return ("", .plainText, false) }

        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data

        // Try plist — convert to XML for editing, remember original format
        var format = PropertyListSerialization.PropertyListFormat.binary
        if let plist = try? PropertyListSerialization.propertyList(from: slice, options: [], format: &format),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return (text + (truncated ? "\n\n(truncated)" : ""), .plist(format: format), truncated)
        }

        // Try JSON — pretty-print for editing
        if let object = try? JSONSerialization.jsonObject(with: slice, options: []),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return (text, .json, truncated)
        }

        // Try plain text (UTF-8)
        if let text = String(data: slice, encoding: .utf8) {
            return (text + (truncated ? "\n\n(truncated)" : ""), .plainText, truncated)
        }

        return nil
    }

    /// Serialize edited text back to Data, preserving the original format.
    nonisolated static func serialize(text: String, type: EditableType) throws -> Data {
        switch type {
        case .plainText:
            guard let data = text.data(using: .utf8) else {
                throw BQError.io("Failed to encode text as UTF-8")
            }
            return data
        case .plist(let format):
            guard let plistData = text.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) else {
                throw BQError.io("Failed to parse edited plist — check XML syntax")
            }
            return try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        case .json:
            guard let jsonData = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
                throw BQError.io("Failed to parse edited JSON — check syntax")
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
    }
}

// MARK: - Preview

struct BQFilePreview: View {
    @Environment(BQFileSystemModel.self) private var model
    let item: FSItem

    @State private var content: PreviewContent = .loading
    @State private var editableType: EditableType?
    @State private var editText: String = ""
    @State private var originalText: String = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var isTruncated = false
    @State private var saveError: String?
    @State private var showDiscardAlert = false

    var body: some View {
        @Bindable var model = model
        Group {
            if isEditing {
                TextEditor(text: $editText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 4)
            } else {
                ScrollView {
                    switch content {
                    case .loading:
                        ProgressView("Reading…")
                            .padding(.top, 80)
                    case .text(let text):
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    case .image(let image):
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    case .hex(let dump):
                        Text(dump)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    case .unreadable(let message):
                        ContentUnavailableView {
                            Label("Unreadable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        }
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if editText != originalText {
                            showDiscardAlert = true
                        } else {
                            isEditing = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(isSaving || editText == originalText)
                } else {
                    HStack {
                        if editableType != nil && !isTruncated {
                            Button {
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                        }
                        Button {
                            model.export(item)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let type = editableType, !isEditing {
                Text(type.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .task {
            await loadContent()
        }
        .alert("Discard Changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                editText = originalText
                isEditing = false
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes that will be lost.")
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .sheet(item: $model.pendingShare) { share in
            ShareSheetView(url: share.url)
        }
    }

    private func loadContent() async {
        model.ensureExtension(for: parentPath(item.path))
        model.ensureExtension(for: item.path)

        // Try to load as editable text first
        let result = await Task.detached { EditableLoader.loadEditable(path: item.path) }.value
        if let result {
            editText = result.text
            originalText = result.text
            editableType = result.type
            isTruncated = result.truncated
            content = .text(result.text)
        } else {
            // Fall back to preview (image, hex, etc.)
            editableType = nil
            isTruncated = false
            content = await Task.detached { PreviewLoader.load(path: item.path) }.value
        }
    }

    private func save() {
        guard let type = editableType else { return }
        if isTruncated {
            saveError = "Cannot save: the file was truncated during loading (exceeds \(ByteCountFormatter.string(fromByteCount: Int64(EditableLoader.maxBytes), countStyle: .file)))."
            return
        }

        isSaving = true
        let textToSave = editText

        Task {
            do {
                let data = try await Task.detached {
                    try EditableLoader.serialize(text: textToSave, type: type)
                }.value
                try model.writeInPlace(at: item.path, data: data)
                originalText = editText
                isSaving = false
                isEditing = false
                content = .text(editText)
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }

    private func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
