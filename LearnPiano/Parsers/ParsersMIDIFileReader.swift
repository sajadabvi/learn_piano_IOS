import Foundation

/// The musically relevant content of a Standard MIDI File, in the file's own tick resolution.
struct ParsersMIDIFileContent: Hashable, Sendable {
    /// A sounding note between a note-on and its note-off.
    struct NoteSpan: Hashable, Sendable {
        var start: Int
        var end: Int
        var pitch: Int
        var velocity: Int
        var track: Int
        var channel: Int
    }

    /// A Set Tempo meta event.
    struct TempoChange: Hashable, Sendable {
        var tick: Int
        var microsecondsPerQuarter: Int
        /// Quarter-note beats per minute.
        var bpm: Double { 60_000_000.0 / Double(max(1, microsecondsPerQuarter)) }
    }

    /// A Time Signature meta event.
    struct MeterChange: Hashable, Sendable {
        var tick: Int
        var numerator: Int
        var denominator: Int
    }

    /// A Key Signature meta event.
    struct KeyChange: Hashable, Sendable {
        var tick: Int
        var fifths: Int
        var minor: Bool
    }

    /// 0, 1 or 2.
    var format = 1
    /// Ticks per quarter note. For SMPTE-timed files this is derived for an assumed 120 BPM.
    var ticksPerQuarter = 480
    /// Whether the header used SMPTE (frames per second) timing rather than ticks per quarter.
    var isSMPTE = false
    var trackCount = 0
    var notes: [NoteSpan] = []
    var tempos: [TempoChange] = []
    var meters: [MeterChange] = []
    var keys: [KeyChange] = []
    /// Track Name (meta 0x03) per track index.
    var trackNames: [Int: String] = [:]
    /// Latest tick of any event in any track.
    var lastTick = 0
}

/// Reads Standard MIDI Files (format 0, 1 and — sequentially merged — 2): header and track chunks, variable-length
/// quantities, running status, meta events (tempo, time signature, key signature, track name, end of track),
/// SysEx skipping and note on/off pairing per channel. A RIFF `RMID` wrapper is accepted.
///
/// Running status is kept across meta and SysEx events (strictly they cancel it, but many writers rely on it and
/// keeping it never misreads a well-formed file, because a status byte always follows those events there).
enum ParsersMIDIFileReader {
    /// Parses the file. Throws `ImportError.malformed` when no header can be read; damage inside a track becomes a
    /// diagnostic and the readable part of the track is kept.
    static func read(_ data: Data, log: inout ParsersDiagnosticLog) throws -> ParsersMIDIFileContent {
        let b = [UInt8](data)
        guard let headerStart = findHeader(b) else { throw ImportError.malformed("No MIDI header (MThd) found.") }
        var p = headerStart + 4
        guard p + 4 <= b.count else { throw ImportError.malformed("The MIDI header is truncated.") }
        let headerLength = Int(be32(b, p)); p += 4
        guard headerLength >= 6, p + 6 <= b.count else { throw ImportError.malformed("The MIDI header is truncated.") }
        var content = ParsersMIDIFileContent()
        content.format = Int(be16(b, p))
        content.trackCount = Int(be16(b, p + 2))
        let division = be16(b, p + 4)
        if division & 0x8000 != 0 {
            // SMPTE: high byte = -frames per second, low byte = ticks per frame. Map seconds to quarters at 120 BPM.
            let fps = -Int(Int8(bitPattern: UInt8(division >> 8)))
            let perFrame = Int(division & 0xFF)
            let effectiveFPS = fps == 29 ? 29.97 : Double(max(1, fps))
            content.ticksPerQuarter = max(1, Int((effectiveFPS * Double(max(1, perFrame)) / 2).rounded()))
            content.isSMPTE = true
            log.add(.warning, "The file uses SMPTE timing; it was interpreted at 120 BPM and needs a tempo check.")
        } else {
            content.ticksPerQuarter = max(1, Int(division))
            if division == 0 { log.add(.warning, "The MIDI header declares 0 ticks per quarter; 480 is assumed."); content.ticksPerQuarter = 480 }
        }
        if content.format > 2 { log.add(.warning, "Unknown MIDI file format \(content.format); reading it like format 1.") }
        if content.format == 2 { log.add(.warning, "MIDI format 2 (independent patterns) is played back to back.") }

        p += headerLength
        var trackIndex = 0
        var formatTwoOffset = 0
        while p + 8 <= b.count {
            let id = String(decoding: b[p ..< p + 4], as: UTF8.self)
            var length = Int(be32(b, p + 4))
            p += 8
            if p + length > b.count {
                log.add(.warning, "Chunk \(id) is truncated; reading what is there.")
                length = b.count - p
            }
            if id == "MTrk" {
                let end = readTrack(b, from: p, to: p + length, index: trackIndex, offset: formatTwoOffset, into: &content, log: &log)
                if content.format == 2 { formatTwoOffset = end }
                trackIndex += 1
            }
            p += length
        }
        if trackIndex == 0 { throw ImportError.malformed("The MIDI file has no tracks.") }
        if content.trackCount != trackIndex {
            log.add(.info, "The header announces \(content.trackCount) track(s) but \(trackIndex) were found.")
        }
        content.trackCount = trackIndex
        if content.isSMPTE { content.tempos = [] }
        content.notes.sort { ($0.start, $0.pitch, $0.track) < ($1.start, $1.pitch, $1.track) }
        content.tempos.sort { $0.tick < $1.tick }
        content.meters.sort { $0.tick < $1.tick }
        content.keys.sort { $0.tick < $1.tick }
        return content
    }

