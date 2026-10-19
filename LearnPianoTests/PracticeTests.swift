import XCTest
@testable import LearnPiano

/// Deterministic tests of the Practice engine: every timing comes from a `ManualPracticeClock`.
final class PracticeTests: XCTestCase {

    // MARK: - Fixtures

    private static func pitch(_ name: String) -> Pitch { Pitch(name: name) ?? Pitch(step: .C, octave: 4) }
    private func midi(_ name: String) -> Int { Self.pitch(name).midi }

    private static func event(_ names: [String], onset: Ticks, ticks: Ticks, hand: Hand = .right, tieStart: Bool = false, tieStop: Bool = false) -> MeasureEvent {
        MeasureEvent(onset: onset, duration: ticks, notes: names.map { ChordNote(pitch: pitch($0), tieStart: tieStart, tieStop: tieStop) }, hand: hand)
    }

    /// 4/4 at 120 BPM: a quarter is 0.5 s (960 ticks) at full speed.
    /// m1 RH C D E F, LH C3 whole · m2 RH G4 half + C-E-G half, LH G2 half + C3 half ·
    /// m3 RH rest, D-F, E4 half (tie start), LH rest · m4 RH E4 (tie stop) D4 C4 half, LH C3 whole.
    private static func lessonScore() -> Score {
        let q = Ticks.perQuarter, h = 2 * q, w = 4 * q
        return Score(metadata: ScoreMetadata(title: "Test", source: .exercise), initialTempoBPM: 120, measures: [
            Measure(number: 1, events: [event(["C4"], onset: 0, ticks: q), event(["D4"], onset: q, ticks: q), event(["E4"], onset: 2 * q, ticks: q), event(["F4"], onset: 3 * q, ticks: q), event(["C3"], onset: 0, ticks: w, hand: .left)]),
            Measure(number: 2, events: [event(["G4"], onset: 0, ticks: h), event(["C4", "E4", "G4"], onset: h, ticks: h), event(["G2"], onset: 0, ticks: h, hand: .left), event(["C3"], onset: h, ticks: h, hand: .left)]),
            Measure(number: 3, events: [event([], onset: 0, ticks: q), event(["D4", "F4"], onset: q, ticks: q), event(["E4"], onset: h, ticks: h, tieStart: true), event([], onset: 0, ticks: w, hand: .left)]),
            Measure(number: 4, events: [event(["E4"], onset: 0, ticks: q, tieStop: true), event(["D4"], onset: q, ticks: q), event(["C4"], onset: h, ticks: h), event(["C3"], onset: 0, ticks: w, hand: .left)], barline: Barline(isFinal: true)),
        ])
    }

    /// Right hand only, two measures of a C major scale in quarters at 120 BPM.
    private static func scaleScore() -> Score {
        ScoreBuilder.make(title: "Scale", tempo: 120, right: [
            [(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)],
            [(["G4"], 960), (["A4"], 960), (["B4"], 960), (["C5"], 960)],
        ])
    }

    private func on(_ name: String, _ clock: ManualPracticeClock) -> NoteInputEvent { .on(midi(name), time: clock.now, source: .virtualKeyboard) }
    private func off(_ name: String, _ clock: ManualPracticeClock) -> NoteInputEvent { .off(midi(name), time: clock.now, source: .virtualKeyboard) }

    private func records(_ events: [PracticeFollowerEvent]) -> [PlayedRecord] {
        events.compactMap { if case .played(let r) = $0 { return r } else { return nil } }
    }

    private func waitFollower(_ score: Score, hands: HandSelection = .right, loop: MeasureRange? = nil, speed: Double = 1, restScale: Double = 0, window: Double = 0.25, octaveTolerance: Bool = false, options: PracticeWaitOptions = PracticeWaitOptions(), clock: ManualPracticeClock) -> PracticeWaitFollower {
        let settings = PracticeSettings(mode: .wait, hands: hands, speed: speed, loop: loop, octaveTolerance: octaveTolerance, chordWindowSeconds: window, waitModeRestScale: restScale)
        return PracticeWaitFollower(timeline: score.makeTimeline(), settings: settings, clock: clock, options: options)
    }

    /// Moves the follower to the C-E-G chord (material position 5) by playing the first five notes.
    private func playToChord(_ f: PracticeWaitFollower, clock: ManualPracticeClock) {
        for n in ["C4", "D4", "E4", "F4", "G4"] {
            f.handle(on(n, clock)); f.handle(off(n, clock))
            clock.advance(by: 0.1)
            f.update()
        }
    }

    // MARK: - Wait Mode: chords

