import SwiftUI

/// The Settings window's root: one tab per area and a footer that applies
/// or reverts the pending edits.
struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                CollectorsTab()
                    .tabItem { Label("Collectors", systemImage: "square.stack.3d.up") }
                PrivacyTab()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
                ServerTab()
                    .tabItem { Label("Server", systemImage: "network") }
                AgentsTab()
                    .tabItem { Label("Agents", systemImage: "sparkles") }
                MaintenanceTab()
                    .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
            }
            .padding([.horizontal, .top], 12)
            Divider()
            SettingsFooter()
                .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct SettingsFooter: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        HStack {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if let invalid = model.validationError {
                Label(invalid, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if model.isDirty {
                Label("Unsaved changes", systemImage: "pencil")
                    .foregroundColor(.secondary)
            } else if let message = model.lastMessage {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundColor(.secondary)
            } else {
                Text(model.document.url.path)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Apply") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || model.validationError != nil)
        }
        .font(.callout)
    }
}
