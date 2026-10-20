import CoreGraphics
import XCTest
@testable import LearnPiano

/// Deterministic tests of the practice screen's view-state logic (no audio, input hardware or SwiftUI).
final class PracticeUITests: XCTestCase {

    // MARK: - Fixtures

    /// RH: m1 C4 D4 E4 F4, m2 G4 half + C5 half. LH: m1 C3 whole, m2 G2 whole. 4/4 at 120 BPM.
    private static func twoHandScore() -> Score {
        ScoreBuilder.make(title: "Two hands", tempo: 120,
                          right: [[(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)],
                                  [(["G4"], 1920), (["C5"], 1920)]],
                          left: [[(["C3"], 3840)], [(["G2"], 3840)]])
    }

    /// Eight measures of quarter-note C4s (RH only).
    private static func eightBarScore() -> Score {
        let bar: [(pitches: [String], ticks: Ticks)] = [(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)]
        return ScoreBuilder.make(title: "Eight", tempo: 120, right: Array(repeating: bar, count: 8))
    }

    private static func summary(mode: PracticeMode = .wait, expected: Int = 20, correct: Int = 17, wrong: Int = 4,
                                mistakes: [Int: Int] = [:], duration: Double = 83, reachedEnd: Bool = true) -> PracticeSummary {
        PracticeSummary(arrangementID: "test", startedAt: Date(timeIntervalSince1970: 0), durationSeconds: duration, mode: mode,
                        hands: .right, speed: 0.75, stepsExpected: expected, stepsCorrect: correct, wrongNotes: wrong,
                        mistakesByMeasure: mistakes, measuresCompleted: [0, 1], reachedEnd: reachedEnd)
    }

    // MARK: - FeedbackSnapshot → keyboard state

    func testKeyboardStateMapsEveryFeedbackStateWithHands() {
        let timeline = Self.twoHandScore().makeTimeline()
        let snapshot = FeedbackSnapshot(keyStates: [60: .expected, 48: .expected, 61: .wrong, 64: .correct, 62: .upcoming, 70: .pressed],
                                        eventStates: [:], currentStepIndex: 0, missingPitches: [60, 48])
        let state = PracticeUIFeedbackMapper.keyboardState(from: snapshot, timeline: timeline)
        XCTAssertEqual(state.keyStates[60], .expected(.right))
        XCTAssertEqual(state.keyStates[48], .expected(.left))
        XCTAssertEqual(state.keyStates[62], .upcoming(.right))
        XCTAssertEqual(state.keyStates[61], .wrong)
        XCTAssertEqual(state.keyStates[64], .correct)
        XCTAssertEqual(state.keyStates[70], .pressed)
        XCTAssertEqual(state.wrongPitches, [61])
        XCTAssertEqual(state.expectedPitches, [48, 60])
    }

    func testKeyboardStatePrefersSessionExpectedPitches() {
        let snapshot = FeedbackSnapshot(keyStates: [60: .correct])
        let state = PracticeUIFeedbackMapper.keyboardState(from: snapshot, timeline: nil, expectedPitches: [67, 64, 64])
        XCTAssertEqual(state.expectedPitches, [64, 67])
        XCTAssertEqual(state.keyStates[60], .correct)
        XCTAssertTrue(state.wrongPitches.isEmpty)
    }

    func testEmptySnapshotGivesEmptyKeyboardState() {
        let state = PracticeUIFeedbackMapper.keyboardState(from: .empty, timeline: nil)
        XCTAssertEqual(state, .empty)
    }

    // MARK: - FeedbackSnapshot → notation state

    func testNotationStateDimsTheOtherHand() {
        let snapshot = FeedbackSnapshot(eventStates: ["0:x": .expected], currentStepIndex: 3)
        let loop = MeasureRange(start: 1, end: 2)
        let state = PracticeUIFeedbackMapper.notationState(from: snapshot, settings: PracticeSettings(mode: .wait, hands: .left, loop: loop))
        XCTAssertEqual(state.practicedHands, .left)
        XCTAssertTrue(state.dimsOtherHands)
        XCTAssertEqual(state.loop, loop)
        XCTAssertEqual(state.feedback, snapshot)
    }

