import SwiftUI

/// Placeholder: the server/agents fork fills this in. Keep the type name.
struct ServerTab: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack {
            Text("Server and links")
                .font(.title2)
            Text("Bind address, port, Grafana and Prometheus URLs, log level and extra labels go here.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
