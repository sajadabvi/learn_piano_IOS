import Foundation

// MARK: - End-of-session record (persisted by the Library module)

/// Everything the Library module needs to persist about one finished practice session.
///
/// `summary` is the Core `PracticeSummary` that `UserProfile.record(_:)` folds into `SongProgress`; the other
/// fields are detail for history views (they are optional to persist). Codable, so the whole record can be
/// written as JSON next to the profile if the Library module wants a session history.
struct PracticeSessionRecord: Hashable, Codable, Sendable {
    var summary: PracticeSummary
    var statistics: PracticeStatistics
    var scoreTitle: String
    var loop: MeasureRange?
    var endedAt: Date
    /// Every record emitted during the session, in order (uncorrected log; `statistics` is authoritative).
    var played: [PlayedRecord]
}

/// Builds the Core `PracticeSummary` (and the full `PracticeSessionRecord`) from engine statistics.
///
/// Mapping of "correct" per mode:
/// * Wait Mode: every completed step is a hit; a step counts as correct only when no wrong note was played
///   while it was expected (`PracticeStatistics.cleanSteps`). So `accuracy` = share of steps played cleanly.
/// * Just Play: correct, early and late steps all count as correct (the learner played the right notes inside
///   the timing window); missed steps do not.
/// * Listen: nothing is expected; the summary only carries the time practiced.
enum PracticeSummaryBuilder {
    /// The Core summary for one session.
    static func summary(arrangementID: String, startedAt: Date, durationSeconds: Double, settings: PracticeSettings, statistics: PracticeStatistics, reachedEnd: Bool) -> PracticeSummary {
        let correct: Int
        switch settings.mode {
        case .wait: correct = statistics.cleanSteps
        case .justPlay: correct = statistics.stepsHit
        case .listen: correct = 0
        }
        let expected = settings.mode == .listen ? 0 : statistics.stepsExpected
        return PracticeSummary(
            arrangementID: arrangementID,
            startedAt: startedAt,
            durationSeconds: max(0, durationSeconds),
            mode: settings.mode,
            hands: settings.hands,
            speed: settings.speed,
            stepsExpected: expected,
            stepsCorrect: min(correct, expected),
            wrongNotes: settings.mode == .listen ? 0 : statistics.wrongNotes,
            mistakesByMeasure: settings.mode == .listen ? [:] : statistics.mistakesByMeasure,
            measuresCompleted: settings.mode == .listen ? [] : statistics.measuresCompleted,
            reachedEnd: reachedEnd
        )
    }

    /// The full record for one session.
    static func record(arrangementID: String, scoreTitle: String, startedAt: Date, endedAt: Date, durationSeconds: Double, settings: PracticeSettings, statistics: PracticeStatistics, played: [PlayedRecord], reachedEnd: Bool) -> PracticeSessionRecord {
        PracticeSessionRecord(
            summary: summary(arrangementID: arrangementID, startedAt: startedAt, durationSeconds: durationSeconds, settings: settings, statistics: statistics, reachedEnd: reachedEnd),
            statistics: statistics,
            scoreTitle: scoreTitle,
            loop: settings.loop,
            endedAt: endedAt,
            played: played
        )
    }
}
