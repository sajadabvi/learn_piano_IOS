import XCTest
import CoreGraphics
@testable import LearnPiano

/// Tests for the Notation module's pure logic: staff geometry, the layout engine and highlight resolution.
final class NotationTests: XCTestCase {

    // MARK: Fixture

    private let q = Ticks.perQuarter

    private func note(_ name: String, tieStart: Bool = false, tieStop: Bool = false, finger: Int? = nil) -> ChordNote {
        guard let pitch = Pitch(name: name) else {
            XCTFail("bad pitch \(name)")
            return ChordNote(pitch: Pitch(step: .C, octave: 4))
        }
        return ChordNote(pitch: pitch, tieStart: tieStart, tieStop: tieStop, fingering: finger)
    }

    private func event(_ onset: Ticks, _ duration: Ticks, _ notes: [ChordNote], _ hand: Hand, voice: Int = 1, notated: NoteDuration? = nil) -> MeasureEvent {
        MeasureEvent(onset: onset, duration: duration, notated: notated, notes: notes, hand: hand, voice: voice)
    }

    /// A known four-measure score in G major, 4/4:
    /// m1 RH: G4 A4 (8ths, fingered 1 2) | F4 F4 (8ths, F natural twice) | C5+D5 quarter chord (second) | quarter rest; LH: C3-E3-G3 whole chord.
    /// m2 RH: C6 B5 A5 G5 (16ths) | E5 dotted quarter | D5 dotted quarter tied over; LH: F#2 half, Bb2 half.
    /// m3 RH: D5 quarter (tie stop) | E5 F5 G5 triplet 8ths | C4 half; LH two voices: C3 D3 halves (v1), C2 G2 quarters + C2 half (v2).
    /// m4 (key change to B♭ major, final barline) RH: G4-B4-D5 whole chord; LH empty.
    private func knownScore() -> Score {
        let e8 = q / 2, s16 = q / 4
        let triplet = NoteDuration(value: .eighth, tuplet: .triplet)
        let dottedQuarter = NoteDuration(value: .quarter, dots: 1)
        let m1 = [event(0, e8, [note("G4", finger: 1)], .right), event(e8, e8, [note("A4", finger: 2)], .right),
                  event(q, e8, [note("F4")], .right), event(q + e8, e8, [note("F4")], .right),
                  event(2 * q, q, [note("C5"), note("D5")], .right), event(3 * q, q, [], .right),
                  event(0, 4 * q, [note("C3"), note("E3"), note("G3")], .left)]
        let m2 = [event(0, s16, [note("C6")], .right), event(s16, s16, [note("B5")], .right),
                  event(2 * s16, s16, [note("A5")], .right), event(3 * s16, s16, [note("G5")], .right),
                  event(q, q + e8, [note("E5")], .right, notated: dottedQuarter),
                  event(2 * q + e8, q + e8, [note("D5", tieStart: true)], .right, notated: dottedQuarter),
                  event(0, 2 * q, [note("F#2")], .left), event(2 * q, 2 * q, [note("Bb2")], .left)]
        let m3 = [event(0, q, [note("D5", tieStop: true)], .right),
                  event(q, q / 3, [note("E5")], .right, notated: triplet),
                  event(q + q / 3, q / 3, [note("F5")], .right, notated: triplet),
                  event(q + 2 * q / 3, q / 3, [note("G5")], .right, notated: triplet),
                  event(2 * q, 2 * q, [note("C4")], .right),
                  event(0, 2 * q, [note("C3")], .left, voice: 1), event(2 * q, 2 * q, [note("D3")], .left, voice: 1),
                  event(0, q, [note("C2")], .left, voice: 2), event(q, q, [note("G2")], .left, voice: 2),
                  event(2 * q, 2 * q, [note("C2")], .left, voice: 2)]
        let m4 = [event(0, 4 * q, [note("G4"), note("B4"), note("D5")], .right)]
        return Score(metadata: ScoreMetadata(title: "Known"), initialTime: .common, initialKey: KeySignature(fifths: 1),
                     measures: [Measure(number: 1, events: m1), Measure(number: 2, events: m2), Measure(number: 3, events: m3),
                                Measure(number: 4, keySignature: KeySignature(fifths: -2), events: m4, barline: Barline(isFinal: true))])
    }

    private func layout(_ score: Score, mode: NotationLayoutMode = .scroll) -> NotationLayout {
        NotationLayoutEngine.layout(score: score, options: NotationLayoutOptions(staffSpace: 10, mode: mode))
    }

    /// Event of a measure with the given hand and first pitch name.
    private func find(_ layout: NotationLayout, measure: Int, hand: Hand, pitch: String, occurrence: Int = 0) -> NotationEventLayout? {
        let matches = layout.events(inMeasure: measure).filter { $0.hand == hand && $0.noteheads.first?.pitch.name == pitch }
        return matches.indices.contains(occurrence) ? matches[occurrence] : nil
    }

    // MARK: Staff geometry

