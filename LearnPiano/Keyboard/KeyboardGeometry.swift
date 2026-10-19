import CoreGraphics
import Foundation

// MARK: - Viewport

/// The horizontal window of the 88-key piano that a keyboard surface shows.
///
/// The window is expressed in *white-key units* so that zoom and scroll can be animated smoothly:
/// `firstWhiteIndex` is the absolute white-key index (C-1 = 0, C4 = 35) at the left edge and
/// `whiteKeyCount` is how many white keys span the full width. Both are fractional while a
/// zoom/scroll transition is in flight; a viewport built from a MIDI range is always integral.
struct KeyboardViewport: Hashable {
    /// Absolute white-key index at the left edge of the surface (fractional during animation).
    var firstWhiteIndex: Double
    /// Number of white keys that fit across the surface width (fractional during animation).
    var whiteKeyCount: Double

    init(firstWhiteIndex: Double, whiteKeyCount: Double) {
        self.firstWhiteIndex = firstWhiteIndex
        self.whiteKeyCount = max(1, whiteKeyCount)
    }

    /// Builds the integral viewport that shows exactly the given MIDI range, snapped outward to white keys
    /// and clamped to the 88-key piano.
    init(range: ClosedRange<Int>) {
        let snapped = KeyboardRangeFitter.snappedToWhiteKeys(range)
        let first = KeyboardGeometry.whiteKeyIndex(midi: snapped.lowerBound)
        let last = KeyboardGeometry.whiteKeyIndex(midi: snapped.upperBound)
        self.init(firstWhiteIndex: Double(first), whiteKeyCount: Double(last - first + 1))
    }

    /// Absolute white-key index just past the right edge.
    var endWhiteIndex: Double { firstWhiteIndex + whiteKeyCount }

    /// The MIDI range of white keys that the (rounded) viewport covers.
    var range: ClosedRange<Int> {
        let first = Int(firstWhiteIndex.rounded())
        let last = Int((firstWhiteIndex + whiteKeyCount).rounded()) - 1
        let lo = KeyboardGeometry.midi(whiteKeyIndex: first)
        let hi = KeyboardGeometry.midi(whiteKeyIndex: max(first, last))
        return min(lo, hi)...max(lo, hi)
    }

    /// Linear interpolation between two viewports (used by zoom/scroll transitions).
    static func interpolate(_ a: KeyboardViewport, _ b: KeyboardViewport, fraction t: Double) -> KeyboardViewport {
        let f = max(0, min(1, t))
        return KeyboardViewport(
            firstWhiteIndex: a.firstWhiteIndex + (b.firstWhiteIndex - a.firstWhiteIndex) * f,
            whiteKeyCount: a.whiteKeyCount + (b.whiteKeyCount - a.whiteKeyCount) * f
        )
    }
}

// MARK: - Geometry

/// Pure key geometry for a keyboard surface of a given size showing a given viewport.
///
/// White keys are equal-width strips. Black keys are 60 % as tall and ~58 % as wide as a white key and
/// are placed as on a real instrument: within the C–E group the three white keys have equal rear widths,
/// and within the F–B group the four white keys have equal rear widths. That puts C♯ slightly left of
/// the C/D boundary, D♯ slightly right of the D/E boundary, F♯ well left, G♯ centered and A♯ well right.
struct KeyboardGeometry: Hashable {
    /// Black key width as a fraction of a white key width (a real piano is ≈ 13.7 mm / 23.5 mm).
    static let blackKeyWidthRatio: CGFloat = 0.58
    /// Black key height as a fraction of the white key height.
    static let blackKeyHeightRatio: CGFloat = 0.60

    /// Size of the drawing surface in points.
    let size: CGSize
    /// The window of the piano shown in `size`.
    let viewport: KeyboardViewport

    init(size: CGSize, viewport: KeyboardViewport) {
        self.size = CGSize(width: max(1, size.width), height: max(1, size.height))
        self.viewport = viewport
    }

    /// Convenience: geometry for an integral MIDI range.
    init(size: CGSize, range: ClosedRange<Int>) {
        self.init(size: size, viewport: KeyboardViewport(range: range))
    }

    // MARK: Static key arithmetic

