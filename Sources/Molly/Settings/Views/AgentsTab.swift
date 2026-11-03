import SwiftUI

/// The insights collector, the MCP server command and the tuner.
struct AgentsTab: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var newAPIKey = ""
    @State private var runningInsights = false
    @State private var runningTune = false
    @State private var tuneOutput = ""
    @State private var recommendations: [Recommendation] = []

    private var binaryPath: String { Bundle.main.executablePath ?? CommandLine.arguments.first ?? "molly" }
    private var mcpCommand: String { AgentsRules.mcpAddCommand(binary: binaryPath) }
    private var hasPatches: Bool { recommendations.contains { $0.configPatch != nil } }

    var body: some View {
        Form {
            insightsSection
            mcpSection
            tuneSection
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .scrollIndicators(.visible)
    }

    private var insightsSection: some View {
        Section {
            Toggle("Write a daily report", isOn: model.binding(\.insightsEnabled))
            Picker("Backend", selection: model.binding(\.insightsBackend)) {
                ForEach(AgentsRules.backends, id: \.self) { Text($0).tag($0) }
            }
            TextField("Model", text: model.binding(\.insightsModel))
                .multilineTextAlignment(.trailing)
            HStack {
                SecureField("API key", text: $newAPIKey,
                            prompt: Text(model.hasInsightsAPIKey ? "key set; type to replace" : "no key; type to set"))
                Button("Save key") {
                    model.setInsightsAPIKey(newAPIKey)
                    newAPIKey = ""
                }
                .disabled(newAPIKey.isEmpty)
                Button("Clear") { model.setInsightsAPIKey("") }
                    .disabled(!model.hasInsightsAPIKey)
            }
            Picker("Daily at", selection: model.binding(\.insightsDailyHour)) {
                ForEach(0...23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Toggle("Also write a weekly report", isOn: model.binding(\.insightsWeekly))
            HStack {
                Button("Open latest report") {
                    Browser.open(ServerRules.insightsURL(bind: model.serverBind, port: model.serverPort))
                }
                Button(runningInsights ? "Running…" : "Run now") { runInsights() }
                    .disabled(runningInsights || model.isDirty)
                if model.isDirty {
                    Text("apply your changes first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Insights")
        } footer: {
            Text("auto uses the API key when set, else the claude CLI. The key is written to config.json and never shown again.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var mcpSection: some View {
        Section {
            TextField("Prometheus URL for MCP", text: model.binding(\.mcpPrometheusURL))
            HStack(alignment: .top) {
                Text(mcpCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") { Clipboard.copy(mcpCommand) }
            }
        } header: {
            Text("MCP")
        } footer: {
            Text("Registers Molly's read-only query tools with Claude Code. Run the command once in a terminal.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var tuneSection: some View {
        Section {
            HStack {
                Button(runningTune ? "Running…" : "Run molly tune") { runTune() }
                    .disabled(runningTune)
                Button("Stage recommendations") { stageRecommendations() }
                    .disabled(!hasPatches)
            }
            if !tuneOutput.isEmpty {
                ScrollView {
                    Text(tuneOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 200)
            }
        } header: {
            Text("Tune")
        } footer: {
            Text("Rules-based suggestions from the live registry and collector health. Staging copies their config patches into this window; press Apply to save them.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func runInsights() {
        runningInsights = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AgentActions.runInsights() }
            DispatchQueue.main.async {
                switch result {
                case .success(let report):
                    model.lastMessage = report.cached
                        ? "Report for \(report.date) already existed"
                        : "Wrote report for \(report.date) via \(report.backend)"
                    model.lastError = nil
                case .failure(let error):
                    model.lastError = "\(error)"
                }
                runningInsights = false
            }
        }
    }

    private func runTune() {
        runningTune = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AgentActions.runTune() }
            DispatchQueue.main.async {
                switch result {
                case .success(let recs):
                    recommendations = recs
                    tuneOutput = TuneReport.text(recs)
                case .failure(let error):
                    recommendations = []
                    tuneOutput = "\(error)"
                }
                runningTune = false
            }
        }
    }

    private func stageRecommendations() {
        let paths = AgentsRules.stage(recommendations, into: model)
        model.lastMessage = "Staged \(paths.count) settings; press Apply to save"
    }
}
