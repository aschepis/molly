import SwiftUI

/// Placeholder: the collectors fork fills this in. Keep the type name.
struct CollectorsTab: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack {
            Text("Collectors")
                .font(.title2)
            Text("Per-collector on/off switches, intervals and permission badges go here.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