    /// White-key offsets within an octave, indexed by pitch class (black keys map to the white key below them).
    private static let whiteOffsetByPitchClass: [Int] = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    /// Pitch class of each of the seven white keys of an octave.
    private static let pitchClassByWhiteOffset: [Int] = [0, 2, 4, 5, 7, 9, 11]

    /// Whether the MIDI number is a black key.
    static func isBlackKey(_ midi: Int) -> Bool { Pitch.isBlackKey(midi: midi) }

    /// Absolute white-key index of a MIDI number (C-1 = 0, C4 = 35). A black key returns the index of the
    /// white key immediately below it.
    static func whiteKeyIndex(midi: Int) -> Int {
        let octave = Int((Double(midi) / 12).rounded(.down))
        let pc = ((midi % 12) + 12) % 12
        return octave * 7 + whiteOffsetByPitchClass[pc]
    }

    /// MIDI number of the white key with the given absolute white-key index.
    static func midi(whiteKeyIndex index: Int) -> Int {
        let octave = Int((Double(index) / 7).rounded(.down))
        let offset = ((index % 7) + 7) % 7
        return octave * 12 + pitchClassByWhiteOffset[offset]
    }

    /// Left edge of a black key relative to the left edge of its octave's C, in white-key widths.
    static func blackKeyOctaveOffset(pitchClass pc: Int) -> CGFloat {
        let b = blackKeyWidthRatio
        let rearCE = (3 - 2 * b) / 3       // rear width of C, D and E
        let rearFB = (4 - 3 * b) / 4       // rear width of F, G, A and B
        switch pc {
        case 1: return rearCE
        case 3: return 2 * rearCE + b
        case 6: return 3 + rearFB
        case 8: return 3 + 2 * rearFB + b
        case 10: return 3 + 3 * rearFB + 2 * b
        default: return 0
        }
    }

    // MARK: Derived sizes

    /// Width of one white key in points.
    var whiteKeyWidth: CGFloat { size.width / CGFloat(viewport.whiteKeyCount) }
    /// Width of one black key in points.
    var blackKeyWidth: CGFloat { whiteKeyWidth * KeyboardGeometry.blackKeyWidthRatio }
    /// Height of one black key in points.
    var blackKeyHeight: CGFloat { size.height * KeyboardGeometry.blackKeyHeightRatio }

    /// Full bounds of the surface.
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// X position (points) of an absolute, possibly fractional, white-key index.
    func minX(ofWhiteIndex index: Double) -> CGFloat {
        CGFloat(index - viewport.firstWhiteIndex) * whiteKeyWidth
    }

    /// Frame of a key. Keys outside the viewport get frames outside `bounds`; use `isVisible(_:)` to filter.
    func frame(forKey midi: Int) -> CGRect {
        if KeyboardGeometry.isBlackKey(midi) {
            let octaveWhite = Double(KeyboardGeometry.whiteKeyIndex(midi: midi - ((midi % 12) + 12) % 12))
            let pc = ((midi % 12) + 12) % 12
            let x = minX(ofWhiteIndex: octaveWhite) + KeyboardGeometry.blackKeyOctaveOffset(pitchClass: pc) * whiteKeyWidth
            return CGRect(x: x, y: 0, width: blackKeyWidth, height: blackKeyHeight)
        }
        let x = minX(ofWhiteIndex: Double(KeyboardGeometry.whiteKeyIndex(midi: midi)))
        return CGRect(x: x, y: 0, width: whiteKeyWidth, height: size.height)
    }

    /// Whether any part of the key is inside the surface.
    func isVisible(_ midi: Int) -> Bool {
        let f = frame(forKey: midi)
        return f.maxX > 0 && f.minX < size.width
    }

    /// Piano keys (21…108) that are at least partially visible, ascending.
    var visibleKeys: [Int] {
        let firstWhite = Int(viewport.firstWhiteIndex.rounded(.down)) - 1
        let lastWhite = Int(viewport.endWhiteIndex.rounded(.up)) + 1
        let lo = max(Pitch.pianoRange.lowerBound, KeyboardGeometry.midi(whiteKeyIndex: firstWhite))
        let hi = min(Pitch.pianoRange.upperBound, KeyboardGeometry.midi(whiteKeyIndex: lastWhite))
        guard lo <= hi else { return [] }
        return (lo...hi).filter { isVisible($0) }
    }

