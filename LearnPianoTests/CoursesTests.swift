import XCTest
@testable import LearnPiano

final class CoursesTests: XCTestCase {
    private let courses = CoursesCurriculum.courses
    private var allLessons: [Lesson] { courses.flatMap(\.lessons) }

    // MARK: Curriculum shape

    func testCoursesAppearInTeachingOrderWithLevels() {
        XCTAssertEqual(courses.map(\.title), ["Welcome to the Piano", "Reading Music", "Chords and Scales", "Playing with Expression and Improvising"])
        XCTAssertEqual(courses.map(\.level), [.beginner, .beginner, .intermediate, .advanced])
        XCTAssertEqual(courses.map { $0.lessons.count }, [6, 6, 5, 3])
    }

    func testLessonTitlesFollowTheSyllabus() {
        XCTAssertEqual(CoursesCurriculum.welcomeCourse.lessons.map(\.title), [
            "The keyboard layout", "Finger numbers", "Finding middle C", "Right-hand C position", "Left-hand C position", "Both hands together",
        ])
        XCTAssertEqual(CoursesCurriculum.readingMusicCourse.lessons.last?.title, "Your first song: Ode to Joy")
        XCTAssertEqual(CoursesCurriculum.chordsAndScalesCourse.lessons.first?.title, "Triads: C, F and G")
        XCTAssertEqual(CoursesCurriculum.expressionCourse.lessons.map(\.title), ["Dynamics and phrasing", "12-bar blues improvisation", "Practising a hard piece"])
    }

    func testIDsAreUnique() {
        let courseIDs = courses.map(\.id)
        XCTAssertEqual(Set(courseIDs).count, courseIDs.count, "duplicate course id")
        let lessonIDs = allLessons.map(\.id)
        XCTAssertEqual(Set(lessonIDs).count, lessonIDs.count, "duplicate lesson id")
        let exerciseIDs = CoursesCurriculum.allExercises.map(\.id)
        XCTAssertEqual(Set(exerciseIDs).count, exerciseIDs.count, "duplicate exercise id")
        XCTAssertTrue(Set(lessonIDs).isDisjoint(with: Set(courseIDs)))
    }

    func testEveryLessonHasBlocksAndTeachingText() {
        for lesson in allLessons {
            XCTAssertFalse(lesson.blocks.isEmpty, "\(lesson.id) has no blocks")
            XCTAssertGreaterThan(lesson.minutes, 0, lesson.id)
            XCTAssertFalse(lesson.summary.isEmpty, lesson.id)
            let paragraphs = lesson.blocks.reduce(0) { n, block in
                if case .text(let t) = block { return n + CoursesMarkdown.paragraphs(in: t).count }
                return n
            }
            XCTAssertGreaterThanOrEqual(paragraphs, 2, "\(lesson.id) needs at least two paragraphs")
            XCTAssertTrue(lesson.blocks.contains { if case .tip = $0 { return true } else { return false } }, "\(lesson.id) has no tip")
        }
    }

    func testEveryExerciseHasAScoreFileThatExists() throws {
        let songs = Self.songsDirectory
        for exercise in CoursesCurriculum.allExercises {
            XCTAssertTrue(exercise.scoreFileName != nil || exercise.inlineScore != nil, "\(exercise.id) has no score")
            guard let file = exercise.scoreFileName else { continue }
            let inBundle = Bundle.main.url(forResource: file, withExtension: nil) != nil
            let onDisk = FileManager.default.fileExists(atPath: songs.appendingPathComponent(file).path)
            XCTAssertTrue(inBundle || onDisk, "\(file) (exercise \(exercise.id)) is not in Content/Songs")
            XCTAssertFalse(exercise.instructions.isEmpty, exercise.id)
        }
    }

