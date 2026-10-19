import Foundation

/// A value guarded by a lock so it can be read and written from any thread.
///
/// Input sources receive data on CoreMIDI's and the audio engine's threads while their UI-facing state lives
/// on the main actor; the few values both sides need (the event handler, a lifecycle mirror for the
/// nonisolated `NoteInputSource` requirements, enabled source kinds) are kept in boxes like this one.
/// Critical sections are tiny (copying a value), so contention is negligible.
final class InputLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    /// Wraps an initial value.
    init(_ value: Value) { storage = value }

    /// Thread-safe read/write of the whole value.
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    /// Mutates the value in place under the lock and returns the closure's result.
    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&storage) }
    }
}

/// Thread-safe holder for a `NoteInputSource.onEvent` handler.
///
/// `send` copies the handler out of the lock before calling it, so a handler may replace itself or call back
/// into the source without deadlocking.
final class InputEventRelay: @unchecked Sendable {
    private let handler = InputLockedValue<((NoteInputEvent) -> Void)?>(nil)

    init() {}

    /// The consumer's callback (nil = events are dropped).
    var onEvent: ((NoteInputEvent) -> Void)? {
        get { handler.value }
        set { handler.value = newValue }
    }

    /// Delivers one event on the calling thread.
    func send(_ event: NoteInputEvent) {
        handler.value?(event)
    }

    /// Delivers events in order on the calling thread.
    func send(_ events: [NoteInputEvent]) {
        guard !events.isEmpty, let deliver = handler.value else { return }
        for event in events { deliver(event) }
    }
}

/// Runs work on the main actor from any thread, preserving submission order.
enum InputMainActor {
    /// Runs `body` synchronously when already on the main thread, otherwise enqueues it on the main queue
    /// (FIFO, unlike unstructured tasks, so state updates arrive in the order they were produced).
    static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
