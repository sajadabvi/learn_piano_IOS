import Foundation
import SwiftUI

// MARK: - Per-key state

/// Visual state of one key as the keyboard draws it. The caller (practice screen) supplies a map
/// `[midi: KeyboardKeyState]`; absent keys are neutral.
///
/// Compared with Core's `NoteFeedbackState`, the hand-dependent states carry the hand so expected and
/// upcoming keys can be tinted with the hand colors; `KeyboardKeyStateMapper` performs that conversion.
enum KeyboardKeyState: Hashable, Sendable {
    /// Waiting for the learner; tinted with the hand color (neutral accent when the hand is unknown).
    case expected(Hand?)
    /// Preview of what comes next; a lighter tint of the hand color.
    case upcoming(Hand?)
    /// Currently sounded by the app's demonstration playback.
    case demo(Hand?)
    /// Held by the learner, no judgement yet.
    case pressed
    /// Played correctly.
    case correct
    /// Played but not expected.
    case wrong

    /// Whether the key is drawn depressed (slight darkening and scale).
    var isDepressed: Bool {
        switch self {
        case .pressed, .correct, .wrong, .demo: return true
        case .expected, .upcoming: return false
        }
    }

    /// Hand attached to the state, if any.
    var hand: Hand? {
        switch self {
        case .expected(let h), .upcoming(let h), .demo(let h): return h
        case .pressed, .correct, .wrong: return nil
        }
    }
}

/// Converts the practice engine's `FeedbackSnapshot` into keyboard key states, attaching hands where the
/// timeline makes them known (the current and upcoming steps, and events sounding at the current step).
enum KeyboardKeyStateMapper {
    /// How many steps after the current one are consulted to attribute a hand to upcoming/demo pitches.
    static let lookaheadSteps = 3

    /// Builds the hand lookup used by `states(from:timeline:)`.
    static func handByPitch(timeline: PlaybackTimeline?, currentStepIndex: Int?) -> [Int: Hand] {
        guard let timeline else { return [:] }
        var result: [Int: Hand] = [:]
        let start = currentStepIndex ?? 0
        guard timeline.steps.indices.contains(start) else { return result }
        // Later steps first so the current step's attribution wins where pitches collide.
        for i in stride(from: min(timeline.steps.count - 1, start + lookaheadSteps), through: start, by: -1) {
            for e in timeline.steps[i].events {
                for p in e.pitches { result[p] = e.hand }
            }
        }
        for e in timeline.events(soundingAt: timeline.steps[start].tick) {
            for p in e.pitches where result[p] == nil { result[p] = e.hand }
        }
        return result
    }

    /// Maps a snapshot to keyboard states. `handOfPitch` overrides the timeline-derived attribution.
    static func states(from snapshot: FeedbackSnapshot, timeline: PlaybackTimeline? = nil, handOfPitch: ((Int) -> Hand?)? = nil) -> [Int: KeyboardKeyState] {
        let lookup = handByPitch(timeline: timeline, currentStepIndex: snapshot.currentStepIndex)
        func hand(_ midi: Int) -> Hand? { handOfPitch?(midi) ?? lookup[midi] }
        var out: [Int: KeyboardKeyState] = [:]
        out.reserveCapacity(snapshot.keyStates.count)
        for (midi, s) in snapshot.keyStates {
            switch s {
            case .expected: out[midi] = .expected(hand(midi))
            case .upcoming: out[midi] = .upcoming(hand(midi))
            case .demo: out[midi] = .demo(hand(midi))
            case .pressed: out[midi] = .pressed
            case .correct: out[midi] = .correct
            case .wrong: out[midi] = .wrong
            }
        }
        return out
    }

    /// Merges keys the on-screen keyboard itself is holding into a caller-supplied map (the caller's
    /// judgement wins; untouched held keys show as `.pressed`).
    static func merging(_ states: [Int: KeyboardKeyState], heldByTouch: Set<Int>) -> [Int: KeyboardKeyState] {
        guard !heldByTouch.isEmpty else { return states }
        var out = states
        for midi in heldByTouch where out[midi] == nil { out[midi] = .pressed }
        return out
    }
}

// MARK: - Labels

/// Which keys get a note-name label.
enum KeyboardNoteLabels: String, Hashable, CaseIterable, Sendable {
    case none, cOnly, all

    /// Whether a key of this MIDI number is labelled.
    func shows(midi: Int) -> Bool {
        switch self {
        case .none: return false
        case .cOnly: return ((midi % 12) + 12) % 12 == 0
        case .all: return true
        }
    }
}

