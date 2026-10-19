import Foundation
import SwiftUI

// MARK: - KeyboardView

/// The on-screen 88-key piano.
///
/// It is drawn in one `Canvas` pass (no per-key views), so it renders at the display's refresh rate.
/// Per-key states come from the caller as `[midi: KeyboardKeyState]`; changes cross-fade over ~120 ms and
/// depressed keys darken and shrink slightly. The visible range zooms/scrolls smoothly when it changes.
/// Multi-touch input (chords, glissando) is reported through `onNoteEvent` as `NoteInputEvent`s with
/// `InputSourceKind.virtualKeyboard`.
struct KeyboardView: View {
    /// Keys shown edge to edge (snapped outward to white keys). Use `KeyboardRangeFitter` to compute it.
    var visibleRange: ClosedRange<Int>
    /// Caller-supplied state per MIDI number; absent keys are neutral.
    var keyStates: [Int: KeyboardKeyState]
    /// Note-name labels.
    var labels: KeyboardNoteLabels
    /// Draw a dot on middle C.
    var showsMiddleCMarker: Bool
    /// Accept touches as note input.
    var isTouchEnabled: Bool
    /// Show keys under the learner's fingers as `.pressed` unless the caller supplies a state for them.
    var highlightsTouches: Bool
    /// The range is being changed by direct manipulation (e.g. a mini-map drag); follow it with a short
    /// ease-out instead of the regular zoom animation.
    var isRangeInteractive: Bool
    var palette: KeyboardPalette
    /// Note on/off from touch input.
    var onNoteEvent: ((NoteInputEvent) -> Void)?

    @State private var tracker: KeyboardTransitionTracker
    @State private var animatedViewport: KeyboardAnimatedViewport
    @State private var heldByTouch: Set<Int> = []
    @State private var isAnimating = false

    init(visibleRange: ClosedRange<Int> = KeyboardRangeFitter.defaultRange,
         keyStates: [Int: KeyboardKeyState] = [:],
         labels: KeyboardNoteLabels = .cOnly,
         showsMiddleCMarker: Bool = true,
         isTouchEnabled: Bool = true,
         highlightsTouches: Bool = true,
         isRangeInteractive: Bool = false,
         palette: KeyboardPalette = .standard,
         onNoteEvent: ((NoteInputEvent) -> Void)? = nil) {
        self.visibleRange = visibleRange
        self.keyStates = keyStates
        self.labels = labels
        self.showsMiddleCMarker = showsMiddleCMarker
        self.isTouchEnabled = isTouchEnabled
        self.highlightsTouches = highlightsTouches
        self.isRangeInteractive = isRangeInteractive
        self.palette = palette
        self.onNoteEvent = onNoteEvent
        _tracker = State(initialValue: KeyboardTransitionTracker(states: keyStates))
        _animatedViewport = State(initialValue: KeyboardAnimatedViewport(range: visibleRange))
    }

    /// Caller states merged with locally held keys.
    private var effectiveStates: [Int: KeyboardKeyState] {
        highlightsTouches ? KeyboardKeyStateMapper.merging(keyStates, heldByTouch: heldByTouch) : keyStates
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !isAnimating)) { frame in
                let now = frame.date.timeIntervalSinceReferenceDate
                let viewport = animatedViewport.viewport(at: now)
                Canvas(rendersAsynchronously: false) { context, size in
                    let geometry = KeyboardGeometry(size: size, viewport: viewport)
                    KeyboardRenderer.draw(in: &context,
                                          geometry: geometry,
                                          tracker: tracker,
                                          time: now,
                                          palette: palette,
                                          labels: labels,
                                          showsMiddleCMarker: showsMiddleCMarker)
                }
                .onChange(of: frame.date) { _, date in
                    let t = date.timeIntervalSinceReferenceDate
                    if isAnimating && !tracker.isAnimating(at: t) && !animatedViewport.isAnimating(at: t) {
                        tracker.prune(at: t)
                        animatedViewport.prune(at: t)
                        isAnimating = false
                    }
                }
            }
            .overlay {
                KeyboardTouchOverlay(animatedViewport: animatedViewport,
                                     isEnabled: isTouchEnabled,
                                     onEvent: onNoteEvent,
                                     onHeldKeysChanged: { held in heldByTouch = held })
            }
        }
        .background(palette.keyOutline)
        .onChange(of: effectiveStates, initial: false) { _, states in
            tracker.update(to: states, at: Date().timeIntervalSinceReferenceDate)
            isAnimating = true
        }
        .onChange(of: visibleRange) { _, range in
            animatedViewport.retarget(to: range, at: Date().timeIntervalSinceReferenceDate, interactive: isRangeInteractive)
            isAnimating = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piano keyboard")
        .accessibilityValue(accessibilitySummary)
    }

    /// Short description of the expected keys for VoiceOver.
    private var accessibilitySummary: String {
        let expected = keyStates.compactMap { (midi, s) -> Int? in
            if case .expected = s { return midi }
            return nil
        }.sorted()
        guard !expected.isEmpty else { return "" }
        return "Expected: " + expected.map { MusicHelpers.noteName(midi: $0) }.joined(separator: ", ")
    }
}

