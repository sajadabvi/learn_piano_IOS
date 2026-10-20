import CoreGraphics
import Foundation

// Pure, deterministic view-state logic for the practice screen. Everything here is a value type or a
// static function so it can be unit-tested without SwiftUI, audio or input hardware.

// MARK: - Feedback → keyboard / notation

/// What the keyboard region renders for one feedback snapshot.
struct PracticeUIKeyboardState: Equatable {
    /// Per-key visual state (hand-attributed) for `KeyboardView` / `KeyboardStageView`.
    var keyStates: [Int: KeyboardKeyState]
    /// Keys currently flashing as wrong, ascending.
    var wrongPitches: [Int]
    /// Keys the learner is expected to play now, ascending.
    var expectedPitches: [Int]

    static let empty = PracticeUIKeyboardState(keyStates: [:], wrongPitches: [], expectedPitches: [])
}

/// What the notation region renders for one feedback snapshot (besides the cursor tick).
struct PracticeUINotationState: Equatable {
    var feedback: FeedbackSnapshot
    /// Hands drawn at full opacity.
    var practicedHands: HandSelection
    /// Whether the other hand's staff is dimmed.
    var dimsOtherHands: Bool
    /// Loop region tinted on the score.
    var loop: MeasureRange?
}

/// Maps the engine's `FeedbackSnapshot` to the keyboard and notation state structs.
enum PracticeUIFeedbackMapper {
    /// Keyboard state: hand-attributed key states plus the wrong and expected key lists.
    static func keyboardState(from snapshot: FeedbackSnapshot, timeline: PlaybackTimeline?, expectedPitches: [Int] = []) -> PracticeUIKeyboardState {
        let states = KeyboardKeyStateMapper.states(from: snapshot, timeline: timeline)
        let wrong = snapshot.keyStates.filter { $0.value == .wrong }.map(\.key).sorted()
        let expectedFromKeys = snapshot.keyStates.filter { $0.value == .expected }.map(\.key)
        let expected = expectedPitches.isEmpty ? expectedFromKeys.sorted() : Array(Set(expectedPitches)).sorted()
        return PracticeUIKeyboardState(keyStates: states, wrongPitches: wrong, expectedPitches: expected)
    }

    /// Notation state: in Listen mode nothing is dimmed (the app plays every hand).
    static func notationState(from snapshot: FeedbackSnapshot, settings: PracticeSettings) -> PracticeUINotationState {
        let listening = settings.mode == .listen
        return PracticeUINotationState(
            feedback: snapshot,
            practicedHands: listening ? .both : settings.hands,
            dimsOtherHands: !listening && settings.hands != .both,
            loop: settings.loop
        )
    }
}

// MARK: - Note names

enum PracticeUINoteNames {
    /// "C4 E4 G4" for MIDI numbers (sorted, deduplicated). Flat keys spell flats.
    static func names(_ pitches: [Int], key: KeySignature = .cMajor) -> String {
        Array(Set(pitches)).sorted().map { Pitch(midi: $0, in: key).name }.joined(separator: " ")
    }

    /// The Wait Mode hint shown after a wrong note, e.g. "Expected: C4 E4"; nil when nothing is expected.
    static func expectedPill(_ pitches: [Int], key: KeySignature = .cMajor) -> String? {
        guard !pitches.isEmpty else { return nil }
        return "Expected: " + names(pitches, key: key)
    }

    /// Spoken form for VoiceOver ("C sharp 4" instead of "C#4").
    static func spoken(_ pitches: [Int], key: KeySignature = .cMajor) -> String {
        Array(Set(pitches)).sorted().map { midi -> String in
            let p = Pitch(midi: midi, in: key)
            let accidental: String
            switch p.alter {
            case 1: accidental = " sharp"
            case 2: accidental = " double sharp"
            case -1: accidental = " flat"
            case -2: accidental = " double flat"
            default: accidental = ""
            }
            return "\(p.step.name)\(accidental) \(p.octave)"
        }.joined(separator: ", ")
    }
}

