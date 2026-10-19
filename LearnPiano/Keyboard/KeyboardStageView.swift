import Foundation
import SwiftUI

/// Falling-note lanes stacked on the keyboard: the "video demonstration" region of the practice screen.
///
/// Both halves receive the same `visibleRange` and animate range changes with identical timing, so the
/// lanes stay aligned with the keys while zooming or scrolling.
// INTEGRATION: PracticeUI composes this with `KeyboardKeyStateMapper.states(from: snapshot, timeline:)`
// for `keyStates`, the player's `positionTick` (or the Wait-Mode cursor tick) for `currentTick`,
// `timeline.tickRange(of: settings.loop)` for `loopTicks` (nil when no loop is set), and routes
// `onNoteEvent` into the Input hub. While the learner drags `KeyboardMiniMap`, pass `isRangeInteractive: true`
// (from the mini map's `onDragActiveChanged`) so the keys and lanes track the finger.
struct KeyboardStageView: View {
    var visibleRange: ClosedRange<Int> = KeyboardRangeFitter.defaultRange
    var keyStates: [Int: KeyboardKeyState] = [:]
    /// Timeline for the lanes; nil hides the notes but keeps the lane area.
    var timeline: PlaybackTimeline? = nil
    var currentTick: Double = 0
    var lookaheadTicks: Ticks = Ticks.perQuarter * 8
    /// Vertical lane scale; nil fits `lookaheadTicks` into `laneHeight`.
    var pixelsPerTick: CGFloat? = nil
    /// Height of the lane area in points; 0 hides it.
    var laneHeight: CGFloat = 220
    /// Hands whose notes fall in the lanes.
    var laneHands: HandSelection = .both
    /// Active loop region in playback ticks; the lanes stop at its end and preview the wrap.
    var loopTicks: Range<Ticks>? = nil
    /// The range is being changed by direct manipulation; both halves follow it with a short ease-out.
    var isRangeInteractive: Bool = false
    var labels: KeyboardNoteLabels = .cOnly
    var showsMiddleCMarker: Bool = true
    var showsLaneNoteNames: Bool = false
    var isTouchEnabled: Bool = true
    var palette: KeyboardPalette = .standard
    var onNoteEvent: ((NoteInputEvent) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if laneHeight > 0 {
                KeyboardLanesView(timeline: timeline,
                                  currentTick: currentTick,
                                  lookaheadTicks: lookaheadTicks,
                                  pixelsPerTick: pixelsPerTick,
                                  visibleRange: visibleRange,
                                  hands: laneHands,
                                  loopTicks: loopTicks,
                                  showsNoteNames: showsLaneNoteNames,
                                  isRangeInteractive: isRangeInteractive,
                                  palette: palette)
                    .frame(height: laneHeight)
            }
            KeyboardView(visibleRange: visibleRange,
                         keyStates: keyStates,
                         labels: labels,
                         showsMiddleCMarker: showsMiddleCMarker,
                         isTouchEnabled: isTouchEnabled,
                         isRangeInteractive: isRangeInteractive,
                         palette: palette,
                         onNoteEvent: onNoteEvent)
        }
    }
}
