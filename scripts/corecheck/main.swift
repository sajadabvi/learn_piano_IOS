import Foundation

func check(_ cond: Bool, _ msg: String) { print((cond ? "PASS " : "FAIL ") + msg); if !cond { exit(1) } }

// Pitch
check(Pitch(name: "C4")!.midi == 60, "C4 == 60")
check(Pitch(name: "F#3")!.midi == 54, "F#3 == 54")
check(Pitch(name: "Bb2")!.midi == 46, "Bb2 == 46")
check(Pitch(midi: 61).name == "C#4" && Pitch(midi: 61, preferFlats: true).name == "Db4", "spelling")
check(KeySignature(fifths: 2).alteration(of: .C) == 1 && KeySignature(fifths: -1).alteration(of: .B) == -1, "key sig alterations")
check(TimeSignature(beats: 6, beatType: 8).measureTicks == 2880 && TimeSignature(beats: 6, beatType: 8).isCompound, "6/8 ticks")
check(NoteDuration(value: .quarter, dots: 1).ticks == 1440, "dotted quarter")
check(NoteDuration(value: .eighth, tuplet: .triplet).ticks == 320, "triplet eighth")
check(NoteDuration.exact(ticks: 320)?.tuplet == .triplet, "exact triplet lookup")
check(NoteDuration.tiedChain(ticks: 960 * 5).map { $0.ticks } == [3840, 960], "tied chain 5 quarters")

// Tempo
let tm = TempoMap(events: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 1920, bpm: 60)])
check(abs(tm.seconds(at: 1920) - 1.0) < 1e-9, "2 quarters at 120 = 1s")
check(abs(tm.seconds(at: 3840) - 3.0) < 1e-9, "then 2 quarters at 60 = +2s")
check(abs(tm.tick(atSeconds: 3.0) - 3840) < 1e-6, "inverse")
check(abs(tm.seconds(at: 1920, speed: 0.5) - 2.0) < 1e-9, "half speed")

// Score with ties, chord and a repeat
let q = Ticks.perQuarter
let c4 = Pitch(name: "C4")!, e4 = Pitch(name: "E4")!, g4 = Pitch(name: "G4")!, c3 = Pitch(name: "C3")!
let m1 = Measure(number: 1, events: [
    MeasureEvent(onset: 0, duration: 2*q, notes: [ChordNote(pitch: c4, tieStart: true)], hand: .right),
    MeasureEvent(onset: 2*q, duration: 2*q, notes: [ChordNote(pitch: c4, tieStop: true), ChordNote(pitch: e4)], hand: .right),
    MeasureEvent(onset: 0, duration: 4*q, notes: [ChordNote(pitch: c3)], hand: .left),
], barline: Barline(repeatBackwardTimes: 2))
let m2 = Measure(number: 2, events: [
    MeasureEvent(onset: 0, duration: 4*q, notes: [ChordNote(pitch: g4)], hand: .right),
    MeasureEvent(onset: 0, duration: 4*q, notes: [], hand: .left),
], barline: Barline(isFinal: true))
let score = Score(metadata: ScoreMetadata(title: "T"), initialTempoBPM: 120, measures: [m1, m2])
let order = score.playbackOrder()
check(order.map { $0.measureIndex } == [0, 0, 1] && order.map { $0.pass } == [1, 2, 1], "repeat expansion \(order)")
let tl = score.makeTimeline()
check(tl.totalTicks == 3 * 4 * q, "total ticks")
check(tl.segments.count == 3 && tl.segments[2].startTick == 8*q, "segments")
let step1 = tl.steps[1]
check(tl.steps.count == 5, "steps: m1 beat1, m1 beat3, m1' beat1, m1' beat3, m2 = \(tl.steps.count)")
check(step1.attackPitches(for: .both) == [64], "tie continuation not expected (only E4): \(step1.attackPitches(for: .both))")
check(tl.steps[0].attackPitches(for: .both) == [48, 60], "first step both hands")
check(tl.steps[0].attackPitches(for: .right) == [60], "first step right only")
check(tl.measurePosition(atTick: 9*q).measureIndex == 1 && tl.measurePosition(atTick: 9*q).tickInMeasure == q, "measure position")
check(tl.startTick(ofMeasure: 1) == 8*q, "start tick m2")
check(tl.tickRange(of: MeasureRange(start: 0, end: 0)) == (0..<4*q), "loop range m1")
check(tl.stepIndex(atOrAfter: 2*q) == 1, "step index at beat 3")
check(tl.events(soundingAt: 3*q).map { $0.pitches }.flatMap { $0 }.sorted() == [48, 60, 64], "sounding at beat 4")

// Validation
let diags = ScoreValidator.validate(score)
check(!diags.contains { $0.severity == .error }, "valid score has no errors: \(diags)")
var bad = score
bad.measures[0].events.append(MeasureEvent(onset: 3*q, duration: 2*q, notes: [ChordNote(pitch: g4)], hand: .right, voice: 2))
check(ScoreValidator.validate(bad).contains { $0.severity == .error }, "overfull measure is an error")
let repaired = ScoreValidator.repair(bad).score
check(repaired.measures[0].contentLength == 4*q, "repair trims")

// Endings: m1 |: m2 (ending 1) :| m3 (ending 2) m4
let mk = { (n: Int, b: Barline) in Measure(number: n, events: [MeasureEvent(onset: 0, duration: 4*q, notes: [ChordNote(pitch: c4)], hand: .right)], barline: b) }
let s2 = Score(metadata: ScoreMetadata(title: "E"), measures: [mk(1, Barline(repeatForward: true)), mk(2, Barline(repeatBackwardTimes: 2, endings: [1])), mk(3, Barline(endings: [2])), mk(4, .plain)])
check(s2.playbackOrder().map { $0.measureIndex } == [0, 1, 0, 2, 3], "volta endings \(s2.playbackOrder().map { $0.measureIndex })")

// Builder + Codable round trip
let built = ScoreBuilder.make(title: "Ex", right: [[(["C4"], q), (["D4"], q), (["E4"], q), (["F4"], q)], [(["G4"], 4*q)]], left: [[(["C3", "G3"], 4*q)], [([], 4*q)]])
let data = try JSONEncoder().encode(built)
let back = try JSONDecoder().decode(Score.self, from: data)
check(back == built, "Codable round trip")
check(built.makeTimeline().steps.count == 5, "builder steps")
print("ALL CORE CHECKS PASSED")