// MARK: - Loop selection

/// Loop-region selection from taps, drags and the loop toggle, in notated measure indices.
///
/// Taps build a range in two steps: the first tap loops that single measure and remembers it as the anchor;
/// a second tap on another measure extends the loop from the anchor to it. Tapping the anchor (or a lone
/// looped measure) again clears the loop. A drag selects its range directly.
struct PracticeUILoopSelection: Equatable {
    /// Current loop region (nil = whole piece).
    var loop: MeasureRange?
    /// Measure of the first tap of a two-tap selection.
    var anchor: Int?
    /// The last loop that was set, offered again when the loop toggle is switched back on.
    var remembered: MeasureRange?

    init(loop: MeasureRange? = nil, anchor: Int? = nil, remembered: MeasureRange? = nil) {
        self.loop = loop
        self.anchor = anchor
        self.remembered = remembered ?? loop
    }

    /// Applies a tap on a measure.
    mutating func tap(measure rawMeasure: Int, measureCount: Int) {
        guard measureCount > 0 else { return }
        let m = max(0, min(measureCount - 1, rawMeasure))
        if let a = anchor, loop != nil {
            if a == m {
                clear()
            } else {
                setLoop(MeasureRange(start: a, end: m))
                anchor = nil
            }
            return
        }
        if let current = loop, current.count == 1, current.start == m {
            clear()
            return
        }
        setLoop(MeasureRange(single: m))
        anchor = m
    }

    /// Applies a drag selection.
    mutating func drag(_ range: MeasureRange, measureCount: Int) {
        guard measureCount > 0 else { return }
        setLoop(range.clamped(toMeasureCount: measureCount))
        anchor = nil
    }

    /// Switches looping on (restoring the remembered range, or `fallback`) or off.
    mutating func toggle(fallback: MeasureRange, measureCount: Int) {
        anchor = nil
        if loop != nil {
            loop = nil
        } else if measureCount > 0 {
            setLoop((remembered ?? fallback).clamped(toMeasureCount: measureCount))
        }
    }

    /// Sets an explicit range (e.g. "Loop the trouble spot").
    mutating func set(_ range: MeasureRange, measureCount: Int) {
        guard measureCount > 0 else { return }
        setLoop(range.clamped(toMeasureCount: measureCount))
        anchor = nil
    }

    mutating func clear() {
        loop = nil
        anchor = nil
    }

    private mutating func setLoop(_ range: MeasureRange) {
        loop = range
        remembered = range
    }

    /// Default range when looping is switched on with nothing remembered: the cursor's measure and the next.
    static func defaultRange(cursorMeasure: Int, measureCount: Int) -> MeasureRange {
        let n = max(1, measureCount)
        let start = max(0, min(n - 1, cursorMeasure))
        return MeasureRange(start: start, end: min(n - 1, start + 1))
    }

    /// "Bar 3" / "Bars 3–5" using the score's printed measure numbers.
    static func label(_ range: MeasureRange?, score: Score) -> String {
        guard let range else { return "Loop" }
        let first = PracticeUIMeasureText.number(of: range.start, in: score)
        let last = PracticeUIMeasureText.number(of: range.end, in: score)
        return range.count == 1 ? "Bar \(first)" : "Bars \(first)–\(last)"
    }
}

// MARK: - Measure text and navigation

enum PracticeUIMeasureText {
    /// Printed measure number of a notated index (index + 1 when the index is out of range).
    static func number(of index: Int, in score: Score) -> Int {
        score.measures.indices.contains(index) ? score.measures[index].number : index + 1
    }

    /// Short visible label, e.g. "Bar 5 / 32".
    static func position(measureIndex: Int, in score: Score) -> String {
        let last = score.measures.last?.number ?? score.measures.count
        return "Bar \(number(of: measureIndex, in: score)) / \(last)"
    }