    func testExercisesUseTheSpecifiedFiles() {
        XCTAssertEqual(Set(CoursesCurriculum.bundledFileNames), [
            "ex-middle-c__beginner.musicxml", "ex-c-position-rh__beginner.musicxml", "ex-c-position-lh__beginner.musicxml",
            "ex-c-position-both__beginner.musicxml", "ex-rhythm-quarters-halves__beginner.musicxml", "ex-rhythm-eighths__beginner.musicxml",
            "ode-to-joy__beginner.musicxml", "ex-triads-c-f-g__beginner.musicxml", "ex-c-major-scale__intermediate.musicxml",
            "ex-g-major-scale__intermediate.musicxml", "ex-chord-progression-i-iv-v__intermediate.musicxml", "ex-intervals__beginner.musicxml",
            "gymnopedie-1__intermediate.musicxml", "ex-blues-improv-base__intermediate.musicxml", "fur-elise__intermediate.musicxml",
        ])
    }

    func testOdeToJoyIsRightHandThenBoth() {
        let exercises = CoursesCurriculum.readingOdeToJoy.exercises
        XCTAssertEqual(exercises.map(\.hands), [.right, .both])
        XCTAssertTrue(exercises.allSatisfy { $0.scoreFileName == "ode-to-joy__beginner.musicxml" })
    }

    func testBluesIsListenThenLeftHandWait() {
        let exercises = CoursesCurriculum.expressionBlues.exercises
        XCTAssertEqual(exercises.map(\.mode), [.listen, .wait])
        XCTAssertEqual(exercises.last?.hands, .left)
        XCTAssertEqual(CoursesCurriculum.expressionDynamics.exercises.first?.mode, .listen)
    }

    func testIllustrationsAreWellFormed() {
        for lesson in allLessons {
            for block in lesson.blocks {
                switch block {
                case .keyboardIllustration(let pitches, let caption):
                    XCTAssertFalse(pitches.isEmpty, lesson.id)
                    XCTAssertFalse(caption.isEmpty, lesson.id)
                    let range = CoursesKeyboardIllustrationLayout.visibleRange(for: pitches)
                    for p in pitches { XCTAssertTrue(range.contains(p), "\(lesson.id): \(p) outside \(range)") }
                    XCTAssertEqual(Set(CoursesKeyboardIllustrationLayout.keyStates(for: pitches).keys), Set(pitches))
                case .notationIllustration(let score, let caption):
                    XCTAssertFalse(caption.isEmpty, lesson.id)
                    XCTAssertFalse(score.measures.isEmpty, lesson.id)
                    XCTAssertGreaterThan(score.noteCount(), 0, lesson.id)
                    for (i, m) in score.measures.enumerated() {
                        XCTAssertFalse(m.events(for: .right).isEmpty, "\(lesson.id) measure \(i) has an empty treble staff")
                        XCTAssertFalse(m.events(for: .left).isEmpty, "\(lesson.id) measure \(i) has an empty bass staff")
                        XCTAssertLessThanOrEqual(m.contentLength, score.timeSignature(atMeasure: i).measureTicks, "\(lesson.id) measure \(i) overflows")
                    }
                case .glossary(let rows):
                    XCTAssertFalse(rows.isEmpty, lesson.id)
                    for row in rows { XCTAssertEqual(row.count, 2, "\(lesson.id): glossary row \(row)") }
                default:
                    break
                }
            }
        }
    }

    func testGMajorIllustrationUsesKeySignature() {
        let score = CoursesCurriculum.chordsGScale
        XCTAssertEqual(score.initialKey.fifths, 1)
        XCTAssertTrue(score.allEvents.flatMap(\.midiPitches).contains(78))
    }

    // MARK: Lookups

    func testNextLessonWithinAndAcrossCourses() {
        XCTAssertEqual(CoursesCurriculum.nextLesson(after: "welcome-keyboard-layout")?.lesson.id, "welcome-finger-numbers")
        let crossing = CoursesCurriculum.nextLesson(after: "welcome-both-hands")
        XCTAssertEqual(crossing?.course.id, "reading-music")
        XCTAssertEqual(crossing?.lesson.id, CoursesCurriculum.readingMusicCourse.lessons.first?.id)
        XCTAssertNil(CoursesCurriculum.nextLesson(after: "expression-hard-piece"))
        XCTAssertNil(CoursesCurriculum.nextLesson(after: "no-such-lesson"))
    }

    func testLessonAndCourseLookup() {
        XCTAssertEqual(CoursesCurriculum.lesson(id: "chords-intervals")?.title, "Intervals")
        XCTAssertEqual(CoursesCurriculum.course(containingLesson: "chords-intervals")?.id, "chords-scales")
        XCTAssertNil(CoursesCurriculum.course(id: "missing"))
        XCTAssertEqual(CoursesCurriculum.arrangementID(forExercise: "middle-c"), "exercise:middle-c")
    }