// MARK: - Palette

/// Colors used by the keyboard surfaces.
///
/// `standard` mirrors `App/Theme.swift` (accent, hand, correct/wrong/waiting and media colors) because
/// this module is type-checked without `App/`.
// INTEGRATION: the integrator may build the palette from Theme directly, e.g.
// `KeyboardPalette(rightHand: Theme.rightHand, leftHand: Theme.leftHand, correct: Theme.correct, wrong: Theme.wrong, …)`,
// or keep `.standard`, whose values are identical to Theme's today.
struct KeyboardPalette: Hashable, Sendable {
    /// Neutral white key fill.
    var whiteKey: Color
    /// Neutral black key fill.
    var blackKey: Color
    /// Outline between white keys.
    var keyOutline: Color
    /// Label text on white keys.
    var whiteKeyText: Color
    /// Label text on black keys.
    var blackKeyText: Color
    /// Right-hand tint (expected / upcoming / demo / lanes).
    var rightHand: Color
    /// Left-hand tint.
    var leftHand: Color
    /// Tint used when the hand of a key is unknown.
    var neutralAccent: Color
    var correct: Color
    var wrong: Color
    /// Learner-held key with no judgement.
    var pressed: Color
    /// Middle-C marker dot.
    var middleCMarker: Color
    /// Background of the falling-note lanes and the mini map.
    var mediaBackground: Color
    /// Hit line at the bottom of the lanes.
    var laneHitLine: Color
    /// Octave guide lines in the lanes.
    var laneGuide: Color

    init(whiteKey: Color = Color(red: 0.99, green: 0.99, blue: 0.99),
         blackKey: Color = Color(red: 0.13, green: 0.13, blue: 0.15),
         keyOutline: Color = Color(red: 0.78, green: 0.78, blue: 0.81),
         whiteKeyText: Color = Color(red: 0.45, green: 0.46, blue: 0.50),
         blackKeyText: Color = Color(white: 0.9),
         rightHand: Color = Color(red: 0.16, green: 0.47, blue: 0.96),
         leftHand: Color = Color(red: 0.98, green: 0.55, blue: 0.16),
         neutralAccent: Color = Color(red: 0.16, green: 0.47, blue: 0.96),
         correct: Color = Color(red: 0.20, green: 0.72, blue: 0.42),
         wrong: Color = Color(red: 0.90, green: 0.26, blue: 0.26),
         pressed: Color = Color(red: 0.80, green: 0.82, blue: 0.86),
         middleCMarker: Color = Color(red: 0.16, green: 0.47, blue: 0.96),
         mediaBackground: Color = Color(red: 0.11, green: 0.11, blue: 0.13),
         laneHitLine: Color = Color(white: 0.85),
         laneGuide: Color = Color(white: 0.22)) {
        self.whiteKey = whiteKey
        self.blackKey = blackKey
        self.keyOutline = keyOutline
        self.whiteKeyText = whiteKeyText
        self.blackKeyText = blackKeyText
        self.rightHand = rightHand
        self.leftHand = leftHand
        self.neutralAccent = neutralAccent
        self.correct = correct
        self.wrong = wrong
        self.pressed = pressed
        self.middleCMarker = middleCMarker
        self.mediaBackground = mediaBackground
        self.laneHitLine = laneHitLine
        self.laneGuide = laneGuide
    }

    /// The default palette, matching `Theme`.
    static let standard = KeyboardPalette()

    /// Tint for a hand (neutral accent when unknown).
    func handColor(_ hand: Hand?) -> Color {
        switch hand {
        case .right: return rightHand
        case .left: return leftHand
        case nil: return neutralAccent
        }
    }

    /// Fill color of a key in a given state (`nil` = neutral). Black keys get a darker variant so they
    /// stay distinguishable from the white keys around them.
    func fill(for state: KeyboardKeyState?, isBlack: Bool) -> Color {
        let base = isBlack ? blackKey : whiteKey
        guard let state else { return base }
        let color: Color
        switch state {
        case .expected(let h): color = handColor(h)
        case .upcoming(let h): color = handColor(h).mix(with: base, by: isBlack ? 0.45 : 0.6)
        case .demo(let h): color = handColor(h).mix(with: base, by: 0.15)
        case .pressed: color = isBlack ? blackKey.mix(with: pressed, by: 0.35) : pressed
        case .correct: color = correct
        case .wrong: color = wrong
        }
        return isBlack ? color.mix(with: .black, by: 0.22) : color
    }

