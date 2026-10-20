import Foundation
import Observation

/// Loads an arrangement's score (off the main thread, through ContentStore) and opens the practice screen with a
/// request whose `onFinish` folds the session into the learner's profile. Exposes loading and error state for the UI.
@MainActor
@Observable
final class LibraryPracticeLauncher {
    /// Arrangement whose score is being loaded, nil when idle.
    private(set) var loadingArrangementID: String?
    /// Mode of the pending launch (to show the spinner on the right button).
    private(set) var loadingMode: PracticeMode?
    /// Message for the error alert; nil when there is nothing to show.
    var errorMessage: String?

    var isLoading: Bool { loadingArrangementID != nil }

    init() {}

    /// Loads the score and presents practice. Ignores the call while another launch is in flight.
    func launch(song: SongEntry, arrangement: ArrangementEntry, mode: PracticeMode? = nil,
                content: ContentStore, profile: ProfileStore, app: AppModel) async {
        guard loadingArrangementID == nil else { return }
        loadingArrangementID = arrangement.id
        loadingMode = mode
        defer {
            loadingArrangementID = nil
            loadingMode = nil
        }
        do {
            let score = try await content.loadScore(for: arrangement)
            let settings = Self.settings(base: profile.settings.defaultPractice, mode: mode)
            let request = Self.makeRequest(song: song, arrangement: arrangement, score: score, settings: settings, profile: profile)
            app.presentPractice(request)
        } catch {
            errorMessage = Self.errorText(for: error, song: song, arrangement: arrangement)
        }
    }

    // MARK: Pure helpers

    /// Practice settings for a launch: the learner's defaults with the requested mode. A plain "Practice" launch never
    /// starts in Listen (the default would otherwise make the Practice and Listen buttons identical).
    nonisolated static func settings(base: PracticeSettings, mode: PracticeMode?) -> PracticeSettings {
        var s = base
        if let mode {
            s.mode = mode
        } else if s.mode == .listen {
            s.mode = .wait
        }
        // A saved loop belongs to whatever piece it was set on; a new arrangement always starts with the whole piece.
        s.loop = nil
        return s
    }

    /// Subtitle of the practice header: "Beginner · Ludwig van Beethoven".
    nonisolated static func subtitle(song: SongEntry, arrangement: ArrangementEntry) -> String {
        [arrangement.label.isEmpty ? arrangement.difficulty.displayName : arrangement.label, song.composer]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Whether a finished session carries anything worth persisting (a session closed right after opening does not).
    nonisolated static func shouldRecord(_ summary: PracticeSummary) -> Bool {
        if summary.stepsExpected > 0 || summary.wrongNotes > 0 || !summary.measuresCompleted.isEmpty || summary.reachedEnd { return true }
        return summary.durationSeconds >= 5
    }

    static func makeRequest(song: SongEntry, arrangement: ArrangementEntry, score: Score, settings: PracticeSettings, profile: ProfileStore) -> PracticeRequest {
        PracticeRequest(
            score: score,
            arrangementID: arrangement.id,
            title: song.title,
            subtitle: subtitle(song: song, arrangement: arrangement),
            settings: settings,
            onFinish: { [weak profile] summary in
                guard shouldRecord(summary) else { return }
                // PracticeRequest documents that onFinish is always called on the main actor.
                MainActor.assumeIsolated {
                    profile?.record(summary)
                }
            }
        )
    }

    nonisolated static func errorText(for error: Error, song: SongEntry, arrangement: ArrangementEntry) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\u{201C}\(song.title)\u{201D} (\(arrangement.label)) could not be opened. \(reason)"
    }
}
