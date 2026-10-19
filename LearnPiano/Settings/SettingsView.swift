import SwiftUI

/// PLACEHOLDER — replaced by the Settings module implementation.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Settings", systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle("Settings")
        }
    }
}