    /// Label color readable on a key in a given state.
    func labelColor(for state: KeyboardKeyState?, isBlack: Bool) -> Color {
        guard let state else { return isBlack ? blackKeyText : whiteKeyText }
        switch state {
        case .upcoming: return isBlack ? blackKeyText : whiteKeyText
        case .pressed: return isBlack ? blackKeyText : whiteKeyText.mix(with: .black, by: 0.3)
        default: return .white
        }
    }
}

// MARK: - Transition tracking

/// Tracks per-key state changes so the renderer can cross-fade between the old and the new look.
///
/// The keyboard is drawn in a single `Canvas` pass; SwiftUI cannot implicitly animate canvas content,
/// so this struct records each key's `(from, to, start)` and the renderer blends with `progress(at:)`.
/// Time is an abstract `TimeInterval` so tests are deterministic.
struct KeyboardTransitionTracker: Hashable {
    /// One in-flight change of a key's state.
    struct Transition: Hashable {
        var from: KeyboardKeyState?
        var to: KeyboardKeyState?
        var start: TimeInterval
    }

    /// Duration of the cross-fade in seconds.
    var duration: TimeInterval
    /// Target state per key (what the caller last supplied).
    private(set) var current: [Int: KeyboardKeyState]
    /// Keys whose change may still be animating.
    private(set) var transitions: [Int: Transition]

    init(states: [Int: KeyboardKeyState] = [:], duration: TimeInterval = 0.12) {
        self.current = states
        self.transitions = [:]
        self.duration = max(0, duration)
    }

    /// Records the differences between the current and the new state map, starting transitions at `time`.
    mutating func update(to states: [Int: KeyboardKeyState], at time: TimeInterval) {
        guard states != current else { return }
        var keys = Set(states.keys)
        keys.formUnion(current.keys)
        for midi in keys {
            let old = current[midi]
            let new = states[midi]
            guard old != new else { continue }
            // Interrupting an in-flight fade: start from the look it had reached so there is no jump.
            let from = transitions[midi].map { t in blendedOrigin(of: t, at: time) } ?? old
            transitions[midi] = Transition(from: from, to: new, start: time)
        }
        current = states
    }

    /// Replaces everything instantly (no animation), e.g. on first appearance.
    mutating func reset(to states: [Int: KeyboardKeyState]) {
        current = states
        transitions = [:]
    }

    /// Drops transitions that have finished by `time`.
    mutating func prune(at time: TimeInterval) {
        transitions = transitions.filter { !isFinished($0.value, at: time) }
    }

    /// Whether any key is still cross-fading.
    func isAnimating(at time: TimeInterval) -> Bool {
        transitions.values.contains { !isFinished($0, at: time) }
    }

    /// Eased 0…1 progress of a key's transition (1 when the key is idle).
    func progress(forKey midi: Int, at time: TimeInterval) -> Double {
        guard let t = transitions[midi] else { return 1 }
        return progress(of: t, at: time)
    }

    /// `(from, to, progress)` the renderer blends for one key.
    func blend(forKey midi: Int, at time: TimeInterval) -> (from: KeyboardKeyState?, to: KeyboardKeyState?, progress: Double) {
        guard let t = transitions[midi] else { return (current[midi], current[midi], 1) }
        return (t.from, t.to, progress(of: t, at: time))
    }

    /// A transition counts as finished once its duration has elapsed (with a tiny tolerance so that
    /// floating-point subtraction of frame timestamps cannot keep a finished fade alive).
    private func isFinished(_ t: Transition, at time: TimeInterval) -> Bool { time - t.start >= duration - KeyboardEasing.timeTolerance }

    private func progress(of t: Transition, at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let linear = max(0, min(1, (time - t.start) / duration))
        return KeyboardEasing.easeOut(linear)
    }

    /// When a fade is interrupted before half-way we keep its origin; after half-way its target is the
    /// closer look, so the new fade starts from there.
    private func blendedOrigin(of t: Transition, at time: TimeInterval) -> KeyboardKeyState? {
        progress(of: t, at: time) < 0.5 ? t.from : t.to
    }
}

/// Easing curve of a viewport transition.
enum KeyboardViewportCurve: Hashable, Sendable {
    /// Starts and ends at rest; used when the viewport was idle before the change.
    case easeInOut
    /// Starts at full speed and decelerates; used when a change interrupts one already in flight (or follows
    /// a finger), so the motion never restarts from zero velocity.
    case easeOut

