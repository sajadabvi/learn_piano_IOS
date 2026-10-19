import Foundation
import SwiftUI

// MARK: - Lane math

/// One falling-note rectangle above the keyboard.
///
/// A tied note is drawn as a chain of rects that touch: the first has `isAttack == true`, every rect but the
/// last has `tiedForward == true`, and only the outer ends of the chain are rounded and stroked.
struct KeyboardLaneRect: Hashable {
    /// `TimelineEvent.id` of the event this note belongs to.
    var eventID: String
    var midi: Int
    var hand: Hand
    /// Rectangle in lane coordinates (y grows downward; the keyboard is at `laneHeight`).
    var rect: CGRect
    /// The note is struck at its onset (false for tie continuations, which join the note below them).
    var isAttack: Bool
    /// The note is tied into the next note on the same key, so its top joins that note without a gap.
    var tiedForward: Bool
    /// The note has started (its onset is at or before the current tick).
    var isSounding: Bool
    /// 0 for the note at its real playback position; n > 0 for its copy shown after the loop wrapped n times.
    var loopPass: Int = 0
}

/// Pure geometry for the Synthesia-style falling notes: future notes descend from the top and the one
/// starting at the current tick touches the keyboard.
enum KeyboardLaneLayout {
    /// Upper bound on how many loop wraps are laid out (protects against a tiny loop and a huge lookahead).
    static let maximumLoopWraps = 64

    /// Scale that makes exactly `lookaheadTicks` fit in `height`.
    static func pixelsPerTick(fitting lookaheadTicks: Ticks, in height: CGFloat) -> CGFloat {
        height / CGFloat(max(1, lookaheadTicks))
    }

    /// Vertical position of a tick: the current tick is at the bottom (`laneHeight`), later ticks higher.
    static func y(forTick tick: Double, currentTick: Double, pixelsPerTick: CGFloat, laneHeight: CGFloat) -> CGFloat {
        laneHeight - CGFloat(tick - currentTick) * pixelsPerTick
    }