    func testNotationStateNeverDimsInListenOrBothHands() {
        let listen = PracticeUIFeedbackMapper.notationState(from: .empty, settings: PracticeSettings(mode: .listen, hands: .right))
        XCTAssertEqual(listen.practicedHands, .both)
        XCTAssertFalse(listen.dimsOtherHands)
        let both = PracticeUIFeedbackMapper.notationState(from: .empty, settings: PracticeSettings(mode: .justPlay, hands: .both))
        XCTAssertFalse(both.dimsOtherHands)
    }

    // MARK: - Note names

    func testExpectedPillListsSortedDistinctNames() {
        XCTAssertEqual(PracticeUINoteNames.expectedPill([64, 60, 64]), "Expected: C4 E4")
        XCTAssertNil(PracticeUINoteNames.expectedPill([]))
    }

    func testNoteNamesFollowFlatKeys() {
        XCTAssertEqual(PracticeUINoteNames.names([70], key: KeySignature(fifths: -1)), "Bb4")
        XCTAssertEqual(PracticeUINoteNames.names([70]), "A#4")
        XCTAssertEqual(PracticeUINoteNames.spoken([61, 60]), "C 4, C sharp 4")
    }

    // MARK: - Loop selection

    func testTwoTapsSelectARange() {
        var s = PracticeUILoopSelection()
        s.tap(measure: 2, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(single: 2))
        XCTAssertEqual(s.anchor, 2)
        s.tap(measure: 5, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(start: 2, end: 5))
        XCTAssertNil(s.anchor)
    }

    func testSecondTapBeforeAnchorOrdersTheRange() {
        var s = PracticeUILoopSelection()
        s.tap(measure: 6, measureCount: 8)
        s.tap(measure: 1, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(start: 1, end: 6))
    }

    func testTappingTheAnchorAgainClearsTheLoop() {
        var s = PracticeUILoopSelection()
        s.tap(measure: 3, measureCount: 8)
        s.tap(measure: 3, measureCount: 8)
        XCTAssertNil(s.loop)
        XCTAssertNil(s.anchor)
    }

    func testTapAfterACompletedRangeStartsANewOne() {
        var s = PracticeUILoopSelection(loop: MeasureRange(start: 1, end: 4))
        s.tap(measure: 6, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(single: 6))
        XCTAssertEqual(s.anchor, 6)
    }

    func testTappingALoneLoopedMeasureWithoutAnchorClearsIt() {
        var s = PracticeUILoopSelection(loop: MeasureRange(single: 4))
        s.tap(measure: 4, measureCount: 8)
        XCTAssertNil(s.loop)
    }

    func testTapsAndDragsAreClampedToTheScore() {
        var s = PracticeUILoopSelection()
        s.tap(measure: 20, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(single: 7))
        s.drag(MeasureRange(start: -3, end: 12), measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(start: 0, end: 7))
        XCTAssertNil(s.anchor)
        var empty = PracticeUILoopSelection()
        empty.tap(measure: 0, measureCount: 0)
        XCTAssertNil(empty.loop)
    }

    func testToggleRestoresTheRememberedLoop() {
        var s = PracticeUILoopSelection()
        s.drag(MeasureRange(start: 2, end: 3), measureCount: 8)
        s.toggle(fallback: MeasureRange(single: 0), measureCount: 8)
        XCTAssertNil(s.loop)
        s.toggle(fallback: MeasureRange(single: 0), measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(start: 2, end: 3))
    }

    func testToggleUsesTheFallbackWhenNothingWasSelected() {
        var s = PracticeUILoopSelection()
        let fallback = PracticeUILoopSelection.defaultRange(cursorMeasure: 7, measureCount: 8)
        XCTAssertEqual(fallback, MeasureRange(single: 7))
        XCTAssertEqual(PracticeUILoopSelection.defaultRange(cursorMeasure: 2, measureCount: 8), MeasureRange(start: 2, end: 3))
        s.toggle(fallback: fallback, measureCount: 8)
        XCTAssertEqual(s.loop, MeasureRange(single: 7))
    }

