//
//  BQSandboxPoCView.swift
//  bad_query
//
//  MobileHouseArrest container escape & class-13 MobileGestalt PoC UI.
//  Only accessible when the app's bundle identifier is
//  com.apple.mobile.MobileHouseArrest.
//

import SwiftUI

// MARK: - Result Wrapper

struct BQPocResult {
    let success: Bool
    let activated: Bool
    let deniedBefore: Bool
    let deniedAfter: Bool
    let restored: Bool
    let writable: Bool
    let message: String
    let path: String

    init(from c: bq_poc_result) {
        success = c.success == 0
        activated = c.activated != 0
        deniedBefore = c.denied_before != 0
        deniedAfter = c.denied_after != 0
        restored = c.restored != 0
        writable = c.writable != 0
        message = withUnsafeBytes(of: c.message) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        path = withUnsafeBytes(of: c.path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class BQSandboxPoCModel {
    var mhaNotesResult: BQPocResult?
    var mhaSafariResult: BQPocResult?
    var mgClass13Result: BQPocResult?
    var isRunning = false

    static var isMobileHouseArrest: Bool {
        Bundle.main.bundleIdentifier == "com.apple.mobile.MobileHouseArrest"
    }

    func runMHAPoC() {
        guard !isRunning else { return }
        isRunning = true
        let notesRaw = "com.apple.mobilenotes".withCString { ptr in
            bq_run_mha_poc(ptr)
        }
        mhaNotesResult = BQPocResult(from: notesRaw)
        let safariRaw = "com.apple.mobilesafari".withCString { ptr in
            bq_run_mha_poc(ptr)
        }
        mhaSafariResult = BQPocResult(from: safariRaw)
        isRunning = false
    }

    func runMGClass13PoC() {
        guard !isRunning else { return }
        isRunning = true
        let raw = bq_run_mg_class13_poc()
        mgClass13Result = BQPocResult(from: raw)
        isRunning = false
    }
}

// MARK: - View

struct BQSandboxPoCView: View {
    @State private var model = BQSandboxPoCModel()

    var body: some View {
        List {
            // Identity
            Section {
                HStack {
                    Label("Bundle ID", systemImage: "app.badge")
                    Spacer()
                    Text(Bundle.main.bundleIdentifier ?? "(unknown)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Label("Match", systemImage: "checkmark.seal")
                    Spacer()
                    Text(BQSandboxPoCModel.isMobileHouseArrest ? "Yes" : "No")
                        .font(.caption)
                        .foregroundStyle(BQSandboxPoCModel.isMobileHouseArrest ? .green : .red)
                }
            } header: {
                Text("Identity")
            }

            // MHA PoC
            Section {
                Button {
                    model.runMHAPoC()
                } label: {
                    HStack {
                        Label("Run MobileHouseArrest PoC", systemImage: "play.circle.fill")
                        Spacer()
                        if model.isRunning {
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isRunning)

                if let r = model.mhaNotesResult {
                    pocResultCard(r, title: "MobileNotes Result", showRestored: true)
                }
                if let r = model.mhaSafariResult {
                    pocResultCard(r, title: "MobileSafari Result", showRestored: true)
                }
            } header: {
                Label("App-Data Container Escape (Class 2)", systemImage: "shippingbox")
            } footer: {
                Text("Queries the app-data containers for com.apple.mobilenotes and com.apple.mobilesafari, activates each sandbox extension, writes a canary file, verifies, and cleans it up.")
            }

            // MG Class-13 PoC
            Section {
                Button {
                    model.runMGClass13PoC()
                } label: {
                    HStack {
                        Label("Run MobileGestalt Class-13 PoC", systemImage: "play.circle.fill")
                        Spacer()
                        if model.isRunning {
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isRunning)

                if let r = model.mgClass13Result {
                    pocResultCard(r, title: "MG Class-13 Result", showWritable: true)
                }
            } header: {
                Label("System-Group Container Escape (Class 13)", systemImage: "lock.trianglebadge.exclamationmark")
            } footer: {
                Text("Queries the MobileGestalt cache system-group container, verifies the returned path, activates the extension, and checks read-write access to com.apple.MobileGestalt.plist.")
            }
        }
        .navigationTitle("Sandbox PoC")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Result Card

    private func pocResultCard(_ r: BQPocResult, title: String, showRestored: Bool = false, showWritable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status header
            HStack(spacing: 6) {
                Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(r.success ? .green : .red)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(r.success ? "PASS" : "FAIL")
                    .font(.caption.bold())
                    .foregroundStyle(r.success ? .green : .red)
            }

            // Path
            if !r.path.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(r.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            // Detail rows
            Group {
                detailRow("Denied Before", r.deniedBefore)
                detailRow("Activated", r.activated)
                if showRestored {
                    detailRow("Canary Restored", r.restored)
                }
                if showWritable {
                    detailRow("Plist Writable", r.writable)
                }
                detailRow("Denied After", r.deniedAfter)
            }

            // Message
            if !r.message.isEmpty {
                Text(r.message)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func detailRow(_ label: String, _ value: Bool) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ? "Yes" : "No")
                .font(.caption.bold())
                .foregroundStyle(value ? .green : .red)
        }
    }
}
