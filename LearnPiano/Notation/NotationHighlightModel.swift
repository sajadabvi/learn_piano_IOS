import Foundation
import CoreGraphics
import SwiftUI
import Observation

// MARK: - Palette

/// Colours used by the notation renderer.
///
/// INTEGRATION: `standard` mirrors `Theme` (App/Theme.swift) value for value, because the module type-check
/// only sees Core. The integrator may replace it with `NotationPalette(theme-backed values)` or pass a custom
/// palette to `NotationScoreView`; no other wiring is needed.
struct NotationPalette {
    var ink: Color
    var sheetBackground: Color
    var accent: Color
    var rightHand: Color
    var leftHand: Color
    var correct: Color
    var wrong: Color
    var waiting: Color
    /// Opacity of the hand that is not being practised.
    var dimmedOpacity: Double
    /// Opacity of the loop-region tint.
    var loopTintOpacity: Double

    /// Theme values: Theme.textPrimary ink on Theme.sheetBackground, Theme.accent cursor, hand and feedback colours.
    static let standard = NotationPalette(
        ink: Color(red: 0.12, green: 0.12, blue: 0.14),
        sheetBackground: .white,
        accent: Color(red: 0.16, green: 0.47, blue: 0.96),
        rightHand: Color(red: 0.16, green: 0.47, blue: 0.96),
        leftHand: Color(red: 0.98, green: 0.55, blue: 0.16),
        correct: Color(red: 0.20, green: 0.72, blue: 0.42),
        wrong: Color(red: 0.90, green: 0.26, blue: 0.26),
        waiting: Color(red: 0.96, green: 0.78, blue: 0.20),
        dimmedOpacity: 0.3,
        loopTintOpacity: 0.12)

    /// Colour of a hand.
    func color(for hand: Hand) -> Color { hand == .right ? rightHand : leftHand }

    /// Concrete colour for a tint.
    func color(for tint: NotationNoteTint, hand: Hand) -> Color {
        switch tint {
        case .ink: return ink
        case .hand: return color(for: hand)
        case .handFaded: return color(for: hand).opacity(0.55)
        case .correct: return correct
        case .wrong: return wrong
        }
    }
}

/// Abstract colouring decision for one event (tested without SwiftUI colours).
enum NotationNoteTint: Equatable, Sendable {
    case ink, hand, handFaded, correct, wrong
}

// MARK: - Highlight model

/// Everything the score view shows on top of the engraving: cursor position, feedback, practised hands,
/// loop region. Updating it never triggers a re-layout; only the canvases redraw.
@MainActor
@Observable
final class NotationHighlightModel {
    /// Playback position in ticks (fractional, interpolated by the caller every frame while playing).
    var positionTick: Double
    /// Latest feedback from the practice engine (`eventStates` keyed by `TimelineEvent.id`).
    var feedback: FeedbackSnapshot
    /// Hands the learner practises; the others are dimmed when `dimsUnpracticedHands` is on.
    var practicedHands: HandSelection
    var dimsUnpracticedHands: Bool
    /// Loop region in notated measure indices.
    var loopRange: MeasureRange?
    var showsCursor: Bool
    /// Colour notes that sound at the cursor in their hand colour even without feedback states.
    var highlightsSoundingNotes: Bool
    /// Playback timeline used to map playback ticks (with repeats) to notated measures; nil = notated order.
    var timeline: PlaybackTimeline?

    init(timeline: PlaybackTimeline? = nil, positionTick: Double = 0, feedback: FeedbackSnapshot = .empty,
         practicedHands: HandSelection = .both, dimsUnpracticedHands: Bool = true, loopRange: MeasureRange? = nil,
         showsCursor: Bool = true, highlightsSoundingNotes: Bool = true) {
        self.timeline = timeline
        self.positionTick = positionTick
        self.feedback = feedback
        self.practicedHands = practicedHands
        self.dimsUnpracticedHands = dimsUnpracticedHands
        self.loopRange = loopRange
        self.showsCursor = showsCursor
        self.highlightsSoundingNotes = highlightsSoundingNotes
    }

