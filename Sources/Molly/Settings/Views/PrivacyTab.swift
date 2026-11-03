import SwiftUI

/// Placeholder: the privacy fork fills this in. Keep the type name.
struct PrivacyTab: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        VStack {
            Text("Privacy")
                .font(.title2)
            Text("One row per label dimension with allowlist/denylist, patterns, hashing and limits goes here.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
