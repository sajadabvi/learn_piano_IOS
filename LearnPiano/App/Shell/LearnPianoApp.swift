import SwiftUI
import os

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

    private static let log = Logger(subsystem: "LearnPiano", category: "App")

    init() {
        // Category only; each screen that makes sound activates the session itself (ARCHITECTURE §7).
        do {
            if !AudioSessionConfigurator.isConfigured() { try AudioSessionConfigurator.configure() }
        } catch {
            Self.log.error("Audio session configuration failed at launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profileStore)
                .environment(contentStore)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    // "Open in LearnPiano" from Files, Safari, Mail or AirDrop: hand the file to the Import screen.
                    ImportIncomingFiles.shared.receive(url, appModel: appModel)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { profileStore.saveNow() }
                }
        }
    }
}