    /// Snapshot of the drawable state for one frame (reading it registers observation for the caller).
    func drawState(for layout: NotationLayout) -> NotationDrawState {
        NotationDrawState.make(layout: layout, positionTick: positionTick, timeline: timeline, feedback: feedback,
                               practicedHands: practicedHands, dims: dimsUnpracticedHands, loop: loopRange,
                               showsCursor: showsCursor, highlightsSounding: highlightsSoundingNotes)
    }
}

// MARK: - Per-frame state

/// Where the cursor is on the notated score.
struct NotationCursorLocation: Equatable, Sendable {
    var measureIndex: Int
    var tickInMeasure: Double
    /// Playback segment (pass) the position belongs to, when a timeline is known.
    var segmentIndex: Int?
}

/// The highlight inputs resolved for one frame; pure value consumed by the painter.
struct NotationDrawState {
    var cursor: NotationCursorLocation?
    /// Cursor x in layout units (staff spaces).
    var cursorX: CGFloat?
    var cursorSystem: Int?
    var states: [UUID: NoteFeedbackState]
    var sounding: Set<UUID>
    var practicedHands: HandSelection
    var dims: Bool
    var loop: MeasureRange?
    /// In-progress measure selection (drag) shown with a stronger tint.
    var selection: MeasureRange?
    var showsCursor: Bool
    var highlightsSounding: Bool

    /// Resolves cursor, event states and sounding notes for a frame.
    static func make(layout: NotationLayout, positionTick: Double, timeline: PlaybackTimeline?, feedback: FeedbackSnapshot,
                     practicedHands: HandSelection, dims: Bool, loop: MeasureRange?, showsCursor: Bool, highlightsSounding: Bool) -> NotationDrawState {
        let cursor = NotationHighlightResolver.cursorLocation(positionTick: positionTick, timeline: timeline, layout: layout)
        let x = cursor.flatMap { layout.cursorX(measureIndex: $0.measureIndex, tickInMeasure: $0.tickInMeasure) }
        let system = cursor.map { layout.measures[$0.measureIndex].systemIndex }
        return NotationDrawState(
            cursor: cursor, cursorX: x, cursorSystem: system,
            states: NotationHighlightResolver.eventStates(feedback, currentSegment: cursor?.segmentIndex),
            sounding: cursor.map { NotationHighlightResolver.soundingEvents(layout: layout, at: $0) } ?? [],
            practicedHands: practicedHands, dims: dims, loop: loop, selection: nil,
            showsCursor: showsCursor, highlightsSounding: highlightsSounding)
    }

    /// A copy showing an in-progress measure selection.
    func with(selection: MeasureRange?) -> NotationDrawState {
        var copy = self
        copy.selection = selection
        return copy
    }

    /// Tint of an event.
    func tint(for id: UUID) -> NotationNoteTint {
        NotationHighlightResolver.tint(state: states[id], isSounding: sounding.contains(id), highlightsSounding: highlightsSounding)
    }

    /// Opacity multiplier for elements of a hand.
    func opacity(for hand: Hand) -> Double {
        NotationHighlightResolver.opacity(hand: hand, practiced: practicedHands, dims: dims)
    }
}

/// Pure highlight rules (unit tested).
enum NotationHighlightResolver {
    /// Opacity factor applied to the hand that is not practised.
    static let dimmedOpacity = 0.3

    /// Splits a `TimelineEvent.id` ("<segmentIndex>:<event uuid>") into its parts.
    static func parseTimelineEventID(_ id: String) -> (segment: Int?, eventID: UUID)? {
        guard let colon = id.lastIndex(of: ":") else { return UUID(uuidString: id).map { (nil, $0) } }
        guard let uuid = UUID(uuidString: String(id[id.index(after: colon)...])) else { return nil }
        return (Int(id[..<colon]), uuid)
    }

