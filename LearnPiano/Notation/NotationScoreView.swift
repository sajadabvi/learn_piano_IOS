import SwiftUI

/// Which presentation the score view uses.
enum NotationDisplayMode: String, Hashable, CaseIterable, Sendable {
    /// One long system scrolled horizontally so the cursor stays at ~35 % of the width (landscape practice).
    case scroll
    /// Systems wrapped to the width and scrolled vertically, following the cursor's system (portrait / reading).
    case page
}

/// The engraved grand-staff score with cursor, feedback highlights, hand dimming, loop tint and measure selection.
///
/// Layout is computed once per (score, staff space, mode, width) off the main thread and cached; per-frame
/// changes in `highlight` only redraw the canvases.
struct NotationScoreView: View {
    let score: Score
    let highlight: NotationHighlightModel
    var mode: NotationDisplayMode = .scroll
    /// Points per staff space.
    var staffSpace: CGFloat = 9
    var showsFingering: Bool = true
    var palette: NotationPalette = .standard
    /// Tap on a measure.
    var onSelectMeasure: ((Int) -> Void)?
    /// Long-press and drag across measures.
    var onSelectRange: ((MeasureRange) -> Void)?

    @State private var plan: NotationRenderPlan?
    @State private var width: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(palette.sheetBackground)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: request) {
                guard let request else { return }
                if let cached = NotationLayoutCache.shared.cachedPlan(for: request) {
                    plan = cached
                    return
                }
                let built = await NotationLayoutCache.shared.plan(for: request)
                if !Task.isCancelled { plan = built }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .scroll:
            if let plan, case .scroll = plan.layout.options.mode {
                NotationScrollStage(plan: plan, highlight: highlight, palette: palette, onSelectMeasure: onSelectMeasure, onSelectRange: onSelectRange)
                    .frame(height: plan.contentSize.height)
            } else {
                palette.sheetBackground.frame(height: staffSpace * 30)
            }
        case .page:
            if let plan, case .page = plan.layout.options.mode {
                NotationPageStage(plan: plan, highlight: highlight, palette: palette, onSelectMeasure: onSelectMeasure, onSelectRange: onSelectRange)
            } else {
                palette.sheetBackground
            }
        }
    }

    /// Layout identity; page widths are quantised so live resizing does not re-engrave on every point.
    private var request: NotationLayoutRequest? {
        let layoutMode: NotationLayoutMode
        switch mode {
        case .scroll:
            layoutMode = .scroll
        case .page:
            guard width > 0 else { return nil }
            layoutMode = .page(width: (width / 16).rounded(.down) * 16)
        }
        return NotationLayoutRequest(score: score, options: NotationLayoutOptions(staffSpace: staffSpace, mode: layoutMode, showsFingering: showsFingering))
    }
}

// MARK: - Painter

/// Draws a render plan into a `GraphicsContext` whose coordinate space is the layout in points.
enum NotationCanvasPainter {
    /// Draws the measures intersecting `visible` (points) with tints, ink, highlights and the cursor.
    static func draw(_ plan: NotationRenderPlan, state: NotationDrawState, palette: NotationPalette,
                     in context: inout GraphicsContext, visible: CGRect, systems: Range<Int>? = nil) {
        let s = plan.scale
        let layout = plan.layout
        let candidates: [Int]
        if let systems {
            candidates = systems.flatMap { layout.systems.indices.contains($0) ? Array(layout.systems[$0].measureIndices) : [] }
        } else {
            candidates = Array(plan.measures.indices)
        }
        let visibleMeasures = candidates.filter { plan.measures[$0].bounds.intersects(visible) }

        // Loop region and live selection tints behind the ink.
        for i in visibleMeasures {
            let m = layout.measures[i]
            let band = CGRect(x: m.frame.minX * s, y: (m.frame.minY - 1.5) * s, width: m.frame.width * s, height: (m.frame.height + 3) * s)
            if let loop = state.loop, loop.contains(i) {
                context.fill(Path(band), with: .color(palette.accent.opacity(palette.loopTintOpacity)))
            }
            if let selection = state.selection, selection.contains(i) {
                context.fill(Path(band), with: .color(palette.accent.opacity(0.22)))
            }
        }

        let rightOpacity = state.opacity(for: .right)
        let leftOpacity = state.opacity(for: .left)
        for i in visibleMeasures {
            let ink = plan.measures[i]
            context.fill(ink.scoreInk, with: .color(palette.ink))
            if !ink.rightHandInk.isEmpty { context.fill(ink.rightHandInk, with: .color(palette.ink.opacity(rightOpacity))) }
            if !ink.leftHandInk.isEmpty { context.fill(ink.leftHandInk, with: .color(palette.ink.opacity(leftOpacity))) }
            for event in ink.events {
                let opacity = event.hand == .right ? rightOpacity : leftOpacity
                if state.states[event.id] == .expected {
                    for r in event.headRects {
                        context.fill(Path(ellipseIn: r.insetBy(dx: -0.45 * s, dy: -0.45 * s)), with: .color(palette.waiting.opacity(0.45 * opacity)))
                    }
                }
                let color = palette.color(for: state.tint(for: event.id), hand: event.hand)
                context.fill(event.path, with: .color(color.opacity(opacity)))
            }
        }

        // Cursor band and line.
        if state.showsCursor, let x = state.cursorX, let systemIndex = state.cursorSystem, layout.systems.indices.contains(systemIndex) {
            if systems == nil || systems?.contains(systemIndex) == true {
                let system = layout.systems[systemIndex]
                let top = (system.trebleTop - 2) * s
                let height = (system.bassBottom - system.trebleTop + 4) * s
                let band = CGRect(x: (x - 0.9) * s, y: top, width: 1.8 * s, height: height)
                if band.intersects(visible) {
                    context.fill(Path(roundedRect: band, cornerRadius: 0.5 * s), with: .color(palette.accent.opacity(0.14)))
                    context.fill(Path(CGRect(x: (x - 0.08) * s, y: top, width: 0.16 * s, height: height)), with: .color(palette.accent.opacity(0.75)))
                }
            }
        }
    }
}