    func testLoopLabelUsesPrintedMeasureNumbers() {
        var score = Self.eightBarScore()
        XCTAssertEqual(PracticeUILoopSelection.label(nil, score: score), "Loop")
        XCTAssertEqual(PracticeUILoopSelection.label(MeasureRange(single: 0), score: score), "Bar 1")
        XCTAssertEqual(PracticeUILoopSelection.label(MeasureRange(start: 2, end: 4), score: score), "Bars 3–5")
        // A pickup measure is numbered 0, so indices and printed numbers line up.
        score.measures[0].number = 0
        for i in 1..<score.measures.count { score.measures[i].number = i }
        XCTAssertEqual(PracticeUILoopSelection.label(MeasureRange(start: 0, end: 2), score: score), "Bars 0–2")
    }

    // MARK: - Measure text and navigation

    func testPositionTexts() {
        let score = Self.eightBarScore()
        XCTAssertEqual(PracticeUIMeasureText.position(measureIndex: 4, in: score), "Bar 5 / 8")
        XCTAssertEqual(PracticeUIMeasureText.spokenPosition(measureIndex: 0, pass: 1, in: score), "Measure 1 of 8")
        XCTAssertEqual(PracticeUIMeasureText.spokenPosition(measureIndex: 0, pass: 2, in: score), "Measure 1 of 8, second time through")
        XCTAssertEqual(PracticeUIMeasureText.spokenPosition(measureIndex: 0, pass: 3, in: score), "Measure 1 of 8, pass 3")
    }

    func testPreviousMeasureGoesToStartOfCurrentWhenInsideIt() {
        XCTAssertEqual(PracticeUINavigation.previousMeasure(current: 3, tickInMeasure: 1500, beatTicks: 960), 3)
        XCTAssertEqual(PracticeUINavigation.previousMeasure(current: 3, tickInMeasure: 0, beatTicks: 960), 2)
        XCTAssertEqual(PracticeUINavigation.previousMeasure(current: 0, tickInMeasure: 0, beatTicks: 960), 0)
        XCTAssertEqual(PracticeUINavigation.nextMeasure(current: 7, measureCount: 8), 7)
        XCTAssertEqual(PracticeUINavigation.nextMeasure(current: 2, measureCount: 8), 3)
    }

    // MARK: - Progress and count-in

    func testProgressCountsStepsBeforeTheCursor() {
        let ticks: [Ticks] = [0, 960, 1920, 2880]
        XCTAssertEqual(PracticeUIProgress.completedSteps(stepTicks: ticks, cursorTick: 0, finished: false), 0)
        XCTAssertEqual(PracticeUIProgress.completedSteps(stepTicks: ticks, cursorTick: 960, finished: false), 1)
        XCTAssertEqual(PracticeUIProgress.completedSteps(stepTicks: ticks, cursorTick: 2000, finished: false), 3)
        XCTAssertEqual(PracticeUIProgress.completedSteps(stepTicks: ticks, cursorTick: .nan, finished: false), 0)
        XCTAssertEqual(PracticeUIProgress.completedSteps(stepTicks: ticks, cursorTick: 0, finished: true), 4)
        XCTAssertEqual(PracticeUIProgress.fraction(completed: 1, total: 4), 0.25)
        XCTAssertEqual(PracticeUIProgress.fraction(completed: 3, total: 0), 0)
    }

    func testProgressStepTicksRespectHandsAndLoop() {
        let timeline = Self.twoHandScore().makeTimeline()
        XCTAssertEqual(PracticeUIProgress.stepTicks(timeline: timeline, hands: .right, loop: nil), [0, 960, 1920, 2880, 3840, 5760])
        XCTAssertEqual(PracticeUIProgress.stepTicks(timeline: timeline, hands: .left, loop: nil), [0, 3840])
        XCTAssertEqual(PracticeUIProgress.stepTicks(timeline: timeline, hands: .right, loop: MeasureRange(single: 1)), [3840, 5760])
    }

