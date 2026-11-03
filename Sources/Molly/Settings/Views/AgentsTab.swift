import SwiftUI

/// Placeholder: the server/agents fork fills this in. Keep the type name.
struct AgentsTab: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack {
            Text("Insights and agents")
                .font(.title2)
            Text("Insights backend, model, schedule and the MCP Prometheus URL go here.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