// MARK: - Renderer

/// Draws the keyboard into a `GraphicsContext`. A pure function of geometry, animation state and palette.
enum KeyboardRenderer {
    /// Horizontal shrink of a fully depressed key.
    static let depressedWidthScale: CGFloat = 0.04
    /// Vertical shrink of a fully depressed key.
    static let depressedHeightScale: CGFloat = 0.03
    /// Darkening of a fully depressed key.
    static let depressedDarkening = 0.14

    static func draw(in context: inout GraphicsContext,
                     geometry: KeyboardGeometry,
                     tracker: KeyboardTransitionTracker,
                     time: TimeInterval,
                     palette: KeyboardPalette,
                     labels: KeyboardNoteLabels,
                     showsMiddleCMarker: Bool) {
        let whiteWidth = geometry.whiteKeyWidth
        let whiteRadius = min(4, whiteWidth * 0.12)
        let blackRadius = min(3, geometry.blackKeyWidth * 0.15)
        let labelSize = max(8, min(13, whiteWidth * 0.32))

        for midi in geometry.visibleWhiteKeys {
            let look = look(forKey: midi, isBlack: false, tracker: tracker, time: time, palette: palette)
            let rect = depressedRect(geometry.frame(forKey: midi), amount: look.depression)
            let path = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(bottomLeading: whiteRadius, bottomTrailing: whiteRadius))
            context.fill(path, with: .color(look.fill))
            context.stroke(path, with: .color(palette.keyOutline), lineWidth: 1)

            let labelShown = labels.shows(midi: midi) && whiteWidth >= 14
            if labelShown {
                let text = Text(MusicHelpers.noteName(midi: midi))
                    .font(.system(size: labelSize, weight: .medium, design: .rounded))
                    .foregroundStyle(look.label)
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.maxY - labelSize), anchor: .center)
            }
            if showsMiddleCMarker, midi == 60 {
                let r = max(2, min(3.5, whiteWidth * 0.1))
                let y = rect.maxY - (labelShown ? labelSize * 2.2 : labelSize)
                let dot = Path(ellipseIn: CGRect(x: rect.midX - r, y: y - r, width: 2 * r, height: 2 * r))
                context.fill(dot, with: .color(look.toState == nil ? palette.middleCMarker : look.label))
            }
        }

        for midi in geometry.visibleBlackKeys {
            let look = look(forKey: midi, isBlack: true, tracker: tracker, time: time, palette: palette)
            let rect = depressedRect(geometry.frame(forKey: midi), amount: look.depression)
            let path = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(bottomLeading: blackRadius, bottomTrailing: blackRadius))
            context.fill(path, with: .color(look.fill))
            // Lighter front edge for a hint of depth.
            let lip = CGRect(x: rect.minX + 1, y: rect.maxY - max(2, rect.height * 0.06), width: rect.width - 2, height: max(2, rect.height * 0.06) - 1)
            context.fill(Path(roundedRect: lip, cornerRadius: 1), with: .color(.white.opacity(0.12)))

            if labels == .all, geometry.blackKeyWidth >= 11 {
                let text = Text(MusicHelpers.pitchClassName(midi: midi))
                    .font(.system(size: max(7, min(10, geometry.blackKeyWidth * 0.5)), weight: .medium, design: .rounded))
                    .foregroundStyle(look.label)
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.maxY - 12), anchor: .center)
            }
        }
    }

    /// Blended fill, label color and depression amount for one key at `time`.
    struct KeyLook {
        var fill: Color
        var label: Color
        /// 0 = at rest, 1 = fully depressed.
        var depression: CGFloat
        var toState: KeyboardKeyState?
    }

    static func look(forKey midi: Int, isBlack: Bool, tracker: KeyboardTransitionTracker, time: TimeInterval, palette: KeyboardPalette) -> KeyLook {
        let blend = tracker.blend(forKey: midi, at: time)
        let toFill = palette.fill(for: blend.to, isBlack: isBlack)
        let fill: Color
        if blend.progress >= 1 || blend.from == blend.to {
            fill = toFill
        } else {
            fill = palette.fill(for: blend.from, isBlack: isBlack).mix(with: toFill, by: blend.progress)
        }
        let fromDepressed: Double = (blend.from?.isDepressed ?? false) ? 1 : 0
        let toDepressed: Double = (blend.to?.isDepressed ?? false) ? 1 : 0
        let depression = fromDepressed + (toDepressed - fromDepressed) * blend.progress
        let darkened = depression > 0 ? fill.mix(with: .black, by: depressedDarkening * depression) : fill
        return KeyLook(fill: darkened,
                       label: palette.labelColor(for: blend.progress < 0.5 ? blend.from : blend.to, isBlack: isBlack),
                       depression: CGFloat(depression),
                       toState: blend.to)
    }

    /// Shrinks a key frame towards its bottom center by the depression amount.
    static func depressedRect(_ frame: CGRect, amount: CGFloat) -> CGRect {
        guard amount > 0 else { return frame }
        let w = frame.width * (1 - depressedWidthScale * amount)
        let h = frame.height * (1 - depressedHeightScale * amount)
        return CGRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
    }
}
