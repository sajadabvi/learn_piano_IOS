import Foundation

// MARK: - Note input (MIDI keyboard, microphone, on-screen keyboard)

/// Where a note event came from.
public enum InputSourceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case midi, microphone, virtualKeyboard

    public var displayName: String {
        switch self {
        case .midi: return "MIDI keyboard"
        case .microphone: return "Microphone"
        case .virtualKeyboard: return "On-screen keyboard"
        }
    }
}

/// A key press or release as seen by the practice engine, independent of how it was detected.
public struct NoteInputEvent: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case on, off }
    public var kind: Kind
    /// MIDI note number 0…127 (piano keys are 21…108).
    public var midi: Int
    /// 0…1 (1 = loudest). Microphone sources estimate it from level.
    public var velocity: Double
    /// Monotonic time in seconds (the Input module uses the audio/host clock; comparable across sources).
    public var time: TimeInterval
    public var source: InputSourceKind

    public init(kind: Kind, midi: Int, velocity: Double = 0.8, time: TimeInterval, source: InputSourceKind) {
        self.kind = kind
        self.midi = midi
        self.velocity = max(0, min(1, velocity))
        self.time = time
        self.source = source
    }

    public static func on(_ midi: Int, velocity: Double = 0.8, time: TimeInterval, source: InputSourceKind) -> NoteInputEvent {
        NoteInputEvent(kind: .on, midi: midi, velocity: velocity, time: time, source: source)
    }
    public static func off(_ midi: Int, time: TimeInterval, source: InputSourceKind) -> NoteInputEvent {
        NoteInputEvent(kind: .off, midi: midi, velocity: 0, time: time, source: source)
    }
}

/// Lifecycle state of a note source.
public enum InputSourceState: String, Codable, Hashable, Sendable {
    case idle, starting, running, permissionDenied, unavailable, failed
}

/// A producer of note events. Implementations: CoreMIDI, microphone pitch detection, the on-screen keyboard.
/// Delivery is on an arbitrary thread; consumers must hop to the main actor themselves.
public protocol NoteInputSource: AnyObject {
    var kind: InputSourceKind { get }
    var state: InputSourceState { get }
    /// Human-readable description, e.g. the connected device name.
    var displayName: String { get }
    /// Set by the consumer (the Input hub). Called for every note on/off.
    var onEvent: ((NoteInputEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// A monotonic clock. Injected into engines so tests are deterministic.
public protocol PracticeClock: AnyObject {
    /// Seconds, monotonic, arbitrary origin.
    var now: TimeInterval { get }
}

/// Real clock based on the system uptime.
public final class SystemPracticeClock: PracticeClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Clock that tests advance by hand.
public final class ManualPracticeClock: PracticeClock {
    public var now: TimeInterval
    public init(now: TimeInterval = 0) { self.now = now }
    public func advance(by seconds: TimeInterval) { now += seconds }
}