    /// Rectangles for every sounding or upcoming note of the selected hands.
    ///
    /// - Parameters:
    ///   - loopTicks: active loop region in playback ticks (end exclusive). While the cursor is before its end,
    ///     notes at or after the loop end are dropped, notes are clipped to it, and the start of the loop is
    ///     repeated above the loop end (as often as the lookahead reaches) so the learner sees the wrap coming.
    ///     Pass `timeline.tickRange(of: settings.loop)`.
    ///   - gap: points removed from the top of each note that is not tied forward, so consecutive strikes of
    ///     one key stay distinct while a tie chain stays one continuous bar.
    ///   - minimumHeight: very short notes are stretched to at least this height.
    static func rects(timeline: PlaybackTimeline,
                      currentTick: Double,
                      lookaheadTicks: Ticks,
                      pixelsPerTick: CGFloat,
                      laneHeight: CGFloat,
                      geometry: KeyboardGeometry,
                      hands: HandSelection = .both,
                      loopTicks: Range<Ticks>? = nil,
                      gap: CGFloat = 0,
                      minimumHeight: CGFloat = 2) -> [KeyboardLaneRect] {
        let horizon = currentTick + Double(max(0, lookaheadTicks))
        let events = timeline.events
        // The loop only shapes the lanes while the cursor has not passed its end; beyond it playback is linear.
        let loop: Range<Ticks>? = loopTicks.flatMap { l in (!l.isEmpty && currentTick < Double(l.upperBound)) ? l : nil }
        var out: [KeyboardLaneRect] = []

        /// Appends the rects of one event displayed `shift` ticks later than its real onset.
        func emit(_ e: TimelineEvent, shift: Ticks, pass: Int) {
            guard !e.isRest, hands.includes(e.hand) else { return }
            let end = loop.map { min(e.endTick, $0.upperBound) } ?? e.endTick
            let onset = Double(e.tick + shift)
            let displayedEnd = Double(end + shift)
            guard end > e.tick, displayedEnd > currentTick, onset < horizon else { return }
            let bottom = min(laneHeight, y(forTick: onset, currentTick: currentTick, pixelsPerTick: pixelsPerTick, laneHeight: laneHeight))
            let top = max(0, y(forTick: displayedEnd, currentTick: currentTick, pixelsPerTick: pixelsPerTick, laneHeight: laneHeight))
            let attacks = Set(e.attackPitches)
            for p in e.pitches where geometry.isVisible(p) {
                let isAttack = attacks.contains(p)
                let tiedForward = continuesTie(e, pitch: p, in: events, before: loop?.upperBound)
                var noteTop = top + (tiedForward ? 0 : gap)
                var noteBottom = bottom
                if noteBottom - noteTop < minimumHeight { noteTop = noteBottom - minimumHeight }
                if noteTop < 0 { noteTop = 0 }
                if noteBottom > laneHeight { noteBottom = laneHeight }
                guard noteBottom > 0, noteTop < laneHeight, noteBottom > noteTop else { continue }
                let span = geometry.laneSpan(forKey: p)
                out.append(KeyboardLaneRect(
                    eventID: e.id,
                    midi: p,
                    hand: e.hand,
                    rect: CGRect(x: span.minX, y: noteTop, width: span.width, height: noteBottom - noteTop),
                    isAttack: isAttack,
                    tiedForward: tiedForward,
                    isSounding: onset <= currentTick,
                    loopPass: pass
                ))
            }
        }

        // Notes at their real position (cut at the loop end while looping).
        let realLimit = loop.map { min(horizon, Double($0.upperBound)) } ?? horizon
        for e in events {
            if Double(e.tick) >= realLimit { break }
            emit(e, shift: 0, pass: 0)
        }

        // Upcoming loop passes, stacked above the loop end.
        if let loop {
            let length = loop.upperBound - loop.lowerBound
            let first = firstEventIndex(atOrAfter: loop.lowerBound, in: events)
            var pass = 1
            while pass <= maximumLoopWraps, Double(loop.lowerBound + pass * length) < horizon {
                let shift = pass * length
                var j = first
                while j < events.count, events[j].tick < loop.upperBound, Double(events[j].tick + shift) < horizon {
                    emit(events[j], shift: shift, pass: pass)
                    j += 1
                }
                pass += 1
            }
        }
        return out
    }

    /// Whether pitch `p` of `e` is tied into a continuation that starts exactly where `e` ends (same hand and
    /// voice, sounding `p` without striking it). Continuations at or after `limit` (the loop end) do not count,
    /// because playback jumps away before they sound.
    static func continuesTie(_ e: TimelineEvent, pitch p: Int, in events: [TimelineEvent], before limit: Ticks?) -> Bool {
        guard e.notes.contains(where: { $0.midi == p && $0.tieStart }) else { return false }
        let end = e.endTick
        if let limit, end >= limit { return false }
        var j = firstEventIndex(atOrAfter: end, in: events)
        while j < events.count, events[j].tick == end {
            let c = events[j]
            if c.hand == e.hand, c.voice == e.voice, c.pitches.contains(p), !c.attackPitches.contains(p) { return true }
            j += 1
        }
        return false
    }

