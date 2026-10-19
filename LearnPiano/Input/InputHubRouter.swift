import Foundation

/// Which physical input the learner uses. The on-screen keyboard is always accepted in addition.
enum InputHubSelection: String, Codable, Hashable, CaseIterable, Sendable {
    case midi
    case microphone
    case both
    /// Only the on-screen keyboard (no hardware is listened to).
    case onScreenOnly

    /// Maps the persisted `UserSettings.preferredInput` to a selection.
    init(preferred kind: InputSourceKind) {
        switch kind {
        case .midi: self = .midi
        case .microphone: self = .microphone
        case .virtualKeyboard: self = .onScreenOnly
        }
    }

    /// Source kinds whose events are accepted (always including the on-screen keyboard).
    var enabledKinds: Set<InputSourceKind> {
        switch self {
        case .midi: return [.midi, .virtualKeyboard]
        case .microphone: return [.microphone, .virtualKeyboard]
        case .both: return [.midi, .microphone, .virtualKeyboard]
        case .onScreenOnly: return [.virtualKeyboard]
        }
    }

    /// The kind that best describes the selection (used for `NoteInputSource.kind`).
    var primaryKind: InputSourceKind {
        switch self {
        case .midi, .both: return .midi
        case .microphone: return .microphone
        case .onScreenOnly: return .virtualKeyboard
        }
    }

    /// The equivalent persisted preference (`.both` is stored as MIDI, its primary kind).
    var preferredKind: InputSourceKind { primaryKind }

    /// Label for pickers.
    var displayName: String {
        switch self {
        case .midi: return "MIDI keyboard"
        case .microphone: return "Microphone"
        case .both: return "MIDI + Microphone"
        case .onScreenOnly: return "On-screen keyboard"
        }
    }
}

/// Cancels a hub subscription when cancelled explicitly or when released.
final class InputHubSubscription: @unchecked Sendable {
    private let cancellation = InputLockedValue<(() -> Void)?>(nil)

    init(_ cancel: @escaping () -> Void) {
        cancellation.value = cancel
    }

    /// Stops delivery; idempotent.
    func cancel() {
        let action = cancellation.withValue { value -> (() -> Void)? in
            defer { value = nil }
            return value
        }
        action?()
    }

    deinit { cancel() }
}

/// Thread-safe heart of `InputHub`: filters events by the selected source kinds, keeps the merged
/// held-note state, and fans events out to subscribers. Runs on whatever thread a source delivers on.
///
/// State changes happen under a lock; subscribers are called after the lock is released (so a handler may
/// call back into the hub), in the order events were accepted per calling thread.
final class InputHubRouter: @unchecked Sendable {
    /// The merged state after an accepted event, with a sequence number so the main actor can drop stale
    /// snapshots that arrive out of order from different source threads.
    struct Snapshot: Sendable, Equatable {
        var sequence: Int
        var heldOnTimes: [Int: TimeInterval]
    }

    /// Result of routing one event.
    struct Routed: Sendable {
        /// Events to deliver downstream (empty when the event was filtered or a duplicate).
        var events: [NoteInputEvent]
        /// State after routing.
        var snapshot: Snapshot
    }

    private let lock = NSLock()
    private var tracker = InputHeldNoteTracker()
    private var enabled: Set<InputSourceKind>
    private var running = false
    private var sequence = 0
    private var primaryHandler: ((NoteInputEvent) -> Void)?
    private var handlers: [Int: (NoteInputEvent) -> Void] = [:]
    private var continuations: [Int: AsyncStream<NoteInputEvent>.Continuation] = [:]
    private var nextID = 0

    init(selection: InputHubSelection) {
        enabled = selection.enabledKinds
    }

    // MARK: Configuration

    /// Whether events are accepted at all (the hub is started).
    var isRunning: Bool {
        get { lock.withLock { running } }
        set { lock.withLock { running = newValue } }
    }

    /// The `NoteInputSource.onEvent` consumer of the hub.
    var onEvent: ((NoteInputEvent) -> Void)? {
        get { lock.withLock { primaryHandler } }
        set { lock.withLock { primaryHandler = newValue } }
    }