    /// Feedback states keyed by notated event. When several playback occurrences of the same event carry a state,
    /// the occurrence in the current segment wins, otherwise the latest segment.
    static func eventStates(_ feedback: FeedbackSnapshot, currentSegment: Int?) -> [UUID: NoteFeedbackState] {
        var result: [UUID: (state: NoteFeedbackState, rank: Int)] = [:]
        for (key, state) in feedback.eventStates {
            guard let parsed = parseTimelineEventID(key) else { continue }
            let segment = parsed.segment ?? -1
            let rank = (currentSegment != nil && segment == currentSegment) ? Int.max : segment
            if let existing = result[parsed.eventID], existing.rank >= rank { continue }
            result[parsed.eventID] = (state, rank)
        }
        return result.mapValues { $0.state }
    }

    /// Cursor location for a playback tick: through the timeline's segments when available (repeats), else notated order.
    static func cursorLocation(positionTick: Double, timeline: PlaybackTimeline?, layout: NotationLayout) -> NotationCursorLocation? {
        guard !layout.measures.isEmpty else { return nil }
        let t = max(0, positionTick.isFinite ? positionTick : 0)
        let whole = t.rounded(.down)
        if let timeline, !timeline.segments.isEmpty {
            let tick = Int(whole)
            let position = timeline.measurePosition(atTick: tick)
            guard layout.measures.indices.contains(position.measureIndex) else { return nil }
            let length = Double(layout.measures[position.measureIndex].length)
            let inMeasure = min(length, Double(position.tickInMeasure) + (t - whole))
            return NotationCursorLocation(measureIndex: position.measureIndex, tickInMeasure: inMeasure, segmentIndex: timeline.segmentIndex(atTick: tick))
        }
        // Notated order: last measure whose start is at or before t.
        var lo = 0
        var hi = layout.measures.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(layout.measures[mid].notatedStart) <= t { lo = mid } else { hi = mid - 1 }
        }
        let m = layout.measures[lo]
        return NotationCursorLocation(measureIndex: lo, tickInMeasure: min(Double(m.length), t - Double(m.notatedStart)), segmentIndex: nil)
    }

    /// Non-rest events of the cursor's measure sounding at the cursor (onset ≤ t < end).
    static func soundingEvents(layout: NotationLayout, at cursor: NotationCursorLocation) -> Set<UUID> {
        var result = Set<UUID>()
        for e in layout.events(inMeasure: cursor.measureIndex) where !e.isRest {
            if Double(e.onset) <= cursor.tickInMeasure && cursor.tickInMeasure < Double(e.onset + e.duration) {
                result.insert(e.id)
            }
        }
        return result
    }

    /// Colour rule: explicit feedback wins (correct green, wrong red, expected/demo/pressed in the hand colour,
    /// upcoming faded); otherwise notes sounding at the cursor take their hand colour; everything else is ink.
    static func tint(state: NoteFeedbackState?, isSounding: Bool, highlightsSounding: Bool) -> NotationNoteTint {
        switch state {
        case .correct: return .correct
        case .wrong: return .wrong
        case .expected, .demo, .pressed: return .hand
        case .upcoming: return .handFaded
        case nil: return isSounding && highlightsSounding ? .hand : .ink
        }
    }

    /// 1 for practised hands, `dimmedOpacity` for the other hand when dimming is on.
    static func opacity(hand: Hand, practiced: HandSelection, dims: Bool) -> Double {
        dims && !practiced.includes(hand) ? dimmedOpacity : 1
    }
}

// MARK: - Scroll easing

/// Eases the horizontal scroll offset after a jump (seek, loop restart, Wait-Mode step) while still tracking
/// a moving target; continuous motion follows the target directly.
struct NotationScrollTransition: Equatable, Sendable {
    /// Offset at the moment the transition started.
    var from: CGFloat = 0
    /// Start time (seconds, any monotonic reference); nil = no transition.
    var startTime: TimeInterval?
    var duration: TimeInterval = 0.35

