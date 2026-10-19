import Foundation

// macOS command-line harness for the Practice engine (Core + Practice are Foundation/Observation only).
//
// Build and run:
//   xcrun swiftc -swift-version 5 -parse-as-library -o /tmp/practicecheck \
//     LearnPiano/Core/*.swift LearnPiano/Practice/*.swift scripts/practicecheck/main.swift && /tmp/practicecheck
//
// It simulates Wait-Mode sessions over a small in-code score (C D E F G + chords + a rest + a tie) with a
// manual clock, feeding correct, wrong and partial-chord input, and asserts the cursor behaviour.

/// Collects assertion results and prints a report.
@MainActor
final class PracticeCheckReport {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    /// Records one assertion.
    func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition {
            passed += 1
        } else {
            let text = "line \(line): \(message())"
            failures.append(text)
            print("FAIL \(text)")
        }
    }

    /// Records an equality assertion with both values in the message.
    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String, line: Int = #line) {
        check(a == b, "\(message): got \(a), expected \(b)", line: line)
    }
}

/// The test score: 4/4 at 120 BPM (a quarter = 0.5 s at full speed).
///
///     m1  RH: C4 D4 E4 F4 (quarters)            LH: C3 (whole)
///     m2  RH: G4 (half), C4-E4-G4 (half chord)  LH: G2 (half), C3 (half)
///     m3  RH: rest (q), D4-F4 (q), E4 (half, tie start)    LH: rest (whole)
///     m4  RH: E4 (q, tie stop), D4 (q), C4 (half)          LH: C3 (whole)
enum PracticeCheckScore {
    static func pitch(_ name: String) -> Pitch {
        Pitch(name: name) ?? Pitch(step: .C, octave: 4)
    }

    static func event(_ names: [String], onset: Ticks, ticks: Ticks, hand: Hand, tieStart: Bool = false, tieStop: Bool = false) -> MeasureEvent {
        MeasureEvent(onset: onset, duration: ticks, notes: names.map { ChordNote(pitch: pitch($0), tieStart: tieStart, tieStop: tieStop) }, hand: hand)
    }

    static func make() -> Score {
        let q = Ticks.perQuarter, h = 2 * q, w = 4 * q
        let m1 = Measure(number: 1, events: [
            event(["C4"], onset: 0, ticks: q, hand: .right), event(["D4"], onset: q, ticks: q, hand: .right),
            event(["E4"], onset: 2 * q, ticks: q, hand: .right), event(["F4"], onset: 3 * q, ticks: q, hand: .right),
            event(["C3"], onset: 0, ticks: w, hand: .left),
        ])
        let m2 = Measure(number: 2, events: [
            event(["G4"], onset: 0, ticks: h, hand: .right), event(["C4", "E4", "G4"], onset: h, ticks: h, hand: .right),
            event(["G2"], onset: 0, ticks: h, hand: .left), event(["C3"], onset: h, ticks: h, hand: .left),
        ])
        let m3 = Measure(number: 3, events: [
            event([], onset: 0, ticks: q, hand: .right), event(["D4", "F4"], onset: q, ticks: q, hand: .right),
            event(["E4"], onset: h, ticks: h, hand: .right, tieStart: true),
            event([], onset: 0, ticks: w, hand: .left),
        ])
        let m4 = Measure(number: 4, events: [
            event(["E4"], onset: 0, ticks: q, hand: .right, tieStop: true), event(["D4"], onset: q, ticks: q, hand: .right),
            event(["C4"], onset: h, ticks: h, hand: .right),
            event(["C3"], onset: 0, ticks: w, hand: .left),
        ], barline: Barline(isFinal: true))
        return Score(metadata: ScoreMetadata(title: "Practice check", source: .exercise), initialTempoBPM: 120, measures: [m1, m2, m3, m4])
    }
}

@main
struct PracticeCheck {
    @MainActor
    static func main() {
        let report = PracticeCheckReport()
        followerScenario(report)
        bothHandsTieScenario(report)
        sessionLoopScenario(report)
        justPlayScenario(report)
        print("practicecheck: \(report.passed) checks passed, \(report.failures.count) failed")
        if !report.failures.isEmpty { exit(1) }
    }

