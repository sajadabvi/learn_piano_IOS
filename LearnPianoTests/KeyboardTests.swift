import CoreGraphics
import XCTest
@testable import LearnPiano

/// Unit tests for the pure logic of the Keyboard module: key geometry, hit testing, range fitting,
/// falling-note lane math, state transitions and the multi-touch tracker.
final class KeyboardTests: XCTestCase {

    // Seven white keys (C4…B4) across 700 pt → a white key is exactly 100 pt wide.
    private let octaveGeometry = KeyboardGeometry(size: CGSize(width: 700, height: 200), range: 60...71)

    // MARK: - White-key arithmetic

    func testWhiteKeyIndexOfMiddleCAndNeighbors() {
        XCTAssertEqual(KeyboardGeometry.whiteKeyIndex(midi: 60), 35)   // C4
        XCTAssertEqual(KeyboardGeometry.whiteKeyIndex(midi: 61), 35)   // C#4 sits on C4's white index
        XCTAssertEqual(KeyboardGeometry.whiteKeyIndex(midi: 62), 36)   // D4
        XCTAssertEqual(KeyboardGeometry.whiteKeyIndex(midi: 21), 12)   // A0
        XCTAssertEqual(KeyboardGeometry.whiteKeyIndex(midi: 108), 63)  // C8
        XCTAssertEqual(KeyboardGeometry.midi(whiteKeyIndex: 35), 60)
        XCTAssertEqual(KeyboardGeometry.midi(whiteKeyIndex: 12), 21)
    }

    func testWhiteKeyIndexRoundTripsForEveryWhiteKeyOnThePiano() {
        for midi in Pitch.pianoRange where !Pitch.isBlackKey(midi: midi) {
            XCTAssertEqual(KeyboardGeometry.midi(whiteKeyIndex: KeyboardGeometry.whiteKeyIndex(midi: midi)), midi)
        }
    }

    // MARK: - Key frames

