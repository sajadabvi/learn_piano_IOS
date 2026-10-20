import Foundation

/// Everything needed to open the practice screen for a score. Screens (Library, Courses, Import) build one of these and
/// hand it to `AppModel.presentPractice(_:)`; the practice screen (PracticeUI) renders it and reports back through `onFinish`.
struct PracticeRequest: Identifiable {
    let id = UUID()
    var score: Score
    /// Arrangement id used for progress; exercises use "exercise:<exercise-id>".
    var arrangementID: String
    var title: String
    var subtitle: String
    var settings: PracticeSettings
    /// Set for lesson exercises: instructions shown above the score and the pass criteria.
    var exerciseInstructions: String?
    var passCriteria: ExercisePassCriteria?
    /// Custom pass rule for exercises (set by Courses). When present it replaces the default rule below, so the
    /// practice screen's "Passed!" banner and the lesson's progress always agree.
    var grade: ((PracticeSummary) -> Bool)?
    /// Called on the main actor whenever a session ends (stop, finish, or screen dismissed), possibly several times per screen.
    var onFinish: ((PracticeSummary) -> Void)?

    init(score: Score, arrangementID: String, title: String, subtitle: String = "", settings: PracticeSettings = PracticeSettings(), exerciseInstructions: String? = nil, passCriteria: ExercisePassCriteria? = nil, onFinish: ((PracticeSummary) -> Void)? = nil) {
        self.score = score
        self.arrangementID = arrangementID
        self.title = title
        self.subtitle = subtitle
        self.settings = settings
        self.exerciseInstructions = exerciseInstructions
        self.passCriteria = passCriteria
        self.onFinish = onFinish
    }

    /// Whether a summary satisfies the exercise's pass criteria (always true for songs).
    func passes(_ summary: PracticeSummary) -> Bool {
        if let grade { return grade(summary) }
        guard let c = passCriteria else { return true }
        let accuracyOK = summary.mode == .wait ? summary.reachedEnd : summary.accuracy >= c.minimumAccuracy
        return accuracyOK && summary.wrongNotes <= c.maxWrongNotes
    }
}