    /// Visible white keys, ascending.
    var visibleWhiteKeys: [Int] { visibleKeys.filter { !KeyboardGeometry.isBlackKey($0) } }
    /// Visible black keys, ascending.
    var visibleBlackKeys: [Int] { visibleKeys.filter { KeyboardGeometry.isBlackKey($0) } }

    /// The piano key under a point, black keys taking priority in the upper part of the keyboard.
    /// Returns nil outside the surface or outside the 88-key range.
    func key(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let whiteIndex = Int((Double(point.x / whiteKeyWidth) + viewport.firstWhiteIndex).rounded(.down))
        let white = KeyboardGeometry.midi(whiteKeyIndex: whiteIndex)
        if point.y < blackKeyHeight {
            for candidate in [white - 1, white + 1] where KeyboardGeometry.isBlackKey(candidate) {
                if Pitch.pianoRange.contains(candidate), frame(forKey: candidate).contains(point) { return candidate }
            }
        }
        return Pitch.pianoRange.contains(white) ? white : nil
    }

    /// Horizontal span (minX, width) used by falling-note lanes for a key, slightly inset from the key edges.
    func laneSpan(forKey midi: Int, inset: CGFloat = 1) -> (minX: CGFloat, width: CGFloat) {
        let f = frame(forKey: midi)
        let i = min(inset, f.width / 4)
        return (f.minX + i, max(1, f.width - 2 * i))
    }
}

// MARK: - Range fitting

/// Chooses which part of the piano to show for a score's pitch extent.
enum KeyboardRangeFitter {
    /// Default window: C2 … C7 (36 … 96), 36 white keys.
    static let defaultRange: ClosedRange<Int> = 36...96
    /// Never zoom in closer than this many white keys (about two octaves).
    static let minimumWhiteKeys = 15
    /// The whole instrument, A0 … C8.
    static let fullRange: ClosedRange<Int> = Pitch.pianoRange

    /// Clamps a range to the piano and extends it outward so both ends are white keys
    /// (a black key at either end would otherwise be clipped).
    static func snappedToWhiteKeys(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        var lo = max(Pitch.pianoRange.lowerBound, min(Pitch.pianoRange.upperBound, range.lowerBound))
        var hi = max(Pitch.pianoRange.lowerBound, min(Pitch.pianoRange.upperBound, range.upperBound))
        if KeyboardGeometry.isBlackKey(lo) { lo -= 1 }
        if KeyboardGeometry.isBlackKey(hi) { hi += 1 }
        lo = max(Pitch.pianoRange.lowerBound, lo)
        hi = min(Pitch.pianoRange.upperBound, hi)
        return min(lo, hi)...max(lo, hi)
    }

    /// Number of white keys in a (white-snapped) range.
    static func whiteKeyCount(in range: ClosedRange<Int>) -> Int {
        let r = snappedToWhiteKeys(range)
        return KeyboardGeometry.whiteKeyIndex(midi: r.upperBound) - KeyboardGeometry.whiteKeyIndex(midi: r.lowerBound) + 1
    }

    /// Range covering `count` white keys starting at an absolute white-key index, shifted to stay on the piano.
    static func range(firstWhiteIndex: Int, whiteKeyCount count: Int) -> ClosedRange<Int> {
        let minIndex = KeyboardGeometry.whiteKeyIndex(midi: Pitch.pianoRange.lowerBound)
        let maxIndex = KeyboardGeometry.whiteKeyIndex(midi: Pitch.pianoRange.upperBound)
        let n = max(1, min(count, maxIndex - minIndex + 1))
        let first = max(minIndex, min(firstWhiteIndex, maxIndex - n + 1))
        return KeyboardGeometry.midi(whiteKeyIndex: first)...KeyboardGeometry.midi(whiteKeyIndex: first + n - 1)
    }

    /// Range of `count` white keys centered (as nearly as possible) on a white-key index.
    static func range(centeredOnWhiteIndex center: Double, whiteKeyCount count: Int) -> ClosedRange<Int> {
        range(firstWhiteIndex: Int((center - Double(count) / 2).rounded()), whiteKeyCount: count)
    }

