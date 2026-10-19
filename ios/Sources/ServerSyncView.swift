import SwiftUI

struct ServerSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var token = ""
    @State private var problem: String?
    @State private var archives: [URL] = []
    var body: some View {
        Form {
            Section("Plan sync mode") {
                Text(model.serverSync.enabled ? "Shared server" : "Mac / local")
                Text("Shared server mode pauses Mac sync. Your iPhone keeps controlling its independently connected Home Assistant, Hue and Apple Home devices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("House Control server") {
                TextField("https://house.example.com", text: $address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Access token (leave blank to keep saved token)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("The access token stays in this iPhone’s Keychain. HTTP is available only for private IP addresses, localhost and .local hosts; that network can read unencrypted traffic.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Connect and sync") {
                    do { try model.serverSync.connect(address: address, token: token); token = "" }
                    catch { problem = error.localizedDescription }
                }.disabled(model.serverSync.busy)
            }
            Section("Status") {
                Text(model.serverSync.status)
                if model.serverSync.busy { ProgressView() }
                if model.serverSync.conflict {
                    Text("Both plans differ. The replaced plan is kept in this iPhone’s server-conflicts folder. Your device connections are kept independently.")
                    Button("Keep iPhone plan on both") { Task { await model.serverSync.resolve(keepPhone: true) } }
                    Button("Keep server plan on both") { Task { await model.serverSync.resolve(keepPhone: false) } }
                } else {
                    Button("Sync now") { Task { await model.serverSync.synchronize() } }
                        .disabled(!model.serverSync.enabled || model.serverSync.busy)
                }
                Button("Use Mac / local mode") { model.serverSync.useMacMode() }
                    .disabled(!model.serverSync.enabled || model.serverSync.busy)
            }
            if !archives.isEmpty {
                Section("Saved alternatives") {
                    ForEach(Array(archives.enumerated()), id: \.element) { index, url in
                        ShareLink("Export saved alternative \(index + 1)", item: url)
                    }
                }
            }
            Section {
                Text("In shared server mode, edits save here first, then sync automatically. Failed uploads remain on this iPhone and retry on the next foreground sync. A conflicting server edit always asks which plan to keep.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Shared server")
        .onAppear { address = model.serverSync.address; loadArchives() }
        .onChange(of: model.serverSync.status) { _, _ in loadArchives() }
        .alert("Could not connect", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }
    private func loadArchives() {
        let folder = model.plans.directory.appendingPathComponent("server-conflicts", isDirectory: true)
        archives = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