// MARK: - Measure selection

/// Shared tap / long-press-drag selection logic for both stages.
struct NotationSelectionTracker: Equatable {
    var anchor: Int?
    var range: MeasureRange?

    /// Updates the in-progress range for the measure under the finger.
    mutating func update(anchorMeasure: Int?, currentMeasure: Int?) {
        if anchor == nil { anchor = anchorMeasure ?? currentMeasure }
        guard let a = anchor, let c = currentMeasure ?? anchor else { return }
        range = MeasureRange(start: a, end: c)
    }

    /// Finishes the gesture, returning the selected range.
    mutating func finish() -> MeasureRange? {
        defer { anchor = nil; range = nil }
        return range
    }
}

// MARK: - Scroll stage

/// Horizontal single-system presentation: a viewport-sized canvas translated so the cursor sits at 35 %.
/// Jumps are eased; dragging pans temporarily until the position moves again.
struct NotationScrollStage: View {
    let plan: NotationRenderPlan
    let highlight: NotationHighlightModel
    let palette: NotationPalette
    let onSelectMeasure: ((Int) -> Void)?
    let onSelectRange: ((MeasureRange) -> Void)?

    @State private var viewportWidth: CGFloat = 0
    @State private var transition = NotationScrollTransition()
    @State private var clock = NotationScrollClock()
    @State private var panOffset: CGFloat = 0
    @State private var panBase: CGFloat?
    @State private var selection = NotationSelectionTracker()
    @State private var settleToken = 0

    /// Cursor anchor as a fraction of the viewport width.
    static let cursorAnchor: CGFloat = 0.35

    var body: some View {
        let state = highlight.drawState(for: plan.layout)
        let target = autoOffset(state)
        let now = Date().timeIntervalSinceReferenceDate
        let animating = transition.isActive(at: now)
        let _ = settleToken
        TimelineView(.animation(paused: !animating)) { timeline in
            let offset = displayedOffset(target: target, at: timeline.date.timeIntervalSinceReferenceDate)
            Canvas(rendersAsynchronously: false) { context, size in
                let state = state.with(selection: selection.range)
                context.translateBy(x: -offset, y: 0)
                NotationCanvasPainter.draw(plan, state: state, palette: palette, in: &context,
                                           visible: CGRect(x: offset, y: 0, width: size.width, height: size.height))
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onChange(of: NotationScrollSample(tick: highlight.positionTick, measureIndex: state.cursor?.measureIndex, offset: target)) { old, new in
            let t = Date().timeIntervalSinceReferenceDate
            let sinceLast = clock.tick(at: t)
            if new.tick != old.tick, panOffset != 0, panBase == nil {
                // Playback moved while the score was panned by hand: glide back to the cursor.
                let displayed = displayedOffset(target: old.offset, at: t)
                panOffset = 0
                transition = .starting(from: displayed, at: t)
                return
            }
            let pulse = old.measureIndex.flatMap { plan.layout.measures.indices.contains($0) ? plan.layout.measures[$0].timeSignature.pulseTicks : nil } ?? Ticks.perQuarter
            if let next = transition.next(from: old, to: new, displayedOld: displayedOffset(target: old.offset, at: t),
                                          viewportWidth: viewportWidth, pulseTicks: pulse, sinceLastUpdate: sinceLast, at: t) {
                transition = next
            }
        }
        .task(id: transition) {
            // Re-evaluate once the easing has finished so the timeline pauses.
            guard let start = transition.startTime else { return }
            let remaining = start + transition.duration - Date().timeIntervalSinceReferenceDate
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining + 0.02)) }
            if !Task.isCancelled { settleToken &+= 1 }
        }
        .onTapGesture { location in
            if let m = measure(at: location, target: target) { onSelectMeasure?(m) }
        }
        .gesture(selectionGesture(target: target).exclusively(before: panGesture(target: target)))
    }

    /// Offset that keeps the cursor at the anchor.
    private func autoOffset(_ state: NotationDrawState) -> CGFloat {
        guard let x = state.cursorX, viewportWidth > 0 else { return 0 }
        return NotationLayout.scrollOffset(cursorX: x * plan.scale, viewportWidth: viewportWidth, contentWidth: plan.contentSize.width, anchor: Self.cursorAnchor)
    }

    /// Eased automatic offset plus manual pan, clamped to the content.
    private func displayedOffset(target: CGFloat, at time: TimeInterval) -> CGFloat {
        let maxOffset = max(0, plan.contentSize.width - viewportWidth)
        return max(0, min(maxOffset, transition.offset(target: target, at: time) + panOffset))
    }

    /// Measure under a point of the viewport.
    private func measure(at location: CGPoint, target: CGFloat) -> Int? {
        let offset = displayedOffset(target: target, at: Date().timeIntervalSinceReferenceDate)
        return plan.layout.measureIndex(at: CGPoint(x: (location.x + offset) / plan.scale, y: location.y / plan.scale))
    }

    /// Long press, then drag across measures to select a range.
    private func selectionGesture(target: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                selection.update(anchorMeasure: measure(at: drag.startLocation, target: target), currentMeasure: measure(at: drag.location, target: target))
            }
            .onEnded { _ in
                if let range = selection.finish() { onSelectRange?(range) }
            }
    }

    /// Plain drag pans the score temporarily.
    private func panGesture(target: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let base = panBase ?? panOffset
                if panBase == nil { panBase = base }
                let maxOffset = max(0, plan.contentSize.width - viewportWidth)
                panOffset = max(-target, min(maxOffset - target, base - value.translation.width))
            }
            .onEnded { _ in panBase = nil }
    }
}

