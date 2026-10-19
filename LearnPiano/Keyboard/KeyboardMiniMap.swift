import Foundation
import SwiftUI

/// A compact strip of all 88 keys that shows which part of the piano the keyboard is displaying, and
/// optionally the pitch extent of the current score. Dragging on it scrolls the visible window.
struct KeyboardMiniMap: View {
    /// The window the main keyboard shows.
    var visibleRange: ClosedRange<Int>
    /// Lowest…highest pitch used by the score (drawn as a bar), nil for none.
    var scoreRange: ClosedRange<Int>?
    var palette: KeyboardPalette = .standard
    /// Called with a new window of the same size when the learner drags the indicator.
    var onChangeRange: ((ClosedRange<Int>) -> Void)?
    /// Called with true when a drag starts and false when it ends. Forward it as `isRangeInteractive` to
    /// `KeyboardView` / `KeyboardLanesView` / `KeyboardStageView` so they track the finger during the drag.
    var onDragActiveChanged: ((Bool) -> Void)?

    @State private var animatedViewport: KeyboardAnimatedViewport
    @State private var isAnimating = false
    @State private var isDragging = false

    init(visibleRange: ClosedRange<Int>,
         scoreRange: ClosedRange<Int>? = nil,
         palette: KeyboardPalette = .standard,
         onChangeRange: ((ClosedRange<Int>) -> Void)? = nil,
         onDragActiveChanged: ((Bool) -> Void)? = nil) {
        self.visibleRange = visibleRange
        self.scoreRange = scoreRange
        self.palette = palette
        self.onChangeRange = onChangeRange
        self.onDragActiveChanged = onDragActiveChanged
        _animatedViewport = State(initialValue: KeyboardAnimatedViewport(range: visibleRange, duration: 0.3))
    }

    /// Geometry of the whole instrument in the mini map.
    private func fullGeometry(size: CGSize) -> KeyboardGeometry {
        KeyboardGeometry(size: size, range: KeyboardRangeFitter.fullRange)
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !isAnimating)) { frame in
                let now = frame.date.timeIntervalSinceReferenceDate
                let window = animatedViewport.viewport(at: now)
                Canvas(rendersAsynchronously: false) { context, size in
                    KeyboardMiniMapRenderer.draw(in: &context, size: size, window: window, scoreRange: scoreRange, palette: palette)
                }
                .onChange(of: frame.date) { _, date in
                    let t = date.timeIntervalSinceReferenceDate
                    if isAnimating && !animatedViewport.isAnimating(at: t) {
                        animatedViewport.prune(at: t)
                        isAnimating = false
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let onChangeRange else { return }
                        if !isDragging {
                            isDragging = true
                            onDragActiveChanged?(true)
                        }
                        let g = fullGeometry(size: proxy.size)
                        let center = Double(value.location.x / g.whiteKeyWidth) + g.viewport.firstWhiteIndex
                        let count = KeyboardRangeFitter.whiteKeyCount(in: visibleRange)
                        let newRange = KeyboardRangeFitter.range(centeredOnWhiteIndex: center, whiteKeyCount: count)
                        if newRange != visibleRange { onChangeRange(newRange) }
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        onDragActiveChanged?(false)
                    }
            )
        }
        .frame(minHeight: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onChange(of: visibleRange) { _, range in
            animatedViewport.retarget(to: range, at: Date().timeIntervalSinceReferenceDate, interactive: isDragging)
            isAnimating = true
        }
        .accessibilityLabel("Keyboard range")
        .accessibilityValue("\(MusicHelpers.noteName(midi: visibleRange.lowerBound)) to \(MusicHelpers.noteName(midi: visibleRange.upperBound))")
    }
}

/// Drawing code for `KeyboardMiniMap`.
enum KeyboardMiniMapRenderer {
    static func draw(in context: inout GraphicsContext, size: CGSize, window: KeyboardViewport, scoreRange: ClosedRange<Int>?, palette: KeyboardPalette) {
        let g = KeyboardGeometry(size: size, range: KeyboardRangeFitter.fullRange)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.mediaBackground))

        // Keys: pale strips for white keys, dark stubs for black keys.
        for midi in g.visibleWhiteKeys {
            let f = g.frame(forKey: midi).insetBy(dx: 0.25, dy: 0)
            context.fill(Path(f), with: .color(Color(white: 0.82)))
        }
        for midi in g.visibleBlackKeys {
            context.fill(Path(g.frame(forKey: midi)), with: .color(Color(white: 0.2)))
        }

        // Score extent as a thin bar along the bottom.
        if let scoreRange {
            let lo = g.frame(forKey: scoreRange.lowerBound)
            let hi = g.frame(forKey: scoreRange.upperBound)
            let bar = CGRect(x: lo.minX, y: size.height - 3, width: max(2, hi.maxX - lo.minX), height: 3)
            context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(palette.neutralAccent.mix(with: .white, by: 0.2)))
        }

        // Visible window.
        let x0 = g.minX(ofWhiteIndex: window.firstWhiteIndex)
        let x1 = g.minX(ofWhiteIndex: window.endWhiteIndex)
        let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
        context.fill(Path(rect), with: .color(palette.neutralAccent.opacity(0.28)))
        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(palette.neutralAccent), lineWidth: 1)
    }
}
