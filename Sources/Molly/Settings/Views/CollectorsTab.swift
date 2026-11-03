import Combine
import SwiftUI

/// Every collector with its switch, interval and live status.
struct CollectorsTab: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var query = ""
    // Re-renders the "ok Ns ago" ages while the window is open.
    @State private var tick = Date()
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var visible: [CollectorInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return CollectorCatalog.all }
        return CollectorCatalog.all.filter {
            $0.title.lowercased().contains(needle) || $0.name.contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search collectors", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Reset intervals to defaults") {
                    for info in CollectorCatalog.all {
                        model.setCollectorInterval(info.name, info.defaultInterval)
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Collectors")
                    ForEach(visible.filter { !$0.isOptIn }) { info in
                        CollectorRow(info: info, now: tick)
                        Divider()
                    }
                    SectionHeader(title: "Needs extra permission")
                    ForEach(visible.filter { $0.isOptIn }) { info in
                        CollectorRow(info: info, now: tick)
                        Divider()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 300)
        }
        .onReceive(clock) { tick = $0 }
    }
}

/// A plain header on the window background; List section headers get their own band.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

private struct CollectorRow: View {
    @EnvironmentObject private var model: SettingsModel
    let info: CollectorInfo
    let now: Date

    private static let minInterval: Double = 1
    private static let maxInterval: Double = 86_400

    private var enabled: Bool { model.collectorEnabled(info.name) }
    private var status: CollectorManager.Status? { model.status(of: info.name) }
    private var pill: CollectorStatusText.Pill {
        CollectorStatusText.pill(enabled: enabled, status: status, now: now)
    }
    private var needsPermission: Bool {
        enabled && status?.unavailable == true && info.permission != .none
    }

    private var interval: Binding<Double> {
        Binding(
            get: { model.collectorInterval(info.name) },
            set: { model.setCollectorInterval(info.name, min(max($0, Self.minInterval), Self.maxInterval)) })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: model.collectorEnabledBinding(info.name))
                .labelsHidden()
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                Text(info.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if needsPermission {
                    HStack(spacing: 6) {
                        Label(info.permission.title, systemImage: "lock")
                            .font(.caption)
                            .foregroundColor(.orange)
                        if let url = info.permission.settingsURL {
                            Button("Open System Settings") { NSWorkspace.shared.open(url) }
                                .controlSize(.small)
                        }
                    }
                } else if info.permission != .none {
                    Text("Needs \(info.permission.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField("", value: interval, format: .number)
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: interval, in: Self.minInterval...Self.maxInterval)
                    .labelsHidden()
                Text("s")
                    .foregroundColor(.secondary)
            }
            .frame(width: 130, alignment: .trailing)
            .disabled(!enabled)
            StatusPill(pill: pill)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.6)
    }
}

private struct StatusPill: View {
    let pill: CollectorStatusText.Pill

    private var color: Color {
        switch pill.kind {
        case .off, .waiting: return .secondary
        case .ok: return .green
        case .errors: return .orange
        case .unavailable: return .red
        }
    }

    var body: some View {
        Text(pill.text)
            .font(.caption)
            .foregroundColor(color)
            .lineLimit(1)
    }
}