    func testWhiteKeyFramesForKnownWidth() {
        let c4 = octaveGeometry.frame(forKey: 60)
        let d4 = octaveGeometry.frame(forKey: 62)
        let b4 = octaveGeometry.frame(forKey: 71)
        XCTAssertEqual(c4.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(c4.width, 100, accuracy: 1e-9)
        XCTAssertEqual(c4.height, 200, accuracy: 1e-9)
        XCTAssertEqual(d4.minX, 100, accuracy: 1e-9)
        XCTAssertEqual(b4.minX, 600, accuracy: 1e-9)
        XCTAssertEqual(b4.maxX, 700, accuracy: 1e-9)
    }

    func testBlackKeyGeometryFollowsRealLayout() {
        let w: CGFloat = 100
        let b = KeyboardGeometry.blackKeyWidthRatio * w            // 58
        let cSharp = octaveGeometry.frame(forKey: 61)
        let dSharp = octaveGeometry.frame(forKey: 63)
        let fSharp = octaveGeometry.frame(forKey: 66)
        let gSharp = octaveGeometry.frame(forKey: 68)
        let aSharp = octaveGeometry.frame(forKey: 70)

        // C–E group: equal rear widths of (3w − 2b)/3.
        let rearCE = (3 * w - 2 * b) / 3
        XCTAssertEqual(cSharp.minX, rearCE, accuracy: 1e-6)                      // 61.33
        XCTAssertEqual(dSharp.minX, 2 * rearCE + b, accuracy: 1e-6)              // 180.67
        // F–B group: equal rear widths of (4w − 3b)/4.
        let rearFB = (4 * w - 3 * b) / 4
        XCTAssertEqual(fSharp.minX, 3 * w + rearFB, accuracy: 1e-6)
        XCTAssertEqual(gSharp.midX, 5 * w, accuracy: 1e-6)                        // G# is centered on the G/A boundary
        XCTAssertEqual(aSharp.minX, 3 * w + 3 * rearFB + 2 * b, accuracy: 1e-6)

        for f in [cSharp, dSharp, fSharp, gSharp, aSharp] {
            XCTAssertEqual(f.width, b, accuracy: 1e-9)
            XCTAssertEqual(f.height, 200 * KeyboardGeometry.blackKeyHeightRatio, accuracy: 1e-9)  // 120
            XCTAssertEqual(f.minY, 0)
        }
        // C# leans left of the C/D boundary, D# leans right of the D/E boundary.
        XCTAssertLessThan(cSharp.midX, w)
        XCTAssertGreaterThan(dSharp.midX, 2 * w)
        // F# leans further left than C# does, A# further right than D# does.
        XCTAssertLessThan(fSharp.midX - 4 * w, cSharp.midX - w)
        XCTAssertGreaterThan(aSharp.midX - 6 * w, dSharp.midX - 2 * w)
    }

    // MARK: - Hit testing

    func testHitTestingPrefersBlackKeysInTheUpperRegion() {
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 70, y: 50)), 61)    // inside C#4
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 70, y: 150)), 60)   // below the black keys → C4
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 150, y: 50)), 62)   // between C# and D# → D4
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 185, y: 50)), 63)   // inside D#4 (starts at 180.67)
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 250, y: 50)), 64)   // E4 has no black key to its right
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 500, y: 10)), 68)   // G#4 centered on x = 500
        XCTAssertEqual(octaveGeometry.key(at: CGPoint(x: 699, y: 199)), 71)  // B4
    }

    func testHitTestingOutsideReturnsNil() {
        XCTAssertNil(octaveGeometry.key(at: CGPoint(x: -1, y: 50)))
        XCTAssertNil(octaveGeometry.key(at: CGPoint(x: 701, y: 50)))
        XCTAssertNil(octaveGeometry.key(at: CGPoint(x: 10, y: 201)))
        // Beyond C8 there are no keys even though the viewport might extend there.
        let top = KeyboardGeometry(size: CGSize(width: 400, height: 100), viewport: KeyboardViewport(firstWhiteIndex: 62, whiteKeyCount: 4))
        XCTAssertEqual(top.key(at: CGPoint(x: 150, y: 90)), 108)
        XCTAssertNil(top.key(at: CGPoint(x: 250, y: 90)))
    }

    func testVisibleKeysCoverExactlyTheRange() {
        XCTAssertEqual(octaveGeometry.visibleKeys, Array(60...71))
        XCTAssertEqual(octaveGeometry.visibleWhiteKeys, [60, 62, 64, 65, 67, 69, 71])
        XCTAssertEqual(octaveGeometry.visibleBlackKeys, [61, 63, 66, 68, 70])
        XCTAssertTrue(octaveGeometry.isVisible(60))
        XCTAssertFalse(octaveGeometry.isVisible(59))
        XCTAssertFalse(octaveGeometry.isVisible(72))
    }

    // MARK: - Viewport

    func testViewportFromRangeAndInterpolation() {
        let v = KeyboardViewport(range: 36...96)
        XCTAssertEqual(v.firstWhiteIndex, 21)
        XCTAssertEqual(v.whiteKeyCount, 36)
        XCTAssertEqual(v.range, 36...96)

        let narrow = KeyboardViewport(range: 60...72)
        let mid = KeyboardViewport.interpolate(v, narrow, fraction: 0.5)
        XCTAssertEqual(mid.firstWhiteIndex, (21 + 35) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.whiteKeyCount, (36 + 8) / 2, accuracy: 1e-9)
        XCTAssertEqual(KeyboardViewport.interpolate(v, narrow, fraction: 1.5), narrow)
    }

    // MARK: - Range fitting

    func testSnappingExtendsBlackKeyEndsToWhiteKeys() {
        XCTAssertEqual(KeyboardRangeFitter.snappedToWhiteKeys(61...70), 60...71)
        XCTAssertEqual(KeyboardRangeFitter.snappedToWhiteKeys(60...71), 60...71)
        XCTAssertEqual(KeyboardRangeFitter.snappedToWhiteKeys(0...200), 21...108)
        XCTAssertEqual(KeyboardRangeFitter.whiteKeyCount(in: KeyboardRangeFitter.fullRange), 52)
        XCTAssertEqual(KeyboardRangeFitter.whiteKeyCount(in: KeyboardRangeFitter.defaultRange), 36)
    }

    func testFitKeepsDefaultWhenScoreFitsInside() {
        XCTAssertEqual(KeyboardRangeFitter.fit(scoreRange: 50...70), 36...96)
        XCTAssertEqual(KeyboardRangeFitter.fit(scoreRange: nil), 36...96)
    }

    func testFitExpandsDefaultToIncludeScoreWithPadding() {
        // 30 = F#1 → snapped to F1 (29) → one white key of padding → E1 (28).
        // 100 = E7 → one white key of padding → F7 (101).
        XCTAssertEqual(KeyboardRangeFitter.fit(scoreRange: 30...100), 28...101)
        // Never past the ends of the piano.
        XCTAssertEqual(KeyboardRangeFitter.fit(scoreRange: 21...108), 21...108)
    }

    func testTightFitWidensToMinimumWhiteKeysAroundTheScore() {
        let r = KeyboardRangeFitter.tightFit(scoreRange: 60...64, paddingWhiteKeys: 0)
        XCTAssertEqual(KeyboardRangeFitter.whiteKeyCount(in: r), KeyboardRangeFitter.minimumWhiteKeys)
        XCTAssertTrue(r.contains(60) && r.contains(64))
        XCTAssertEqual(r, 50...74)

        let wide = KeyboardRangeFitter.tightFit(scoreRange: 36...96, paddingWhiteKeys: 1)
        XCTAssertEqual(wide, 35...98)
    }

    func testTightFitForScoreUsesTheSelectedHands() {
        let score = ScoreBuilder.make(title: "t",
                                      right: [[(pitches: ["C5", "E5"], ticks: 960)]],
                                      left: [[(pitches: ["C2"], ticks: 960)]])
        let rightOnly = KeyboardRangeFitter.tightFit(for: score, hands: .right, paddingWhiteKeys: 0)
        XCTAssertFalse(rightOnly.contains(36))
        XCTAssertTrue(rightOnly.contains(72) && rightOnly.contains(76))
        let both = KeyboardRangeFitter.tightFit(for: score, hands: .both, paddingWhiteKeys: 0)
        XCTAssertTrue(both.contains(36) && both.contains(76))
    }

    func testScrollAndZoomKeepTheWindowOnThePiano() {
        XCTAssertEqual(KeyboardRangeFitter.scrolled(60...71, byWhiteKeys: 7), 72...83)
        XCTAssertEqual(KeyboardRangeFitter.scrolled(21...33, byWhiteKeys: -5), 21...33)
        let zoomed = KeyboardRangeFitter.zoomed(36...96, toWhiteKeyCount: 1000)
        XCTAssertEqual(zoomed, 21...108)
        XCTAssertEqual(KeyboardRangeFitter.whiteKeyCount(in: KeyboardRangeFitter.zoomed(36...96, toWhiteKeyCount: 2)), KeyboardRangeFitter.minimumWhiteKeys)
    }

    // MARK: - Lanes

    private func twoNoteTimeline() -> PlaybackTimeline {
        // C4 quarter then E4 quarter, right hand.
        ScoreBuilder.make(title: "two", right: [[(pitches: ["C4"], ticks: 960), (pitches: ["E4"], ticks: 960)]]).makeTimeline()
    }

    func testLaneRectsAtStartTouchTheKeyboard() {
        let rects = KeyboardLaneLayout.rects(timeline: twoNoteTimeline(), currentTick: 0, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry)
        XCTAssertEqual(rects.count, 2)
        let c4 = rects[0], e4 = rects[1]
        XCTAssertEqual(c4.midi, 60)
        XCTAssertEqual(c4.hand, .right)
        XCTAssertTrue(c4.isAttack)
        XCTAssertTrue(c4.isSounding)
        XCTAssertEqual(c4.rect.maxY, 300, accuracy: 1e-9)      // touches the keys
        XCTAssertEqual(c4.rect.minY, 204, accuracy: 1e-9)      // 960 ticks × 0.1
        XCTAssertEqual(c4.rect.minX, 1, accuracy: 1e-9)        // 1 pt lane inset on a 100 pt key
        XCTAssertEqual(c4.rect.width, 98, accuracy: 1e-9)

        XCTAssertEqual(e4.midi, 64)
        XCTAssertFalse(e4.isSounding)
        XCTAssertEqual(e4.rect.maxY, 204, accuracy: 1e-9)
        XCTAssertEqual(e4.rect.minY, 108, accuracy: 1e-9)
        XCTAssertEqual(e4.rect.minX, 201, accuracy: 1e-9)
    }

    func testLaneRectsDescendAsTheTickAdvancesAndClipAtTheKeys() {
        let rects = KeyboardLaneLayout.rects(timeline: twoNoteTimeline(), currentTick: 480, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].rect.maxY, 300, accuracy: 1e-9)   // half-played note stays clipped at the hit line
        XCTAssertEqual(rects[0].rect.minY, 252, accuracy: 1e-9)   // 480 ticks remain
        XCTAssertEqual(rects[1].rect.maxY, 252, accuracy: 1e-9)
        XCTAssertEqual(rects[1].rect.minY, 156, accuracy: 1e-9)
    }

    func testLaneLookaheadAndPastNotesAreExcluded() {
        let timeline = twoNoteTimeline()
        let onlyFirst = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 0, lookaheadTicks: 500,
                                                 pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry)
        XCTAssertEqual(onlyFirst.map { $0.midi }, [60])
        let finished = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 2000, lookaheadTicks: 3840,
                                                pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry)
        XCTAssertTrue(finished.isEmpty)
        let leftOnly = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 0, lookaheadTicks: 3840,
                                                pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry, hands: .left)
        XCTAssertTrue(leftOnly.isEmpty)
    }

    func testLaneGapAndMinimumHeight() {
        let rects = KeyboardLaneLayout.rects(timeline: twoNoteTimeline(), currentTick: 0, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.001, laneHeight: 300, geometry: octaveGeometry, gap: 2, minimumHeight: 3)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].rect.height, 3, accuracy: 1e-9)
        XCTAssertEqual(rects[0].rect.maxY, 300, accuracy: 1e-9)   // the current note still touches the keys
    }

    func testLaneRectsForTwoHandsUseEachHandAndBlackKeyLanes() {
        // Right hand: C#4 half note. Left hand: quarter rest, then C3 quarter (outside the C4–B4 window).
        let score = ScoreBuilder.make(title: "hands",
                                      right: [[(pitches: ["C#4"], ticks: 1920)]],
                                      left: [[(pitches: [], ticks: 960), (pitches: ["C3"], ticks: 960)]])
        let wide = KeyboardGeometry(size: CGSize(width: 1400, height: 200), range: 48...71)  // C3…B4, 14 white keys of 100 pt
        let rects = KeyboardLaneLayout.rects(timeline: score.makeTimeline(), currentTick: 0, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.1, laneHeight: 300, geometry: wide)
        XCTAssertEqual(rects.count, 2)                          // the rest produces nothing
        let right = rects.first { $0.hand == .right }
        let left = rects.first { $0.hand == .left }
        XCTAssertEqual(right?.midi, 61)
        XCTAssertEqual(right?.rect.maxY ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(right?.rect.minY ?? 0, 108, accuracy: 1e-9)
        // The lane sits over the black key, inset by 1 pt on each side.
        let cSharp = wide.frame(forKey: 61)
        XCTAssertEqual(right?.rect.minX ?? 0, cSharp.minX + 1, accuracy: 1e-9)
        XCTAssertEqual(right?.rect.width ?? 0, cSharp.width - 2, accuracy: 1e-9)
        XCTAssertEqual(left?.midi, 48)
        XCTAssertEqual(left?.isSounding, false)
        XCTAssertEqual(left?.rect.maxY ?? 0, 204, accuracy: 1e-9)

        // Pitches outside the visible window get no lane.
        let narrow = KeyboardLaneLayout.rects(timeline: score.makeTimeline(), currentTick: 0, lookaheadTicks: 3840,
                                              pixelsPerTick: 0.1, laneHeight: 300, geometry: octaveGeometry)
        XCTAssertEqual(narrow.map { $0.midi }, [61])
    }

    /// One measure of 4/4, right hand: C4 half tied to C4 quarter, then C4 struck again (quarter).
    private func tieThenRestrikeTimeline() -> PlaybackTimeline {
        let c4 = Pitch(midi: 60)
        let measure = Measure(number: 1, events: [
            MeasureEvent(onset: 0, duration: 1920, notes: [ChordNote(pitch: c4, tieStart: true)], hand: .right),
            MeasureEvent(onset: 1920, duration: 960, notes: [ChordNote(pitch: c4, tieStop: true)], hand: .right),
            MeasureEvent(onset: 2880, duration: 960, notes: [ChordNote(pitch: c4)], hand: .right)
        ], barline: Barline(isFinal: true))
        return Score(metadata: ScoreMetadata(title: "tie", source: .exercise), measures: [measure]).makeTimeline()
    }

    func testTiedNotesJoinWithoutGapAndARestrikeIsSeparated() {
        let rects = KeyboardLaneLayout.rects(timeline: tieThenRestrikeTimeline(), currentTick: 0, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.1, laneHeight: 400, geometry: octaveGeometry, gap: 2)
        XCTAssertEqual(rects.count, 3)
        guard rects.count == 3 else { return }
        let (half, continuation, restrike) = (rects[0], rects[1], rects[2])

        XCTAssertTrue(half.isAttack)
        XCTAssertTrue(half.tiedForward)
        XCTAssertEqual(half.rect.maxY, 400, accuracy: 1e-9)
        XCTAssertEqual(half.rect.minY, 208, accuracy: 1e-9)            // no gap at the tie

        XCTAssertFalse(continuation.isAttack)
        XCTAssertFalse(continuation.tiedForward)
        XCTAssertEqual(continuation.rect.maxY, half.rect.minY, accuracy: 1e-9)   // joined to the tied note
        XCTAssertEqual(continuation.rect.minY, 112 + 2, accuracy: 1e-9) // gap at the end of the chain

        XCTAssertTrue(restrike.isAttack)
        XCTAssertFalse(restrike.tiedForward)
        XCTAssertEqual(restrike.rect.maxY, 112, accuracy: 1e-9)
        XCTAssertEqual(continuation.rect.minY - restrike.rect.maxY, 2, accuracy: 1e-9)  // visible break before the re-strike
        XCTAssertEqual(restrike.rect.minY, 16 + 2, accuracy: 1e-9)
    }

    func testLaneOutlineOmitsTieJoins() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(KeyboardLaneRenderer.outline(of: rect, radius: 3, closedTop: true, closedBottom: true).boundingRect, rect)
        // A tie continuation (open bottom) and a tied-forward attack (open top) still span the full rect.
        XCTAssertEqual(KeyboardLaneRenderer.outline(of: rect, radius: 3, closedTop: true, closedBottom: false).boundingRect, rect)
        XCTAssertEqual(KeyboardLaneRenderer.outline(of: rect, radius: 3, closedTop: false, closedBottom: true).boundingRect, rect)
    }

    /// Three whole-note measures, right hand: C4, D4, E4.
    private func threeMeasureTimeline() -> PlaybackTimeline {
        ScoreBuilder.make(title: "three", right: [[(pitches: ["C4"], ticks: 3840)],
                                                  [(pitches: ["D4"], ticks: 3840)],
                                                  [(pitches: ["E4"], ticks: 3840)]]).makeTimeline()
    }

    func testTwoMeasureLoopDropsNotesPastTheEndAndPreviewsTheWrap() {
        let timeline = threeMeasureTimeline()
        let loop = timeline.tickRange(of: MeasureRange(start: 0, end: 1))
        XCTAssertEqual(loop, 0..<7680)

        // Without a loop, E4 (measure 3) is the next note.
        let linear = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 6000, lookaheadTicks: 3840,
                                              pixelsPerTick: 0.05, laneHeight: 384, geometry: octaveGeometry)
        XCTAssertEqual(linear.map { $0.midi }, [62, 64])

        let rects = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 6000, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.05, laneHeight: 384, geometry: octaveGeometry, loopTicks: loop)
        XCTAssertEqual(rects.map { $0.midi }, [62, 60])               // E4 never comes; C4 does, after the wrap
        guard rects.count == 2 else { return }
        let d4 = rects[0], wrapped = rects[1]
        XCTAssertEqual(d4.loopPass, 0)
        XCTAssertTrue(d4.isSounding)
        XCTAssertEqual(d4.rect.maxY, 384, accuracy: 1e-9)
        XCTAssertEqual(d4.rect.minY, 300, accuracy: 1e-9)             // loop end: 1680 ticks × 0.05 above the keys
        XCTAssertEqual(wrapped.loopPass, 1)
        XCTAssertFalse(wrapped.isSounding)
        XCTAssertEqual(wrapped.rect.maxY, 300, accuracy: 1e-9)        // starts exactly at the loop end
        XCTAssertEqual(wrapped.rect.minY, 108, accuracy: 1e-9)        // (7680 + 3840 − 6000) × 0.05 = 276 above
    }

    func testShortLoopRepeatsAsOftenAsTheLookaheadReaches() {
        let timeline = threeMeasureTimeline()
        let rects = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 3000, lookaheadTicks: 9600,
                                             pixelsPerTick: 0.01, laneHeight: 200, geometry: octaveGeometry, loopTicks: 0..<3840)
        XCTAssertEqual(rects.map { $0.midi }, [60, 60, 60, 60])
        XCTAssertEqual(rects.map { $0.loopPass }, [0, 1, 2, 3])
        guard rects.count == 4 else { return }
        for i in 1..<4 {
            XCTAssertEqual(rects[i].rect.maxY, rects[i - 1].rect.minY, accuracy: 1e-9)  // passes stack seamlessly
        }
        XCTAssertEqual(rects[3].rect.minY, 200 - (15360 - 3000) * 0.01, accuracy: 1e-9)
    }

    func testLoopIsIgnoredOncePlaybackIsPastItsEnd() {
        let timeline = threeMeasureTimeline()
        let rects = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 8000, lookaheadTicks: 3840,
                                             pixelsPerTick: 0.05, laneHeight: 384, geometry: octaveGeometry, loopTicks: 0..<3840)
        XCTAssertEqual(rects.map { $0.midi }, [64])
        XCTAssertEqual(rects.first?.loopPass, 0)
    }

    func testTieAcrossTheLoopEndIsNotJoined() {
        let c4 = Pitch(midi: 60)
        let score = Score(metadata: ScoreMetadata(title: "tie over bar", source: .exercise), measures: [
            Measure(number: 1, events: [MeasureEvent(onset: 0, duration: 3840, notes: [ChordNote(pitch: c4, tieStart: true)], hand: .right)]),
            Measure(number: 2, events: [MeasureEvent(onset: 0, duration: 3840, notes: [ChordNote(pitch: c4, tieStop: true)], hand: .right)],
                    barline: Barline(isFinal: true))
        ])
        let timeline = score.makeTimeline()
        let open = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 0, lookaheadTicks: 3840,
                                            pixelsPerTick: 0.1, laneHeight: 384, geometry: octaveGeometry, gap: 2)
        XCTAssertEqual(open.first?.tiedForward, true)
        XCTAssertEqual(open.first?.rect.minY ?? -1, 0, accuracy: 1e-9)
        // Looping only measure 1: the continuation never sounds, so the note ends with a gap.
        let looped = KeyboardLaneLayout.rects(timeline: timeline, currentTick: 0, lookaheadTicks: 3840,
                                              pixelsPerTick: 0.1, laneHeight: 384, geometry: octaveGeometry,
                                              loopTicks: 0..<3840, gap: 2)
        XCTAssertEqual(looped.count, 1)
        XCTAssertEqual(looped.first?.tiedForward, false)
        XCTAssertEqual(looped.first?.rect.minY ?? -1, 2, accuracy: 1e-9)
    }

    func testPixelsPerTickFitsLookaheadIntoHeight() {
        XCTAssertEqual(KeyboardLaneLayout.pixelsPerTick(fitting: 3840, in: 384), 0.1, accuracy: 1e-9)
        XCTAssertEqual(KeyboardLaneLayout.y(forTick: 960, currentTick: 0, pixelsPerTick: 0.1, laneHeight: 300), 204, accuracy: 1e-9)
    }

    // MARK: - State mapping

    func testSnapshotMappingAttachesHandsFromTheTimeline() {
        let score = ScoreBuilder.make(title: "hands",
                                      right: [[(pitches: ["E4"], ticks: 960)]],
                                      left: [[(pitches: ["C3"], ticks: 960)]])
        let timeline = score.makeTimeline()
        let snapshot = FeedbackSnapshot(keyStates: [64: .expected, 48: .expected, 70: .wrong, 50: .upcoming], currentStepIndex: 0)
        let states = KeyboardKeyStateMapper.states(from: snapshot, timeline: timeline)
        XCTAssertEqual(states[64], .expected(.right))
        XCTAssertEqual(states[48], .expected(.left))
        XCTAssertEqual(states[70], .wrong)
        XCTAssertEqual(states[50], .upcoming(nil))
        let overridden = KeyboardKeyStateMapper.states(from: snapshot, timeline: timeline) { _ in .left }
        XCTAssertEqual(overridden[64], .expected(.left))
    }

    func testMergingHeldKeysNeverOverridesCallerStates() {
        let merged = KeyboardKeyStateMapper.merging([60: .correct], heldByTouch: [60, 62])
        XCTAssertEqual(merged[60], .correct)
        XCTAssertEqual(merged[62], .pressed)
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Transitions

    func testTransitionTrackerBlendsAndFinishes() {
        // Binary-exact times (0.25 s fade, 1.125 = half-way) keep the assertions free of rounding noise.
        var tracker = KeyboardTransitionTracker(states: [60: .expected(.right)], duration: 0.25)
        XCTAssertFalse(tracker.isAnimating(at: 0))
        tracker.update(to: [60: .correct, 62: .pressed], at: 1.0)
        XCTAssertTrue(tracker.isAnimating(at: 1.0))
        let mid = tracker.blend(forKey: 60, at: 1.125)
        XCTAssertEqual(mid.from, .expected(.right))
        XCTAssertEqual(mid.to, .correct)
        XCTAssertEqual(mid.progress, KeyboardEasing.easeOut(0.5), accuracy: 1e-9)
        let newKey = tracker.blend(forKey: 62, at: 1.0)
        XCTAssertNil(newKey.from)
        XCTAssertEqual(newKey.to, .pressed)
        XCTAssertEqual(newKey.progress, 0, accuracy: 1e-9)
        XCTAssertEqual(tracker.progress(forKey: 60, at: 1.25), 1, accuracy: 1e-9)
        XCTAssertFalse(tracker.isAnimating(at: 1.25))
        tracker.prune(at: 1.25)
        XCTAssertTrue(tracker.transitions.isEmpty)
        XCTAssertEqual(tracker.blend(forKey: 99, at: 5).progress, 1)
    }

    func testTransitionTrackerIgnoresUnchangedUpdates() {
        var tracker = KeyboardTransitionTracker(states: [60: .pressed])
        tracker.update(to: [60: .pressed], at: 3)
        XCTAssertTrue(tracker.transitions.isEmpty)
        tracker.update(to: [:], at: 4)
        XCTAssertEqual(tracker.blend(forKey: 60, at: 4).from, .pressed)
        XCTAssertNil(tracker.blend(forKey: 60, at: 4).to)
    }

    func testAnimatedViewportMovesTowardsTarget() {
        var av = KeyboardAnimatedViewport(range: 36...96, duration: 1)
        av.retarget(to: 60...72, at: 10)
        XCTAssertTrue(av.isAnimating(at: 10.5))
        let half = av.viewport(at: 10.5)
        XCTAssertEqual(half.firstWhiteIndex, 28, accuracy: 1e-9)   // ease-in-out is symmetric at the midpoint
        XCTAssertEqual(av.viewport(at: 11).range, 60...72)
        XCTAssertFalse(av.isAnimating(at: 11))
        av.jump(to: 21...33)
        XCTAssertEqual(av.viewport(at: 0).range, 21...33)
    }

    func testRetargetDuringATransitionKeepsMoving() {
        var av = KeyboardAnimatedViewport(range: 36...96)          // 0.35 s
        av.retarget(to: 60...72, at: 0)
        XCTAssertEqual(av.transition?.curve, .easeInOut)           // from rest: ease in and out
        av.retarget(to: 72...84, at: 0.02)
        XCTAssertEqual(av.transition?.curve, .easeOut)             // interrupted: no restart from zero speed
        guard let t = av.transition else { return XCTFail("expected a transition") }
        let origin = t.from.firstWhiteIndex
        let goal = KeyboardViewport(range: 72...84).firstWhiteIndex
        let moved = (av.viewport(at: 0.05).firstWhiteIndex - origin) / (goal - origin)
        XCTAssertGreaterThan(moved, 0.1)
        XCTAssertEqual(av.viewport(at: 0.37).range, 72...84)
        XCTAssertFalse(av.isAnimating(at: 0.37))
    }

    func testInteractiveRetargetFollowsQuickly() {
        var av = KeyboardAnimatedViewport(range: 60...71, duration: 0.35, interactiveDuration: 0.08)
        av.retarget(to: 72...83, at: 0, interactive: true)
        XCTAssertEqual(av.transition?.curve, .easeOut)
        let start = KeyboardViewport(range: 60...71).firstWhiteIndex
        let goal = KeyboardViewport(range: 72...83).firstWhiteIndex
        let half = av.viewport(at: 0.04).firstWhiteIndex
        XCTAssertEqual((half - start) / (goal - start), KeyboardEasing.easeOutCubic(0.5), accuracy: 1e-9)
        XCTAssertEqual(av.viewport(at: 0.08).range, 72...83)
        XCTAssertFalse(av.isAnimating(at: 0.08))
    }

    // MARK: - Touch

    func testVelocityGrowsTowardsTheBottomOfTheKey() {
        let frame = CGRect(x: 0, y: 0, width: 50, height: 200)
        XCTAssertEqual(KeyboardTouchMapper.velocity(y: 0, keyFrame: frame), KeyboardTouchMapper.minimumVelocity, accuracy: 1e-9)
        XCTAssertEqual(KeyboardTouchMapper.velocity(y: 200, keyFrame: frame), 1, accuracy: 1e-9)
        XCTAssertEqual(KeyboardTouchMapper.velocity(y: 100, keyFrame: frame), (KeyboardTouchMapper.minimumVelocity + 1) / 2, accuracy: 1e-9)
        XCTAssertEqual(KeyboardTouchMapper.velocity(y: 500, keyFrame: frame), 1, accuracy: 1e-9)
    }

    func testTouchTrackerGlissandoAndSharedKeys() {
        var tracker = KeyboardTouchTracker<Int>()
        let first = tracker.begin(id: 1, midi: 60, velocity: 0.7, time: 0)
        XCTAssertEqual(first.map { $0.kind }, [.on])
        XCTAssertEqual(first[0].midi, 60)
        XCTAssertEqual(first[0].velocity, 0.7, accuracy: 1e-9)
        XCTAssertEqual(first[0].source, .virtualKeyboard)

        XCTAssertTrue(tracker.move(id: 1, midi: 60, velocity: 0.9, time: 0.1).isEmpty)
        let slide = tracker.move(id: 1, midi: 62, velocity: 0.9, time: 0.2)
        XCTAssertEqual(slide.map { $0.kind }, [.off, .on])
        XCTAssertEqual(slide.map { $0.midi }, [60, 62])
        XCTAssertEqual(tracker.heldKeys, [62])

        // A second finger on the same key: no second note-on, and the key stays held until both lift.
        XCTAssertTrue(tracker.begin(id: 2, midi: 62, velocity: 0.5, time: 0.3).isEmpty)
        XCTAssertTrue(tracker.end(id: 1, time: 0.4).isEmpty)
        XCTAssertEqual(tracker.heldKeys, [62])
        let lift = tracker.end(id: 2, time: 0.5)
        XCTAssertEqual(lift.map { $0.kind }, [.off])
        XCTAssertTrue(tracker.heldKeys.isEmpty)
    }

    func testTouchTrackerOffKeysAndEndAll() {
        var tracker = KeyboardTouchTracker<Int>()
        XCTAssertTrue(tracker.begin(id: 1, midi: nil, velocity: 0.5, time: 0).isEmpty)
        XCTAssertEqual(tracker.move(id: 1, midi: 65, velocity: 0.5, time: 0.1).map { $0.kind }, [.on])
        XCTAssertEqual(tracker.move(id: 1, midi: nil, velocity: 0.5, time: 0.2).map { $0.kind }, [.off])
        XCTAssertTrue(tracker.end(id: 1, time: 0.3).isEmpty)
        XCTAssertTrue(tracker.end(id: 42, time: 0.3).isEmpty)

        _ = tracker.begin(id: 3, midi: 60, velocity: 0.5, time: 1)
        _ = tracker.begin(id: 4, midi: 64, velocity: 0.5, time: 1)
        let all = tracker.endAll(time: 2)
        XCTAssertEqual(all.map { $0.midi }, [60, 64])
        XCTAssertTrue(all.allSatisfy { $0.kind == .off })
        XCTAssertTrue(tracker.heldKeys.isEmpty)
    }

    // MARK: - Labels and states

    func testNoteLabelModes() {
        XCTAssertTrue(KeyboardNoteLabels.cOnly.shows(midi: 60))
        XCTAssertFalse(KeyboardNoteLabels.cOnly.shows(midi: 62))
        XCTAssertTrue(KeyboardNoteLabels.all.shows(midi: 61))
        XCTAssertFalse(KeyboardNoteLabels.none.shows(midi: 60))
    }

    func testDepressedStatesAndRects() {
        XCTAssertTrue(KeyboardKeyState.pressed.isDepressed)
        XCTAssertTrue(KeyboardKeyState.demo(.left).isDepressed)
        XCTAssertFalse(KeyboardKeyState.expected(.right).isDepressed)
        XCTAssertEqual(KeyboardKeyState.upcoming(.left).hand, .left)
        let frame = CGRect(x: 100, y: 0, width: 100, height: 200)
        let pressed = KeyboardRenderer.depressedRect(frame, amount: 1)
        XCTAssertEqual(pressed.width, 96, accuracy: 1e-9)
        XCTAssertEqual(pressed.height, 194, accuracy: 1e-9)
        XCTAssertEqual(pressed.midX, 150, accuracy: 1e-9)
        XCTAssertEqual(pressed.maxY, 200, accuracy: 1e-9)
        XCTAssertEqual(KeyboardRenderer.depressedRect(frame, amount: 0), frame)
    }
}
