import SwiftUI

/// App entry point. The navigation shell lives in `RootView`; module screens are
/// injected there so each module folder stays independent.
@main
struct LearnPianoApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
        }
    }
}