    static func midi(_ name: String) -> Int { PracticeCheckScore.pitch(name).midi }

    static func on(_ name: String, _ clock: ManualPracticeClock) -> NoteInputEvent {
        .on(midi(name), time: clock.now, source: .virtualKeyboard)
    }

    static func off(_ name: String, _ clock: ManualPracticeClock) -> NoteInputEvent {
        .off(midi(name), time: clock.now, source: .virtualKeyboard)
    }

    static func played(_ events: [PracticeFollowerEvent]) -> [PlayedRecord] {
        events.compactMap { if case .played(let r) = $0 { return r } else { return nil } }
    }

    static func sounded(_ events: [PracticeFollowerEvent]) -> [[Int]] {
        events.compactMap { if case .soundChord(let c, _) = $0 { return c.pitches } else { return nil } }
    }

    /// Right-hand Wait Mode over the whole score with the left hand demonstrated.
    @MainActor
    static func followerScenario(_ r: PracticeCheckReport) {
        let clock = ManualPracticeClock(now: 100)
        let timeline = PracticeCheckScore.make().makeTimeline()
        let settings = PracticeSettings(mode: .wait, hands: .right, speed: 1.0, playOtherHands: true, chordWindowSeconds: 0.25, waitModeRestScale: 0.5)
        let f = PracticeWaitFollower(timeline: timeline, settings: settings, clock: clock)
        r.equal(f.material.steps.count, 10, "right-hand material skips the tie continuation")

        var ev = f.start()
        r.check(ev.contains(.stepBecameCurrent(stepIndex: 0)), "first step current after start")
        r.equal(f.expectedPitches, [midi("C4")], "expects C4 first")
        r.equal(f.cursorTick, 0, "cursor at tick 0")

        // Wrong note: reported with the expected set, never advances.
        clock.advance(by: 0.4)
        ev = f.handle(on("D4", clock))
        let wrong = played(ev)
        r.equal(wrong.first?.outcome, .wrong, "D4 is wrong while C4 is expected")
        r.equal(wrong.first?.expected, [midi("C4")], "wrong record carries the expected set")
        r.equal(f.currentPosition, 0, "wrong note does not advance")
        r.equal(f.feedback().keyStates[midi("D4")], .wrong, "wrong key flagged")
        _ = f.handle(off("D4", clock))

        // Correct note: advances; left-hand C3 sounds with it.
        clock.advance(by: 0.1)
        ev = f.handle(on("C4", clock))
        let correct = played(ev)
        r.equal(correct.first?.outcome, .correct, "C4 completes step 0")
        r.check(abs((correct.first?.deltaSeconds ?? 0) - 0.5) < 1e-9, "deltaSeconds is the time since the step became current")
        r.equal(sounded(ev), [[midi("C3")]], "left hand C3 demonstrated at the completed onset")
        r.equal(f.currentPosition, 1, "cursor heads for D4")
        if case .gap = f.phase {} else { r.check(false, "a gap follows the completion") }
        _ = f.handle(off("C4", clock))

        // Gap = one quarter (0.5 s) × rest scale 0.5 = 0.25 s; the cursor interpolates.
        clock.advance(by: 0.125)
        _ = f.update()
        r.check(abs(f.cursorTick - 480) < 1, "cursor halfway through the gap (got \(f.cursorTick))")
        clock.advance(by: 0.2)
        _ = f.update()
        r.equal(f.phase, .waiting(position: 1), "D4 current after the gap")

        // Holding C4 from before does not count for anything; play D E F.
        for name in ["D4", "E4", "F4"] {
            clock.advance(by: 0.3)
            ev = f.handle(on(name, clock))
            r.equal(played(ev).first?.outcome, .correct, "\(name) correct")
            _ = f.handle(off(name, clock))
            clock.advance(by: 0.3)
            _ = f.update()
        }
        r.check(f.statistics.measuresCompleted.contains(0), "measure 1 completed")
        r.equal(f.expectedPitches, [midi("G4")], "G4 expected at measure 2")

        // G4 then the C-E-G chord after a half-note gap (1.0 s × 0.5).
        ev = f.handle(on("G4", clock))
        r.equal(sounded(ev), [[midi("G2")]], "left hand G2 demonstrated with G4")
        _ = f.handle(off("G4", clock))
        clock.advance(by: 0.4)
        _ = f.update()
        if case .gap = f.phase {} else { r.check(false, "still in the half-note gap after 0.4 s") }
        clock.advance(by: 0.2)
        _ = f.update()
        r.equal(f.expectedPitches, [midi("C4"), midi("E4"), midi("G4")], "C-E-G chord expected")

        // Partial chord: two of three notes do not advance; the third within the window completes.
        ev = f.handle(on("C4", clock))
        ev += f.handle(on("E4", clock))
        r.check(played(ev).isEmpty, "partial chord produces no record")
        r.equal(f.missingPitches, [midi("G4")], "G4 still missing")
        r.equal(f.feedback().missingPitches, [midi("G4")], "snapshot lists the missing pitch")
        clock.advance(by: 0.1)
        ev = f.handle(on("G4", clock))
        r.equal(played(ev).first?.outcome, .correct, "chord completes within the window")
        r.equal(played(ev).first?.played, [midi("C4"), midi("E4"), midi("G4")], "chord record lists all pitches")
        for n in ["C4", "E4", "G4"] { _ = f.handle(off(n, clock)) }

        // Gap to D-F spans a quarter rest: 3 quarters (1.5 s) × 0.5 = 0.75 s.
        clock.advance(by: 0.7)
        _ = f.update()
        if case .gap = f.phase {} else { r.check(false, "rest keeps the gap open at 0.7 s") }
        clock.advance(by: 0.1)
        _ = f.update()
        r.equal(f.expectedPitches, [midi("D4"), midi("F4")], "D-F expected after the rest")

        // Slow chord (lenient window): D4, then F4 a full second later still completes.
        _ = f.handle(on("D4", clock))
        clock.advance(by: 1.0)
        ev = f.handle(on("F4", clock))
        r.equal(played(ev).first?.outcome, .correct, "slow chord completes (lenient window)")
        _ = f.handle(off("D4", clock)); _ = f.handle(off("F4", clock))
        clock.advance(by: 0.3)
        _ = f.update()

        // E4 (tie start) then D4: the tied E4 continuation is not expected again.
        r.equal(f.expectedPitches, [midi("E4")], "tied E4 attack expected")
        ev = f.handle(on("E4", clock))
        clock.advance(by: 1.0)
        _ = f.update()
        r.equal(f.expectedPitches, [midi("D4")], "after the tie the next expected note is D4")
        _ = f.handle(off("E4", clock))
        _ = f.handle(on("D4", clock)); _ = f.handle(off("D4", clock))
        clock.advance(by: 0.3)
        _ = f.update()
        ev = f.handle(on("C4", clock))
        clock.advance(by: 2.0)
        ev += f.update()
        r.check(ev.contains(.finished), "end of the material reached")
        r.check(f.isFinished, "follower finished")
        r.equal(f.statistics.stepsExpected, 10, "ten steps expected")
        r.equal(f.statistics.wrongNotes, 1, "one wrong note")
        r.equal(f.statistics.stepsWithMistakes, 1, "one step needed a retry")
        r.equal(f.statistics.mistakesByMeasure, [0: 1], "the mistake is in measure 1")
        r.equal(f.statistics.measuresCompleted, [0, 1, 2, 3], "all four measures completed")
    }

