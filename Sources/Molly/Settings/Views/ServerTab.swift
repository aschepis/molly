import AppKit
import SwiftUI

/// Metrics endpoint, links, extra labels, the hook token and logging.
struct ServerTab: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var newLabelName = ""
    @State private var newLabelValue = ""

    private var metricsURL: String { ServerRules.metricsURL(bind: model.serverBind, port: model.serverPort) }
    private var newLabelError: String? { newLabelName.isEmpty ? nil : ServerRules.labelNameError(newLabelName) }

    var body: some View {
        Form {
            endpointSection
            linksSection
            labelsSection
            alertsSection
            hooksSection
            loggingSection
        }
        .formStyle(.grouped)
    }

    private var endpointSection: some View {
        Section {
            TextField("Bind address", text: model.binding(\.serverBind))
            if let warning = ServerRules.openBindWarning(bind: model.serverBind, token: model.eventsToken) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            TextField("Port", value: model.binding(\.serverPort), formatter: portFormatter)
                .frame(maxWidth: 200)
            HStack {
                Text(metricsURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { Clipboard.copy(metricsURL) }
                Button("Open") { Browser.open(metricsURL) }
            }
        } header: {
            Text("Metrics endpoint")
        } footer: {
            Text("Prometheus in the local stack reaches 127.0.0.1 through host.docker.internal; bind to another address only for a remote scraper.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var linksSection: some View {
        Section("Links") {
            HStack {
                TextField("Grafana", text: model.binding(\.grafanaURL))
                Button("Open") { Browser.open(model.grafanaURL) }
            }
            HStack {
                TextField("Prometheus", text: model.binding(\.prometheusURL))
                Button("Open") { Browser.open(model.prometheusURL) }
            }
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Show macOS notifications for firing alerts", isOn: model.binding(\.alertsNotify))
            ForEach(AlertCatalog.all, id: \.name) { alert in
                Toggle(isOn: model.alertMutedBinding(alert.name)) {
                    VStack(alignment: .leading) {
                        Text("Mute \(alert.name)")
                        Text(alert.summary).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Notifications need Molly.app and permission in System Settings. Muted alerts still show on the dashboards.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var labelsSection: some View {
        Section {
            ForEach(model.extraLabels.keys.sorted(), id: \.self) { name in
                HStack {
                    Text(name)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 120, alignment: .leading)
                    TextField("value", text: labelValueBinding(name))
                    Button("Remove") { model.setExtraLabel(name, nil) }
                }
            }
            HStack {
                TextField("name", text: $newLabelName)
                    .frame(minWidth: 120)
                TextField("value", text: $newLabelValue)
                Button("Add") { addLabel() }
                    .disabled(newLabelName.isEmpty || newLabelError != nil)
            }
            if let error = newLabelError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Extra labels")
        } footer: {
            Text("Attached to every metric next to user and host, for telling machines or roles apart in a fleet.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var hooksSection: some View {
        Section {
            HStack {
                TextField("Events token", text: model.binding(\.eventsToken))
                    .font(.system(.body, design: .monospaced))
                Button("Generate") { model.eventsToken = ServerRules.randomToken() }
            }
        } header: {
            Text("Hooks")
        } footer: {
            Text("POST /event requires this token when set. Rerun `molly hook install` after changing it so Claude Code sends the new one.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var loggingSection: some View {
        Section("Logging") {
            Picker("Log level", selection: model.binding(\.logLevel)) {
                ForEach(ServerRules.logLevels, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 240)
        }
    }

    private var portFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.minimum = NSNumber(value: ServerRules.portRange.lowerBound)
        f.maximum = NSNumber(value: ServerRules.portRange.upperBound)
        f.allowsFloats = false
        f.usesGroupingSeparator = false
        return f
    }

    private func labelValueBinding(_ name: String) -> Binding<String> {
        Binding(get: { model.extraLabels[name] ?? "" }, set: { model.setExtraLabel(name, $0) })
    }

    private func addLabel() {
        model.setExtraLabel(newLabelName, newLabelValue)
        newLabelName = ""
        newLabelValue = ""
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Browser {
    static func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}
