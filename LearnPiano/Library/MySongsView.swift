import SwiftUI

/// PLACEHOLDER — replaced by the Library module implementation.
struct MySongsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("My Songs", systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle("My Songs")
        }
    }
}