    /// Index of the first event whose onset is at or after `tick` (`events.count` if none); `events` must be
    /// sorted by tick, as `PlaybackTimeline.events` is.
    static func firstEventIndex(atOrAfter tick: Ticks, in events: [TimelineEvent]) -> Int {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].tick < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - View

/// Falling-note lanes drawn above `KeyboardView`, aligned to the same visible range. Give it the playback
/// timeline and the current (fractional) tick every frame; it draws descending rectangles per hand.
struct KeyboardLanesView: View {
    /// Timeline whose notes are shown; nil draws an empty lane area.
    var timeline: PlaybackTimeline?
    /// Current playback tick (fractional, from the player or the practice cursor).
    var currentTick: Double
    /// How far ahead notes become visible, in ticks (default: eight quarters).
    var lookaheadTicks: Ticks = Ticks.perQuarter * 8
    /// Vertical scale; nil fits `lookaheadTicks` into the view height.
    var pixelsPerTick: CGFloat? = nil
    /// Visible key range; must match the keyboard below for the lanes to line up.
    var visibleRange: ClosedRange<Int> = KeyboardRangeFitter.defaultRange
    /// Which hands' notes are shown.
    var hands: HandSelection = .both
    /// Active loop region in playback ticks; the lanes clip at its end and preview the wrap (see
    /// `KeyboardLaneLayout.rects`).
    var loopTicks: Range<Ticks>? = nil
    /// Draw note names inside notes that are large enough.
    var showsNoteNames: Bool = false
    /// The range is being changed by direct manipulation (e.g. a mini-map drag); follow it with a short
    /// ease-out instead of the regular zoom animation.
    var isRangeInteractive: Bool = false
    var palette: KeyboardPalette = .standard

    @State private var animatedViewport: KeyboardAnimatedViewport
    @State private var isAnimating = false

    init(timeline: PlaybackTimeline?,
         currentTick: Double,
         lookaheadTicks: Ticks = Ticks.perQuarter * 8,
         pixelsPerTick: CGFloat? = nil,
         visibleRange: ClosedRange<Int> = KeyboardRangeFitter.defaultRange,
         hands: HandSelection = .both,
         loopTicks: Range<Ticks>? = nil,
         showsNoteNames: Bool = false,
         isRangeInteractive: Bool = false,
         palette: KeyboardPalette = .standard) {
        self.timeline = timeline
        self.currentTick = currentTick
        self.lookaheadTicks = lookaheadTicks
        self.pixelsPerTick = pixelsPerTick
        self.visibleRange = visibleRange
        self.hands = hands
        self.loopTicks = loopTicks
        self.showsNoteNames = showsNoteNames
        self.isRangeInteractive = isRangeInteractive
        self.palette = palette
        _animatedViewport = State(initialValue: KeyboardAnimatedViewport(range: visibleRange))
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !isAnimating)) { frame in
                let now = frame.date.timeIntervalSinceReferenceDate
                let viewport = animatedViewport.viewport(at: now)
                Canvas(rendersAsynchronously: false) { context, size in
                    let geometry = KeyboardGeometry(size: size, viewport: viewport)
                    KeyboardLaneRenderer.draw(in: &context,
                                              size: size,
                                              geometry: geometry,
                                              timeline: timeline,
                                              currentTick: currentTick,
                                              lookaheadTicks: lookaheadTicks,
                                              pixelsPerTick: pixelsPerTick ?? KeyboardLaneLayout.pixelsPerTick(fitting: lookaheadTicks, in: size.height),
                                              hands: hands,
                                              loopTicks: loopTicks,
                                              showsNoteNames: showsNoteNames,
                                              palette: palette)
                }
                .onChange(of: frame.date) { _, date in
                    let t = date.timeIntervalSinceReferenceDate
                    if isAnimating && !animatedViewport.isAnimating(at: t) {
                        animatedViewport.prune(at: t)
                        isAnimating = false
                    }
                }
            }
        }
        .background(palette.mediaBackground)
        .onChange(of: visibleRange) { _, range in
            animatedViewport.retarget(to: range, at: Date().timeIntervalSinceReferenceDate, interactive: isRangeInteractive)
            isAnimating = true
        }
        .accessibilityLabel("Upcoming notes")
        .accessibilityHidden(true)
    }
}

