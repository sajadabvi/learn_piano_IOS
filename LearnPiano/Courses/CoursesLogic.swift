import Foundation

// MARK: - Progress

/// Completion of one course, computed from per-lesson progress.
struct CoursesProgressSummary: Hashable, Sendable {
    var completedLessons: Int
    var totalLessons: Int

    /// 0…1 share of completed lessons.
    var fraction: Double { totalLessons == 0 ? 0 : Double(completedLessons) / Double(totalLessons) }
    var isComplete: Bool { totalLessons > 0 && completedLessons >= totalLessons }
    /// "3/6 lessons".
    var label: String { "\(completedLessons)/\(totalLessons) lessons" }
}

/// Pure progress calculations over the curriculum, with lesson progress supplied by a lookup.
enum CoursesProgressCalculator {
    static func summary(for course: Course, progress: (String) -> LessonProgress) -> CoursesProgressSummary {
        CoursesProgressSummary(completedLessons: course.lessons.filter { progress($0.id).completed }.count,
                               totalLessons: course.lessons.count)
    }

    /// The first lesson of the course that is not completed yet (nil when the course is done).
    static func nextLessonToStudy(in course: Course, progress: (String) -> LessonProgress) -> Lesson? {
        course.lessons.first { !progress($0.id).completed }
    }

    /// The most recently opened lesson that is not completed, across all courses, for the "Continue" card.
    static func continueLesson(in courses: [Course], progress: (String) -> LessonProgress) -> (course: Course, lesson: Lesson)? {
        var best: (course: Course, lesson: Lesson, opened: Date)?
        for c in courses {
            for l in c.lessons {
                let p = progress(l.id)
                guard !p.completed, let opened = p.lastOpened else { continue }
                if best.map({ opened > $0.opened }) ?? true { best = (c, l, opened) }
            }
        }
        return best.map { ($0.course, $0.lesson) }
    }

    /// Passed exercises of a lesson, as "1/2 exercises", or nil when the lesson has none.
    static func exerciseLabel(for lesson: Lesson, progress: LessonProgress) -> String? {
        let ids = lesson.exercises.map(\.id)
        guard !ids.isEmpty else { return nil }
        let passed = ids.filter { progress.completedExerciseIDs.contains($0) }.count
        return "\(passed)/\(ids.count) \(ids.count == 1 ? "exercise" : "exercises")"
    }

    /// Whether a lesson should be completed after an exercise in it passes. A lesson the learner already completed
    /// (for example with "Mark lesson complete") stays completed; otherwise it completes once every exercise passed.
    static func lessonCompletedAfterPassing(wasCompleted: Bool, passedExerciseIDs: Set<String>, allExerciseIDs: [String]) -> Bool {
        wasCompleted || Set(allExerciseIDs).isSubset(of: passedExerciseIDs)
    }

    /// "1 lesson", "6 lessons".
    static func lessonCountLabel(_ n: Int) -> String { n == 1 ? "1 lesson" : "\(n) lessons" }

    /// Total estimated minutes of a course.
    static func totalMinutes(of course: Course) -> Int { course.lessons.reduce(0) { $0 + $1.minutes } }
}

// MARK: - Exercise launching

/// Builds practice requests for lesson exercises and grades the results.
enum CoursesExerciseRequestFactory {
    /// Practice settings for an exercise: the learner's defaults with the exercise's mode and hands, and no loop.
    static func settings(for exercise: Exercise, base: PracticeSettings) -> PracticeSettings {
        var s = base
        s.mode = exercise.mode
        s.hands = exercise.hands
        s.loop = nil
        return s
    }

    /// Listen exercises have no notes to judge, so PracticeUI gets no criteria; Courses grades them on listening time.
    static func passCriteria(for exercise: Exercise) -> ExercisePassCriteria? {
        exercise.mode == .listen ? nil : exercise.pass
    }

    /// Share of the piece (in score time at speed 1) a Listen session must cover to pass.
    static let requiredListenShare: Double = 0.9

    /// Whether a finished session passes the exercise.
    ///
    /// - The session must use the exercise's mode, and its hands: a two-hand exercise needs both hands, a one-hand
    ///   exercise accepts that hand or both.
    /// - Listen: the Practice engine never reports `reachedEnd` in Listen mode, so the session passes when its playing
    ///   time (pauses excluded), converted to score time by the speed, covers at least 90% of `requiredListenSeconds`.
    /// - Just Play: the run must reach the end (accuracy only counts steps actually reached, so a partial run would
    ///   otherwise score 100%), with the minimum accuracy and at most the allowed wrong notes.
    /// - Wait: the request's own criteria (reach the end, at most the allowed wrong notes).
    static func passes(_ summary: PracticeSummary, exercise: Exercise, request: PracticeRequest, requiredListenSeconds: Double) -> Bool {
        guard summary.mode == exercise.mode else { return false }
        let handsOK = exercise.hands == .both ? summary.hands == .both : (summary.hands == exercise.hands || summary.hands == .both)
        guard handsOK else { return false }
        switch exercise.mode {
        case .listen:
            guard summary.durationSeconds > 0 else { return false }
            return summary.durationSeconds * max(summary.speed, 0.1) >= requiredListenShare * requiredListenSeconds
        case .justPlay:
            return summary.reachedEnd
                && summary.accuracy >= exercise.pass.minimumAccuracy
                && summary.wrongNotes <= exercise.pass.maxWrongNotes
        case .wait:
            // Always the default criteria rule: the request may carry a grading hook that calls back into this function.
            var plain = request
            plain.grade = nil
            return plain.passes(summary)
        }
    }

