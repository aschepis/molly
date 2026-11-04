import MollyHealthCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if model.needsOnboarding { onboardingSection }
            serverSection
            typesSection
            actionsSection
            statusSection
            Section {
                NavigationLink("Log") { LogView() }
                NavigationLink("About") { AboutView() }
            }
        }
        .navigationTitle("Molly Health")
        .task { await model.refreshTotals() }
    }

    private var onboardingSection: some View {
        Section("Health access") {
            Text("Molly Health reads the types below from Apple Health and posts daily totals to your Mac. iOS asks once for read access to all of them.")
            Button("Grant Health access") { Task { await model.requestAuthorization() } }
            if let error = model.authorizationError { Text(error).foregroundStyle(.red) }
        }
    }

    private var serverSection: some View {
        Section("Mac") {
            TextField("Server URL", text: $model.settings.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Token (collectors.health.token)", text: $model.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Device name", text: $model.settings.deviceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Test connection") { Task { await model.testConnection() } }
            ForEach(model.connectionReport, id: \.self) { Text($0).font(.footnote) }
        }
    }

    private var typesSection: some View {
        Section("Types to send") {
            ForEach(MollyHealthType.allCases, id: \.self) { type in
                Toggle(type.spec.title, isOn: binding(for: type))
            }
        }
    }

    private func binding(for type: MollyHealthType) -> Binding<Bool> {
        Binding(
            get: { model.settings.enabledTypes.contains(type) },
            set: { isOn in
                if isOn { model.settings.enabledTypes.insert(type) } else { model.settings.enabledTypes.remove(type) }
            })
    }

    private var actionsSection: some View {
        Section {
            Button("Send now") { Task { await model.sendNow() } }
                .disabled(model.busy)
            Stepper("Backfill \(model.settings.backfillDays) days", value: $model.settings.backfillDays, in: 1...BackfillPlanner.maxDays)
            Button("Backfill") { Task { await model.backfill() } }
                .disabled(model.busy)
            if let progress = model.backfillProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("\(progress.done) of \(progress.total) days").font(.footnote)
            }
        } header: {
            Text("Send")
        } footer: {
            Text("The Mac keeps only the last 7 days unless collectors.health.maxAgeSeconds is raised; older days are reported as rejected (too_old).")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            row("Last attempt", model.state.lastAttempt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never")
            row("Last result", resultText)
            row("Last error", model.state.lastError ?? "none")
            Button("Recompute today's totals") { Task { await model.refreshTotals() } }
            ForEach(model.totals) { total in
                row(total.title, total.text)
            }
        }
    }

    private var resultText: String {
        guard let status = model.state.lastHTTPStatus else { return "none" }
        let accepted = model.state.lastAccepted.map { "accepted \($0)" } ?? "no reply body"
        let rejected = model.state.lastRejected.values.reduce(0, +)
        return "HTTP \(status), \(accepted), rejected \(rejected)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing) }
    }
}

struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            List(Array(model.log.lines.reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.footnote, design: .monospaced))
            }
        }
        .navigationTitle("Log")
    }
}

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                Text("Molly Health is open source. It reads Apple Health on this phone and posts daily totals to the Mac address you configure, and nowhere else.")
                Text("No analytics, no third-party code, and no network calls other than to the server URL you set.")
                Text("Plain HTTP is allowed because the address is normally a Tailscale name, and the tailnet already encrypts the traffic.")
            }
        }
        .navigationTitle("About")
    }
}