    /// VoiceOver description of the cursor, e.g. "Measure 5 of 32, second time through".
    static func spokenPosition(measureIndex: Int, pass: Int, in score: Score) -> String {
        let last = score.measures.last?.number ?? score.measures.count
        var text = "Measure \(number(of: measureIndex, in: score)) of \(last)"
        if pass > 1 { text += pass == 2 ? ", second time through" : ", pass \(pass)" }
        return text
    }
}

enum PracticeUINavigation {
    /// Target of "previous measure": the start of the current measure when the cursor is more than a beat
    /// into it, otherwise the previous measure.
    static func previousMeasure(current: Int, tickInMeasure: Ticks, beatTicks: Ticks) -> Int {
        tickInMeasure > max(1, beatTicks) / 2 ? max(0, current) : max(0, current - 1)
    }

    /// Target of "next measure", clamped to the last measure.
    static func nextMeasure(current: Int, measureCount: Int) -> Int {
        max(0, min(max(0, measureCount - 1), current + 1))
    }
}

// MARK: - Progress and count-in

enum PracticeUIProgress {
    /// Ticks of the learner's steps inside the loop (or the whole piece), sorted.
    static func stepTicks(timeline: PlaybackTimeline, hands: HandSelection, loop: MeasureRange?) -> [Ticks] {
        let range = loop.flatMap { timeline.tickRange(of: $0) }
        return timeline.steps(for: hands).map(\.tick).filter { range?.contains($0) ?? true }
    }

    /// Steps strictly before the cursor (the step under the cursor is still to be played).
    static func completedSteps(stepTicks: [Ticks], cursorTick: Double, finished: Bool) -> Int {
        if finished { return stepTicks.count }
        guard cursorTick.isFinite else { return 0 }
        var lo = 0, hi = stepTicks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Double(stepTicks[mid]) < cursorTick - 0.5 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 0…1 share of steps completed.
    static func fraction(completed: Int, total: Int) -> Double {
        total <= 0 ? 0 : max(0, min(1, Double(completed) / Double(total)))
    }
}

enum PracticeUICountIn {
    /// 1-based beat number within its measure for the big count-in overlay.
    static func displayBeat(beat: Int, totalBeats: Int, measures: Int) -> Int {
        let perMeasure = max(1, totalBeats / max(1, measures))
        return (max(0, beat) % perMeasure) + 1
    }
}

// MARK: - Summary formatting

/// The end-of-session summary as displayed text.
struct PracticeUISummaryText: Equatable {
    var headline: String
    var accuracy: String
    var time: String
    var wrongNotes: String
    var steps: String
    /// "Bar 4 (3 mistakes)", worst first.
    var troubleMeasures: [String]
    /// Loop suggested by "Loop the trouble spot", nil when there were no mistakes.
    var troubleLoop: MeasureRange?
    /// Exercise verdict ("Passed!" / "Try again"), nil for songs.
    var exerciseResult: String?
    var passed: Bool?
}

enum PracticeUISummaryFormatter {
    /// Measure indices with mistakes, worst first (ties: earlier measure first), at most `limit`.
    static func troubleMeasures(_ mistakes: [Int: Int], limit: Int = 3) -> [Int] {
        mistakes.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max(0, limit))
            .map(\.key)
    }