    /// Both hands: the tie-continuation onset only expects the left hand's C3.
    @MainActor
    static func bothHandsTieScenario(_ r: PracticeCheckReport) {
        let clock = ManualPracticeClock()
        let timeline = PracticeCheckScore.make().makeTimeline()
        let settings = PracticeSettings(mode: .wait, hands: .both, waitModeRestScale: 0)
        let f = PracticeWaitFollower(timeline: timeline, settings: settings, clock: clock)
        let tieStep = f.material.steps.firstIndex { $0.tick == 11520 }
        r.check(tieStep != nil, "the tie-continuation onset has a step for the left hand")
        if let k = tieStep { r.equal(f.material.expected[k], [midi("C3")], "tied E4 not expected again, only C3") }
        f.start(atTick: 11520)
        r.equal(f.expectedPitches, [midi("C3")], "start at measure 4 expects C3")
        let ev = f.handle(on("C3", clock))
        r.equal(played(ev).first?.outcome, .correct, "C3 completes the step")
        r.equal(f.expectedPitches, [midi("D4")], "rest scale 0 advances instantly")
    }

    /// The observable session in Wait Mode with a one-measure loop.
    @MainActor
    static func sessionLoopScenario(_ r: PracticeCheckReport) {
        let clock = ManualPracticeClock()
        var ended: [PracticeSessionRecord] = []
        let settings = PracticeSettings(mode: .wait, hands: .right, loop: MeasureRange(single: 0), waitModeRestScale: 0)
        let session = PracticeSession(score: PracticeCheckScore.make(), arrangementID: "check", settings: settings, clock: clock, drivesItself: false)
        session.onSessionEnded = { ended.append($0) }
        session.play()
        r.equal(session.transportState, .playing, "Wait Mode plays without a count-in")
        r.equal(session.expectedPitches, [midi("C4")], "session expects C4")
        for name in ["C4", "D4", "E4", "F4"] {
            clock.advance(by: 0.5)
            session.handle(on(name, clock))
            session.handle(off(name, clock))
            session.refresh()
        }
        r.equal(session.loopsCompleted, 1, "loop wrapped once")
        r.equal(session.expectedPitches, [midi("C4")], "back at the loop start")
        r.equal(session.transportState, .playing, "a loop never finishes")
        clock.advance(by: 0.5)
        session.handle(on("A4", clock))
        r.equal(session.feedback.keyStates[midi("A4")], .wrong, "wrong key highlighted in the session snapshot")
        r.equal(session.mistakesByMeasure, [0: 1], "mistake counted for measure 1")
        let record = session.stop()
        r.equal(session.transportState, .stopped, "stopped")
        r.equal(ended.count, 1, "one session record emitted")
        r.equal(record?.summary.stepsExpected, 4, "four steps expected")
        r.equal(record?.summary.wrongNotes, 1, "one wrong note in the summary")
        r.check(abs((record?.summary.durationSeconds ?? 0) - 2.5) < 1e-9, "practice time 2.5 s")
    }

