import SwiftUI

/// PLACEHOLDER — replaced by the Courses module implementation.
struct CoursesHomeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Courses", systemImage: "hammer", description: Text("Coming soon"))
                .navigationTitle("Courses")
        }
    }
}