    /// Loop around the trouble spot: the span of the worst measures when it is short (≤ 4 measures), else the
    /// worst measure and the one after it.
    static func troubleLoop(_ mistakes: [Int: Int], measureCount: Int) -> MeasureRange? {
        let worst = troubleMeasures(mistakes)
        guard let first = worst.first, measureCount > 0,
              let lo = worst.min(), let hi = worst.max() else { return nil }
        let range = hi - lo + 1 <= 4 ? MeasureRange(start: lo, end: hi) : MeasureRange(start: first, end: first + 1)
        return range.clamped(toMeasureCount: measureCount)
    }

    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }

    static func headline(accuracy: Double, mode: PracticeMode, reachedEnd: Bool) -> String {
        if mode == .listen { return "Nice listening" }
        switch accuracy {
        case 0.95...: return reachedEnd ? "Perfect run!" : "Excellent!"
        case 0.8..<0.95: return "Great job!"
        case 0.5..<0.8: return "Good progress"
        default: return "Keep practicing"
        }
    }

    static func format(_ summary: PracticeSummary, score: Score, request: PracticeRequest? = nil) -> PracticeUISummaryText {
        let listening = summary.mode == .listen
        let trouble = troubleMeasures(summary.mistakesByMeasure)
        let troubleLines = trouble.map { index -> String in
            let n = summary.mistakesByMeasure[index] ?? 0
            return "Bar \(PracticeUIMeasureText.number(of: index, in: score)) (\(n) \(n == 1 ? "mistake" : "mistakes"))"
        }
        var exerciseResult: String?
        var passed: Bool?
        if let request, request.exerciseInstructions != nil || request.passCriteria != nil {
            let ok = request.passes(summary)
            passed = ok
            exerciseResult = ok ? "Passed!" : "Try again"
        }
        return PracticeUISummaryText(
            headline: headline(accuracy: summary.accuracy, mode: summary.mode, reachedEnd: summary.reachedEnd),
            accuracy: listening ? "—" : percent(summary.accuracy),
            time: MusicHelpers.clock(summary.durationSeconds),
            wrongNotes: listening ? "—" : "\(summary.wrongNotes)",
            steps: listening ? "—" : "\(summary.stepsCorrect) / \(summary.stepsExpected)",
            troubleMeasures: listening ? [] : troubleLines,
            troubleLoop: listening ? nil : troubleLoop(summary.mistakesByMeasure, measureCount: score.measures.count),
            exerciseResult: exerciseResult,
            passed: passed
        )
    }
}

// MARK: - Speed

enum PracticeUISpeedText {
    /// "25%", "50%", "75%", "100%".
    static func label(_ speed: Double) -> String {
        guard speed.isFinite else { return "100%" }
        return "\(Int((speed * 100).rounded()))%"
    }
}

// MARK: - Layout metrics

/// Sizes of the demo (lanes + keyboard) and notation regions for the space between header and transport.
struct PracticeUILayoutMetrics: Equatable {
    var isLandscape: Bool
    var notationHeight: CGFloat
    var keyboardHeight: CGFloat
    var laneHeight: CGFloat
    var notationMode: NotationDisplayMode
    /// Points per staff space for the notation.
    var staffSpace: CGFloat

    /// Staff spaces one scroll-mode grand-staff system needs (staves plus ledger-line room).
    static let systemHeightInStaffSpaces: CGFloat = 30

    static func make(size: CGSize, showsFallingNotes: Bool) -> PracticeUILayoutMetrics {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let landscape = width > height
        if landscape {
            let keyboard = clamp(height * 0.2, 110, 190)
            let notation: CGFloat
            if showsFallingNotes {
                notation = clamp(height * 0.36, 200, 380)
            } else {
                notation = max(200, height - keyboard)
            }
            let lanes = showsFallingNotes ? max(0, height - keyboard - notation) : 0
            let staff = clamp(min(notation, 380) / systemHeightInStaffSpaces, 6.5, 12)
            return PracticeUILayoutMetrics(isLandscape: true, notationHeight: notation, keyboardHeight: keyboard,
                                           laneHeight: lanes, notationMode: .scroll, staffSpace: staff)
        } else {
            let keyboard = clamp(height * 0.13, 100, 170)
            let notation = showsFallingNotes ? clamp(height * 0.5, 260, height - keyboard) : max(260, height - keyboard)
            let lanes = showsFallingNotes ? max(0, height - keyboard - notation) : 0
            let staff = clamp(width / 110, 7, 10)
            return PracticeUILayoutMetrics(isLandscape: false, notationHeight: notation, keyboardHeight: keyboard,
                                           laneHeight: lanes, notationMode: .page, staffSpace: staff)
        }
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        max(lo, min(max(lo, hi), v))
    }
}