    // MARK: Markdown

    func testBoldRunsAreParsed() {
        XCTAssertEqual(CoursesMarkdown.runs(in: "Play **middle C** now"), [
            CoursesTextRun(text: "Play ", isBold: false),
            CoursesTextRun(text: "middle C", isBold: true),
            CoursesTextRun(text: " now", isBold: false),
        ])
        XCTAssertEqual(CoursesMarkdown.runs(in: "**1** and **2**"), [
            CoursesTextRun(text: "1", isBold: true),
            CoursesTextRun(text: " and ", isBold: false),
            CoursesTextRun(text: "2", isBold: true),
        ])
    }

    func testUnmatchedAndEmptyMarkersStayLiteralOrVanish() {
        XCTAssertEqual(CoursesMarkdown.runs(in: "a **b"), [CoursesTextRun(text: "a **b", isBold: false)])
        XCTAssertEqual(CoursesMarkdown.runs(in: "x****y"), [CoursesTextRun(text: "xy", isBold: false)])
        XCTAssertEqual(CoursesMarkdown.runs(in: ""), [])
        XCTAssertEqual(CoursesMarkdown.plainText("**Bold** and **more** **open"), "Bold and more **open")
    }

    func testParagraphsSplitAtBlankLines() {
        XCTAssertEqual(CoursesMarkdown.paragraphs(in: "One\nstill one\n\n  \nTwo\n"), ["One\nstill one", "Two"])
        XCTAssertEqual(CoursesMarkdown.paragraphs(in: "\n\n"), [])
    }

    func testAttributedStringMarksBold() {
        let attributed = CoursesMarkdown.attributed("A **B** C")
        XCTAssertEqual(String(attributed.characters), "A B C")
        let boldText = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
        XCTAssertEqual(boldText, ["B"])
    }

    func testCurriculumTextHasBalancedBoldMarkers() {
        for lesson in allLessons {
            for block in lesson.blocks {
                if case .text(let t) = block {
                    for p in CoursesMarkdown.paragraphs(in: t) {
                        XCTAssertFalse(CoursesMarkdown.plainText(p).contains("**"), "\(lesson.id): unbalanced bold in \"\(p.prefix(40))\"")
                    }
                }
            }
        }
    }

    // MARK: Progress

    func testProgressSummaryCountsCompletedLessons() {
        let course = CoursesCurriculum.welcomeCourse
        let done: Set<String> = [course.lessons[0].id, course.lessons[2].id, course.lessons[4].id]
        let summary = CoursesProgressCalculator.summary(for: course) { LessonProgress(lessonID: $0, completed: done.contains($0)) }
        XCTAssertEqual(summary.label, "3/6 lessons")
        XCTAssertEqual(summary.fraction, 0.5, accuracy: 1e-9)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(CoursesProgressCalculator.nextLessonToStudy(in: course) { LessonProgress(lessonID: $0, completed: done.contains($0)) }?.id, course.lessons[1].id)

        let all = CoursesProgressCalculator.summary(for: course) { LessonProgress(lessonID: $0, completed: true) }
        XCTAssertTrue(all.isComplete)
        XCTAssertNil(CoursesProgressCalculator.nextLessonToStudy(in: course) { LessonProgress(lessonID: $0, completed: true) })
    }

