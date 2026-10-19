import Foundation

/// A decoded MIDI 1.0 message, reduced to what note input needs.
enum InputMIDIMessage: Hashable, Sendable {
    /// Key pressed. `velocity` is always 1…127 (a note-on with velocity 0 is reported as `noteOff`).
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    /// Key released. `velocity` is the release velocity (0 for a velocity-0 note-on).
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    /// Controller 123 (All Notes Off) or 120 (All Sound Off): every key on the channel is released.
    case allNotesOff(channel: UInt8)
    /// Any other channel message (controllers, program change, pitch bend…), kept for diagnostics.
    case other(status: UInt8, data: [UInt8])
}

/// Incremental MIDI 1.0 byte-stream parser.
///
/// Feed it the raw bytes of each packet in arrival order; it keeps the running status between calls so a
/// packet may start with data bytes that continue the previous packet's status. System real-time bytes
/// (0xF8…0xFF) are transparent and may appear in the middle of a message; system exclusive and system
/// common messages are skipped and cancel running status, as the specification requires.
///
/// One parser instance should be used per MIDI source, because running status is per stream.
struct InputMIDIParser: Sendable {
    /// Status byte of the message currently being assembled (also the running status).
    private var runningStatus: UInt8?
    /// Data bytes collected for the current message.
    private var pending: [UInt8] = []
    /// Whether we are inside a system exclusive message (bytes are discarded until 0xF7).
    private var inSystemExclusive = false
    /// Remaining data bytes to skip for a system common message.
    private var systemCommonBytesToSkip = 0

    init() {}

    /// Forgets the running status and any partially received message.
    mutating func reset() {
        runningStatus = nil
        pending.removeAll(keepingCapacity: true)
        inSystemExclusive = false
        systemCommonBytesToSkip = 0
    }

    /// Parses a chunk of bytes and returns every complete message it finishes.
    mutating func parse<Bytes: Sequence>(_ bytes: Bytes) -> [InputMIDIMessage] where Bytes.Element == UInt8 {
        var messages: [InputMIDIMessage] = []
        for byte in bytes {
            if let message = consume(byte) { messages.append(message) }
        }
        return messages
    }

    /// Consumes one byte; returns a message when it completes one.
    private mutating func consume(_ byte: UInt8) -> InputMIDIMessage? {
        // System real-time: transparent, never affects running status.
        if byte >= 0xF8 { return nil }

        if byte >= 0xF0 {
            // System common / exclusive: cancels running status.
            runningStatus = nil
            pending.removeAll(keepingCapacity: true)
            switch byte {
            case 0xF0:
                inSystemExclusive = true
                systemCommonBytesToSkip = 0
            case 0xF7:
                inSystemExclusive = false
                systemCommonBytesToSkip = 0
            case 0xF1, 0xF3:
                inSystemExclusive = false
                systemCommonBytesToSkip = 1
            case 0xF2:
                inSystemExclusive = false
                systemCommonBytesToSkip = 2
            default: // 0xF4, 0xF5 (undefined), 0xF6 (tune request): no data
                inSystemExclusive = false
                systemCommonBytesToSkip = 0
            }
            return nil
        }

        if byte >= 0x80 {
            // Channel status byte: starts a new message and becomes the running status.
            inSystemExclusive = false
            systemCommonBytesToSkip = 0
            runningStatus = byte
            pending.removeAll(keepingCapacity: true)
            return nil
        }

        // Data byte.
        if inSystemExclusive { return nil }
        if systemCommonBytesToSkip > 0 {
            systemCommonBytesToSkip -= 1
            return nil
        }
        guard let status = runningStatus else { return nil } // stray data byte with no status
        pending.append(byte)
        guard pending.count >= InputMIDIParser.dataByteCount(forStatus: status) else { return nil }
        let message = InputMIDIParser.makeMessage(status: status, data: pending)
        pending.removeAll(keepingCapacity: true)
        return message
    }

    /// Number of data bytes a channel message with this status carries.
    static func dataByteCount(forStatus status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1 // program change, channel pressure
        default: return 2
        }
    }

    /// Builds the message for a complete status + data byte group.
    private static func makeMessage(status: UInt8, data: [UInt8]) -> InputMIDIMessage {
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x90:
            let velocity = data[1]
            if velocity == 0 { return .noteOff(channel: channel, note: data[0], velocity: 0) }
            return .noteOn(channel: channel, note: data[0], velocity: velocity)
        case 0x80:
            return .noteOff(channel: channel, note: data[0], velocity: data[1])
        case 0xB0 where data[0] == 120 || data[0] == 123:
            return .allNotesOff(channel: channel)
        default:
            return .other(status: status, data: data)
        }
    }
}