/// Drawing code for `KeyboardLanesView`, kept separate so it is one pure function of its inputs.
enum KeyboardLaneRenderer {
    static func draw(in context: inout GraphicsContext,
                     size: CGSize,
                     geometry: KeyboardGeometry,
                     timeline: PlaybackTimeline?,
                     currentTick: Double,
                     lookaheadTicks: Ticks,
                     pixelsPerTick: CGFloat,
                     hands: HandSelection,
                     loopTicks: Range<Ticks>?,
                     showsNoteNames: Bool,
                     palette: KeyboardPalette) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.mediaBackground))

        // Octave guides at every C.
        for midi in geometry.visibleWhiteKeys where ((midi % 12) + 12) % 12 == 0 {
            let x = geometry.frame(forKey: midi).minX
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(palette.laneGuide), lineWidth: 1)
        }

        if let timeline {
            // Loop boundary: a dashed line where the loop wraps back to its start.
            if let loop = loopTicks, !loop.isEmpty, currentTick < Double(loop.upperBound) {
                let wrapY = KeyboardLaneLayout.y(forTick: Double(loop.upperBound), currentTick: currentTick,
                                                 pixelsPerTick: pixelsPerTick, laneHeight: size.height)
                if wrapY > 0, wrapY < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: wrapY))
                    line.addLine(to: CGPoint(x: size.width, y: wrapY))
                    context.stroke(line, with: .color(palette.laneHitLine.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }

            let rects = KeyboardLaneLayout.rects(timeline: timeline,
                                                 currentTick: currentTick,
                                                 lookaheadTicks: lookaheadTicks,
                                                 pixelsPerTick: pixelsPerTick,
                                                 laneHeight: size.height,
                                                 geometry: geometry,
                                                 hands: hands,
                                                 loopTicks: loopTicks,
                                                 gap: 2,
                                                 minimumHeight: 3)
            for r in rects {
                let base = palette.handColor(r.hand)
                let fill = r.isSounding ? base.mix(with: .white, by: 0.25) : base
                let radius = min(3, r.rect.width * 0.25, r.rect.height / 2)
                // y grows downward: the onset is the bottom edge, the end the top edge. Only the outer ends of
                // a tie chain are rounded; the joins stay square so the chain reads as one held note.
                let topRadius = r.tiedForward ? 0 : radius
                let bottomRadius = r.isAttack ? radius : 0
                let body = Path(roundedRect: r.rect, cornerRadii: RectangleCornerRadii(topLeading: topRadius,
                                                                                       bottomLeading: bottomRadius,
                                                                                       bottomTrailing: bottomRadius,
                                                                                       topTrailing: topRadius))
                context.fill(body, with: .color(fill))
                context.stroke(outline(of: r.rect, radius: radius, closedTop: !r.tiedForward, closedBottom: r.isAttack),
                               with: .color(base.mix(with: .black, by: 0.3)), lineWidth: 1)
                if showsNoteNames, r.isAttack, r.rect.height >= 16, r.rect.width >= 14 {
                    let label = Text(MusicHelpers.pitchClassName(midi: r.midi))
                        .font(.system(size: min(11, r.rect.width * 0.5), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.9))
                    context.draw(label, at: CGPoint(x: r.rect.midX, y: r.rect.maxY - 9), anchor: .center)
                }
            }
        }

        var hitLine = Path()
        hitLine.move(to: CGPoint(x: 0, y: size.height - 0.5))
        hitLine.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(hitLine, with: .color(palette.laneHitLine), lineWidth: 1)
    }

    /// Outline of one note rect that omits the edges joining it to the rest of its tie chain.
    ///
    /// - Parameters:
    ///   - closedTop: draw the top (end) edge with rounded corners; false when the note is tied forward.
    ///   - closedBottom: draw the bottom (onset) edge with rounded corners; false for a tie continuation.
    static func outline(of rect: CGRect, radius: CGFloat, closedTop: Bool, closedBottom: Bool) -> Path {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        var path = Path()
        // Left edge, from top to bottom.
        if closedTop {
            path.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - (closedBottom ? r : 0)))
        // Bottom edge.
        if closedBottom {
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        // Right edge, from bottom to top, closing the top corner when the top is closed.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + (closedTop ? r : 0)))
        if closedTop {
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
        return path
    }
}