    func testCountInBeatNumbersRestartEachMeasure() {
        XCTAssertEqual((0..<8).map { PracticeUICountIn.displayBeat(beat: $0, totalBeats: 8, measures: 2) }, [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(PracticeUICountIn.displayBeat(beat: 2, totalBeats: 3, measures: 1), 3)
        XCTAssertEqual(PracticeUICountIn.displayBeat(beat: 0, totalBeats: 0, measures: 0), 1)
    }

    // MARK: - Summary formatting

    func testTroubleMeasuresAreWorstFirst() {
        XCTAssertEqual(PracticeUISummaryFormatter.troubleMeasures([2: 1, 5: 4, 3: 4, 7: 0, 1: 2]), [3, 5, 1])
        XCTAssertEqual(PracticeUISummaryFormatter.troubleMeasures([:]), [])
    }

    func testTroubleLoopSpansCloseTroubleMeasures() {
        XCTAssertEqual(PracticeUISummaryFormatter.troubleLoop([3: 2, 5: 1], measureCount: 8), MeasureRange(start: 3, end: 5))
        // Far apart: the worst measure and the next one.
        XCTAssertEqual(PracticeUISummaryFormatter.troubleLoop([1: 5, 7: 1], measureCount: 8), MeasureRange(start: 1, end: 2))
        // Clamped at the end of the piece.
        XCTAssertEqual(PracticeUISummaryFormatter.troubleLoop([7: 5, 0: 1], measureCount: 8), MeasureRange(start: 7, end: 7))
        XCTAssertNil(PracticeUISummaryFormatter.troubleLoop([:], measureCount: 8))
    }

    func testSummaryTextForASong() {
        let score = Self.eightBarScore()
        let text = PracticeUISummaryFormatter.format(Self.summary(mistakes: [2: 3, 4: 1]), score: score)
        XCTAssertEqual(text.accuracy, "85%")
        XCTAssertEqual(text.time, "1:23")
        XCTAssertEqual(text.wrongNotes, "4")
        XCTAssertEqual(text.steps, "17 / 20")
        XCTAssertEqual(text.troubleMeasures, ["Bar 3 (3 mistakes)", "Bar 5 (1 mistake)"])
        XCTAssertEqual(text.troubleLoop, MeasureRange(start: 2, end: 4))
        XCTAssertEqual(text.headline, "Great job!")
        XCTAssertNil(text.exerciseResult)
        XCTAssertNil(text.passed)
    }

    func testSummaryTextForListenHidesScores() {
        let text = PracticeUISummaryFormatter.format(Self.summary(mode: .listen, expected: 0, correct: 0, wrong: 0, mistakes: [1: 2]), score: Self.eightBarScore())
        XCTAssertEqual(text.accuracy, "—")
        XCTAssertEqual(text.wrongNotes, "—")
        XCTAssertTrue(text.troubleMeasures.isEmpty)
        XCTAssertNil(text.troubleLoop)
        XCTAssertEqual(text.headline, "Nice listening")
    }

    func testSummaryTextForExercises() {
        let score = Self.eightBarScore()
        let request = PracticeRequest(score: score, arrangementID: "exercise:x", title: "Ex", exerciseInstructions: "Play it",
                                      passCriteria: ExercisePassCriteria(minimumAccuracy: 0.9, maxWrongNotes: 3))
        let passed = PracticeUISummaryFormatter.format(Self.summary(mode: .wait, wrong: 2, reachedEnd: true), score: score, request: request)
        XCTAssertEqual(passed.exerciseResult, "Passed!")
        XCTAssertEqual(passed.passed, true)
        let tooManyWrong = PracticeUISummaryFormatter.format(Self.summary(mode: .wait, wrong: 5, reachedEnd: true), score: score, request: request)
        XCTAssertEqual(tooManyWrong.exerciseResult, "Try again")
        XCTAssertEqual(tooManyWrong.passed, false)
        let lowAccuracy = PracticeUISummaryFormatter.format(Self.summary(mode: .justPlay, expected: 10, correct: 5, wrong: 0), score: score, request: request)
        XCTAssertEqual(lowAccuracy.exerciseResult, "Try again")
        // A song request (no criteria) never shows a verdict.
        let song = PracticeRequest(score: score, arrangementID: "song", title: "Song")
        XCTAssertNil(PracticeUISummaryFormatter.format(Self.summary(), score: score, request: song).exerciseResult)
    }

    func testPercentAndHeadlines() {
        XCTAssertEqual(PracticeUISummaryFormatter.percent(0.876), "88%")
        XCTAssertEqual(PracticeUISummaryFormatter.percent(1.4), "100%")
        XCTAssertEqual(PracticeUISummaryFormatter.percent(.nan), "0%")
        XCTAssertEqual(PracticeUISummaryFormatter.headline(accuracy: 1, mode: .wait, reachedEnd: true), "Perfect run!")
        XCTAssertEqual(PracticeUISummaryFormatter.headline(accuracy: 0.96, mode: .justPlay, reachedEnd: false), "Excellent!")
        XCTAssertEqual(PracticeUISummaryFormatter.headline(accuracy: 0.6, mode: .wait, reachedEnd: false), "Good progress")
        XCTAssertEqual(PracticeUISummaryFormatter.headline(accuracy: 0.2, mode: .wait, reachedEnd: false), "Keep practicing")
    }

    func testSpeedLabels() {
        XCTAssertEqual(PracticeSpeed.allCases.map { PracticeUISpeedText.label($0.rawValue) }, ["25%", "50%", "75%", "100%"])
    }

    // MARK: - Layout

    func testLandscapeLayoutScrollsTheScore() {
        let m = PracticeUILayoutMetrics.make(size: CGSize(width: 1366, height: 860), showsFallingNotes: true)
        XCTAssertTrue(m.isLandscape)
        XCTAssertEqual(m.notationMode, .scroll)
        XCTAssertGreaterThan(m.laneHeight, 0)
        XCTAssertEqual(m.laneHeight + m.keyboardHeight + m.notationHeight, 860, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(m.staffSpace, 6.5)
        XCTAssertLessThanOrEqual(m.staffSpace, 12)
    }

    func testPortraitLayoutGivesNotationMoreRoom() {
        let landscape = PracticeUILayoutMetrics.make(size: CGSize(width: 1366, height: 860), showsFallingNotes: true)
        let portrait = PracticeUILayoutMetrics.make(size: CGSize(width: 1024, height: 1200), showsFallingNotes: true)
        XCTAssertFalse(portrait.isLandscape)
        XCTAssertEqual(portrait.notationMode, .page)
        XCTAssertGreaterThan(portrait.notationHeight / 1200, landscape.notationHeight / 860)
    }

    func testHidingFallingNotesRemovesTheLanes() {
        let m = PracticeUILayoutMetrics.make(size: CGSize(width: 1366, height: 860), showsFallingNotes: false)
        XCTAssertEqual(m.laneHeight, 0)
        XCTAssertEqual(m.keyboardHeight + m.notationHeight, 860, accuracy: 0.5)
    }

    func testNarrowWidthLayoutStaysPositive() {
        let m = PracticeUILayoutMetrics.make(size: CGSize(width: 768, height: 500), showsFallingNotes: true)
        XCTAssertGreaterThan(m.keyboardHeight, 0)
        XCTAssertGreaterThan(m.notationHeight, 0)
        XCTAssertGreaterThanOrEqual(m.laneHeight, 0)
        let range = PracticeUIKeyboardRange.range(for: Self.twoHandScore(), hands: .both, width: 768)
        XCTAssertLessThanOrEqual(KeyboardRangeFitter.whiteKeyCount(in: range), max(KeyboardRangeFitter.minimumWhiteKeys, 768 / 22))
        XCTAssertTrue(range.contains(43) && range.contains(72))
    }

    // MARK: - Input status

    func testInputStatusForEachSource() {
        func status(_ selection: InputHubSelection, permission: InputMicrophonePermission? = .granted, state: InputSourceState? = .running, midi: [String] = []) -> PracticeUIInputStatus {
            PracticeUIInputStatus.make(selection: selection, microphonePermission: permission, microphoneState: state, microphoneError: nil, midiDeviceNames: midi)
        }
        XCTAssertEqual(status(.onScreenOnly), .onScreen)
        XCTAssertEqual(status(.microphone), .microphoneListening)
        XCTAssertEqual(status(.microphone, permission: .undetermined, state: .starting), .microphoneStarting)
        XCTAssertEqual(status(.microphone, permission: .denied, state: .idle), .microphoneDenied)
        XCTAssertEqual(status(.microphone, state: .permissionDenied), .microphoneDenied)
        XCTAssertEqual(status(.microphone, state: .unavailable), .microphoneUnavailable("No microphone input is available."))
        XCTAssertEqual(status(.midi), .midiNoDevice)
        XCTAssertEqual(status(.midi, midi: ["Roland FP-30", "KORG"]), .midiConnected("Roland FP-30, KORG"))
        XCTAssertEqual(status(.both, midi: ["Roland FP-30"]), .midiConnected("Roland FP-30"))
        XCTAssertEqual(status(.both), .microphoneListening)
        XCTAssertTrue(PracticeUIInputStatus.microphoneDenied.needsAttention)
        XCTAssertTrue(PracticeUIInputStatus.midiNoDevice.needsAttention)
        XCTAssertFalse(PracticeUIInputStatus.microphoneListening.needsAttention)
        XCTAssertEqual(PracticeUIInputStatus.microphoneListening.chipText, "Listening…")
    }

    // MARK: - Controller (no audio or input brought up)

    @MainActor
    func testControllerAppliesLoopSelectionToTheSession() {
        let controller = PracticeUISessionController(request: PracticeRequest(score: Self.eightBarScore(), arrangementID: "eight", title: "Eight"))
        XCTAssertNil(controller.session.loop)
        controller.tapMeasure(1)
        XCTAssertEqual(controller.session.loop, MeasureRange(single: 1))
        controller.tapMeasure(3)
        XCTAssertEqual(controller.session.loop, MeasureRange(start: 1, end: 3))
        controller.toggleLoop()
        XCTAssertNil(controller.session.loop)
        controller.toggleLoop()
        XCTAssertEqual(controller.session.loop, MeasureRange(start: 1, end: 3))
        controller.dragMeasures(MeasureRange(start: 5, end: 9))
        XCTAssertEqual(controller.session.loop, MeasureRange(start: 5, end: 7))
        controller.clearLoop()
        XCTAssertNil(controller.session.loop)
    }

    @MainActor
    func testControllerOffersOnlyHandsTheScoreHas() {
        let rightOnly = PracticeUISessionController(request: PracticeRequest(score: Self.eightBarScore(), arrangementID: "eight", title: "Eight"))
        XCTAssertEqual(rightOnly.availableHands, [.right])
        let both = PracticeUISessionController(request: PracticeRequest(score: Self.twoHandScore(), arrangementID: "two", title: "Two"))
        XCTAssertEqual(both.availableHands, [.right, .left, .both])
    }

    @MainActor
    func testControllerSettingsReachTheSession() {
        let controller = PracticeUISessionController(request: PracticeRequest(score: Self.twoHandScore(), arrangementID: "two", title: "Two"))
        controller.setMode(.justPlay)
        controller.setHands(.left)
        controller.setSpeed(0.5)
        controller.setCountIn(2)
        controller.setOctaveTolerance(true)
        controller.setPlayOtherHands(false)
        controller.toggleMetronome()
        let s = controller.session.settings
        XCTAssertEqual(s.mode, .justPlay)
        XCTAssertEqual(s.hands, .left)
        XCTAssertEqual(s.speed, 0.5)
        XCTAssertEqual(s.countInMeasures, 2)
        XCTAssertTrue(s.octaveTolerance)
        XCTAssertFalse(s.playOtherHands)
        XCTAssertTrue(s.metronome)
        XCTAssertEqual(controller.progressStepTicks, [0, 3840])
        controller.tapMeasure(1)
        XCTAssertEqual(controller.progressStepTicks, [3840])
    }
}
