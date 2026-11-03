import SwiftUI

/// Forget stored cursors per collector and change the stack's retention.
struct MaintenanceTab: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var confirmForgetAll = false
    @State private var retentionOutput = ""
    @State private var applyingRetention = false

    private var stateFiles: [String: URL] { model.stateFiles }

    private var collectorsWithData: [CollectorInfo] {
        CollectorCatalog.all.filter { stateFiles[$0.name] != nil }
    }

    var body: some View {
        Form {
            Section {
                if collectorsWithData.isEmpty {
                    Text("No collector has stored data yet.")
                        .foregroundColor(.secondary)
                }
                ForEach(collectorsWithData) { info in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(info.title)
                            Text(stateFiles[info.name]?.lastPathComponent ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { model.forgetData(collector: info.name) }
                            .buttonStyle(DestructiveButtonStyle())
                    }
                }
                Button("Forget all stored data…", role: .destructive) { confirmForgetAll = true }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(collectorsWithData.isEmpty)
                    .confirmationDialog("Forget stored data for every collector?",
                                        isPresented: $confirmForgetAll, titleVisibility: .visible) {
                        Button("Forget all", role: .destructive) { model.forgetAllData() }
                    } message: {
                        Text("Counters restart from their next run. Prometheus history is not affected.")
                    }
            } header: {
                Text("Forget data")
            } footer: {
                Text("Removes a collector's import cursor so it starts fresh on the next run. Metrics already stored in Prometheus stay; use `molly prune --older-than` to delete history.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    TextField("Retention", text: model.binding(\.retention))
                        .frame(maxWidth: 120)
                    if !model.retentionIsValid {
                        Text("use a duration like 90d, 26w or 2y")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                HStack {
                    TextField("Compose folder", text: model.binding(\.composeDir),
                              prompt: Text(model.effectiveComposeDir?.path ?? "path to deploy/"))
                    Button("Choose…") { chooseComposeDir() }
                }
                HStack {
                    Button(applyingRetention ? "Applying…" : "Apply retention") { applyRetention() }
                        .disabled(applyingRetention || !model.retentionIsValid || model.effectiveComposeDir == nil)
                    Spacer()
                }
                if !retentionOutput.isEmpty {
                    ScrollView {
                        Text(retentionOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            } header: {
                Text("Prometheus retention")
            } footer: {
                Text("Writes PROMETHEUS_RETENTION to the stack's .env and recreates the Prometheus container with the new limit. Needs Docker and a source checkout of Molly.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .scrollIndicators(.visible)
    }

    private func chooseComposeDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.effectiveComposeDir
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.composeDir = url.path
        }
    }

    private func applyRetention() {
        applyingRetention = true
        retentionOutput = ""
        model.applyRetention { result in
            switch result {
            case .success(let output): retentionOutput = output
            case .failure(let error): retentionOutput = "\(error)"
            }
            applyingRetention = false
        }
    }
}

/// Drawn by hand because .bordered ignores .tint when the window is rendered offscreen.
private struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(configuration.isPressed ? 0.3 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5)))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