// MARK: - Page stage

/// Vertical wrapped-systems presentation. Each system is its own lazily created canvas.
struct NotationPageStage: View {
    let plan: NotationRenderPlan
    let highlight: NotationHighlightModel
    let palette: NotationPalette
    let onSelectMeasure: ((Int) -> Void)?
    let onSelectRange: ((MeasureRange) -> Void)?

    @State private var selection = NotationSelectionTracker()
    private static let space = "NotationPage"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(plan.layout.systems, id: \.index) { system in
                        NotationSystemCanvas(plan: plan, systemIndex: system.index, highlight: highlight, palette: palette, selection: selection.range)
                            .frame(height: system.frame.height * plan.scale)
                            .id(system.index)
                    }
                }
                .contentShape(Rectangle())
                .coordinateSpace(.named(Self.space))
                .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                    if let m = measure(at: location) { onSelectMeasure?(m) }
                }
                .gesture(selectionGesture)
            }
            .background(NotationPageFollower(plan: plan, highlight: highlight, proxy: proxy))
        }
    }

    private func measure(at location: CGPoint) -> Int? {
        plan.layout.measureIndex(at: CGPoint(x: location.x / plan.scale, y: location.y / plan.scale))
    }

    private var selectionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                selection.update(anchorMeasure: measure(at: drag.startLocation), currentMeasure: measure(at: drag.location))
            }
            .onEnded { _ in
                if let range = selection.finish() { onSelectRange?(range) }
            }
    }
}

/// One system of the page presentation.
struct NotationSystemCanvas: View {
    let plan: NotationRenderPlan
    let systemIndex: Int
    let highlight: NotationHighlightModel
    let palette: NotationPalette
    let selection: MeasureRange?

    var body: some View {
        let state = highlight.drawState(for: plan.layout).with(selection: selection)
        Canvas(rendersAsynchronously: false) { context, size in
            guard plan.layout.systems.indices.contains(systemIndex) else { return }
            let minY = plan.layout.systems[systemIndex].frame.minY * plan.scale
            context.translateBy(x: 0, y: -minY)
            NotationCanvasPainter.draw(plan, state: state, palette: palette, in: &context,
                                       visible: CGRect(x: 0, y: minY, width: size.width, height: size.height),
                                       systems: systemIndex..<(systemIndex + 1))
        }
    }
}

/// Invisible helper that scrolls the page to the cursor's system whenever it changes.
struct NotationPageFollower: View {
    let plan: NotationRenderPlan
    let highlight: NotationHighlightModel
    let proxy: ScrollViewProxy

    var body: some View {
        let system = NotationHighlightResolver.cursorLocation(positionTick: highlight.positionTick, timeline: highlight.timeline, layout: plan.layout)
            .map { plan.layout.measures[$0.measureIndex].systemIndex }
        Color.clear
            .onChange(of: system) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(0, new), anchor: UnitPoint(x: 0.5, y: 0.15)) }
            }
    }
}