    func testContinueLessonIsMostRecentIncomplete() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let table: [String: LessonProgress] = [
            "welcome-finger-numbers": LessonProgress(lessonID: "welcome-finger-numbers", completed: false, lastOpened: base),
            "chords-intervals": LessonProgress(lessonID: "chords-intervals", completed: false, lastOpened: base.addingTimeInterval(60)),
            "reading-staff-clefs": LessonProgress(lessonID: "reading-staff-clefs", completed: true, lastOpened: base.addingTimeInterval(120)),
        ]
        let lookup: (String) -> LessonProgress = { table[$0] ?? LessonProgress(lessonID: $0) }
        XCTAssertEqual(CoursesProgressCalculator.continueLesson(in: courses, progress: lookup)?.lesson.id, "chords-intervals")
        XCTAssertNil(CoursesProgressCalculator.continueLesson(in: courses) { LessonProgress(lessonID: $0) })
    }

    func testExerciseLabel() {
        let lesson = CoursesCurriculum.readingOdeToJoy
        XCTAssertEqual(CoursesProgressCalculator.exerciseLabel(for: lesson, progress: LessonProgress(lessonID: lesson.id, completedExerciseIDs: ["ode-to-joy-right"])), "1/2 exercises")
        XCTAssertNil(CoursesProgressCalculator.exerciseLabel(for: CoursesCurriculum.welcomeKeyboardLayout, progress: LessonProgress(lessonID: "x")))
        XCTAssertEqual(CoursesProgressCalculator.lessonCountLabel(1), "1 lesson")
    }

    // MARK: Practice requests

    private func summary(mode: PracticeMode, reachedEnd: Bool, wrong: Int, correct: Int = 10, expected: Int = 10,
                         hands: HandSelection = .both, duration: Double = 30, speed: Double = 1) -> PracticeSummary {
        PracticeSummary(arrangementID: "exercise:x", startedAt: Date(timeIntervalSince1970: 0), durationSeconds: duration, mode: mode, hands: hands, speed: speed,
                        stepsExpected: expected, stepsCorrect: correct, wrongNotes: wrong, mistakesByMeasure: [:], measuresCompleted: [], reachedEnd: reachedEnd)
    }

    func testRequestCarriesExerciseSettings() {
        let exercise = CoursesCurriculum.expressionBlues.exercises[1]
        var base = PracticeSettings(mode: .justPlay, hands: .right, speed: 0.75, loop: MeasureRange(start: 1, end: 2), metronome: true)
        base.octaveTolerance = true
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.expressionBlues, course: CoursesCurriculum.expressionCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: base) { _, _ in }
        XCTAssertEqual(request.arrangementID, "exercise:blues-left-hand")
        XCTAssertEqual(request.settings.mode, .wait)
        XCTAssertEqual(request.settings.hands, .left)
        XCTAssertNil(request.settings.loop)
        XCTAssertEqual(request.settings.speed, 0.75, accuracy: 1e-9)
        XCTAssertTrue(request.settings.metronome)
        XCTAssertTrue(request.settings.octaveTolerance)
        XCTAssertEqual(request.exerciseInstructions, exercise.instructions)
        XCTAssertEqual(request.passCriteria, exercise.pass)
        XCTAssertEqual(request.title, exercise.title)
    }

    func testOnFinishReportsPassForWaitMode() {
        let exercise = CoursesCurriculum.welcomeMiddleC.exercises[0]
        var results: [Bool] = []
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.welcomeMiddleC, course: CoursesCurriculum.welcomeCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: PracticeSettings()) { _, passed in results.append(passed) }
        request.onFinish?(summary(mode: .wait, reachedEnd: true, wrong: 1))
        request.onFinish?(summary(mode: .wait, reachedEnd: false, wrong: 0))
        request.onFinish?(summary(mode: .wait, reachedEnd: true, wrong: exercise.pass.maxWrongNotes + 1))
        XCTAssertEqual(results, [true, false, false])
    }

    func testListenExercisesPassOnListeningTime() {
        let exercise = CoursesCurriculum.expressionDynamics.exercises[0]
        XCTAssertNil(CoursesExerciseRequestFactory.passCriteria(for: exercise))
        let score = CoursesCurriculum.readingTrebleLines
        let full = score.makeTimeline().totalSeconds(speed: 1)
        XCTAssertGreaterThan(full, 0)
        var results: [Bool] = []
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.expressionDynamics, course: CoursesCurriculum.expressionCourse,
                                                                score: score, baseSettings: PracticeSettings()) { _, passed in results.append(passed) }
        XCTAssertEqual(request.settings.mode, .listen)
        // The engine never reports reachedEnd in Listen mode, so both summaries carry false.
        request.onFinish?(summary(mode: .listen, reachedEnd: false, wrong: 0, correct: 0, expected: 0, duration: 0.95 * full))
        request.onFinish?(summary(mode: .listen, reachedEnd: false, wrong: 0, correct: 0, expected: 0, duration: 0.5 * full))
        // At half speed, playing time is twice the score time.
        request.onFinish?(summary(mode: .listen, reachedEnd: false, wrong: 0, correct: 0, expected: 0, duration: 1.9 * full, speed: 0.5))
        request.onFinish?(summary(mode: .listen, reachedEnd: false, wrong: 0, correct: 0, expected: 0, duration: 0.95 * full, speed: 0.5))
        request.onFinish?(summary(mode: .listen, reachedEnd: false, wrong: 0, correct: 0, expected: 0, duration: 0))
        XCTAssertEqual(results, [true, false, true, false, false])
    }

    func testJustPlayUsesAccuracy() {
        let exercise = CoursesCurriculum.readingRhythmBasics.exercises[0]
        XCTAssertEqual(exercise.mode, .justPlay)
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.readingRhythmBasics, course: CoursesCurriculum.readingMusicCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: PracticeSettings()) { _, _ in }
        XCTAssertTrue(CoursesExerciseRequestFactory.passes(summary(mode: .justPlay, reachedEnd: true, wrong: 1, correct: 9), exercise: exercise, request: request, requiredListenSeconds: 0))
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: .justPlay, reachedEnd: true, wrong: 1, correct: 5), exercise: exercise, request: request, requiredListenSeconds: 0))
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: .justPlay, reachedEnd: true, wrong: exercise.pass.maxWrongNotes + 1, correct: 10), exercise: exercise, request: request, requiredListenSeconds: 0))
    }

    func testJustPlayPartialRunFails() {
        let exercise = CoursesCurriculum.readingRhythmBasics.exercises[0]
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.readingRhythmBasics, course: CoursesCurriculum.readingMusicCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: PracticeSettings()) { _, _ in }
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: .justPlay, reachedEnd: false, wrong: 0, correct: 10, expected: 10), exercise: exercise, request: request, requiredListenSeconds: 0))
    }

    func testChangedModeFails() {
        let exercise = CoursesCurriculum.readingRhythmBasics.exercises[0]
        XCTAssertEqual(exercise.mode, .justPlay)
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: exercise, lesson: CoursesCurriculum.readingRhythmBasics, course: CoursesCurriculum.readingMusicCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: PracticeSettings()) { _, _ in }
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: .wait, reachedEnd: true, wrong: 0), exercise: exercise, request: request, requiredListenSeconds: 0))
        let listen = CoursesCurriculum.expressionDynamics.exercises[0]
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: .wait, reachedEnd: true, wrong: 0), exercise: listen, request: request, requiredListenSeconds: 1))
    }

    func testHandsMustMatchTheExercise() {
        let both = CoursesCurriculum.readingOdeToJoy.exercises[1]
        XCTAssertEqual(both.hands, .both)
        let request = CoursesExerciseRequestFactory.makeRequest(exercise: both, lesson: CoursesCurriculum.readingOdeToJoy, course: CoursesCurriculum.readingMusicCourse,
                                                                score: CoursesCurriculum.readingTrebleLines, baseSettings: PracticeSettings()) { _, _ in }
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: both.mode, reachedEnd: true, wrong: 0, hands: .right), exercise: both, request: request, requiredListenSeconds: 0))
        XCTAssertTrue(CoursesExerciseRequestFactory.passes(summary(mode: both.mode, reachedEnd: true, wrong: 0, hands: .both), exercise: both, request: request, requiredListenSeconds: 0))

        let right = CoursesCurriculum.readingOdeToJoy.exercises[0]
        XCTAssertEqual(right.hands, .right)
        XCTAssertTrue(CoursesExerciseRequestFactory.passes(summary(mode: right.mode, reachedEnd: true, wrong: 0, hands: .right), exercise: right, request: request, requiredListenSeconds: 0))
        XCTAssertTrue(CoursesExerciseRequestFactory.passes(summary(mode: right.mode, reachedEnd: true, wrong: 0, hands: .both), exercise: right, request: request, requiredListenSeconds: 0))
        XCTAssertFalse(CoursesExerciseRequestFactory.passes(summary(mode: right.mode, reachedEnd: true, wrong: 0, hands: .left), exercise: right, request: request, requiredListenSeconds: 0))
    }

    func testLessonCompletionIsNeverUndoneByPassingAnExercise() {
        let all = ["ode-to-joy-right", "ode-to-joy-both"]
        XCTAssertTrue(CoursesProgressCalculator.lessonCompletedAfterPassing(wasCompleted: true, passedExerciseIDs: ["ode-to-joy-right"], allExerciseIDs: all))
        XCTAssertFalse(CoursesProgressCalculator.lessonCompletedAfterPassing(wasCompleted: false, passedExerciseIDs: ["ode-to-joy-right"], allExerciseIDs: all))
        XCTAssertTrue(CoursesProgressCalculator.lessonCompletedAfterPassing(wasCompleted: false, passedExerciseIDs: Set(all), allExerciseIDs: all))
    }

    func testPassDescriptions() {
        XCTAssertEqual(CoursesExerciseRequestFactory.passDescription(for: CoursesCurriculum.expressionDynamics.exercises[0]), "Listen to the end")
        XCTAssertEqual(CoursesExerciseRequestFactory.passDescription(for: CoursesCurriculum.welcomeMiddleC.exercises[0]), "Play to the end with at most 3 wrong notes")
        XCTAssertEqual(CoursesExerciseRequestFactory.passDescription(for: CoursesCurriculum.readingRhythmBasics.exercises[0]), "Play to the end with 80% accuracy and at most 4 wrong notes")
    }

    // MARK: Layout helpers

    func testKeyboardIllustrationLayout() {
        let range = CoursesKeyboardIllustrationLayout.visibleRange(for: [60])
        XCTAssertTrue(range.contains(60))
        XCTAssertGreaterThanOrEqual(KeyboardRangeFitter.whiteKeyCount(in: range), KeyboardRangeFitter.minimumWhiteKeys)
        XCTAssertEqual(CoursesKeyboardIllustrationLayout.labels(for: range), .all)
        XCTAssertEqual(CoursesKeyboardIllustrationLayout.labels(for: 21...108), .cOnly)
        XCTAssertTrue(CoursesKeyboardIllustrationLayout.keyStates(for: [10, 60]).keys.elementsEqual([60]))
        XCTAssertEqual(CoursesKeyboardIllustrationLayout.accessibilityLabel(for: [64, 60]), "Highlighted keys: C4, E4")
    }

    func testNotationLayoutRequestMatchesViewQuantisation() {
        let score = CoursesCurriculum.readingTrebleLines
        XCTAssertNil(CoursesNotationIllustrationLayout.layoutRequest(score: score, width: 0))
        let request = CoursesNotationIllustrationLayout.layoutRequest(score: score, width: 500)
        XCTAssertEqual(request?.options.mode, .page(width: 496))
        XCTAssertEqual(request?.options.staffSpace, CoursesNotationIllustrationLayout.staffSpace)
        XCTAssertGreaterThan(CoursesNotationIllustrationLayout.maximumWidth(for: score), 0)
    }

    // MARK: Navigation

    @MainActor
    func testNavigatorReplacesLessonKeepingCourseBelow() {
        let navigator = CoursesNavigator()
        let welcome = CoursesCurriculum.welcomeCourse
        navigator.openCourse(welcome)
        navigator.openLesson(welcome.lessons[0], in: welcome)
        navigator.replaceLesson(with: welcome.lessons[1], in: welcome)
        XCTAssertEqual(navigator.path, [.course(id: welcome.id), .lesson(courseID: welcome.id, lessonID: welcome.lessons[1].id)])

        let reading = CoursesCurriculum.readingMusicCourse
        navigator.replaceLesson(with: reading.lessons[0], in: reading)
        XCTAssertEqual(navigator.path, [.course(id: reading.id), .lesson(courseID: reading.id, lessonID: reading.lessons[0].id)])

        navigator.popToRoot()
        navigator.openLesson(welcome.lessons[2], in: welcome)
        navigator.replaceLesson(with: welcome.lessons[3], in: welcome)
        XCTAssertEqual(navigator.path, [.course(id: welcome.id), .lesson(courseID: welcome.id, lessonID: welcome.lessons[3].id)])
    }

    // MARK: Helpers

    private static var songsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LearnPiano/Content/Songs", isDirectory: true)
    }
}
