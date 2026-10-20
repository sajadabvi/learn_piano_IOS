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

/// How the router tells the learner's notes from echoes the microphone picks up.
struct InputHubEchoConfiguration: Hashable, Sendable {
    /// With MIDI enabled, a microphone note-on for a key whose MIDI note-on lies within this many seconds of it
    /// (either side) is the microphone hearing the digital piano. The microphone confirms ~70 ms after the
    /// onset and tap buffering adds 50–100 ms, so a staccato key is often MIDI-released by then.
    var midiEchoWindow: TimeInterval = 0.35
    /// Microphone note-ons are also dropped this long after the app stops sounding a pitch (string and room
    /// decay, speaker latency).
    var appSoundingTail: TimeInterval = 0.15
    /// …and this long before the app starts sounding it (microphone onsets are stamped slightly early).
    var appSoundingLead: TimeInterval = 0.03
    /// Semitones above a sounded pitch whose microphone detections are treated as its echo: the pitch itself,
    /// its octave, twelfth and double octave (partials 1–4, where octave errors and harmonic ghosts land).
    var echoIntervals: Set<Int> = [0, 12, 19, 24]
    /// App-sounding intervals that ended this long before the newest one started are forgotten.
    var appSoundingRetention: TimeInterval = 5

    init() {}
}

/// Thread-safe heart of `InputHub`: filters events by the selected source kinds, keeps the merged
/// held-note state, drops microphone echoes, and fans events out to subscribers. Runs on whatever thread a
/// source delivers on.
///
/// Echo suppression (microphone note-ons that are not the learner's attacks):
/// - With MIDI enabled, the microphone hears the digital piano: a microphone note-on is dropped while the
///   key (or a pitch an `echoIntervals` step below it) is MIDI-held or had a MIDI note-on within
///   `midiEchoWindow` of the microphone event.
/// - The app's own playback (other hands in Wait Mode, the accompaniment in Just Play, Listen): pitches
///   registered with `noteAppSounding(pitches:from:until:)` suppress microphone note-ons on the same keys
///   and their partials within the interval plus `appSoundingTail`.
/// A dropped microphone note-on also swallows the microphone's matching note-off, so it never reaches the
/// engine as a stray release.
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
    private var echo: InputHubEchoConfiguration
    /// Time of the latest MIDI note-on per key.
    private var lastMIDIOnTime: [Int: TimeInterval] = [:]
    /// Keys whose microphone note-on was dropped as an echo; their next microphone note-off is swallowed.
    private var swallowedMicrophoneKeys: Set<Int> = []
    /// Intervals during which the app itself sounds each key.
    private var appSounding: [Int: [ClosedRange<TimeInterval>]] = [:]
    private var enabled: Set<InputSourceKind>
    private var running = false
    private var sequence = 0
    private var primaryHandler: ((NoteInputEvent) -> Void)?
    private var handlers: [Int: (NoteInputEvent) -> Void] = [:]
    private var continuations: [Int: AsyncStream<NoteInputEvent>.Continuation] = [:]
    private var nextID = 0

    init(selection: InputHubSelection, echo: InputHubEchoConfiguration = InputHubEchoConfiguration()) {
        enabled = selection.enabledKinds
        self.echo = echo
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

    /// Echo-suppression parameters.
    var echoConfiguration: InputHubEchoConfiguration {
        get { lock.withLock { echo } }
        set { lock.withLock { echo = newValue } }
    }

    /// Registers that the app itself sounds `pitches` (MIDI numbers) from `from` until `until` (Input clock
    /// seconds, the clock of `NoteInputEvent.time`), so the microphone does not report them as the learner's
    /// notes. Overlapping registrations simply add up.
    func noteAppSounding(pitches: [Int], from: TimeInterval, until: TimeInterval) {
        guard !pitches.isEmpty, until.isFinite, from.isFinite else { return }
        let interval = min(from, until)...max(from, until)
        lock.withLock {
            let horizon = interval.lowerBound - echo.appSoundingRetention
            for key in appSounding.keys {
                appSounding[key]?.removeAll { $0.upperBound < horizon }
                if appSounding[key]?.isEmpty == true { appSounding[key] = nil }
            }
            for pitch in Set(pitches) where (0...127).contains(pitch) {
                appSounding[pitch, default: []].append(interval)
            }
        }
    }

    /// Forgets every app-sounding registration (playback stopped or seeked).
    func clearAppSounding() {
        lock.withLock { appSounding.removeAll() }
    }

    /// Changes the accepted kinds; keys held by kinds that are no longer accepted are released.
    /// Returns what was delivered (the releases).
    @discardableResult
    func setEnabledKinds(_ kinds: Set<InputSourceKind>, at time: TimeInterval) -> Routed {
        let routed: Routed = lock.withLock {
            let removed = enabled.subtracting(kinds)
            enabled = kinds
            if removed.contains(.microphone) { swallowedMicrophoneKeys.removeAll() }
            if removed.contains(.midi) { lastMIDIOnTime.removeAll() }
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
            guard running, enabled.contains(event.source), (0...127).contains(event.midi) else {
                return Routed(events: [], snapshot: snapshotLocked())
            }
            if event.source == .midi, event.kind == .on { lastMIDIOnTime[event.midi] = event.time }
            if event.source == .microphone {
                switch event.kind {
                case .on where isMicrophoneEchoLocked(event):
                    swallowedMicrophoneKeys.insert(event.midi)
                    return Routed(events: [], snapshot: snapshotLocked())
                case .off where swallowedMicrophoneKeys.contains(event.midi):
                    swallowedMicrophoneKeys.remove(event.midi)
                    return Routed(events: [], snapshot: snapshotLocked())
                case .on:
                    // A genuine microphone attack replaces any pending swallow for the key.
                    swallowedMicrophoneKeys.remove(event.midi)
                default:
                    break
                }
            }
            guard let forwarded = tracker.apply(event) else { return Routed(events: [], snapshot: snapshotLocked()) }
            return makeRoutedLocked([forwarded])
        }
        deliver(routed.events)
        return routed
    }

    /// Releases every held key from `kind` (a source stopped or failed). Returns what was delivered.
    @discardableResult
    func releaseAll(from kind: InputSourceKind, at time: TimeInterval) -> Routed {
        let routed = lock.withLock {
            if kind == .microphone { swallowedMicrophoneKeys.removeAll() }
            return makeRoutedLocked(tracker.releaseAll(from: kind, at: time))
        }
        deliver(routed.events)
        return routed
    }

    /// Releases every held key. Returns what was delivered.
    @discardableResult
    func releaseAll(at time: TimeInterval) -> Routed {
        let routed = lock.withLock {
            swallowedMicrophoneKeys.removeAll()
            return makeRoutedLocked(tracker.releaseAll(at: time))
        }
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

    /// Whether a microphone note-on is an echo of the MIDI keyboard or of the app's own playback.
    private func isMicrophoneEchoLocked(_ event: NoteInputEvent) -> Bool {
        let midiEnabled = enabled.contains(.midi)
        for interval in echo.echoIntervals {
            let source = event.midi - interval
            guard (0...127).contains(source) else { continue }
            if midiEnabled {
                if tracker.holders[source]?.contains(.midi) == true { return true }
                if let on = lastMIDIOnTime[source], abs(event.time - on) <= echo.midiEchoWindow { return true }
            }
            if let intervals = appSounding[source], intervals.contains(where: {
                event.time >= $0.lowerBound - echo.appSoundingLead && event.time <= $0.upperBound + echo.appSoundingTail
            }) { return true }
        }
        return false
    }

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