// MARK: - Keyboard range

enum PracticeUIKeyboardRange {
    /// Visible keys: the auto-expanded default window on wide screens, a tight fit on narrow ones.
    static func range(for score: Score, hands: HandSelection, width: CGFloat) -> ClosedRange<Int> {
        if width >= 1000 { return KeyboardRangeFitter.fit(for: score) }
        let tight = KeyboardRangeFitter.tightFit(for: score, hands: hands)
        // Keep keys at least ~22 pt wide.
        let maxWhiteKeys = max(KeyboardRangeFitter.minimumWhiteKeys, Int(width / 22))
        if KeyboardRangeFitter.whiteKeyCount(in: tight) <= maxWhiteKeys { return tight }
        return KeyboardRangeFitter.zoomed(tight, toWhiteKeyCount: maxWhiteKeys)
    }
}

// MARK: - Input status

/// What the input status chip/banner says about the selected note source.
enum PracticeUIInputStatus: Equatable {
    /// Only the on-screen keyboard is listened to.
    case onScreen
    /// Waiting for the microphone (permission prompt or engine start).
    case microphoneStarting
    /// The microphone is running.
    case microphoneListening
    /// Microphone access was refused; only the Settings app can change it.
    case microphoneDenied
    /// The microphone could not run (no input route, engine failure).
    case microphoneUnavailable(String)
    /// MIDI selected and at least one device is reachable.
    case midiConnected(String)
    /// MIDI selected but nothing is connected.
    case midiNoDevice

    static func make(selection: InputHubSelection,
                     microphonePermission: InputMicrophonePermission?,
                     microphoneState: InputSourceState?,
                     microphoneError: String?,
                     midiDeviceNames: [String]) -> PracticeUIInputStatus {
        let midi: PracticeUIInputStatus = midiDeviceNames.isEmpty ? .midiNoDevice : .midiConnected(midiDeviceNames.joined(separator: ", "))
        func microphone() -> PracticeUIInputStatus {
            if microphonePermission == .denied || microphoneState == .permissionDenied { return .microphoneDenied }
            switch microphoneState {
            case .running: return .microphoneListening
            case .permissionDenied: return .microphoneDenied
            case .unavailable: return .microphoneUnavailable(microphoneError ?? "No microphone input is available.")
            case .failed: return .microphoneUnavailable(microphoneError ?? "The microphone could not be started.")
            case .idle, .starting, nil: return .microphoneStarting
            }
        }
        switch selection {
        case .onScreenOnly: return .onScreen
        case .midi: return midi
        case .microphone: return microphone()
        case .both:
            // A connected MIDI keyboard is the more reliable source; otherwise report the microphone.
            return midiDeviceNames.isEmpty ? microphone() : midi
        }
    }

    /// Short text for the status chip.
    var chipText: String {
        switch self {
        case .onScreen: return "On-screen keyboard"
        case .microphoneStarting: return "Starting microphone…"
        case .microphoneListening: return "Listening…"
        case .microphoneDenied: return "Microphone access is off"
        case .microphoneUnavailable: return "Microphone unavailable"
        case .midiConnected(let name): return name
        case .midiNoDevice: return "No MIDI keyboard connected"
        }
    }

    /// Whether the learner should be offered the switch to the on-screen keyboard (an inline banner).
    var needsAttention: Bool {
        switch self {
        case .microphoneDenied, .microphoneUnavailable, .midiNoDevice: return true
        case .onScreen, .microphoneStarting, .microphoneListening, .midiConnected: return false
        }
    }

    var systemImage: String {
        switch self {
        case .onScreen: return "hand.tap"
        case .microphoneStarting, .microphoneListening: return "mic.fill"
        case .microphoneDenied, .microphoneUnavailable: return "mic.slash.fill"
        case .midiConnected: return "pianokeys"
        case .midiNoDevice: return "cable.connector.slash"
        }
    }
}