    /// Kinds currently accepted.
    var enabledKinds: Set<InputSourceKind> { lock.withLock { enabled } }

    /// Changes the accepted kinds; keys held by kinds that are no longer accepted are released.
    /// Returns what was delivered (the releases).
    @discardableResult
    func setEnabledKinds(_ kinds: Set<InputSourceKind>, at time: TimeInterval) -> Routed {
        let routed: Routed = lock.withLock {
            let removed = enabled.subtracting(kinds)
            enabled = kinds
            var released: [NoteInputEvent] = []
            for kind in removed.sorted(by: { $0.rawValue < $1.rawValue }) {
                released += tracker.releaseAll(from: kind, at: time)
            }
            return makeRoutedLocked(released)
        }
        deliver(routed.events)
        return routed
    }

    // MARK: Routing

    /// Accepts one event from a source (or an injection) and delivers what survives.
    @discardableResult
    func receive(_ event: NoteInputEvent) -> Routed {
        let routed: Routed = lock.withLock {
            guard running, enabled.contains(event.source), (0...127).contains(event.midi),
                  let forwarded = tracker.apply(event) else {
                return Routed(events: [], snapshot: snapshotLocked())
            }
            return makeRoutedLocked([forwarded])
        }
        deliver(routed.events)
        return routed
    }

    /// Releases every held key from `kind` (a source stopped or failed). Returns what was delivered.
    @discardableResult
    func releaseAll(from kind: InputSourceKind, at time: TimeInterval) -> Routed {
        let routed = lock.withLock { makeRoutedLocked(tracker.releaseAll(from: kind, at: time)) }
        deliver(routed.events)
        return routed
    }

    /// Releases every held key. Returns what was delivered.
    @discardableResult
    func releaseAll(at time: TimeInterval) -> Routed {
        let routed = lock.withLock { makeRoutedLocked(tracker.releaseAll(at: time)) }
        deliver(routed.events)
        return routed
    }

    /// Keys held right now, with the time of their (latest) attack.
    var heldOnTimes: [Int: TimeInterval] { lock.withLock { tracker.onTimes } }

    // MARK: Subscribers

    /// Adds a handler called on the delivering thread; returns its id for `removeHandler`.
    func addHandler(_ handler: @escaping (NoteInputEvent) -> Void) -> Int {
        lock.withLock {
            nextID += 1
            handlers[nextID] = handler
            return nextID
        }
    }

    /// Removes a handler added with `addHandler`.
    func removeHandler(_ id: Int) {
        lock.withLock { handlers[id] = nil }
    }

    /// Registers a stream continuation; it is finished when removed.
    func addContinuation(_ continuation: AsyncStream<NoteInputEvent>.Continuation) -> Int {
        lock.withLock {
            nextID += 1
            continuations[nextID] = continuation
            return nextID
        }
    }

    /// Removes (and finishes) a continuation.
    func removeContinuation(_ id: Int) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.finish()
    }

    /// Finishes every stream (hub deallocation).
    func finishAllStreams() {
        let all = lock.withLock { () -> [AsyncStream<NoteInputEvent>.Continuation] in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in all { continuation.finish() }
    }

    // MARK: Private

    private func makeRoutedLocked(_ events: [NoteInputEvent]) -> Routed {
        if !events.isEmpty { sequence += 1 }
        return Routed(events: events, snapshot: snapshotLocked())
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(sequence: sequence, heldOnTimes: tracker.onTimes)
    }

    /// Calls the primary handler, the extra handlers and the streams outside the lock.
    private func deliver(_ events: [NoteInputEvent]) {
        guard !events.isEmpty else { return }
        let (primary, extra, streams) = lock.withLock {
            (primaryHandler, handlers.sorted { $0.key < $1.key }.map(\.value), Array(continuations.values))
        }
        for event in events {
            primary?(event)
            for handler in extra { handler(event) }
            for stream in streams { stream.yield(event) }
        }
    }
}
