import SwiftUI

/// Every sensitive label dimension: whether real values are recorded, how
/// they are filtered, and what the running daemon has actually emitted.
struct PrivacyTab: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var audit: [String: PrivacyAuditSummary.Counts] = [:]
    @State private var auditNote = "not fetched yet"

    private var groups: [CollectorInfo] {
        CollectorCatalog.all.filter { !PrivacyCatalog.dimensions(for: $0.name).isEmpty }
    }

    var body: some View {
        VStack(spacing: 8) {
            PresetBar()
            HStack {
                Text("What has left this machine: \(auditNote)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { fetchAudit() }
                    .controlSize(.small)
            }
            List {
                ForEach(groups) { info in
                    Section {
                        ForEach(PrivacyCatalog.dimensions(for: info.name)) { dimension in
                            PolicyRow(dimension: dimension,
                                      collectorOn: model.collectorEnabled(info.name),
                                      counts: audit[dimension.id])
                        }
                    } header: {
                        Text(model.collectorEnabled(info.name) ? info.title : "\(info.title) (collector off)")
                    }
                }
            }
            .frame(minHeight: 280)
        }
        .onAppear { fetchAudit() }
    }

    private func fetchAudit() {
        guard let url = URL(string: "http://\(model.serverBind):\(model.serverPort)/privacy") else {
            auditNote = "bad server address"
            return
        }
        auditNote = "fetching…"
        URLSession.shared.dataTask(with: url) { data, _, error in
            let outcome: Result<[String: PrivacyAuditSummary.Counts], Error>
            if let data, error == nil {
                outcome = Result { try PrivacyAuditSummary.parse(data) }
            } else {
                outcome = .failure(error ?? URLError(.badServerResponse))
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let counts):
                    audit = counts
                    auditNote = "from the running daemon, "
                        + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                case .failure:
                    audit = [:]
                    auditNote = "daemon not reachable on \(model.serverBind):\(model.serverPort)"
                }
            }
        }.resume()
    }
}

private struct PresetBar: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Presets")
                ForEach(SettingsModel.Preset.allCases) { preset in
                    Button(preset.title) { model.applyPreset(preset) }
                }
            }
            Text("A preset rewrites every policy below and the collector switches; nothing changes until you press Apply.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PolicyRow: View {
    @EnvironmentObject private var model: SettingsModel
    let dimension: PrivacyDimension
    let collectorOn: Bool
    let counts: PrivacyAuditSummary.Counts?

    private var policy: LabelPolicy { model.policy(dimension) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Toggle("Record actual values", isOn: model.policyEnabledBinding(dimension))
                    .toggleStyle(.switch)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(dimension.title)
                    Text(dimension.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if dimension.permission != .none {
                        Text("Needs \(dimension.permission.title)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(counts?.summary ?? "no audit data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 170, alignment: .trailing)
            }
            if policy.enabled {
                PolicyEditor(dimension: dimension)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 2)
        .opacity(collectorOn ? 1 : 0.5)
    }
}

private struct PolicyEditor: View {
    @EnvironmentObject private var model: SettingsModel
    let dimension: PrivacyDimension
    @State private var patternDraft = ""

    private var policy: LabelPolicy { model.policy(dimension) }

    private var limit: Binding<Int> {
        Binding(
            get: { model.policy(dimension).maxCardinality },
            set: { model.setPolicyMaxCardinality(dimension, max(0, $0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: model.policyModeBinding(dimension)) {
                Text("Denylist: record everything except the patterns").tag(LabelPolicy.Mode.denylist)
                Text("Allowlist: record only the patterns").tag(LabelPolicy.Mode.allowlist)
            }
            .pickerStyle(.radioGroup)
            VStack(alignment: .leading, spacing: 2) {
                Text("Patterns, one per line. `*` matches anything; a bare `example.com` also matches its subdomains.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $patternDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 48, maxHeight: 96)
                    .border(Color.secondary.opacity(0.3))
            }
            HStack(spacing: 12) {
                Toggle("Hash values", isOn: model.policyHashBinding(dimension))
                if policy.hash {
                    Text(model.hasSalt(dimension) ? "salt set" : "no salt")
                        .font(.caption)
                        .foregroundColor(model.hasSalt(dimension) ? .secondary : .orange)
                    Button("Regenerate salt") { model.regenerateSalt(dimension) }
                        .controlSize(.small)
                }
                Spacer()
                Text("Limit")
                TextField("", value: limit, format: .number)
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: limit, in: 0...10_000)
                    .labelsHidden()
                Text(policy.maxCardinality == 0 ? "unlimited" : "distinct values")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { patternDraft = PatternText.join(policy.patterns) }
        // A preset or Revert changes the patterns under the editor; only then
        // overwrite what the user is typing.
        .onChange(of: policy.patterns) { patterns in
            if PatternText.split(patternDraft) != patterns { patternDraft = PatternText.join(patterns) }
        }
        .onChange(of: patternDraft) { text in
            let parsed = PatternText.split(text)
            if parsed != policy.patterns { model.setPolicyPatterns(dimension, parsed) }
        }
    }
}
