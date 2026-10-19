import Foundation

/// Converts Universal MIDI Packet words, as delivered by `MIDIInputPortCreateWithProtocol`, into a MIDI 1.0
/// byte stream for `InputMIDIParser`.
///
/// Only messages that matter for note input survive: MIDI 1.0 channel voice messages (UMP type 2) pass
/// through unchanged; MIDI 2.0 note on/off and controller messages (type 4) are down-converted following the
/// MIDI 2.0 translation rules (a MIDI 2.0 note-on never means note-off, so its 7-bit velocity is at least 1).
/// System, SysEx, utility and stream messages are skipped, which is safe because system real-time bytes
/// never affect notes and system common/exclusive messages only cancel running status (and UMP never uses
/// running status).
enum InputMIDIUniversalPacket {
    /// Number of 32-bit words in a UMP message, indexed by its message type (top nibble of the first word).
    static let wordCounts: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    /// MIDI 1.0 bytes for a sequence of UMP words (any number of complete messages).
    static func midi1Bytes<Words: Collection>(fromWords words: Words) -> [UInt8] where Words.Element == UInt32 {
        var bytes: [UInt8] = []
        var index = words.startIndex
        while index != words.endIndex {
            let first = words[index]
            let type = Int(first >> 28)
            let count = wordCounts[type]
            // Collect the message's words (a truncated trailing message is ignored).
            var message: [UInt32] = [first]
            var cursor = words.index(after: index)
            while message.count < count, cursor != words.endIndex {
                message.append(words[cursor])
                cursor = words.index(after: cursor)
            }
            index = cursor
            guard message.count == count else { break }
            switch type {
            case 0x2:
                appendMIDI1ChannelVoice(first, to: &bytes)
            case 0x4:
                appendMIDI2ChannelVoice(message[0], message[1], to: &bytes)
            default:
                continue
            }
        }
        return bytes
    }

    /// A MIDI 1.0 channel voice message in a 32-bit UMP: `[type 2][group][status][data1][data2]`.
    private static func appendMIDI1ChannelVoice(_ word: UInt32, to bytes: inout [UInt8]) {
        let status = UInt8((word >> 16) & 0xFF)
        guard status >= 0x80, status < 0xF0 else { return }
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        bytes.append(status)
        bytes.append(data1)
        if InputMIDIParser.dataByteCount(forStatus: status) == 2 { bytes.append(data2) }
    }

    /// A MIDI 2.0 channel voice message (64 bits); note on/off and the all-notes-off controllers only.
    private static func appendMIDI2ChannelVoice(_ word0: UInt32, _ word1: UInt32, to bytes: inout [UInt8]) {
        let opcode = UInt8((word0 >> 20) & 0x0F)
        let channel = UInt8((word0 >> 16) & 0x0F)
        let index = UInt8((word0 >> 8) & 0x7F)
        switch opcode {
        case 0x9:
            let velocity16 = UInt16(word1 >> 16)
            let velocity7 = UInt8(max(1, velocity16 >> 9))
            bytes += [0x90 | channel, index, velocity7]
        case 0x8:
            let velocity16 = UInt16(word1 >> 16)
            bytes += [0x80 | channel, index, UInt8(velocity16 >> 9)]
        case 0xB:
            bytes += [0xB0 | channel, index, UInt8(word1 >> 25)]
        default:
            break
        }
    }
}

/// Per-device note bookkeeping that turns parsed MIDI messages into `NoteInputEvent`s.
///
/// Channel-agnostic: a key counts as held while it is held on any channel. A keyboard in layer mode that
/// sends one key press on two channels therefore produces one note-on and one note-off. A second note-on on
/// a channel that already holds the key (some devices omit the note-off between fast repeats) is reported
/// as a fresh attack. All Notes Off / All Sound Off on a channel releases every key held on that channel.
struct InputMIDINoteMapper: Sendable, Equatable {
    /// Channels currently holding each note number.
    private(set) var held: [UInt8: Set<UInt8>] = [:]

    init() {}

    /// The MIDI numbers currently held on any channel.
    var heldNotes: Set<Int> { Set(held.keys.map(Int.init)) }