    /// The session in Just Play with the silent transport: on-time notes are correct, silence is missed.
    @MainActor
    static func justPlayScenario(_ r: PracticeCheckReport) {
        let clock = ManualPracticeClock()
        let settings = PracticeSettings(mode: .justPlay, hands: .right, speed: 1.0, countInMeasures: 1)
        let session = PracticeSession(score: PracticeCheckScore.make(), arrangementID: "check", settings: settings, clock: clock, drivesItself: false)
        session.play()
        r.equal(session.transportState, .countingIn, "Just Play counts in")
        clock.advance(by: 2.0)
        session.refresh()
        r.equal(session.transportState, .playing, "count-in of one 4/4 bar at 120 BPM lasts 2 s")
        session.handle(on("C4", clock))
        clock.advance(by: 0.5)
        session.refresh()
        session.handle(on("D4", clock))
        clock.advance(by: 1.5)
        session.refresh()
        r.equal(session.statistics.stepsCorrect, 2, "C4 and D4 on time")
        r.equal(session.statistics.stepsMissed, 2, "E4 and F4 missed")
        r.check(abs(session.accuracy - 0.5) < 1e-9, "running accuracy 50 %")
        clock.advance(by: 10)
        session.refresh()
        r.equal(session.transportState, .finished, "Just Play finishes at the end of the timeline")
        r.equal(session.lastRecord?.summary.reachedEnd, true, "summary marks the end reached")
    }
}