    /// Ease-in-out cubic on 0…1.
    static func ease(_ p: Double) -> Double {
        let x = max(0, min(1, p))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Whether the transition is still running at `time`.
    func isActive(at time: TimeInterval) -> Bool {
        guard let startTime else { return false }
        return time < startTime + duration
    }

    /// Displayed offset at `time` while heading for `target`.
    func offset(target: CGFloat, at time: TimeInterval) -> CGFloat {
        guard let startTime, duration > 0, time < startTime + duration else { return target }
        let p = CGFloat(Self.ease((time - startTime) / duration))
        return from + (target - from) * p
    }

    /// Whether a playback position change is a jump that should be eased (seek, loop restart, repeat jump, Wait-Mode
    /// step) rather than followed directly.
    ///
    /// The decision is made from ticks, not from the offset change, because continuous playback can move the offset
    /// by large amounts per update at high zoom or tempo. A jump is: the tick going backwards, the tick advancing by more
    /// than 1/8 of the pulse (never less than a 32nd note, so short pulses like 3/16 still scroll directly) in one
    /// update, or the cursor landing on a measure other than the same or the next one
    /// (a repeat or D.C./D.S. jump in a playback timeline, where ticks stay continuous).
    static func isJump(fromTick oldTick: Double, toTick newTick: Double, fromMeasure oldMeasure: Int?, toMeasure newMeasure: Int?, pulseTicks: Ticks) -> Bool {
        guard oldTick.isFinite, newTick.isFinite else { return true }
        let delta = newTick - oldTick
        if delta < -0.5 { return true }
        if delta > Double(max(pulseTicks, Ticks.perQuarter)) / 8 { return true }
        if let oldMeasure, let newMeasure, newMeasure != oldMeasure, newMeasure != oldMeasure + 1 { return true }
        return false
    }

    /// A transition that starts at the currently displayed offset.
    static func starting(from displayed: CGFloat, at time: TimeInterval, duration: TimeInterval = 0.35) -> NotationScrollTransition {
        NotationScrollTransition(from: displayed, startTime: time, duration: duration)
    }
}

// MARK: - Layout cache

/// Identity of a layout request (score content + options).
struct NotationLayoutRequest: Hashable, Sendable {
    var score: Score
    var options: NotationLayoutOptions
}

/// Small LRU cache of render plans so a score is engraved once per size and mode; builds run off the main thread.
final class NotationLayoutCache: @unchecked Sendable {
    static let shared = NotationLayoutCache()

    private let lock = NSLock()
    private var entries: [(request: NotationLayoutRequest, plan: NotationRenderPlan)] = []
    private let capacity: Int

    init(capacity: Int = 6) { self.capacity = max(1, capacity) }

    /// Cached plan for a request, if any (moves it to the front).
    func cachedPlan(for request: NotationLayoutRequest) -> NotationRenderPlan? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.request == request }) else { return nil }
        let entry = entries.remove(at: i)
        entries.insert(entry, at: 0)
        return entry.plan
    }

    /// Returns the cached plan or engraves the score on a background task.
    func plan(for request: NotationLayoutRequest) async -> NotationRenderPlan {
        if let hit = cachedPlan(for: request) { return hit }
        let plan = await Task.detached(priority: .userInitiated) {
            NotationRenderPlan.make(layout: NotationLayoutEngine.layout(score: request.score, options: request.options))
        }.value
        store(plan, for: request)
        return plan
    }

    /// Inserts a plan at the front, evicting the least recently used entries.
    private func store(_ plan: NotationRenderPlan, for request: NotationLayoutRequest) {
        lock.withLock {
            entries.removeAll { $0.request == request }
            entries.insert((request, plan), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }
    }
}
