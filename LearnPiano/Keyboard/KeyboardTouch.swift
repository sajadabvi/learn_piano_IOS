import Foundation
import SwiftUI
import UIKit

// MARK: - Pure touch → note logic

/// Maps touch positions to velocities.
enum KeyboardTouchMapper {
    /// Softest velocity produced by a touch at the very top of a key.
    static let minimumVelocity = 0.35
    /// Velocity from the vertical position inside a key: the lower on the key (closer to the player), the louder.
    static func velocity(y: CGFloat, keyFrame: CGRect) -> Double {
        guard keyFrame.height > 0 else { return 0.8 }
        let fraction = Double(max(0, min(1, (y - keyFrame.minY) / keyFrame.height)))
        return minimumVelocity + (1 - minimumVelocity) * fraction
    }
}

/// Tracks several simultaneous touches on the keyboard and turns them into note on/off events,
/// including glissando (a finger sliding across keys) and several fingers on one key (the key is released
/// only when the last finger leaves). Pure and deterministic; `ID` identifies a touch for its lifetime.
struct KeyboardTouchTracker<ID: Hashable> {
    /// Key currently under each live touch (nil when the finger is off the keys).
    private(set) var keyByTouch: [ID: Int?] = [:]
    /// Number of touches holding each key.
    private(set) var holdCount: [Int: Int] = [:]

    init() {}

    /// Keys with at least one finger on them.
    var heldKeys: Set<Int> { Set(holdCount.keys) }

    /// A finger landed on `midi` (nil = outside the keys). Returns the events to emit.
    mutating func begin(id: ID, midi: Int?, velocity: Double, time: TimeInterval) -> [NoteInputEvent] {
        var events: [NoteInputEvent] = []
        if let previous = keyByTouch[id] ?? nil { events += release(previous, time: time) }
        keyByTouch[id] = midi
        if let midi { events += press(midi, velocity: velocity, time: time) }
        return events
    }

    /// A finger moved; when it crosses onto another key the old key is released and the new one struck.
    mutating func move(id: ID, midi: Int?, velocity: Double, time: TimeInterval) -> [NoteInputEvent] {
        guard keyByTouch.keys.contains(id) else { return begin(id: id, midi: midi, velocity: velocity, time: time) }
        let previous = keyByTouch[id] ?? nil
        guard previous != midi else { return [] }
        var events: [NoteInputEvent] = []
        if let previous { events += release(previous, time: time) }
        keyByTouch[id] = midi
        if let midi { events += press(midi, velocity: velocity, time: time) }
        return events
    }

    /// A finger lifted (or the touch was cancelled).
    mutating func end(id: ID, time: TimeInterval) -> [NoteInputEvent] {
        guard let previous = keyByTouch.removeValue(forKey: id) else { return [] }
        guard let previous else { return [] }
        return release(previous, time: time)
    }

    /// Releases everything (e.g. when the view disappears).
    mutating func endAll(time: TimeInterval) -> [NoteInputEvent] {
        let keys = holdCount.keys.sorted()
        keyByTouch = [:]
        holdCount = [:]
        return keys.map { NoteInputEvent.off($0, time: time, source: .virtualKeyboard) }
    }

    private mutating func press(_ midi: Int, velocity: Double, time: TimeInterval) -> [NoteInputEvent] {
        let count = (holdCount[midi] ?? 0) + 1
        holdCount[midi] = count
        return count == 1 ? [NoteInputEvent.on(midi, velocity: velocity, time: time, source: .virtualKeyboard)] : []
    }

    private mutating func release(_ midi: Int, time: TimeInterval) -> [NoteInputEvent] {
        guard let count = holdCount[midi] else { return [] }
        if count <= 1 {
            holdCount.removeValue(forKey: midi)
            return [NoteInputEvent.off(midi, time: time, source: .virtualKeyboard)]
        }
        holdCount[midi] = count - 1
        return []
    }
}