    func testChordCompletesWhenAllPitchesArriveWithinWindow() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.lessonScore(), clock: clock)
        f.start()
        playToChord(f, clock: clock)
        XCTAssertEqual(f.expectedPitches, [midi("C4"), midi("E4"), midi("G4")])
        XCTAssertTrue(records(f.handle(on("C4", clock))).isEmpty)
        clock.advance(by: 0.1)
        XCTAssertTrue(records(f.handle(on("E4", clock))).isEmpty)
        XCTAssertEqual(f.missingPitches, [midi("G4")])
        XCTAssertEqual(f.currentPosition, 5, "a partial chord does not advance")
        clock.advance(by: 0.1)
        let done = records(f.handle(on("G4", clock)))
        XCTAssertEqual(done.map { $0.outcome }, [.correct])
        XCTAssertEqual(done.first?.played, [midi("C4"), midi("E4"), midi("G4")])
        XCTAssertEqual(f.expectedPitches, [midi("D4"), midi("F4")])
    }

    func testLenientChordWindowKeepsSlowNotes() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.lessonScore(), clock: clock)
        f.start()
        playToChord(f, clock: clock)
        f.handle(on("C4", clock))
        clock.advance(by: 2)
        f.handle(on("E4", clock))
        clock.advance(by: 2)
        XCTAssertEqual(records(f.handle(on("G4", clock))).first?.outcome, .correct, "lenient policy: slow chords still complete")
    }

    func testStrictChordWindowExpiresOldNotes() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.lessonScore(), options: PracticeWaitOptions(chordWindowPolicy: .strict), clock: clock)
        f.start()
        playToChord(f, clock: clock)
        f.handle(on("C4", clock))
        f.handle(on("E4", clock))
        clock.advance(by: 0.5)
        XCTAssertTrue(records(f.handle(on("G4", clock))).isEmpty, "C4 and E4 expired outside the 250 ms window")
        XCTAssertEqual(f.missingPitches, [midi("C4"), midi("E4")])
        clock.advance(by: 0.05)
        f.handle(on("C4", clock))
        clock.advance(by: 0.05)
        XCTAssertEqual(records(f.handle(on("E4", clock))).first?.outcome, .correct)
    }

    func testChordWindowUsesInputOnsetTimes() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.lessonScore(), options: PracticeWaitOptions(chordWindowPolicy: .strict), clock: clock)
        f.start()
        playToChord(f, clock: clock)
        f.handle(on("C4", clock))
        let onset = clock.now
        // E4 and G4 were played 50 and 100 ms after C4 but reach the follower 500 ms later (detection latency).
        clock.advance(by: 0.5)
        XCTAssertTrue(records(f.handle(.on(midi("E4"), time: onset + 0.05, source: .microphone))).isEmpty)
        let done = records(f.handle(.on(midi("G4"), time: onset + 0.1, source: .microphone)))
        XCTAssertEqual(done.map { $0.outcome }, [.correct], "judged by onset: all three within the 250 ms window")
    }

    func testOctaveToleranceMatchesPitchClass() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), octaveTolerance: true, clock: clock)
        f.start()
        XCTAssertEqual(records(f.handle(on("C5", clock))).first?.outcome, .correct)
        XCTAssertEqual(f.expectedPitches, [midi("D4")])
    }

    // MARK: - Wait Mode: wrong notes, held keys, ties

    func testWrongNoteIsReportedButNeverAdvances() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), clock: clock)
        f.start()
        for n in ["E4", "F4", "B3"] {
            let r = records(f.handle(on(n, clock)))
            XCTAssertEqual(r.first?.outcome, .wrong)
            XCTAssertEqual(r.first?.expected, [midi("C4")])
            XCTAssertEqual(r.first?.played, [midi(n)])
            f.handle(off(n, clock))
        }
        XCTAssertEqual(f.currentPosition, 0)
        XCTAssertEqual(f.statistics.wrongNotes, 3)
        XCTAssertEqual(f.statistics.mistakesByMeasure, [0: 3])
        XCTAssertEqual(f.feedback().keyStates[midi("B3")], .wrong)
        clock.advance(by: 0.5)
        XCTAssertNil(f.feedback().keyStates[midi("B3")], "the wrong flash fades after ~400 ms")
        f.handle(on("C4", clock))
        XCTAssertEqual(f.currentPosition, 1)
        XCTAssertEqual(f.statistics.stepsWithMistakes, 1)
    }

    func testHeldKeyFromPreviousStepDoesNotCount() {
        let clock = ManualPracticeClock()
        let score = ScoreBuilder.make(title: "Repeated", tempo: 120, right: [[(["C4"], 960), (["C4"], 960), (["D4"], 1920)]])
        let f = waitFollower(score, clock: clock)
        f.start()
        f.handle(on("C4", clock))
        clock.advance(by: 1)
        f.update()
        XCTAssertEqual(f.currentPosition, 1)
        XCTAssertEqual(f.missingPitches, [midi("C4")], "holding C4 does not satisfy the repeated C4")
        f.handle(off("C4", clock))
        f.handle(on("C4", clock))
        XCTAssertEqual(f.currentPosition, 2)
    }

    func testHeldKeysCountWhenEnabled() {
        let clock = ManualPracticeClock()
        let score = ScoreBuilder.make(title: "Held", tempo: 120, right: [[(["C4"], 960), (["C4", "E4"], 960), (["D4"], 1920)]])
        let f = waitFollower(score, options: PracticeWaitOptions(creditsHeldKeys: true), clock: clock)
        f.start()
        f.handle(on("C4", clock))
        f.update()
        XCTAssertEqual(f.missingPitches, [midi("E4")], "held C4 credited to the next chord")
        f.handle(on("E4", clock))
        XCTAssertEqual(f.expectedPitches, [midi("D4")])
    }

    /// Regression: a held key in a one-step loop used to recurse until the stack overflowed (rest scale 0)
    /// or replay the loop forever on its own (rest scale > 0). A held key now earns one credit per press.
    func testHeldKeyInOneStepLoopIsCreditedOncePerPress() {
        for restScale in [0.0, 0.5] {
            let clock = ManualPracticeClock()
            let score = ScoreBuilder.make(title: "One", tempo: 120, right: [[(["C4"], 3840)]])
            let f = waitFollower(score, loop: MeasureRange(single: 0), restScale: restScale, options: PracticeWaitOptions(creditsHeldKeys: true), clock: clock)
            f.start()
            var events = f.handle(on("C4", clock))
            for _ in 0..<20 {
                clock.advance(by: 0.5)
                events += f.update()
            }
            XCTAssertEqual(f.statistics.stepsExpected, 2, "the press itself plus one held-key credit (rest scale \(restScale))")
            XCTAssertEqual(events.filter { $0 == .loopWrapped }.count, 2)
            XCTAssertEqual(f.phase, .waiting(position: 0), "then the loop waits for a new press")
            f.handle(off("C4", clock))
            f.handle(on("C4", clock))
            for _ in 0..<20 {
                clock.advance(by: 0.5)
                f.update()
            }
            XCTAssertEqual(f.statistics.stepsExpected, 4, "a new press earns a new held-key credit")
        }
    }

    func testTieContinuationIsNotExpectedAgain() {
        let clock = ManualPracticeClock()
        let timeline = Self.lessonScore().makeTimeline()
        // Right hand: the tied E4 in measure 4 produces no step at all.
        let right = PracticeMaterial(timeline: timeline, hands: .right, loop: nil)
        XCTAssertFalse(right.steps.contains { $0.tick == 11520 })
        XCTAssertEqual(right.steps.count, 10)
        // Both hands: the onset exists (left-hand C3) but expects only C3.
        let f = waitFollower(Self.lessonScore(), hands: .both, clock: clock)
        f.start(atTick: 9600)
        XCTAssertEqual(f.expectedPitches, [midi("E4")])
        f.handle(on("E4", clock))
        XCTAssertEqual(f.expectedPitches, [midi("C3")], "the tie continuation E4 is excluded")
        XCTAssertEqual(records(f.handle(on("E4", clock))).first?.outcome, .wrong, "re-striking the tied note is not expected")
        f.handle(on("C3", clock))
        XCTAssertEqual(f.expectedPitches, [midi("D4")])
    }

    // MARK: - Wait Mode: rests, gaps, demo of the other hand

    func testRestGapIsScaledBySpeedAndRestScale() {
        let clock = ManualPracticeClock()
        // Speed 0.5 doubles the 1.5 s gap (C-E-G → rest → D-F) to 3 s; rest scale 0.5 halves it to 1.5 s.
        let f = waitFollower(Self.lessonScore(), speed: 0.5, restScale: 0.5, clock: clock)
        f.start(atTick: 5760)
        XCTAssertEqual(f.expectedPitches, [midi("C4"), midi("E4"), midi("G4")])
        for n in ["C4", "E4", "G4"] { f.handle(on(n, clock)) }
        guard case .gap(_, _, _, _, let duration) = f.phase else { return XCTFail("expected a gap") }
        XCTAssertEqual(duration, 1.5, accuracy: 1e-9)
        clock.advance(by: 0.75)
        f.update()
        XCTAssertEqual(f.cursorTick, 5760 + 1440, accuracy: 1e-6, "cursor interpolates halfway")
        clock.advance(by: 0.74)
        f.update()
        if case .waiting = f.phase { XCTFail("still resting") }
        clock.advance(by: 0.02)
        f.update()
        XCTAssertEqual(f.phase, .waiting(position: 6))
    }

    func testZeroRestScaleAdvancesInstantly() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.lessonScore(), restScale: 0, clock: clock)
        f.start(atTick: 5760)
        for n in ["C4", "E4", "G4"] { f.handle(on(n, clock)) }
        XCTAssertEqual(f.phase, .waiting(position: 6))
    }

    func testEarlyAttackDuringGapIsCredited() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), restScale: 1, clock: clock)
        f.start()
        f.handle(on("C4", clock))
        clock.advance(by: 0.2)
        XCTAssertTrue(records(f.handle(on("D4", clock))).isEmpty)
        clock.advance(by: 0.31)
        let ev = f.update()
        XCTAssertEqual(records(ev).first?.outcome, .correct, "D4 pressed during the gap completes the step when it becomes current")
        XCTAssertEqual(f.currentPosition, 2)
    }

    func testOtherHandIsDemonstratedAtOnsetsAndInGaps() {
        let clock = ManualPracticeClock()
        let settings = PracticeSettings(mode: .wait, hands: .right, playOtherHands: true, waitModeRestScale: 1)
        // RH half notes, LH quarters: the second LH quarter falls inside the RH gap.
        let score = ScoreBuilder.make(title: "Demo", tempo: 120, right: [[(["E4"], 1920), (["F4"], 1920)]], left: [[(["C3"], 960), (["G3"], 960), (["C3"], 1920)]])
        let f = PracticeWaitFollower(timeline: score.makeTimeline(), settings: settings, clock: clock)
        f.start()
        let ev = f.handle(on("E4", clock))
        let chords = ev.compactMap { if case .soundChord(let c, _) = $0 { return c } else { return nil } }
        XCTAssertEqual(chords.map { $0.pitches }, [[midi("C3")]])
        XCTAssertEqual(chords.first?.durationSeconds ?? 0, 0.5, accuracy: 1e-9)
        clock.advance(by: 0.49)
        XCTAssertTrue(f.update().isEmpty)
        clock.advance(by: 0.02)
        let later = f.update().compactMap { if case .soundChord(let c, _) = $0 { return c.pitches } else { return nil } }
        XCTAssertEqual(later, [[midi("G3")]], "LH G3 sounds at its scaled time inside the gap")
        XCTAssertEqual(f.feedback().keyStates[midi("G3")], .demo)
    }

    // MARK: - Wait Mode: loop and end

    func testLoopEndJumpsBackToLoopStart() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), loop: MeasureRange(single: 1), clock: clock)
        f.start()
        XCTAssertEqual(f.expectedPitches, [midi("G4")], "material starts at the loop")
        var events: [PracticeFollowerEvent] = []
        for n in ["G4", "A4", "B4", "C5"] { events += f.handle(on(n, clock)); f.handle(off(n, clock)) }
        XCTAssertTrue(events.contains(.loopWrapped))
        XCTAssertFalse(events.contains(.finished))
        XCTAssertEqual(f.expectedPitches, [midi("G4")])
        XCTAssertEqual(f.statistics.measuresCompleted, [1])
    }

    func testEndOfMaterialFinishes() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), clock: clock)
        f.start()
        var events: [PracticeFollowerEvent] = []
        for n in ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5"] { events += f.handle(on(n, clock)) }
        XCTAssertTrue(events.contains(.finished))
        XCTAssertTrue(f.isFinished)
        XCTAssertEqual(f.statistics.measuresCompleted, [0, 1])
        XCTAssertEqual(f.statistics.stepsExpected, 8)
    }

    func testPauseFreezesGap() {
        let clock = ManualPracticeClock()
        let f = waitFollower(Self.scaleScore(), restScale: 1, clock: clock)
        f.start()
        f.handle(on("C4", clock))
        clock.advance(by: 0.2)
        f.pause()
        clock.advance(by: 5)
        f.update()
        XCTAssertNotEqual(f.phase, .waiting(position: 1))
        f.resume()
        clock.advance(by: 0.31)
        f.update()
        XCTAssertEqual(f.phase, .waiting(position: 1))
    }

    // MARK: - Just Play

    private func justPlay(_ score: Score, speed: Double = 1, loop: MeasureRange? = nil, clock: ManualPracticeClock) -> PracticeJustPlayFollower {
        let settings = PracticeSettings(mode: .justPlay, hands: .right, speed: speed, loop: loop, timingWindowSeconds: 0.3)
        return PracticeJustPlayFollower(timeline: score.makeTimeline(), settings: settings, clock: clock)
    }

    /// Ticks per second at 120 BPM and full speed.
    private let ticksPerSecond = 1920.0

    func testJustPlayClassifiesTiming() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), clock: clock)
        f.start(atTick: 0)
        f.update(positionTick: 0)
        XCTAssertEqual(records(f.handle(on("C4", clock))).first?.outcome, .correct)
        clock.advance(by: 0.25)
        f.update(positionTick: 0.25 * ticksPerSecond)
        XCTAssertEqual(records(f.handle(on("D4", clock))).first?.outcome, .early, "250 ms early is inside ±300 ms but beyond ±150 ms")
        clock.advance(by: 1.0)
        f.update(positionTick: 1.25 * ticksPerSecond)
        XCTAssertEqual(records(f.handle(on("E4", clock))).first?.outcome, .late)
        clock.advance(by: 0.5)
        let ev = f.update(positionTick: 1.75 * ticksPerSecond)
        XCTAssertTrue(records(ev).isEmpty, "F4 (1.5 s) still inside its window")
        clock.advance(by: 0.1)
        XCTAssertTrue(records(f.update(positionTick: 1.85 * ticksPerSecond)).isEmpty, "window closed, but the miss waits out the input-latency grace")
        clock.advance(by: 0.15)
        XCTAssertEqual(records(f.update(positionTick: 2.0 * ticksPerSecond)).map { $0.outcome }, [.missed])
        XCTAssertEqual(records(f.handle(on("C2", clock))).first?.outcome, .wrong)
        XCTAssertEqual(f.statistics.stepsHit, 3)
        XCTAssertEqual(f.statistics.stepsMissed, 1)
        XCTAssertEqual(f.accuracy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(f.statistics.wrongNotes, 1)
    }

    func testJustPlaySpeedScalesExpectedTimes() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), speed: 0.5, clock: clock)
        f.start(atTick: 0)
        f.handle(on("C4", clock))
        // At half speed D4 (tick 960) is due at 1.0 s, not 0.5 s.
        clock.advance(by: 0.5)
        f.update(positionTick: 960 / 2)
        XCTAssertEqual(records(f.handle(on("D4", clock))).first?.outcome, .wrong)
        clock.advance(by: 0.5)
        f.update(positionTick: 960)
        XCTAssertEqual(records(f.handle(on("D4", clock))).first?.outcome, .correct)
        // The Wait-Mode material agrees: one quarter lasts 1 s at half speed.
        let material = PracticeMaterial(timeline: Self.scaleScore().makeTimeline(), hands: .right, loop: nil)
        XCTAssertEqual(material.seconds(from: 0, to: 960, speed: 0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(material.seconds(from: 0, to: 960, speed: 1.0), 0.5, accuracy: 1e-9)
    }

    func testJustPlayResyncsWhenLearnerIsAhead() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), clock: clock)
        f.start(atTick: 0)
        f.update(positionTick: 0)
        // The learner plays E F G (steps 2…4) while the transport is at steps 0…2: one second ahead.
        var events: [PracticeFollowerEvent] = []
        for (i, n) in ["E4", "F4", "G4"].enumerated() {
            if i > 0 { clock.advance(by: 0.5); events += f.update(positionTick: Double(i) * 960) }
            events += f.handle(on(n, clock))
        }
        XCTAssertTrue(events.contains(.resyncRequested(toTick: 4 * 960)), "three matches at a consistent offset jump the transport")
        XCTAssertEqual(f.statistics.wrongNotes, 0, "the chain's wrong records are withdrawn")
        XCTAssertEqual(f.statistics.stepsCorrect, 3)
        XCTAssertEqual(f.statistics.stepsMissed, 2, "C4 and D4 skipped")
        XCTAssertEqual(f.currentPosition, 5)
        XCTAssertEqual(f.cursorTick, 4 * 960)
        // The follower now judges against the new position.
        clock.advance(by: 0.5)
        f.update(positionTick: 5 * 960)
        XCTAssertEqual(records(f.handle(on("A4", clock))).first?.outcome, .correct)
    }

    func testJustPlayNoResyncForScatteredWrongNotes() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), clock: clock)
        f.start(atTick: 0)
        var events: [PracticeFollowerEvent] = []
        for (i, n) in ["G4", "D4", "B4"].enumerated() {
            if i > 0 { clock.advance(by: 0.5); events += f.update(positionTick: Double(i) * 960) }
            events += f.handle(on(n, clock))
        }
        XCTAssertFalse(events.contains { if case .resyncRequested = $0 { return true } else { return false } })
    }

    func testJustPlayLoopWrap() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), loop: MeasureRange(single: 0), clock: clock)
        f.start(atTick: 0)
        for (i, n) in ["C4", "D4", "E4", "F4"].enumerated() {
            f.update(positionTick: Double(i) * 960)
            f.handle(on(n, clock))
            clock.advance(by: 0.5)
        }
        let ev = f.update(positionTick: 100)
        XCTAssertTrue(ev.contains(.loopWrapped))
        XCTAssertEqual(f.currentPosition, 0)
        XCTAssertEqual(f.statistics.stepsCorrect, 4, "the first pass is banked")
        f.handle(on("C4", clock))
        XCTAssertEqual(f.statistics.stepsCorrect, 5)
    }

    func testJustPlayEarlyFirstNoteAtLoopWrap() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), loop: MeasureRange(single: 0), clock: clock)
        f.start(atTick: 0)
        for (i, n) in ["C4", "D4", "E4", "F4"].enumerated() {
            f.update(positionTick: Double(i) * 960)
            f.handle(on(n, clock))
            clock.advance(by: 0.5)
        }
        // 50 ms before the 2 s loop end the learner starts the next pass.
        clock.advance(by: -0.05)
        var events = f.update(positionTick: 1.95 * ticksPerSecond)
        events += f.handle(on("C4", clock))
        XCTAssertTrue(records(events).isEmpty, "buffered for the next pass, not judged wrong")
        clock.advance(by: 0.05)
        let wrap = f.update(positionTick: 0)
        XCTAssertTrue(wrap.contains(.loopWrapped))
        let credited = records(wrap)
        XCTAssertEqual(credited.count, 1)
        XCTAssertTrue(credited.first.map { $0.outcome == .correct || $0.outcome == .early } ?? false)
        XCTAssertEqual(credited.first?.deltaSeconds ?? 0, -0.05, accuracy: 1e-6)
        XCTAssertEqual(f.currentPosition, 1)
        clock.advance(by: 0.5)
        events = f.update(positionTick: 960)
        events += f.handle(on("D4", clock))
        XCTAssertEqual(records(events).map { $0.outcome }, [.correct])
        XCTAssertEqual(f.statistics.wrongNotes, 0)
        XCTAssertEqual(f.statistics.stepsMissed, 0)
        XCTAssertEqual(f.statistics.stepsHit, 6)
    }

    func testJustPlayJudgesInputAtItsOnsetTime() {
        let clock = ManualPracticeClock()
        let f = justPlay(Self.scaleScore(), clock: clock)
        f.start(atTick: 0)
        f.update(positionTick: 0)
        f.handle(on("C4", clock))
        // D4 is due at 0.5 s and played at 0.55 s, but the (microphone) event arrives at 0.85 s: after the
        // ±300 ms window closed, still inside the miss grace.
        clock.advance(by: 0.85)
        XCTAssertTrue(records(f.update(positionTick: 0.85 * ticksPerSecond)).isEmpty)
        let late = records(f.handle(.on(midi("D4"), time: clock.now - 0.3, source: .microphone)))
        XCTAssertEqual(late.map { $0.outcome }, [.correct])
        XCTAssertEqual(late.first?.deltaSeconds ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(f.statistics.stepsMissed, 0)
    }

    func testInputTimingFallsBackForImplausibleStamps() {
        let event = { (t: TimeInterval) in NoteInputEvent.on(60, time: t, source: .midi) }
        XCTAssertEqual(PracticeInputTiming.time(of: event(4.9), now: 5), 4.9, accuracy: 1e-12)
        XCTAssertEqual(PracticeInputTiming.time(of: event(5.003), now: 5), 5, accuracy: 1e-12, "tiny lead is clamped to now")
        XCTAssertEqual(PracticeInputTiming.time(of: event(7), now: 5), 5, accuracy: 1e-12, "future stamp: other clock")
        XCTAssertEqual(PracticeInputTiming.time(of: event(0), now: 5), 5, accuracy: 1e-12, "stale stamp: other clock")
    }

    // MARK: - Session

    @MainActor
    func testSessionWaitModeLoopAndSummary() {
        let clock = ManualPracticeClock()
        var ended: [PracticeSessionRecord] = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        let settings = PracticeSettings(mode: .wait, hands: .right, loop: MeasureRange(single: 0), waitModeRestScale: 0)
        let session = PracticeSession(score: Self.scaleScore(), arrangementID: "scale", settings: settings, clock: clock, drivesItself: false, dateProvider: { start })
        session.onSessionEnded = { ended.append($0) }
        session.play()
        XCTAssertEqual(session.transportState, .playing)
        for n in ["C4", "D4", "E4", "F4", "C4"] {
            clock.advance(by: 0.5)
            session.handle(on(n, clock)); session.handle(off(n, clock))
        }
        XCTAssertEqual(session.loopsCompleted, 1)
        XCTAssertEqual(session.expectedPitches, [midi("D4")])
        XCTAssertEqual(session.feedback.keyStates[midi("D4")], .expected)
        session.handle(on("G4", clock))
        XCTAssertEqual(session.feedback.keyStates[midi("G4")], .wrong)
        session.pause()
        clock.advance(by: 10)
        session.refresh()
        XCTAssertEqual(session.practicedSeconds, 2.5, accuracy: 1e-9, "paused time is not practice time")
        let record = session.stop()
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(record?.summary.arrangementID, "scale")
        XCTAssertEqual(record?.summary.startedAt, start)
        XCTAssertEqual(record?.summary.stepsExpected, 5)
        XCTAssertEqual(record?.summary.stepsCorrect, 5)
        XCTAssertEqual(record?.summary.wrongNotes, 1)
        XCTAssertEqual(record?.summary.mistakesByMeasure, [0: 1])
        XCTAssertEqual(record?.summary.measuresCompleted, [0])
        XCTAssertEqual(record?.summary.reachedEnd, false)
        XCTAssertEqual(session.transportState, .stopped)
        // The summary folds into the Core profile.
        var profile = UserProfile()
        if let summary = record?.summary { profile.record(summary) }
        XCTAssertEqual(profile.progress["scale"]?.sessions, 1)
    }

    @MainActor
    func testSessionSpeedChangeKeepsStatisticsAndPosition() {
        let clock = ManualPracticeClock()
        let session = PracticeSession(score: Self.scaleScore(), arrangementID: "scale", settings: PracticeSettings(mode: .wait, hands: .right, waitModeRestScale: 0), clock: clock, drivesItself: false)
        session.play()
        for n in ["C4", "D4"] { session.handle(on(n, clock)); session.handle(off(n, clock)) }
        session.speed = 0.62
        XCTAssertEqual(session.speed, 0.6, accuracy: 1e-9, "speed snaps to 0.05 steps")
        XCTAssertEqual(session.expectedPitches, [midi("E4")], "rebuilt follower continues at the cursor")
        XCTAssertEqual(session.statistics.stepsExpected, 2)
        session.speed = 0.1
        XCTAssertEqual(session.speed, 0.25, accuracy: 1e-9)
    }

    @MainActor
    func testSessionCountInThenJustPlayFinishes() {
        let clock = ManualPracticeClock()
        let session = PracticeSession(score: Self.scaleScore(), arrangementID: "scale", settings: PracticeSettings(mode: .justPlay, hands: .right, countInMeasures: 1), clock: clock, drivesItself: false)
        session.play()
        XCTAssertEqual(session.transportState, .countingIn)
        XCTAssertEqual(session.countInTotalBeats, 4)
        clock.advance(by: 1.1)
        session.refresh()
        XCTAssertEqual(session.countInBeat, 2)
        clock.advance(by: 0.9)
        session.refresh()
        XCTAssertEqual(session.transportState, .playing)
        session.handle(on("C4", clock))
        clock.advance(by: 5)
        session.refresh()
        XCTAssertEqual(session.transportState, .finished)
        XCTAssertEqual(session.lastRecord?.summary.stepsExpected, 8)
        XCTAssertEqual(session.lastRecord?.summary.stepsCorrect, 1)
        XCTAssertEqual(session.lastRecord?.summary.reachedEnd, true)
    }

    @MainActor
    func testSessionCreditsFirstNotePlayedAtEndOfCountIn() {
        let clock = ManualPracticeClock()
        let session = PracticeSession(score: Self.scaleScore(), arrangementID: "scale", settings: PracticeSettings(mode: .justPlay, hands: .right, countInMeasures: 1), clock: clock, drivesItself: false)
        session.play()
        clock.advance(by: 1.5)
        session.refresh()
        session.handle(on("G4", clock)); session.handle(off("G4", clock))
        clock.advance(by: 0.44)
        session.refresh()
        XCTAssertEqual(session.transportState, .countingIn)
        session.handle(on("C4", clock))
        XCTAssertNil(session.lastPlayed)
        clock.advance(by: 0.1)
        session.refresh()
        XCTAssertEqual(session.transportState, .playing)
        XCTAssertTrue(session.lastPlayed.map { $0.outcome == .correct || $0.outcome == .early } ?? false, "C4 100 ms before the downbeat counts")
        XCTAssertEqual(session.lastPlayed?.deltaSeconds ?? 0, -0.1, accuracy: 1e-6)
        clock.advance(by: 0.5)
        session.refresh()
        XCTAssertEqual(session.statistics.stepsMissed, 0)
        XCTAssertEqual(session.statistics.wrongNotes, 0, "noodling well before the downbeat is ignored")
        XCTAssertEqual(session.statistics.stepsHit, 1)
        XCTAssertEqual(session.keyState(for: midi("C4")), .pressed, "still held")
    }

    @MainActor
    func testSessionSeekAndPhrases() {
        let clock = ManualPracticeClock()
        let measures = (0..<8).map { _ in [(pitches: ["C4"], ticks: 3840)] }
        let session = PracticeSession(score: ScoreBuilder.make(title: "Long", tempo: 120, right: measures), arrangementID: "long", settings: PracticeSettings(mode: .wait, hands: .right), clock: clock, drivesItself: false)
        session.play()
        session.nextPhrase()
        XCTAssertEqual(session.cursorMeasure.measureIndex, 4)
        session.seek(toMeasure: 5)
        XCTAssertEqual(session.cursorMeasure.measureIndex, 5)
        session.previousPhrase()
        XCTAssertEqual(session.cursorMeasure.measureIndex, 4)
        session.previousPhrase()
        XCTAssertEqual(session.cursorMeasure.measureIndex, 0)
    }

    /// Records the calls the session makes on the audio player.
    private final class MockPlayer: ScorePlaybackControlling {
        var loadedTimeline: PlaybackTimeline?
        var audibleHands: HandSelection?
        var speed: Double = 1
        var loopTicks: Range<Ticks>?
        var isPlaying = false
        var positionTick: Double = 0
        var playedFrom: [Ticks] = []
        var immediate: [ImmediateChord] = []
        var seeks: [Ticks] = []
        var onReachedEnd: (() -> Void)?
        var onEventStarted: ((TimelineEvent) -> Void)?
        func load(timeline: PlaybackTimeline) { loadedTimeline = timeline }
        func play(fromTick tick: Ticks) { isPlaying = true; positionTick = Double(tick); playedFrom.append(tick) }
        func pause() { isPlaying = false }
        func stop() { isPlaying = false }
        func seek(toTick tick: Ticks) { positionTick = Double(tick); seeks.append(tick) }
        func playImmediately(_ chord: ImmediateChord) { immediate.append(chord) }
    }

    @MainActor
    func testSessionDrivesPlayer() {
        let clock = ManualPracticeClock()
        let player = MockPlayer()
        let score = Self.lessonScore()
        let session = PracticeSession(score: score, arrangementID: "lesson", settings: PracticeSettings(mode: .wait, hands: .right, playOtherHands: true, waitModeRestScale: 0), clock: clock, player: player, drivesItself: false)
        XCTAssertNotNil(player.loadedTimeline)
        session.play()
        session.handle(on("C4", clock))
        XCTAssertEqual(player.immediate.map { $0.pitches }, [[midi("C3")]], "Wait Mode demonstrates the left hand")
        session.stop()
        session.mode = .justPlay
        session.countInMeasures = 0
        session.speed = 0.5
        session.play()
        XCTAssertEqual(player.audibleHands, .left, "the learner's hand is muted")
        XCTAssertEqual(player.speed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(player.playedFrom.last, 0)
        player.positionTick = 960
        clock.advance(by: 1.0)
        session.handle(on("D4", clock))
        XCTAssertEqual(session.lastPlayed?.outcome, .correct, "judged against the player's position")
        player.onReachedEnd?()
        XCTAssertEqual(session.transportState, .finished)
    }

    // MARK: - Pure helpers

    func testPhraseStartsHonourPickupAndRepeats() {
        var score = ScoreBuilder.make(title: "P", right: (0..<10).map { _ in [(pitches: ["C4"], ticks: 3840)] })
        score.measures[0].isPickup = true
        score.measures[6].barline = Barline(repeatForward: true)
        XCTAssertEqual(PracticePhraseNavigator.phraseStarts(of: score), [0, 1, 5, 6])
        XCTAssertEqual(PracticePhraseNavigator.nextPhraseStart(after: 6, starts: [0, 1, 5, 6]), nil)
        XCTAssertEqual(PracticePhraseNavigator.previousPhraseStart(from: 5, tickInMeasure: 1500, beatTicks: 960, starts: [0, 1, 5, 6]), 5)
        XCTAssertEqual(PracticePhraseNavigator.previousPhraseStart(from: 5, tickInMeasure: 0, beatTicks: 960, starts: [0, 1, 5, 6]), 1)
    }

    func testSpeedRules() {
        XCTAssertEqual(PracticeSpeedRules.snap(0.33), 0.35, accuracy: 1e-9)
        XCTAssertEqual(PracticeSpeedRules.snap(2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PracticeSpeedRules.preset(from: 0.6, up: true), 0.75, accuracy: 1e-9)
        XCTAssertEqual(PracticeSpeedRules.preset(from: 0.25, up: false), 0.25, accuracy: 1e-9)
    }

    func testVirtualTransportWrapsLoop() {
        let timeline = Self.scaleScore().makeTimeline()
        var t = PracticeVirtualTransport(timeline: timeline, speed: 1, loopTicks: 0..<3840)
        t.play(fromTick: 0, now: 10)
        XCTAssertEqual(t.position(now: 11), 1920, accuracy: 1e-6)
        XCTAssertEqual(t.position(now: 12.5), 960, accuracy: 1e-6, "2.5 s into a 2 s loop is 0.5 s in")
        t.loopTicks = nil
        XCTAssertTrue(t.reachedEnd(now: 15))
    }

    func testSummaryBuilderMapsModes() {
        var stats = PracticeStatistics()
        stats.stepsExpected = 10; stats.stepsCorrect = 6; stats.stepsLate = 2; stats.stepsMissed = 2
        stats.stepsWithMistakes = 3
        let wait = PracticeSummaryBuilder.summary(arrangementID: "a", startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60, settings: PracticeSettings(mode: .wait), statistics: stats, reachedEnd: true)
        XCTAssertEqual(wait.stepsCorrect, 5, "wait: hits minus steps that needed retries")
        let jp = PracticeSummaryBuilder.summary(arrangementID: "a", startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60, settings: PracticeSettings(mode: .justPlay), statistics: stats, reachedEnd: true)
        XCTAssertEqual(jp.stepsCorrect, 8, "just play: on-time plus early/late")
        XCTAssertEqual(jp.accuracy, 0.8, accuracy: 1e-9)
        let data = try? JSONEncoder().encode(PracticeSummaryBuilder.record(arrangementID: "a", scoreTitle: "T", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60), durationSeconds: 60, settings: PracticeSettings(), statistics: stats, played: [], reachedEnd: false))
        XCTAssertNotNil(data)
        if let data { XCTAssertEqual(try? JSONDecoder().decode(PracticeSessionRecord.self, from: data).statistics, stats) }
    }
}
