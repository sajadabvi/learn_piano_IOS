import SwiftUI

/// PLACEHOLDER — replaced by the Library module implementation.
struct SongsBrowserView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Songs", systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle("Songs")
        }
    }
}
