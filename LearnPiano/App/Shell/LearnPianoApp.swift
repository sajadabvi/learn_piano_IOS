import SwiftUI

/// App entry point. Creates the shared stores once and injects them into the environment; module screens read them with
/// `@Environment(AppModel.self)`, `@Environment(ProfileStore.self)` and `@Environment(ContentStore.self)`.
@main
struct LearnPianoApp: App {
    @State private var appModel = AppModel()
    @State private var profileStore = ProfileStore()
    @State private var contentStore = ContentStore(
        importers: [ParsersMusicXMLImporter(), ParsersMIDIImporter(), ParsersCompactScoreImporter()],
        exporter: { score in ParsersMusicXMLExporter().exportData(score) }
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profileStore)
                .environment(contentStore)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { profileStore.saveNow() }
                }
        }
    }
}
