import Foundation

/// Pure bookkeeping of which keys are currently held, merged across several note sources.
///
/// Semantics chosen for a practice engine that treats every forwarded note-on as an attack:
/// - A note-on is forwarded when no *other* source already holds the key. A note-on from a source that
///   already holds the key is a re-attack (the microphone re-triggers a repeated note this way) and is
///   forwarded as well, refreshing the on-time.
/// - A note-off is forwarded only when the *last* holding source releases the key; releases of keys that
///   are not held are dropped so stale or duplicated offs never reach the engine.
struct InputHeldNoteTracker: Sendable, Equatable {
    /// Which sources hold each MIDI number.
    private(set) var holders: [Int: Set<InputSourceKind>] = [:]
    /// Time of the most recent forwarded note-on per held MIDI number.
    private(set) var onTimes: [Int: TimeInterval] = [:]

    init() {}

    /// The MIDI numbers currently held by at least one source.
    var heldNotes: Set<Int> { Set(holders.keys) }

    /// Whether the key is held by any source.
    func isHeld(_ midi: Int) -> Bool { holders[midi] != nil }

    /// Seconds for which the key has been held at `now`, or nil when it is not held.
    func holdDuration(of midi: Int, at now: TimeInterval) -> TimeInterval? {
        guard let on = onTimes[midi] else { return nil }
        return max(0, now - on)
    }

    /// Records the event and returns the event to forward downstream, or nil when it is a duplicate.
    @discardableResult
    mutating func apply(_ event: NoteInputEvent) -> NoteInputEvent? {
        switch event.kind {
        case .on:
            var sources = holders[event.midi] ?? []
            let heldByOthers = !sources.subtracting([event.source]).isEmpty
            sources.insert(event.source)
            holders[event.midi] = sources
            if heldByOthers { return nil }
            onTimes[event.midi] = event.time
            return event
        case .off:
            guard var sources = holders[event.midi], sources.contains(event.source) else { return nil }
            sources.remove(event.source)
            if sources.isEmpty {
                holders[event.midi] = nil
                onTimes[event.midi] = nil
                return event
            }
            holders[event.midi] = sources
            return nil
        }
    }

    /// Releases every key held by `source` (used when a source stops or disconnects).
    /// Returns the note-offs to forward, in ascending MIDI order.
    mutating func releaseAll(from source: InputSourceKind, at time: TimeInterval) -> [NoteInputEvent] {
        var released: [NoteInputEvent] = []
        for midi in holders.keys.sorted() where holders[midi]?.contains(source) == true {
            if let forwarded = apply(.off(midi, time: time, source: source)) { released.append(forwarded) }
        }
        return released
    }

    /// Releases everything. Returns the note-offs to forward, in ascending MIDI order.
    mutating func releaseAll(at time: TimeInterval) -> [NoteInputEvent] {
        var released: [NoteInputEvent] = []
        for midi in holders.keys.sorted() {
            // Attribute the synthetic release to one of the holders so `apply` accepts it.
            guard let sources = holders[midi], let source = sources.sorted(by: { $0.rawValue < $1.rawValue }).first else { continue }
            for s in sources where s != source { _ = apply(.off(midi, time: time, source: s)) }
            if let forwarded = apply(.off(midi, time: time, source: source)) { released.append(forwarded) }
        }
        return released
    }

    /// Forgets all state without producing events.
    mutating func reset() {
        holders.removeAll()
        onTimes.removeAll()
    }
}