    /// The request for an exercise; `onFinish` receives every finished session and whether it passed.
    static func makeRequest(exercise: Exercise, lesson: Lesson, course: Course, score: Score, baseSettings: PracticeSettings,
                            onFinish: @escaping (PracticeSummary, Bool) -> Void) -> PracticeRequest {
        var request = PracticeRequest(
            score: score,
            arrangementID: CoursesCurriculum.arrangementID(forExercise: exercise.id),
            title: exercise.title,
            subtitle: "\(course.title) · \(lesson.title)",
            settings: settings(for: exercise, base: baseSettings),
            exerciseInstructions: exercise.instructions,
            passCriteria: passCriteria(for: exercise)
        )
        let fullSeconds = exercise.mode == .listen ? score.makeTimeline().totalSeconds(speed: 1) : 0
        let graded = request
        let rule: (PracticeSummary) -> Bool = { summary in
            passes(summary, exercise: exercise, request: graded, requiredListenSeconds: fullSeconds)
        }
        request.grade = rule
        request.onFinish = { summary in onFinish(summary, rule(summary)) }
        return request
    }

    /// One-line description of what passing requires.
    static func passDescription(for exercise: Exercise) -> String {
        switch exercise.mode {
        case .listen:
            return "Listen to the end"
        case .wait:
            return exercise.pass.maxWrongNotes == 0 ? "Play to the end with no wrong notes" : "Play to the end with at most \(exercise.pass.maxWrongNotes) wrong notes"
        case .justPlay:
            let percent = Int((exercise.pass.minimumAccuracy * 100).rounded())
            return "Play to the end with \(percent)% accuracy and at most \(exercise.pass.maxWrongNotes) wrong notes"
        }
    }

    /// SF Symbol for an exercise's mode.
    static func symbol(for mode: PracticeMode) -> String {
        switch mode {
        case .wait: return "hand.raised"
        case .justPlay: return "metronome"
        case .listen: return "headphones"
        }
    }
}

// MARK: - Keyboard illustrations

enum CoursesKeyboardIllustrationLayout {
    /// The keys shown for an illustration: a snug window around the pitches, at least two octaves wide.
    static func visibleRange(for pitches: [Int]) -> ClosedRange<Int> {
        let valid = pitches.filter { Pitch.pianoRange.contains($0) }
        guard let lo = valid.min(), let hi = valid.max() else { return KeyboardRangeFitter.snappedToWhiteKeys(48...72) }
        return KeyboardRangeFitter.tightFit(scoreRange: lo...hi, paddingWhiteKeys: 2)
    }

    /// Labels every key when the window is narrow enough to read them, otherwise only the Cs.
    static func labels(for range: ClosedRange<Int>) -> KeyboardNoteLabels {
        KeyboardRangeFitter.whiteKeyCount(in: range) <= 22 ? .all : .cOnly
    }

    /// Highlighted keys: each illustrated pitch shown as an expected key in the neutral accent.
    static func keyStates(for pitches: [Int]) -> [Int: KeyboardKeyState] {
        var states: [Int: KeyboardKeyState] = [:]
        for p in pitches where Pitch.pianoRange.contains(p) { states[p] = .expected(nil) }
        return states
    }

    /// Accessible description: "Highlighted keys: C4, E4, G4".
    static func accessibilityLabel(for pitches: [Int]) -> String {
        let names = pitches.sorted().map { MusicHelpers.noteName(midi: $0) }
        return names.isEmpty ? "Keyboard" : "Highlighted keys: " + names.joined(separator: ", ")
    }
}

// MARK: - Notation illustrations

enum CoursesNotationIllustrationLayout {
    static let staffSpace: CGFloat = 8

    /// Widest the illustration is drawn, so a one-bar example is not stretched across the whole page.
    static func maximumWidth(for score: Score) -> CGFloat {
        CGFloat(140 + 230 * max(1, score.measures.count))
    }

    /// The layout request `NotationScoreView` makes in page mode for this width (same quantisation), so the plan
    /// computed here for sizing is shared through `NotationLayoutCache`.
    static func layoutRequest(score: Score, width: CGFloat) -> NotationLayoutRequest? {
        guard width > 0 else { return nil }
        let quantized = (width / 16).rounded(.down) * 16
        return NotationLayoutRequest(score: score, options: NotationLayoutOptions(staffSpace: staffSpace, mode: .page(width: quantized), showsFingering: true))
    }
}