    /// Events produced by one message, stamped with `time` (seconds on the Input clock).
    mutating func map(_ message: InputMIDIMessage, time: TimeInterval) -> [NoteInputEvent] {
        switch message {
        case let .noteOn(channel, note, velocity):
            var channels = held[note] ?? []
            let isNewKey = channels.isEmpty
            let isRestrike = channels.contains(channel)
            channels.insert(channel)
            held[note] = channels
            guard isNewKey || isRestrike else { return [] }
            return [.on(Int(note), velocity: Double(velocity) / 127, time: time, source: .midi)]
        case let .noteOff(channel, note, _):
            guard var channels = held[note], channels.contains(channel) else { return [] }
            channels.remove(channel)
            if channels.isEmpty {
                held[note] = nil
                return [.off(Int(note), time: time, source: .midi)]
            }
            held[note] = channels
            return []
        case let .allNotesOff(channel):
            var events: [NoteInputEvent] = []
            for note in held.keys.sorted() {
                guard var channels = held[note], channels.contains(channel) else { continue }
                channels.remove(channel)
                if channels.isEmpty {
                    held[note] = nil
                    events.append(.off(Int(note), time: time, source: .midi))
                } else {
                    held[note] = channels
                }
            }
            return events
        case .other:
            return []
        }
    }

    /// Releases every held key (device removed or source stopped), in ascending order.
    mutating func releaseAll(at time: TimeInterval) -> [NoteInputEvent] {
        let events = held.keys.sorted().map { NoteInputEvent.off(Int($0), time: time, source: .midi) }
        held.removeAll()
        return events
    }
}

/// Receive-side state shared by all MIDI sources of one input port: a running-status parser and a note
/// mapper per connected endpoint, keyed by the connection token CoreMIDI hands back as `srcConnRefCon`.
///
/// Thread-safe: CoreMIDI calls `handle` on its own high-priority thread while the main actor registers and
/// unregisters endpoints. A key held on two devices at once is released only when the last one lets go.
final class InputMIDIReceiver: @unchecked Sendable {
    /// Parsing state for one connected endpoint.
    private struct Stream {
        var parser = InputMIDIParser()
        var mapper = InputMIDINoteMapper()
    }

    private let lock = NSLock()
    private var streams: [Int: Stream] = [:]

    init() {}

    /// Starts tracking a newly connected endpoint.
    func register(token: Int) {
        lock.withLock { streams[token] = Stream() }
    }

    /// Stops tracking an endpoint and returns note-offs for keys only it was holding.
    func unregister(token: Int, at time: TimeInterval) -> [NoteInputEvent] {
        lock.withLock {
            guard var stream = streams.removeValue(forKey: token) else { return [] }
            return stream.mapper.releaseAll(at: time).filter { !isHeldLocked($0.midi) }
        }
    }

    /// Forgets every endpoint and returns note-offs for all held keys.
    func unregisterAll(at time: TimeInterval) -> [NoteInputEvent] {
        lock.withLock {
            let notes = streams.values.reduce(into: Set<Int>()) { $0.formUnion($1.mapper.heldNotes) }
            streams.removeAll()
            return notes.sorted().map { NoteInputEvent.off($0, time: time, source: .midi) }
        }
    }

    /// Decodes the UMP words of one packet from the endpoint registered as `token`.
    /// Unknown tokens (a packet racing an unregister) produce nothing.
    func handle<Words: Collection>(words: Words, time: TimeInterval, token: Int) -> [NoteInputEvent] where Words.Element == UInt32 {
        handle(bytes: InputMIDIUniversalPacket.midi1Bytes(fromWords: words), time: time, token: token)
    }

    /// Parses MIDI 1.0 bytes from the endpoint registered as `token`.
    func handle(bytes: [UInt8], time: TimeInterval, token: Int) -> [NoteInputEvent] {
        guard !bytes.isEmpty else { return [] }
        return lock.withLock {
            guard var stream = streams[token] else { return [] }
            var events: [NoteInputEvent] = []
            for message in stream.parser.parse(bytes) {
                events += stream.mapper.map(message, time: time)
            }
            streams[token] = stream
            // A release from one device must not end a key another device still holds.
            return events.filter { $0.kind == .on || !isHeldLocked($0.midi) }
        }
    }

    /// Whether any registered endpoint holds the key. Caller holds the lock.
    private func isHeldLocked(_ midi: Int) -> Bool {
        guard (0...127).contains(midi) else { return false }
        return streams.values.contains { $0.mapper.held[UInt8(midi)] != nil }
    }
}