// MARK: - UIKit multi-touch overlay

/// Transparent multi-touch surface laid over the keyboard canvas. SwiftUI gestures are single-touch, so
/// this uses `UIView` touch handling to support chords and glissandi.
///
/// Events use `InputSourceKind.virtualKeyboard` and `ProcessInfo.systemUptime` as their clock (the same
/// basis as `SystemPracticeClock`).
// INTEGRATION: feed `onEvent` into the Input hub's virtual-keyboard injection point (e.g. `InputHub.inject(_:)`)
// so the on-screen keyboard behaves like any other `NoteInputSource`.
struct KeyboardTouchOverlay: UIViewRepresentable {
    /// The keyboard's (possibly animating) viewport; touches are hit-tested against the viewport it
    /// yields at the moment of each touch, so hit testing stays exact during zoom/scroll transitions.
    var animatedViewport: KeyboardAnimatedViewport
    /// When false the overlay ignores touches entirely (they pass through).
    var isEnabled: Bool
    /// Note on/off for every touch change.
    var onEvent: ((NoteInputEvent) -> Void)?
    /// Called whenever the set of keys under fingers changes (for local "pressed" highlighting).
    var onHeldKeysChanged: ((Set<Int>) -> Void)?

    func makeUIView(context: Context) -> KeyboardTouchUIView {
        let view = KeyboardTouchUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: KeyboardTouchUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: KeyboardTouchUIView) {
        view.animatedViewport = animatedViewport
        view.isUserInteractionEnabled = isEnabled
        view.onEvent = onEvent
        view.onHeldKeysChanged = onHeldKeysChanged
        if !isEnabled { view.releaseAll() }
    }
}

/// The `UIView` behind `KeyboardTouchOverlay`.
@MainActor
final class KeyboardTouchUIView: UIView {
    /// Viewport (and any in-flight transition) used to hit-test touches against keys.
    var animatedViewport = KeyboardAnimatedViewport(range: KeyboardRangeFitter.defaultRange)
    var onEvent: ((NoteInputEvent) -> Void)?
    var onHeldKeysChanged: ((Set<Int>) -> Void)?

    private var tracker = KeyboardTouchTracker<ObjectIdentifier>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
    }

    /// Geometry matching what the keyboard canvas draws right now (same clock as `TimelineView`).
    private var geometry: KeyboardGeometry {
        KeyboardGeometry(size: bounds.size, viewport: animatedViewport.viewport(at: Date().timeIntervalSinceReferenceDate))
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Key and velocity for a touch location.
    private func resolve(_ touch: UITouch) -> (midi: Int?, velocity: Double) {
        let g = geometry
        let p = touch.location(in: self)
        guard let midi = g.key(at: p) else { return (nil, 0) }
        return (midi, KeyboardTouchMapper.velocity(y: p.y, keyFrame: g.frame(forKey: midi)))
    }

    private func emit(_ events: [NoteInputEvent]) {
        guard !events.isEmpty else { return }
        events.forEach { onEvent?($0) }
        onHeldKeysChanged?(tracker.heldKeys)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let t = now
        var out: [NoteInputEvent] = []
        for touch in touches {
            let r = resolve(touch)
            out += tracker.begin(id: ObjectIdentifier(touch), midi: r.midi, velocity: r.velocity, time: t)
        }
        emit(out)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let t = now
        var out: [NoteInputEvent] = []
        for touch in touches {
            let r = resolve(touch)
            out += tracker.move(id: ObjectIdentifier(touch), midi: r.midi, velocity: r.velocity, time: t)
        }
        emit(out)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let t = now
        var out: [NoteInputEvent] = []
        for touch in touches { out += tracker.end(id: ObjectIdentifier(touch), time: t) }
        emit(out)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// Sends note-off for every held key (used when touch input is disabled or the view goes away).
    func releaseAll() {
        emit(tracker.endAll(time: now))
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseAll() }
    }
}
