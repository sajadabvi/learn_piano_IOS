import Foundation

/// Note source driven by the on-screen keyboard (or by tests and previews), so the app works without
/// hardware.
///
/// The Keyboard module's touch overlay produces `NoteInputEvent`s itself; it can pass them to `send(_:)`
/// (or to `InputHub.inject(_:)`, which routes here). `press`/`release` build events on the Input clock
/// (`ProcessInfo.systemUptime` epoch, like `SystemPracticeClock`). Thread-safe; events are delivered on the
/// calling thread. While stopped, events are dropped.
final class InputVirtualKeyboardSource: NoteInputSource, @unchecked Sendable {
    let kind: InputSourceKind = .virtualKeyboard
    let displayName: String = InputSourceKind.virtualKeyboard.displayName

    var state: InputSourceState { running.value ? .running : .idle }

    var onEvent: ((NoteInputEvent) -> Void)? {
        get { relay.onEvent }
        set { relay.onEvent = newValue }
    }

    private let relay = InputEventRelay()
    private let running = InputLockedValue(false)
    private let pressed = InputLockedValue<Set<Int>>([])

    init() {}

    /// Keys currently held down on the on-screen keyboard.
    var pressedKeys: Set<Int> { pressed.value }

    func start() {
        running.value = true
    }

    /// Stops the source and releases every key it holds.
    func stop() {
        let wasRunning = running.withValue { value -> Bool in
            defer { value = false }
            return value
        }
        let keys = pressed.withValue { keys -> [Int] in
            defer { keys.removeAll() }
            return keys.sorted()
        }
        guard wasRunning else { return }
        let now = InputClock.now
        relay.send(keys.map { NoteInputEvent.off($0, time: now, source: .virtualKeyboard) })
    }

    /// Presses a key (0…127). `time` defaults to now on the Input clock.
    func press(_ midi: Int, velocity: Double = 0.8, at time: TimeInterval? = nil) {
        send(.on(midi, velocity: velocity, time: time ?? InputClock.now, source: .virtualKeyboard))
    }

    /// Releases a key. `time` defaults to now on the Input clock.
    func release(_ midi: Int, at time: TimeInterval? = nil) {
        send(.off(midi, time: time ?? InputClock.now, source: .virtualKeyboard))
    }

    /// Forwards an event produced elsewhere (e.g. `KeyboardTouchOverlay`), re-labelled as coming from the
    /// on-screen keyboard. Out-of-range MIDI numbers and events while stopped are dropped.
    func send(_ event: NoteInputEvent) {
        guard running.value, (0...127).contains(event.midi) else { return }
        var forwarded = event
        forwarded.source = .virtualKeyboard
        pressed.withValue { keys in
            if forwarded.kind == .on { keys.insert(forwarded.midi) } else { keys.remove(forwarded.midi) }
        }
        relay.send(forwarded)
    }
}