    /// The default window expanded (never shrunk) to include a score's pitch range plus padding.
    /// This is the "auto-expanding" behavior used for the practice screen.
    static func fit(scoreRange: ClosedRange<Int>?, base: ClosedRange<Int> = defaultRange, paddingWhiteKeys: Int = 1) -> ClosedRange<Int> {
        let baseSnapped = snappedToWhiteKeys(base)
        guard let scoreRange else { return baseSnapped }
        let padded = padded(scoreRange, whiteKeys: paddingWhiteKeys)
        return snappedToWhiteKeys(min(baseSnapped.lowerBound, padded.lowerBound)...max(baseSnapped.upperBound, padded.upperBound))
    }

    /// The tightest window around a score's pitch range plus padding, widened symmetrically to at least
    /// `minimumWhiteKeys`. Used when the learner asks the keyboard to zoom onto the piece.
    static func tightFit(scoreRange: ClosedRange<Int>?, paddingWhiteKeys: Int = 2, minimumWhiteKeys: Int = minimumWhiteKeys) -> ClosedRange<Int> {
        guard let scoreRange else { return snappedToWhiteKeys(defaultRange) }
        let padded = padded(scoreRange, whiteKeys: paddingWhiteKeys)
        let count = whiteKeyCount(in: padded)
        if count >= minimumWhiteKeys { return padded }
        let center = Double(KeyboardGeometry.whiteKeyIndex(midi: padded.lowerBound) + KeyboardGeometry.whiteKeyIndex(midi: padded.upperBound)) / 2 + 0.5
        return range(centeredOnWhiteIndex: center, whiteKeyCount: minimumWhiteKeys)
    }

    /// `fit(scoreRange:)` for a score (all hands).
    static func fit(for score: Score, base: ClosedRange<Int> = defaultRange, paddingWhiteKeys: Int = 1) -> ClosedRange<Int> {
        fit(scoreRange: score.pitchRange, base: base, paddingWhiteKeys: paddingWhiteKeys)
    }

    /// `tightFit(scoreRange:)` for the hands the learner practices (falls back to all hands when those are empty).
    static func tightFit(for score: Score, hands: HandSelection = .both, paddingWhiteKeys: Int = 2) -> ClosedRange<Int> {
        var ranges: [ClosedRange<Int>] = []
        for hand in Hand.allCases where hands.includes(hand) {
            if let r = score.pitchRange(for: hand) { ranges.append(r) }
        }
        let union = ranges.reduce(nil as ClosedRange<Int>?) { acc, r in
            guard let acc else { return r }
            return min(acc.lowerBound, r.lowerBound)...max(acc.upperBound, r.upperBound)
        }
        return tightFit(scoreRange: union ?? score.pitchRange, paddingWhiteKeys: paddingWhiteKeys)
    }

    /// Extends a range by a number of white keys on both sides (clamped to the piano, white-snapped).
    static func padded(_ range: ClosedRange<Int>, whiteKeys: Int) -> ClosedRange<Int> {
        let snapped = snappedToWhiteKeys(range)
        let lo = KeyboardGeometry.whiteKeyIndex(midi: snapped.lowerBound) - max(0, whiteKeys)
        let hi = KeyboardGeometry.whiteKeyIndex(midi: snapped.upperBound) + max(0, whiteKeys)
        return snappedToWhiteKeys(KeyboardGeometry.midi(whiteKeyIndex: lo)...KeyboardGeometry.midi(whiteKeyIndex: hi))
    }

    /// Shifts a window left/right by whole white keys, keeping its size.
    static func scrolled(_ range: ClosedRange<Int>, byWhiteKeys delta: Int) -> ClosedRange<Int> {
        let snapped = snappedToWhiteKeys(range)
        let count = whiteKeyCount(in: snapped)
        return self.range(firstWhiteIndex: KeyboardGeometry.whiteKeyIndex(midi: snapped.lowerBound) + delta, whiteKeyCount: count)
    }

    /// Zooms a window around its center to a new white-key count (clamped to `minimumWhiteKeys` … 52).
    static func zoomed(_ range: ClosedRange<Int>, toWhiteKeyCount count: Int) -> ClosedRange<Int> {
        let snapped = snappedToWhiteKeys(range)
        let center = Double(KeyboardGeometry.whiteKeyIndex(midi: snapped.lowerBound) + KeyboardGeometry.whiteKeyIndex(midi: snapped.upperBound)) / 2 + 0.5
        let n = max(minimumWhiteKeys, min(whiteKeyCount(in: fullRange), count))
        return self.range(centeredOnWhiteIndex: center, whiteKeyCount: n)
    }
}