    /// Reads one MTrk chunk; returns the absolute tick at which the track ended.
    private static func readTrack(_ b: [UInt8], from start: Int, to end: Int, index: Int, offset: Int,
                                  into content: inout ParsersMIDIFileContent, log: inout ParsersDiagnosticLog) -> Int {
        var p = start
        var tick = offset
        var running: UInt8? = nil
        // Open notes keyed by channel * 128 + pitch: (start tick, velocity), oldest first.
        var open: [Int: [(Int, Int)]] = [:]
        var strayOffs = 0
        var damaged = false

        func close(_ key: Int, at t: Int) {
            guard var stack = open[key], !stack.isEmpty else { strayOffs += 1; return }
            let (s, v) = stack.removeFirst()
            open[key] = stack
            if t > s {
                content.notes.append(.init(start: s, end: t, pitch: key % 128, velocity: v, track: index, channel: key / 128))
            }
        }

        trackLoop: while p < end {
            guard let delta = readVLQ(b, &p, limit: end) else { damaged = true; break }
            tick += delta
            guard p < end else { break }
            var status = b[p]
            if status & 0x80 != 0 {
                p += 1
            } else if let r = running {
                status = r
            } else {
                damaged = true
                break
            }
            switch status {
            case 0xFF:
                guard p < end else { damaged = true; break trackLoop }
                let type = b[p]; p += 1
                guard let len = readVLQ(b, &p, limit: end), p + len <= end else { damaged = true; break trackLoop }
                let payload = Array(b[p ..< p + len])
                p += len
                switch type {
                case 0x2F:
                    break trackLoop
                case 0x51 where len >= 3:
                    let us = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                    if us > 0 { content.tempos.append(.init(tick: tick, microsecondsPerQuarter: us)) }
                case 0x58 where len >= 2:
                    let num = Int(payload[0])
                    let den = 1 << min(6, Int(payload[1]))
                    if num > 0 { content.meters.append(.init(tick: tick, numerator: num, denominator: den)) }
                case 0x59 where len >= 2:
                    let sf = Int(Int8(bitPattern: payload[0]))
                    content.keys.append(.init(tick: tick, fifths: max(-7, min(7, sf)), minor: payload[1] == 1))
                case 0x03:
                    let name = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    if !name.isEmpty, content.trackNames[index] == nil { content.trackNames[index] = name }
                default:
                    break
                }
            case 0xF0, 0xF7:
                guard let len = readVLQ(b, &p, limit: end), p + len <= end else { damaged = true; break trackLoop }
                p += len
            case 0xF1, 0xF3:
                p += 1
            case 0xF2:
                p += 2
            case 0xF4...0xFE:
                break
            default:
                running = status
                let kind = status & 0xF0
                let channel = Int(status & 0x0F)
                let count = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard p + count <= end else { damaged = true; break trackLoop }
                let d1 = Int(b[p] & 0x7F)
                let d2 = count == 2 ? Int(b[p + 1] & 0x7F) : 0
                p += count
                let key = channel * 128 + d1
                if kind == 0x90 && d2 > 0 {
                    if let stack = open[key], !stack.isEmpty {
                        // Re-attack while still sounding: a piano key cannot sound twice, so end the earlier note here.
                        close(key, at: tick)
                    }
                    open[key, default: []].append((tick, d2))
                } else if kind == 0x80 || (kind == 0x90 && d2 == 0) {
                    close(key, at: tick)
                }
            }
        }
        if damaged { log.add(.warning, "Track \(index + 1) is damaged after tick \(tick); the rest of it was ignored.") }
        var unclosed = 0
        for (key, stack) in open {
            for (s, v) in stack {
                unclosed += 1
                if tick > s { content.notes.append(.init(start: s, end: tick, pitch: key % 128, velocity: v, track: index, channel: key / 128)) }
            }
        }
        if unclosed > 0 { log.add(.warning, "Track \(index + 1): \(unclosed) note(s) were never released; they end with the track.") }
        if strayOffs > 0 { log.add(.info, "Track \(index + 1): \(strayOffs) note-off(s) without a matching note-on were ignored.") }
        content.lastTick = max(content.lastTick, tick)
        return tick
    }

    /// Position of "MThd" (directly at the start, or inside a RIFF RMID wrapper).
    private static func findHeader(_ b: [UInt8]) -> Int? {
        let magic: [UInt8] = [0x4D, 0x54, 0x68, 0x64]
        if b.count >= 4, Array(b[0..<4]) == magic { return 0 }
        guard b.count >= 12, Array(b[0..<4]) == [0x52, 0x49, 0x46, 0x46] else { return nil }
        var i = 12
        while i + 4 <= b.count {
            if Array(b[i ..< i + 4]) == magic { return i }
            i += 1
        }
        return nil
    }

    /// Reads a variable-length quantity (at most 4 bytes); nil when truncated or overlong.
    static func readVLQ(_ b: [UInt8], _ p: inout Int, limit: Int) -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard p < limit, p < b.count else { return nil }
            let byte = b[p]
            p += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