    /// Eased 0…1 value for a linear 0…1 time fraction.
    func value(_ t: Double) -> Double {
        switch self {
        case .easeInOut: return KeyboardEasing.easeInOut(t)
        case .easeOut: return KeyboardEasing.easeOutCubic(t)
        }
    }
}

/// A zoom/scroll of the visible range in flight.
struct KeyboardViewportTransition: Hashable {
    var from: KeyboardViewport
    var to: KeyboardViewport
    var start: TimeInterval
    var duration: TimeInterval
    var curve: KeyboardViewportCurve

    init(from: KeyboardViewport, to: KeyboardViewport, start: TimeInterval, duration: TimeInterval = 0.35, curve: KeyboardViewportCurve = .easeInOut) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = max(0, duration)
        self.curve = curve
    }

    /// Eased 0…1 progress.
    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return curve.value(max(0, min(1, (time - start) / duration)))
    }

    /// Whether the transition has reached its target.
    func isFinished(at time: TimeInterval) -> Bool { time - start >= duration - KeyboardEasing.timeTolerance }

    /// Interpolated viewport at `time`.
    func viewport(at time: TimeInterval) -> KeyboardViewport {
        KeyboardViewport.interpolate(from, to, fraction: progress(at: time))
    }
}

/// Keeps the displayed viewport and animates towards a new target range; shared by the keyboard, the lanes
/// and the mini map so they move together.
///
/// Rapid successive changes (dragging the mini map, auto-follow scrolling) stay fluid: a change that
/// interrupts a transition in flight continues with an ease-out curve from the current position, so it
/// moves at full speed immediately instead of restarting the slow ease-in. Interactive changes use a much
/// shorter ease-out so the window tracks the finger.
struct KeyboardAnimatedViewport: Hashable {
    /// The range the caller most recently asked for.
    private(set) var target: KeyboardViewport
    private(set) var transition: KeyboardViewportTransition?
    /// Duration of programmatic range changes.
    var duration: TimeInterval
    /// Duration of interactive range changes (direct manipulation such as dragging the mini map).
    var interactiveDuration: TimeInterval

    init(range: ClosedRange<Int>, duration: TimeInterval = 0.35, interactiveDuration: TimeInterval = 0.08) {
        self.target = KeyboardViewport(range: range)
        self.transition = nil
        self.duration = duration
        self.interactiveDuration = interactiveDuration
    }

    /// Starts animating from wherever the viewport currently is to `range`.
    ///
    /// - Parameter interactive: the change follows a finger; use the short `interactiveDuration` ease-out.
    mutating func retarget(to range: ClosedRange<Int>, at time: TimeInterval, interactive: Bool = false) {
        let new = KeyboardViewport(range: range)
        guard new != target else { return }
        let origin = viewport(at: time)
        let inFlight = isAnimating(at: time)
        target = new
        if interactive {
            transition = KeyboardViewportTransition(from: origin, to: new, start: time, duration: interactiveDuration, curve: .easeOut)
        } else {
            transition = KeyboardViewportTransition(from: origin, to: new, start: time, duration: duration,
                                                    curve: inFlight ? .easeOut : .easeInOut)
        }
    }

    /// Jumps to `range` without animation.
    mutating func jump(to range: ClosedRange<Int>) {
        target = KeyboardViewport(range: range)
        transition = nil
    }

    /// The viewport to draw at `time`.
    func viewport(at time: TimeInterval) -> KeyboardViewport {
        guard let transition, !transition.isFinished(at: time) else { return target }
        return transition.viewport(at: time)
    }

    /// Whether a zoom/scroll is still in flight.
    func isAnimating(at time: TimeInterval) -> Bool {
        guard let transition else { return false }
        return !transition.isFinished(at: time)
    }

    /// Clears a finished transition.
    mutating func prune(at time: TimeInterval) {
        if let transition, transition.isFinished(at: time) { self.transition = nil }
    }
}

/// Easing curves used by the keyboard animations.
enum KeyboardEasing {
    /// Seconds of slack used when deciding whether an animation has finished.
    static let timeTolerance: TimeInterval = 1e-9
    /// Quadratic ease-out.
    static func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    /// Cubic ease-out: starts at three times the average speed, so an interrupted motion keeps going.
    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    /// Cubic ease-in-out.
    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
