import SwiftUI

/// PLACEHOLDER — replaced by the PracticeUI module implementation. Keeps the type name App/RootView presents.
struct PracticeScreen: View {
    let request: PracticeRequest
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            ContentUnavailableView(request.title, systemImage: "pianokeys", description: Text("Practice screen coming in the next build."))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { appModel.dismissPractice() }
                    }
                }
        }
    }
}