    func testStaffStepsOfReferencePitches() throws {
        let f5 = try XCTUnwrap(Pitch(name: "F5")), e4 = try XCTUnwrap(Pitch(name: "E4")), c4 = try XCTUnwrap(Pitch(name: "C4"))
        let a3 = try XCTUnwrap(Pitch(name: "A3")), g2 = try XCTUnwrap(Pitch(name: "G2"))
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: f5, on: .right), 0)
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: e4, on: .right), 8)
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: c4, on: .right), 10)
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: a3, on: .left), 0)
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: g2, on: .left), 8)
        XCTAssertEqual(NotationStaffGeometry.staffStep(of: c4, on: .left), -2)
    }

    func testLedgerSteps() {
        XCTAssertEqual(NotationStaffGeometry.ledgerSteps(for: 10), [10])     // middle C on the treble staff
        XCTAssertEqual(NotationStaffGeometry.ledgerSteps(for: 11), [10])
        XCTAssertEqual(NotationStaffGeometry.ledgerSteps(for: -4), [-2, -4]) // C6
        XCTAssertEqual(NotationStaffGeometry.ledgerSteps(for: -1), [])
        XCTAssertEqual(NotationStaffGeometry.ledgerSteps(for: 8), [])
    }

    func testKeySignatureStepsForTrebleAndBass() {
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: 7, staff: .right), [0, 3, -1, 2, 5, 1, 4])
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: 7, staff: .left), [2, 5, 1, 4, 7, 3, 6])
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: -7, staff: .right), [4, 1, 5, 2, 6, 3, 7])
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: -7, staff: .left), [6, 3, 7, 4, 8, 5, 9])
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: 2, staff: .right), [0, 3])
        XCTAssertEqual(NotationStaffGeometry.keySignatureSteps(fifths: 0, staff: .left), [])
    }

    func testCancellationSteps() {
        // D major → B♭ major: F♯ and C♯ cancelled.
        XCTAssertEqual(NotationStaffGeometry.cancellationSteps(from: KeySignature(fifths: 2), to: KeySignature(fifths: -2), staff: .right), [0, 3])
        // A major → D major: only G♯ cancelled (third sharp at step −1).
        XCTAssertEqual(NotationStaffGeometry.cancellationSteps(from: KeySignature(fifths: 3), to: KeySignature(fifths: 2), staff: .right), [-1])
        XCTAssertEqual(NotationStaffGeometry.cancellationSteps(from: KeySignature(fifths: 1), to: KeySignature(fifths: 3), staff: .right), [])
    }

    func testStemDirectionRules() {
        XCTAssertTrue(NotationStaffGeometry.stemUp(forSteps: [7]))       // below the middle line
        XCTAssertFalse(NotationStaffGeometry.stemUp(forSteps: [4]))      // on the middle line
        XCTAssertFalse(NotationStaffGeometry.stemUp(forSteps: [1]))      // above
        XCTAssertTrue(NotationStaffGeometry.stemUp(forSteps: [3, 9]))    // farthest note (step 9) is below
        XCTAssertFalse(NotationStaffGeometry.stemUp(forSteps: [-2, 6]))  // farthest note (step −2) is above
        XCTAssertFalse(NotationStaffGeometry.stemUp(forSteps: [2, 6]))   // balanced → down
    }

    func testSecondDisplacement() {
        // C5 D5 (steps 3, 2): stem up → D5 to the right; stem down → C5 to the left.
        XCTAssertEqual(NotationStaffGeometry.displacedNotes(stepsLowToHigh: [3, 2], stemUp: true), [false, true])
        XCTAssertEqual(NotationStaffGeometry.displacedNotes(stepsLowToHigh: [3, 2], stemUp: false), [true, false])
        // Cluster C D E: alternate sides.
        XCTAssertEqual(NotationStaffGeometry.displacedNotes(stepsLowToHigh: [5, 4, 3], stemUp: true), [false, true, false])
        // Triad without seconds: nothing displaced.
        XCTAssertEqual(NotationStaffGeometry.displacedNotes(stepsLowToHigh: [8, 6, 4], stemUp: true), [false, false, false])
    }

    func testAccidentalMemoryRules() throws {
        var memory = NotationStaffGeometry.AccidentalMemory(key: KeySignature(fifths: 1)) // G major: F♯
        let f4 = try XCTUnwrap(Pitch(name: "F4")), fs4 = try XCTUnwrap(Pitch(name: "F#4")), fs5 = try XCTUnwrap(Pitch(name: "F#5"))
        XCTAssertNil(memory.accidental(for: fs4, isTieContinuation: false))              // covered by the key
        XCTAssertEqual(memory.accidental(for: f4, isTieContinuation: false), .natural)   // cancels the key
        XCTAssertNil(memory.accidental(for: f4, isTieContinuation: false))               // remembered in the measure
        XCTAssertEqual(memory.accidental(for: fs4, isTieContinuation: false), .sharp)    // returns to the key → re-drawn
        XCTAssertNil(memory.accidental(for: fs5, isTieContinuation: false))              // other octave: key applies
        var tied = NotationStaffGeometry.AccidentalMemory(key: .cMajor)
        let cs4 = try XCTUnwrap(Pitch(name: "C#4"))
        XCTAssertNil(tied.accidental(for: cs4, isTieContinuation: true))                 // tie continuation: no glyph
        XCTAssertEqual(tied.accidental(for: cs4, isTieContinuation: false), .sharp)      // memory was not touched
    }

    func testAccidentalColumnsStackCloseAccidentals() {
        XCTAssertEqual(NotationStaffGeometry.accidentalColumns(stepsTopToBottom: [2, 4, 8]), [0, 1, 0])
        XCTAssertEqual(NotationStaffGeometry.accidentalColumns(stepsTopToBottom: [0, 6]), [0, 0])
        XCTAssertEqual(NotationStaffGeometry.accidentalColumns(stepsTopToBottom: [0, 1, 2]), [0, 1, 2])
    }

    func testBeamGroupingRules() {
        typealias C = NotationStaffGeometry.BeamCandidate
        let e8 = q / 2
        // Four 8ths in 4/4 with a quarter pulse → two pairs.
        let eighths = (0..<4).map { C(onset: $0 * e8, duration: e8, flags: 1, isRest: false) }
        XCTAssertEqual(NotationStaffGeometry.beamGroups(eighths, pulse: q), [[0, 1], [2, 3]])
        // Six 8ths in 6/8 (dotted-quarter pulse) → two groups of three.
        let six = (0..<6).map { C(onset: $0 * e8, duration: e8, flags: 1, isRest: false) }
        XCTAssertEqual(NotationStaffGeometry.beamGroups(six, pulse: 3 * e8), [[0, 1, 2], [3, 4, 5]])
        // A rest breaks the group; a quarter is never beamed.
        let broken = [C(onset: 0, duration: e8 / 2, flags: 2, isRest: false), C(onset: e8 / 2, duration: e8 / 2, flags: 2, isRest: true),
                      C(onset: e8, duration: e8 / 2, flags: 2, isRest: false), C(onset: 3 * e8 / 2, duration: e8 / 2, flags: 2, isRest: false),
                      C(onset: q, duration: q, flags: 0, isRest: false)]
        XCTAssertEqual(NotationStaffGeometry.beamGroups(broken, pulse: q), [[2, 3]])
        // Pickup of two 8ths before beat 4: the offset aligns them to one beat.
        let pickup = [C(onset: 0, duration: e8, flags: 1, isRest: false), C(onset: e8, duration: e8, flags: 1, isRest: false)]
        XCTAssertEqual(NotationStaffGeometry.beamGroups(pickup, pulse: q, beatOffset: 3 * q), [[0, 1]])
        XCTAssertEqual(NotationStaffGeometry.beamGroups(pickup, pulse: q, beatOffset: 3 * q + e8), [])
    }

    func testBeamLineKeepsStemLengthAndLimitsSlope() {
        let tips = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: -5)]
        let line = NotationStaffGeometry.beamLine(tips: tips, stemUp: true, middleLineY: 10)
        XCTAssertEqual(line.b, -0.5, accuracy: 1e-9)                        // rise clamped to one space
        for t in tips { XCTAssertLessThanOrEqual(line.a + line.b * t.x, t.y + 1e-9) } // never shortens a stem
    }

    func testProportionalSpacing() {
        XCTAssertEqual(NotationStaffGeometry.proportionalWidth(ticks: q), NotationEngraving.quarterNoteSpacing, accuracy: 1e-9)
        XCTAssertEqual(NotationStaffGeometry.proportionalWidth(ticks: 4 * q), 2 * NotationEngraving.quarterNoteSpacing, accuracy: 1e-9)
        XCTAssertEqual(NotationStaffGeometry.proportionalWidth(ticks: 1), NotationEngraving.minimumColumnWidth, accuracy: 1e-9)
    }

    // MARK: Layout of the known score

    func testPositionsAreMonotonic() {
        let l = layout(knownScore())
        XCTAssertEqual(l.systems.count, 1)
        XCTAssertEqual(l.measures.count, 4)
        var lastX = -CGFloat.greatestFiniteMagnitude
        for m in l.measures {
            XCTAssertGreaterThanOrEqual(m.frame.minX, lastX - 1e-6)
            XCTAssertLessThan(m.contentStartX, m.frame.maxX)
            var previousColumn = -CGFloat.greatestFiniteMagnitude
            var previousTick = -1
            for c in m.columns {
                XCTAssertGreaterThan(c.x, previousColumn)
                XCTAssertGreaterThan(c.tick, previousTick)
                XCTAssertGreaterThan(c.x, m.frame.minX)
                XCTAssertLessThan(c.x, m.frame.maxX)
                previousColumn = c.x
                previousTick = c.tick
            }
            lastX = m.frame.maxX
            // Events of each hand are ordered left to right by onset.
            for hand in Hand.allCases {
                let evs = l.events(inMeasure: m.index).filter { $0.hand == hand && $0.voice == 1 }.sorted { $0.onset < $1.onset }
                for (a, b) in zip(evs, evs.dropFirst()) { XCTAssertLessThan(a.x, b.x) }
            }
        }
        // Simultaneous onsets in both hands share a column x.
        let rh = l.events(inMeasure: 2).first { $0.hand == .right && $0.onset == 0 }
        let lh = l.events(inMeasure: 2).first { $0.hand == .left && $0.onset == 0 && $0.voice == 1 }
        XCTAssertEqual(rh?.columnIndex, lh?.columnIndex)
        XCTAssertGreaterThan(l.size.width, l.measures[3].frame.maxX - 1e-6)
    }

    func testGlyphCounts() {
        let l = layout(knownScore())
        XCTAssertEqual(l.glyphs(role: .notehead).count, 30)
        XCTAssertEqual(l.glyphs(role: .clef).count, 2)
        XCTAssertEqual(l.glyphs(role: .brace).count, 1)
        XCTAssertEqual(l.glyphs(role: .timeSignature).count, 4)       // 4/4 on two staves
        XCTAssertEqual(l.glyphs(role: .keySignature).count, 2 + 4)    // F♯ ×2, then B♭ E♭ ×2
        XCTAssertEqual(l.glyphs(role: .keyCancellation).count, 2)     // F natural on both staves
        XCTAssertEqual(l.glyphs(role: .accidental).count, 4)          // F♮ (m1), B♭ (m2), F♮ (m3), B♮ (m4)
        XCTAssertEqual(l.glyphs(role: .augmentationDot).count, 2)
        XCTAssertEqual(l.glyphs(role: .tupletNumber).count, 1)
        XCTAssertEqual(l.glyphs(role: .fingering).count, 2)
        XCTAssertEqual(l.glyphs(role: .rest).count, 1)
        XCTAssertEqual(l.glyphs(role: .measureRest).count, 1)         // empty bass staff in m4
        XCTAssertEqual(l.glyphs(role: .flag).count, 0)                // every 8th/16th is beamed
        XCTAssertEqual(l.rects.filter { $0.role == .thickBarline }.count, 1)
        XCTAssertEqual(l.rects.filter { $0.role == .staffLine }.count, 4 * 2 * 5)
        // C6, B5, A5 need ledger lines above; C4 (RH m3) and C2 (LH m3) need them below.
        XCTAssertGreaterThanOrEqual(l.rects.filter { $0.role == .ledgerLine }.count, 6)
        // Whole notes have no stems; everything else with a stem has one stem rect.
        XCTAssertEqual(l.events.filter { $0.stem != nil }.count, l.events.filter { $0.stemUp != nil }.count)
    }

    func testAccidentalMemoryInLayout() {
        let l = layout(knownScore())
        let firstF = find(l, measure: 0, hand: .right, pitch: "F4", occurrence: 0)
        let secondF = find(l, measure: 0, hand: .right, pitch: "F4", occurrence: 1)
        XCTAssertEqual(firstF?.noteheads.first?.accidental, .natural)
        XCTAssertNil(secondF?.noteheads.first?.accidental)
        XCTAssertNil(find(l, measure: 1, hand: .left, pitch: "F#2")?.noteheads.first?.accidental) // key covers F♯
        XCTAssertEqual(find(l, measure: 1, hand: .left, pitch: "Bb2")?.noteheads.first?.accidental, .flat)
        XCTAssertEqual(find(l, measure: 2, hand: .right, pitch: "F5")?.noteheads.first?.accidental, .natural)
        let chord = find(l, measure: 3, hand: .right, pitch: "G4")
        XCTAssertEqual(chord?.noteheads.map { $0.accidental }, [nil, .natural, nil])         // B♮ against B♭ major
        // Accidentals sit to the left of their notehead.
        for g in l.glyphs(role: .accidental) {
            guard let id = g.owner.eventID, let e = l.event(id) else { return XCTFail("accidental without event") }
            XCTAssertLessThan(g.frame.maxX, (e.noteheads.map { $0.origin.x }.min() ?? 0) + 1e-6)
        }
    }

    func testKeySignaturePositionsInLayout() {
        let l = layout(knownScore())
        let system = l.systems[0]
        let first = l.glyphs(role: .keySignature).filter { $0.measureIndex == 0 }
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0.codepoint == NotationSMuFL.accidentalSharp })
        let ys = Set(first.map { $0.origin.y })
        XCTAssertTrue(ys.contains(system.trebleTop))          // F5 on the top treble line
        XCTAssertTrue(ys.contains(system.bassTop + 1))        // F3 on the fourth bass line
        let changed = l.glyphs(role: .keySignature).filter { $0.measureIndex == 3 }.sorted { ($0.origin.y > system.bassTop ? 1 : 0, $0.origin.x) < ($1.origin.y > system.bassTop ? 1 : 0, $1.origin.x) }
        XCTAssertEqual(changed.map { $0.origin.y }, [system.trebleTop + 2, system.trebleTop + 0.5, system.bassTop + 3, system.bassTop + 1.5])
        // Cancellation naturals come before the new flats.
        let naturalX = l.glyphs(role: .keyCancellation).map { $0.origin.x }.max() ?? 0
        XCTAssertLessThan(naturalX, changed.map { $0.origin.x }.min() ?? 0)
    }

    func testBeamGroupsInLayout() {
        let l = layout(knownScore())
        let sizes = l.beamGroups.map { [$0.measureIndex, $0.eventIDs.count] }
        XCTAssertEqual(sizes, [[0, 2], [0, 2], [1, 4], [2, 3]])
        XCTAssertEqual(l.beamGroups.map { $0.stemUp }, [true, true, false, false])
        // The 16th group carries a secondary beam.
        XCTAssertTrue(l.beams.contains { $0.measureIndex == 1 && $0.level == 2 })
        XCTAssertFalse(l.beams.contains { $0.measureIndex == 0 && $0.level == 2 })
        // Every beamed stem ends on its beam line.
        for group in l.beamGroups {
            guard let primary = l.beams.first(where: { $0.level == 1 && $0.eventIDs == group.eventIDs }) else { return XCTFail("missing primary beam") }
            let slope = (primary.end.y - primary.start.y) / max(0.001, primary.end.x - primary.start.x)
            for id in group.eventIDs {
                guard let stem = l.event(id)?.stem else { return XCTFail("missing stem") }
                let beamY = primary.start.y + slope * (stem.midX - primary.start.x)
                XCTAssertEqual(group.stemUp ? stem.minY : stem.maxY, beamY, accuracy: 0.01)
            }
        }
    }

    func testTieDetection() {
        let l = layout(knownScore())
        XCTAssertEqual(l.ties.count, 1)
        let tie = l.ties[0]
        let from = find(l, measure: 1, hand: .right, pitch: "D5")
        let to = find(l, measure: 2, hand: .right, pitch: "D5")
        XCTAssertEqual(tie.fromEventID, from?.id)
        XCTAssertEqual(tie.toEventID, to?.id)
        XCTAssertEqual(tie.midi, 74)
        XCTAssertTrue(tie.above)                     // stem down → tie above
        XCTAssertLessThan(tie.start.x, tie.end.x)
        // The tied-over D5 draws no accidental and is not re-attacked by the timeline.
        XCTAssertNil(to?.noteheads.first?.accidental)
    }

    func testDanglingTieAndPageSplit() {
        // A tie at the end of a system is split into two arcs in page mode.
        var measures: [Measure] = []
        for i in 0..<8 {
            measures.append(Measure(number: i + 1, events: [event(0, 4 * q, [note("E4", tieStart: i < 7, tieStop: i > 0)], .right)]))
        }
        let score = Score(metadata: ScoreMetadata(title: "Ties"), measures: measures)
        let page = layout(score, mode: .page(width: 400))
        XCTAssertGreaterThan(page.systems.count, 1)
        let crossings = page.systems.count - 1
        XCTAssertEqual(page.ties.count, 7 + crossings)
        XCTAssertTrue(page.ties.allSatisfy { $0.toEventID != nil })
        // A tie start without a continuation still gets a short arc.
        let lone = Score(metadata: ScoreMetadata(title: "Lone"), measures: [Measure(number: 1, events: [event(0, 4 * q, [note("G4", tieStart: true)], .right)])])
        let l = layout(lone)
        XCTAssertEqual(l.ties.count, 1)
        XCTAssertNil(l.ties[0].toEventID)
    }

    func testChordSecondOffsetAndStems() {
        let l = layout(knownScore())
        guard let chord = find(l, measure: 0, hand: .right, pitch: "C5") else { return XCTFail("missing chord") }
        XCTAssertEqual(chord.stemUp, false)
        XCTAssertEqual(chord.noteheads.map { $0.isDisplaced }, [true, false])          // C5 left of a down stem
        XCTAssertLessThan(chord.noteheads[0].origin.x, chord.noteheads[1].origin.x)
        guard let low = find(l, measure: 0, hand: .right, pitch: "G4") else { return XCTFail("missing G4") }
        XCTAssertEqual(low.stemUp, true)
        // Two voices in the bass of m3: voice 1 up, voice 2 down.
        let voices = l.events(inMeasure: 2).filter { $0.hand == .left && !$0.isRest }
        XCTAssertTrue(voices.filter { $0.voice == 1 }.allSatisfy { $0.stemUp == true })
        XCTAssertTrue(voices.filter { $0.voice == 2 }.allSatisfy { $0.stemUp == false })
        // Whole notes have no stem.
        XCTAssertNil(find(l, measure: 0, hand: .left, pitch: "C3")?.stemUp)
    }

    func testPageModeWrapsToWidth() {
        var measures: [Measure] = []
        for i in 0..<12 {
            measures.append(Measure(number: i + 1, events: (0..<4).map { event($0 * q, q, [note(["C4", "E4", "G4", "C5"][$0])], .right) } + [event(0, 4 * q, [note("C3")], .left)]))
        }
        let score = Score(metadata: ScoreMetadata(title: "Page"), measures: measures)
        let width: CGFloat = 700
        let l = layout(score, mode: .page(width: width))
        XCTAssertGreaterThan(l.systems.count, 1)
        XCTAssertEqual(l.systems.flatMap { Array($0.measureIndices) }, Array(0..<12))
        for m in l.measures { XCTAssertLessThanOrEqual(m.frame.maxX, width / 10 + 1e-6) }
        for (a, b) in zip(l.systems, l.systems.dropFirst()) { XCTAssertLessThanOrEqual(a.frame.maxY, b.frame.minY + 1e-6) }
        // Each system starts with a clef pair.
        XCTAssertEqual(l.glyphs(role: .clef).count, 2 * l.systems.count)
        // Measure numbers at system starts after the first.
        XCTAssertEqual(l.texts.filter { $0.role == .measureNumber }.count, l.systems.count - 1)
    }

    func testCursorAndHitTesting() {
        let l = layout(knownScore())
        let m = l.measures[0]
        var previous = -CGFloat.greatestFiniteMagnitude
        for t in stride(from: 0.0, through: Double(m.length), by: 60) {
            guard let x = l.cursorX(measureIndex: 0, tickInMeasure: t) else { return XCTFail("no cursor") }
            XCTAssertGreaterThanOrEqual(x, previous - 1e-9)
            previous = x
        }
        // At a column's tick the cursor is over the column's notehead.
        let column = m.columns[2]
        XCTAssertEqual(l.cursorX(measureIndex: 0, tickInMeasure: Double(column.tick)) ?? 0, column.x + NotationSMuFL.boundingBox(NotationSMuFL.noteheadBlack).width / 2, accuracy: 1e-6)
        for measure in l.measures {
            XCTAssertEqual(l.measureIndex(at: CGPoint(x: measure.frame.midX, y: measure.frame.midY)), measure.index)
        }
        XCTAssertEqual(NotationLayout.scrollOffset(cursorX: 50, viewportWidth: 100, contentWidth: 1000), 15)
        XCTAssertEqual(NotationLayout.scrollOffset(cursorX: 10, viewportWidth: 100, contentWidth: 1000), 0)
        XCTAssertEqual(NotationLayout.scrollOffset(cursorX: 990, viewportWidth: 100, contentWidth: 1000), 900)
        XCTAssertEqual(NotationLayout.scrollOffset(cursorX: 50, viewportWidth: 100, contentWidth: 80), 0)
    }

    func testCursorLocationFollowsRepeats() {
        let a = Measure(number: 1, events: [event(0, 4 * q, [note("C4")], .right)], barline: Barline(repeatBackwardTimes: 2))
        let b = Measure(number: 2, events: [event(0, 4 * q, [note("D4")], .right)])
        let score = Score(metadata: ScoreMetadata(title: "Repeat"), measures: [a, b])
        let l = layout(score)
        let timeline = score.makeTimeline()
        let second = NotationHighlightResolver.cursorLocation(positionTick: Double(4 * q) + 100.5, timeline: timeline, layout: l)
        XCTAssertEqual(second?.measureIndex, 0)            // second pass through measure 1
        XCTAssertEqual(second?.segmentIndex, 1)
        XCTAssertEqual(second?.tickInMeasure ?? 0, 100.5, accuracy: 1e-9)
        let third = NotationHighlightResolver.cursorLocation(positionTick: Double(8 * q), timeline: timeline, layout: l)
        XCTAssertEqual(third?.measureIndex, 1)
        let notated = NotationHighlightResolver.cursorLocation(positionTick: Double(4 * q + 10), timeline: nil, layout: l)
        XCTAssertEqual(notated?.measureIndex, 1)
        XCTAssertEqual(notated?.tickInMeasure ?? 0, 10, accuracy: 1e-9)
    }

    // MARK: Highlights

    func testTimelineIDParsingAndStatePreference() {
        let id = UUID()
        XCTAssertEqual(NotationHighlightResolver.parseTimelineEventID("3:\(id.uuidString)")?.eventID, id)
        XCTAssertEqual(NotationHighlightResolver.parseTimelineEventID("3:\(id.uuidString)")?.segment, 3)
        XCTAssertNil(NotationHighlightResolver.parseTimelineEventID("3:not-a-uuid"))
        let feedback = FeedbackSnapshot(eventStates: ["0:\(id.uuidString)": .correct, "4:\(id.uuidString)": .expected])
        XCTAssertEqual(NotationHighlightResolver.eventStates(feedback, currentSegment: 0)[id], .correct)
        XCTAssertEqual(NotationHighlightResolver.eventStates(feedback, currentSegment: 4)[id], .expected)
        XCTAssertEqual(NotationHighlightResolver.eventStates(feedback, currentSegment: nil)[id], .expected) // latest wins
    }

    func testTintAndDimming() {
        XCTAssertEqual(NotationHighlightResolver.tint(state: .correct, isSounding: false, highlightsSounding: true), .correct)
        XCTAssertEqual(NotationHighlightResolver.tint(state: .wrong, isSounding: true, highlightsSounding: true), .wrong)
        XCTAssertEqual(NotationHighlightResolver.tint(state: .expected, isSounding: false, highlightsSounding: false), .hand)
        XCTAssertEqual(NotationHighlightResolver.tint(state: .upcoming, isSounding: false, highlightsSounding: true), .handFaded)
        XCTAssertEqual(NotationHighlightResolver.tint(state: nil, isSounding: true, highlightsSounding: true), .hand)
        XCTAssertEqual(NotationHighlightResolver.tint(state: nil, isSounding: true, highlightsSounding: false), .ink)
        XCTAssertEqual(NotationHighlightResolver.tint(state: nil, isSounding: false, highlightsSounding: true), .ink)
        XCTAssertEqual(NotationHighlightResolver.opacity(hand: .left, practiced: .right, dims: true), NotationHighlightResolver.dimmedOpacity)
        XCTAssertEqual(NotationHighlightResolver.opacity(hand: .right, practiced: .right, dims: true), 1)
        XCTAssertEqual(NotationHighlightResolver.opacity(hand: .left, practiced: .right, dims: false), 1)
    }

    func testSoundingEventsAtCursor() {
        let l = layout(knownScore())
        let cursor = NotationCursorLocation(measureIndex: 0, tickInMeasure: Double(q) + 10, segmentIndex: nil)
        let sounding = NotationHighlightResolver.soundingEvents(layout: l, at: cursor)
        let expected = Set(l.events(inMeasure: 0).filter { !$0.isRest && $0.onset <= q + 10 && q + 10 < $0.onset + $0.duration }.map { $0.id })
        XCTAssertEqual(sounding, expected)
        XCTAssertEqual(sounding.count, 2)  // the first F4 and the bass whole chord
    }

    @MainActor
    func testHighlightModelDrawState() {
        let score = knownScore()
        let l = layout(score)
        let timeline = score.makeTimeline()
        let model = NotationHighlightModel(timeline: timeline, positionTick: 0, practicedHands: .right)
        guard let step = timeline.steps.first, let rh = step.events.first(where: { $0.hand == .right }) else { return XCTFail("no step") }
        model.feedback = FeedbackSnapshot(eventStates: [rh.id: .expected])
        let state = model.drawState(for: l)
        XCTAssertEqual(state.cursor?.measureIndex, 0)
        XCTAssertEqual(state.states[rh.sourceEventID], .expected)
        XCTAssertEqual(state.opacity(for: .left), NotationHighlightResolver.dimmedOpacity)
        XCTAssertNotNil(state.cursorX)
        XCTAssertEqual(state.with(selection: MeasureRange(start: 2, end: 1)).selection, MeasureRange(start: 1, end: 2))
    }

    func testCursorIsContinuousAcrossBarlinesWithinASystem() {
        let l = layout(knownScore())
        XCTAssertEqual(l.systems.count, 1)
        for i in l.measures.indices.dropLast() where l.measures[i].systemIndex == l.measures[i + 1].systemIndex {
            guard let end = l.cursorX(measureIndex: i, tickInMeasure: Double(l.measures[i].length)),
                  let start = l.cursorX(measureIndex: i + 1, tickInMeasure: 0) else { return XCTFail("no cursor") }
            XCTAssertEqual(end, start, accuracy: 1e-9, "jump at barline after measure \(i)")
        }
    }

    func testCursorSweepHasNoJumpsInScrollMode() {
        let l = layout(knownScore())
        guard let last = l.measures.last else { return XCTFail("no measures") }
        let total = Double(last.notatedStart + last.length)
        var previous: CGFloat?
        var largestStep: CGFloat = 0
        for t in stride(from: 0.0, through: total, by: 30) {
            guard let location = NotationHighlightResolver.cursorLocation(positionTick: t, timeline: nil, layout: l),
                  let x = l.cursorX(measureIndex: location.measureIndex, tickInMeasure: location.tickInMeasure) else { return XCTFail("no cursor") }
            if let previous {
                XCTAssertGreaterThanOrEqual(x, previous - 1e-9)
                largestStep = max(largestStep, x - previous)
            }
            previous = x
        }
        // 30 ticks is a 1/32 of a quarter; even the densest column spacing moves far less than a staff space per step.
        XCTAssertLessThan(largestStep, 1)
    }

    func testCursorGlidesToContentEndAtSystemEnd() {
        let l = layout(knownScore(), mode: .page(width: 400))
        XCTAssertGreaterThan(l.systems.count, 1)
        for system in l.systems {
            guard let i = system.measureIndices.last else { continue }
            let m = l.measures[i]
            let end = l.cursorX(measureIndex: i, tickInMeasure: Double(m.length)) ?? 0
            let lastColumn = l.cursorX(measureIndex: i, tickInMeasure: Double(m.columns.last?.tick ?? 0)) ?? 0
            XCTAssertEqual(end, max(lastColumn, m.contentEndX), accuracy: 1e-9)
            XCTAssertLessThan(end, m.frame.maxX)
        }
    }

    func testScrollJumpDetection() {
        let pulse = TimeSignature.common.pulseTicks
        // Normal forward motion (one 60 Hz frame at 120 bpm) and crossing into the next measure follow directly.
        XCTAssertFalse(NotationScrollTransition.isJump(fromTick: 1000, toTick: 1032, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse))
        XCTAssertFalse(NotationScrollTransition.isJump(fromTick: 3830, toTick: 3862, fromMeasure: 0, toMeasure: 1, pulseTicks: pulse))
        // Seek backwards, loop restart, Wait-Mode step forward and a repeat jump are eased.
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 5000, toTick: 1000, fromMeasure: 1, toMeasure: 0, pulseTicks: pulse))
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 1000, toTick: 1480, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse))
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 7660, toTick: 7690, fromMeasure: 1, toMeasure: 0, pulseTicks: pulse))
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 0, toTick: .nan, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse))
        // Short pulses never make ordinary frames count as jumps.
        XCTAssertFalse(NotationScrollTransition.isJump(fromTick: 0, toTick: 100, fromMeasure: 0, toMeasure: 0, pulseTicks: Ticks.perQuarter / 4))
    }

    func testStreamedLargeStepsAreMotionNotJumps() {
        let pulse = TimeSignature.common.pulseTicks
        // 130 ticks in one update is a jump when isolated (seek, Wait-Mode step after waiting) ...
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 1000, toTick: 1130, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse,
                                                      offsetChange: 6.5, viewportWidth: 1000, sinceLastUpdate: nil))
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 1000, toTick: 1130, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse,
                                                      offsetChange: 6.5, viewportWidth: 1000, sinceLastUpdate: 2))
        // ... but motion when it is one frame of a stream (fast tempo, compressed rests, dropped frames).
        XCTAssertFalse(NotationScrollTransition.isJump(fromTick: 1000, toTick: 1130, fromMeasure: 0, toMeasure: 0, pulseTicks: pulse,
                                                       offsetChange: 6.5, viewportWidth: 1000, sinceLastUpdate: 1.0 / 60))
        // A seek during playback that moves the score by more than a quarter of the viewport is still eased.
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 1000, toTick: 9000, fromMeasure: 0, toMeasure: 2, pulseTicks: pulse,
                                                      offsetChange: 400, viewportWidth: 1000, sinceLastUpdate: 1.0 / 60))
        // Backward moves and repeat jumps stay jumps inside a stream.
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 5000, toTick: 1000, fromMeasure: 1, toMeasure: 0, pulseTicks: pulse,
                                                      offsetChange: -10, viewportWidth: 1000, sinceLastUpdate: 1.0 / 60))
        XCTAssertTrue(NotationScrollTransition.isJump(fromTick: 7660, toTick: 7690, fromMeasure: 1, toMeasure: 0, pulseTicks: pulse,
                                                      offsetChange: 1, viewportWidth: 1000, sinceLastUpdate: 1.0 / 60))
    }

    /// Feeds `frames` updates at 60 Hz, each advancing `ticksPerFrame` ticks and `pointsPerTick` points, through the
    /// same decision the scroll stage makes, and returns (largest |displayed - target|, final |displayed - target|).
    private func simulateScroll(frames: Int, ticksPerFrame: Double, pointsPerTick: CGFloat, viewport: CGFloat) -> (maxLag: CGFloat, finalLag: CGFloat) {
        let measureTicks = Double(TimeSignature.common.measureTicks)
        var transition = NotationScrollTransition()
        var lastUpdate: TimeInterval?
        var maxLag: CGFloat = 0
        var finalLag: CGFloat = 0
        func sample(_ k: Int) -> NotationScrollSample {
            let tick = 1000 + ticksPerFrame * Double(k)
            return NotationScrollSample(tick: tick, measureIndex: Int(tick / measureTicks), offset: CGFloat(tick - 1000) * pointsPerTick)
        }
        for k in 1...frames {
            let t = 100 + TimeInterval(k) / 60
            let old = sample(k - 1), new = sample(k)
            let since = lastUpdate.map { t - $0 }
            lastUpdate = t
            if let next = transition.next(from: old, to: new, displayedOld: transition.offset(target: old.offset, at: t), viewportWidth: viewport,
                                          pulseTicks: TimeSignature.common.pulseTicks, sinceLastUpdate: since, at: t) {
                transition = next
            }
            let lag = abs(transition.offset(target: new.offset, at: t) - new.offset)
            maxLag = max(maxLag, lag)
            finalLag = lag
        }
        return (maxLag, finalLag)
    }

    func testScrollTracksFastContinuousUpdates() {
        // 130 ticks per 60 Hz frame (each one over the isolated-jump threshold): the target reaches 390 pt after 60 frames.
        let result = simulateScroll(frames: 60, ticksPerFrame: 130, pointsPerTick: 0.05, viewport: 1000)
        let velocity: CGFloat = 130 * 0.05 * 60   // points per second
        XCTAssertLessThanOrEqual(result.maxLag, velocity * 0.35)
        XCTAssertEqual(result.finalLag, 0, accuracy: 1e-9)
    }

    func testScrollKeepsMovingThroughAStreamOfLargeJumps() {
        // Every frame moves 300 pt of a 1000 pt viewport, so each one is a jump; the offset must still keep up.
        let result = simulateScroll(frames: 60, ticksPerFrame: 3000, pointsPerTick: 0.1, viewport: 1000)
        let velocity: CGFloat = 300 * 60
        XCTAssertLessThanOrEqual(result.maxLag, velocity * 0.35)
    }

    func testActiveTransitionIsNotRestartedByOrdinaryJumps() {
        let pulse = TimeSignature.common.pulseTicks
        let running = NotationScrollTransition.starting(from: 0, at: 10)
        let old = NotationScrollSample(tick: 1000, measureIndex: 0, offset: 100)
        let small = NotationScrollSample(tick: 1300, measureIndex: 0, offset: 115)
        let large = NotationScrollSample(tick: 9000, measureIndex: 2, offset: 500)
        // Isolated jump while the ease runs: keep the running transition (it follows the live target).
        XCTAssertNil(running.next(from: old, to: small, displayedOld: 20, viewportWidth: 1000, pulseTicks: pulse, sinceLastUpdate: nil, at: 10.05))
        // A large jump restarts it only after half the duration.
        XCTAssertNil(running.next(from: old, to: large, displayedOld: 20, viewportWidth: 1000, pulseTicks: pulse, sinceLastUpdate: nil, at: 10.1))
        let restarted = running.next(from: old, to: large, displayedOld: 80, viewportWidth: 1000, pulseTicks: pulse, sinceLastUpdate: nil, at: 10.2)
        XCTAssertEqual(restarted?.from, 80)
        XCTAssertEqual(restarted?.startTime, 10.2)
        // A finished transition starts a new one for an isolated jump; layout-only changes never do.
        let idle = NotationScrollTransition()
        XCTAssertNotNil(idle.next(from: old, to: small, displayedOld: 100, viewportWidth: 1000, pulseTicks: pulse, sinceLastUpdate: nil, at: 20))
        XCTAssertNil(idle.next(from: old, to: NotationScrollSample(tick: 1000, measureIndex: 0, offset: 300), displayedOld: 100,
                               viewportWidth: 1000, pulseTicks: pulse, sinceLastUpdate: nil, at: 20))
    }

    @MainActor
    func testScrollClockReportsIntervals() {
        let clock = NotationScrollClock()
        XCTAssertNil(clock.tick(at: 5))
        XCTAssertEqual(clock.tick(at: 5.25) ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(clock.lastUpdate, 5.25)
    }

    func testOutOfRangeFingeringIsSkippedWithoutCrashing() {
        var six = note("E4")
        six.fingering = 6
        var negative = note("G4")
        negative.fingering = -1
        var zero = note("B4")
        zero.fingering = 0
        let measure = Measure(number: 1, events: [event(0, 4 * q, [six, negative, zero], .right),
                                                  event(0, 4 * q, [note("C3", finger: 5)], .left)])
        let score = Score(metadata: ScoreMetadata(title: "Fingers"), initialTime: .common, initialKey: KeySignature(fifths: 0), measures: [measure])
        let l = layout(score)
        XCTAssertEqual(l.glyphs(role: .fingering).count, 1)   // only the valid left-hand 5
        XCTAssertTrue(l.events.flatMap { $0.noteheads }.filter { $0.midi != 48 }.allSatisfy { $0.fingering == nil })
        XCTAssertFalse(NotationEngraver.isDrawableFinger(6))
        XCTAssertFalse(NotationEngraver.isDrawableFinger(0))
        XCTAssertTrue(NotationEngraver.isDrawableFinger(1))
        XCTAssertFalse(NotationEngraver.isDrawableFinger(nil))
    }

    func testScrollTransitionEasing() {
        XCTAssertEqual(NotationScrollTransition.ease(0), 0)
        XCTAssertEqual(NotationScrollTransition.ease(1), 1)
        XCTAssertEqual(NotationScrollTransition.ease(0.5), 0.5, accuracy: 1e-12)
        let t = NotationScrollTransition.starting(from: 100, at: 10, duration: 0.5)
        XCTAssertEqual(t.offset(target: 200, at: 10), 100)
        XCTAssertEqual(t.offset(target: 200, at: 10.25), 150, accuracy: 1e-9)
        XCTAssertEqual(t.offset(target: 200, at: 11), 200)
        XCTAssertTrue(t.isActive(at: 10.2))
        XCTAssertFalse(t.isActive(at: 10.6))
        XCTAssertEqual(NotationScrollTransition().offset(target: 42, at: 0), 42)
    }

    func testSelectionTracker() {
        var tracker = NotationSelectionTracker()
        tracker.update(anchorMeasure: 5, currentMeasure: 5)
        tracker.update(anchorMeasure: 5, currentMeasure: 2)
        XCTAssertEqual(tracker.range, MeasureRange(start: 2, end: 5))
        XCTAssertEqual(tracker.finish(), MeasureRange(start: 2, end: 5))
        XCTAssertNil(tracker.range)
        XCTAssertNil(tracker.anchor)
    }

    // MARK: Edge cases

    func testEmptyScoreAndEmptyMeasure() {
        let empty = layout(Score(metadata: ScoreMetadata(title: "Empty"), measures: []))
        XCTAssertTrue(empty.measures.isEmpty)
        XCTAssertEqual(empty.size, .zero)
        XCTAssertNil(NotationHighlightResolver.cursorLocation(positionTick: 100, timeline: nil, layout: empty))
        let blank = layout(Score(metadata: ScoreMetadata(title: "Blank"), measures: [Measure(number: 1, events: [])]))
        XCTAssertEqual(blank.glyphs(role: .measureRest).count, 2)
        XCTAssertGreaterThan(blank.measures[0].frame.width, 0)
    }

    func testRepeatsVoltasAndPickup() {
        let e8 = q / 2
        let six8 = TimeSignature(beats: 6, beatType: 8)
        let pickup = Measure(number: 0, timeSignature: six8, isPickup: true, events: [event(0, e8, [note("D4")], .right), event(0, e8, [], .left)])
        let a = Measure(number: 1, events: (0..<6).map { event($0 * e8, e8, [note("G4")], .right) }, barline: Barline(repeatForward: true))
        let b = Measure(number: 2, events: [event(0, 6 * e8, [note("A4")], .right, notated: NoteDuration(value: .half, dots: 1))], barline: Barline(repeatBackwardTimes: 2, endings: [1]))
        let c = Measure(number: 3, events: [event(0, 6 * e8, [note("B4")], .right, notated: NoteDuration(value: .half, dots: 1))], barline: Barline(endings: [2], isFinal: true))
        let l = layout(Score(metadata: ScoreMetadata(title: "Repeats"), initialTime: six8, measures: [pickup, a, b, c]))
        XCTAssertEqual(l.glyphs(role: .repeatDot).count, 8)                     // forward + backward, 2 staves × 2 dots
        XCTAssertEqual(l.texts.filter { $0.role == .volta }.map { $0.string }, ["1.", "2."])
        XCTAssertEqual(l.beamGroups.map { $0.eventIDs.count }, [3, 3])          // 6/8 groups in dotted quarters
        XCTAssertEqual(l.glyphs(role: .flag).count, 1)                          // the pickup 8th
        XCTAssertEqual(l.glyphs(role: .rest).count, 1)                          // the pickup rest is an 8th rest
        XCTAssertEqual(l.glyphs(role: .augmentationDot).count, 2)
        // Volta labels sit above measure numbers.
        for volta in l.texts where volta.role == .volta {
            for number in l.texts where number.role == .measureNumber && number.measureIndex == volta.measureIndex {
                XCTAssertLessThanOrEqual(volta.origin.y, number.origin.y - number.fontSize)
            }
        }
    }

    func testFortyMeasureLayoutIsDeterministicAndFast() {
        let base = knownScore()
        var measures: [Measure] = []
        for i in 0..<40 {
            var m = base.measures[i % 4]
            m.id = UUID()
            m.number = i + 1
            m.keySignature = nil
            m.barline = i == 39 ? Barline(isFinal: true) : .plain
            m.events = m.events.map { var e = $0; e.id = UUID(); return e }
            measures.append(m)
        }
        let score = Score(metadata: ScoreMetadata(title: "Forty"), initialKey: KeySignature(fifths: 1), measures: measures)
        let start = Date()
        let first = layout(score)
        let elapsed = Date().timeIntervalSince(start)
        let second = layout(score)
        XCTAssertEqual(first.glyphs, second.glyphs)
        XCTAssertEqual(first.measures, second.measures)
        XCTAssertEqual(first.measures.count, 40)
        XCTAssertLessThan(elapsed, 0.5)
    }
}
