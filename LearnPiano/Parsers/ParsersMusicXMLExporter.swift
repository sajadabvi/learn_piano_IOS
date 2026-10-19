import Foundation

/// Writes a Core `Score` as MusicXML 4.0 `score-partwise`: one piano part with two staves (right hand = staff 1,
/// left hand = staff 2), used to save and share imported songs.
///
/// The output re-imports with `ParsersMusicXMLImporter` to the same playback timeline: voices are numbered by the
/// usual convention (1–4 upper staff, 5–8 lower staff) so cross-staff events keep their hand, ties are written as both
/// `<tie>` and `<tied>`, repeats and volta endings become `<barline>` elements, pickups become `implicit="yes"`
/// measures, and tempo changes become metronome directions with `<sound tempo>`.
/// Displayed accidentals are the score's own when present, otherwise computed with key-signature and
/// measure memory so other notation programs show them correctly.
struct ParsersMusicXMLExporter: Sendable {
    /// When set, written as `<encoding-date>`; nil keeps the output byte-for-byte deterministic.
    var encodingDate: Date?

    init(encodingDate: Date? = nil) {
        self.encodingDate = encodingDate
    }

    /// UTF-8 MusicXML bytes for the score.
    func exportData(_ score: Score) -> Data { Data(exportString(score).utf8) }

    /// MusicXML text for the score.
    func exportString(_ score: Score) -> String {
        var w = ParsersXMLWriter()
        let divisionsUnit = ParsersMusicXMLExporter.tickUnit(for: score)
        let divisions = Ticks.perQuarter / divisionsUnit

        w.raw("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        w.raw("<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        w.open("score-partwise", attributes: [("version", "4.0")])
        w.open("work")
        w.leaf("work-title", score.metadata.title)
        w.close("work")
        w.open("identification")
        if !score.metadata.composer.isEmpty { w.leaf("creator", score.metadata.composer, attributes: [("type", "composer")]) }
        w.open("encoding")
        w.leaf("software", "LearnPiano")
        if let date = encodingDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            w.leaf("encoding-date", f.string(from: date))
        }
        w.close("encoding")
        let misc = ParsersMusicXMLExporter.miscellaneousFields(score.metadata)
        if !misc.isEmpty {
            w.open("miscellaneous")
            for (name, value) in misc { w.leaf("miscellaneous-field", value, attributes: [("name", name)]) }
            w.close("miscellaneous")
        }
        w.close("identification")
        w.open("part-list")
        w.open("score-part", attributes: [("id", "P1")])
        w.leaf("part-name", "Piano")
        w.close("score-part")
        w.close("part-list")
        w.open("part", attributes: [("id", "P1")])

        for (i, m) in score.measures.enumerated() {
            writeMeasure(m, index: i, score: score, unit: divisionsUnit, divisions: divisions, into: &w)
        }

        w.close("part")
        w.close("score-partwise")
        return w.text
    }

    // MARK: Measures

    private func writeMeasure(_ m: Measure, index i: Int, score: Score, unit: Ticks, divisions: Int, into w: inout ParsersXMLWriter) {
        var attrs: [(String, String)] = [("number", "\(m.number)")]
        if m.isPickup { attrs.append(("implicit", "yes")) }
        w.open("measure", attributes: attrs)

        let previousEndings = i > 0 ? score.measures[i - 1].barline.endings : []
        let nextEndings = i + 1 < score.measures.count ? score.measures[i + 1].barline.endings : []
        let endingStarts = !m.barline.endings.isEmpty && m.barline.endings != previousEndings
        let endingStops = !m.barline.endings.isEmpty && m.barline.endings != nextEndings
        let endingNumber = m.barline.endings.map(String.init).joined(separator: ", ")

        if m.barline.repeatForward || endingStarts {
            w.open("barline", attributes: [("location", "left")])
            if m.barline.repeatForward { w.leaf("bar-style", "heavy-light") }
            if endingStarts { w.empty("ending", attributes: [("number", endingNumber), ("type", "start")]) }
            if m.barline.repeatForward { w.empty("repeat", attributes: [("direction", "forward")]) }
            w.close("barline")
        }

        let key = i == 0 ? score.initialKey : m.keySignature
        let time = i == 0 ? score.initialTime : m.timeSignature
        if i == 0 || key != nil || time != nil {
            w.open("attributes")
            if i == 0 { w.leaf("divisions", "\(divisions)") }
            if let k = key {
                w.open("key")
                w.leaf("fifths", "\(k.fifths)")
                w.leaf("mode", k.mode.rawValue)
                w.close("key")
            }
            if let t = time {
                w.open("time")
                w.leaf("beats", "\(t.beats)")
                w.leaf("beat-type", "\(t.beatType)")
                w.close("time")
            }
            if i == 0 {
                w.leaf("staves", "2")
                w.open("clef", attributes: [("number", "1")]); w.leaf("sign", "G"); w.leaf("line", "2"); w.close("clef")
                w.open("clef", attributes: [("number", "2")]); w.leaf("sign", "F"); w.leaf("line", "4"); w.close("clef")
            }
            w.close("attributes")
        }

        if let bpm = i == 0 ? score.initialTempoBPM : m.tempoBPM {
            let text = ParsersMusicXMLExporter.format(bpm)
            w.open("direction", attributes: [("placement", "above")])
            w.open("direction-type")
            w.open("metronome")
            w.leaf("beat-unit", "quarter")
            w.leaf("per-minute", text)
            w.close("metronome")
            w.close("direction-type")
            w.leaf("staff", "1")
            w.empty("sound", attributes: [("tempo", text)])
            w.close("direction")
        }

        writeNotes(of: m, keySignature: score.keySignature(atMeasure: i), beatTicks: score.timeSignature(atMeasure: i).beatTicks, unit: unit, into: &w)

        let backward = m.barline.repeatBackwardTimes
        if backward != nil || endingStops || m.barline.isFinal {
            w.open("barline", attributes: [("location", "right")])
            if backward != nil || m.barline.isFinal { w.leaf("bar-style", "light-heavy") }
            if endingStops {
                // An ending that jumps back gets a closing hook; one that runs on (usually the last) is left open.
                let type = backward != nil ? "stop" : "discontinue"
                w.empty("ending", attributes: [("number", endingNumber), ("type", type)])
            }
            if let times = backward {
                var a: [(String, String)] = [("direction", "backward")]
                if times != 2 { a.append(("times", "\(times)")) }
                w.empty("repeat", attributes: a)
            }
            w.close("barline")
        }
        w.close("measure")
    }

    /// Writes every voice of both hands, separated by `<backup>`; gaps inside a voice become `<forward>`.
    private func writeNotes(of m: Measure, keySignature: KeySignature, beatTicks: Ticks, unit: Ticks, into w: inout ParsersXMLWriter) {
        let groups = Dictionary(grouping: m.events) { VoiceKey(hand: $0.hand, voice: $0.voice) }
        let keys = groups.keys.sorted()
        var accidentals = ParsersAccidentalMemory(key: keySignature)
        // Accidental memory is per drawn staff and runs in onset order, independent of voice order.
        var displayed: [UUID: [Accidental?]] = [:]
        for e in m.events.sorted(by: { $0.onset < $1.onset }) {
            displayed[e.id] = e.notes.map { n in accidentals.display(for: n, staff: e.drawnStaff) }
        }

        var cursor: Ticks = 0
        for (gi, key) in keys.enumerated() {
            let events = (groups[key] ?? []).sorted { $0.onset < $1.onset }
            if gi > 0, cursor > 0 {
                w.open("backup"); w.leaf("duration", "\(cursor / unit)"); w.close("backup")
                cursor = 0
            }
            let brackets = ParsersMusicXMLExporter.tupletBrackets(events)
            for (ei, e) in events.enumerated() {
                if e.onset > cursor {
                    w.open("forward"); w.leaf("duration", "\((e.onset - cursor) / unit)"); w.close("forward")
                } else if e.onset < cursor {
                    w.open("backup"); w.leaf("duration", "\((cursor - e.onset) / unit)"); w.close("backup")
                }
                let voiceText = "\(key.hand == .right ? e.voice : e.voice + 4)"
                let staffText = "\(e.drawnStaff.staffNumber)"
                if e.notes.isEmpty {
                    writeNote(nil, displayed: nil, chord: false, event: e, voice: voiceText, staff: staffText, bracket: brackets[ei], unit: unit, into: &w)
                } else {
                    let shown = displayed[e.id] ?? []
                    for (ni, n) in e.notes.enumerated() {
                        writeNote(n, displayed: ni < shown.count ? shown[ni] : nil, chord: ni > 0, event: e, voice: voiceText, staff: staffText,
                                  bracket: ni == 0 ? brackets[ei] : .none, unit: unit, into: &w)
                    }
                }
                cursor = e.end
            }
        }
    }

    /// Writes one `<note>` (a chord member when `chord` is true; a rest when `note` is nil).
    private func writeNote(_ note: ChordNote?, displayed: Accidental?, chord: Bool, event e: MeasureEvent, voice: String, staff: String,
                           bracket: TupletBracket, unit: Ticks, into w: inout ParsersXMLWriter) {
        w.open("note")
        if chord { w.empty("chord") }
        if let n = note {
            w.open("pitch")
            w.leaf("step", n.pitch.step.name)
            if n.pitch.alter != 0 { w.leaf("alter", "\(n.pitch.alter)") }
            w.leaf("octave", "\(n.pitch.octave)")
            w.close("pitch")
        } else {
            w.empty("rest")
        }
        w.leaf("duration", "\(e.duration / unit)")
        if let n = note {
            if n.tieStop { w.empty("tie", attributes: [("type", "stop")]) }
            if n.tieStart { w.empty("tie", attributes: [("type", "start")]) }
        }
        w.leaf("voice", voice)
        if let nd = e.notated {
            w.leaf("type", nd.value.musicXMLName)
            for _ in 0..<nd.dots { w.empty("dot") }
        }
        if let acc = displayed { w.leaf("accidental", ParsersMath.musicXMLName(of: acc)) }
        if let t = e.notated?.tuplet {
            w.open("time-modification")
            w.leaf("actual-notes", "\(t.actual)")
            w.leaf("normal-notes", "\(t.normal)")
            w.close("time-modification")
        }
        w.leaf("staff", staff)
        let ties = note.map { ($0.tieStop, $0.tieStart) } ?? (false, false)
        let fingering = note?.fingering
        if bracket != .none || ties.0 || ties.1 || fingering != nil {
            w.open("notations")
            if bracket == .start || bracket == .both { w.empty("tuplet", attributes: [("type", "start")]) }
            if bracket == .stop || bracket == .both { w.empty("tuplet", attributes: [("type", "stop")]) }
            if ties.0 { w.empty("tied", attributes: [("type", "stop")]) }
            if ties.1 { w.empty("tied", attributes: [("type", "start")]) }
            if let f = fingering {
                w.open("technical"); w.leaf("fingering", "\(f)"); w.close("technical")
            }
            w.close("notations")
        }
        w.close("note")
    }

    // MARK: Helpers

    /// Hand + voice, ordered right hand first, then by voice.
    private struct VoiceKey: Hashable, Comparable {
        var hand: Hand
        var voice: Int
        static func < (a: VoiceKey, b: VoiceKey) -> Bool {
            (a.hand == .right ? 0 : 1, a.voice) < (b.hand == .right ? 0 : 1, b.voice)
        }
    }

    /// Where a tuplet bracket starts or ends.
    enum TupletBracket: Hashable { case none, start, stop, both }

    /// Groups consecutive tuplet events of one voice into complete brackets (e.g. three triplet eighths filling a quarter).
    static func tupletBrackets(_ events: [MeasureEvent]) -> [TupletBracket] {
        var out = [TupletBracket](repeating: .none, count: events.count)
        var runStart: Int? = nil
        var accumulated: Ticks = 0
        var span: Ticks = 0
        var ratio: Tuplet? = nil
        func closeRun(at last: Int) {
            guard let s = runStart else { return }
            if s == last { out[s] = .both } else { out[s] = .start; out[last] = .stop }
            runStart = nil
            accumulated = 0
            ratio = nil
        }
        for (i, e) in events.enumerated() {
            guard let nd = e.notated, let t = nd.tuplet else {
                if runStart != nil { closeRun(at: i - 1) }
                continue
            }
            if runStart != nil, ratio != t || events[i - 1].end != e.onset { closeRun(at: i - 1) }
            if runStart == nil {
                runStart = i
                ratio = t
                span = nd.value.ticks * t.normal
                accumulated = 0
            }
            accumulated += e.duration
            if accumulated >= span { closeRun(at: i) }
        }
        if runStart != nil { closeRun(at: events.count - 1) }
        return out
    }

    /// Largest tick unit that divides every onset, duration and measure length, so `<divisions>` stays small.
    static func tickUnit(for score: Score) -> Ticks {
        var g = Ticks.perQuarter
        for i in score.measures.indices {
            g = ParsersMath.gcd(g, score.measureLength(at: i))
            for e in score.measures[i].events {
                g = ParsersMath.gcd(g, e.onset)
                g = ParsersMath.gcd(g, e.duration)
                g = ParsersMath.gcd(g, e.end)
            }
            if g == 1 { break }
        }
        return max(1, g)
    }

    /// Metadata that MusicXML has no element for, kept as `<miscellaneous-field>`s so a re-import restores it.
    static func miscellaneousFields(_ m: ScoreMetadata) -> [(String, String)] {
        var out: [(String, String)] = []
        if !m.arrangementLabel.isEmpty { out.append((ParsersMusicXMLExporter.fieldArrangement, m.arrangementLabel)) }
        if let d = m.difficulty { out.append((ParsersMusicXMLExporter.fieldDifficulty, d.rawValue)) }
        if !m.genre.isEmpty { out.append((ParsersMusicXMLExporter.fieldGenre, m.genre)) }
        if !m.notes.isEmpty { out.append((ParsersMusicXMLExporter.fieldNotes, m.notes)) }
        return out
    }

    static let fieldArrangement = "learnpiano-arrangement"
    static let fieldDifficulty = "learnpiano-difficulty"
    static let fieldGenre = "learnpiano-genre"
    static let fieldNotes = "learnpiano-notes"

    /// "72" for whole numbers, otherwise up to two decimals ("72.5").
    static func format(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.0005 { return "\(Int(value.rounded()))" }
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Decides which accidentals a reader needs to see: the key signature plus accidentals already shown on the same
/// letter and octave earlier in the measure (per staff). An accidental stored on the note always wins.
struct ParsersAccidentalMemory {
    private let key: KeySignature
    private var memory: [String: Int] = [:]

    init(key: KeySignature) { self.key = key }

    /// The accidental to print for a note drawn on `staff`, updating the measure memory.
    mutating func display(for note: ChordNote, staff: Hand) -> Accidental? {
        let slot = "\(staff.rawValue)-\(note.pitch.step.rawValue)-\(note.pitch.octave)"
        let current = memory[slot] ?? key.alteration(of: note.pitch.step)
        memory[slot] = note.pitch.alter
        if let explicit = note.accidental { return explicit }
        // A tie continuation keeps sounding the same pitch; no new accidental is printed for it.
        if note.tieStop { return nil }
        guard note.pitch.alter != current else { return nil }
        return Accidental(rawValue: max(-2, min(2, note.pitch.alter)))
    }
}

/// Minimal indented XML writer used by the exporter.
struct ParsersXMLWriter {
    private(set) var text = ""
    private var depth = 0

    /// Appends a line verbatim (prolog, doctype).
    mutating func raw(_ line: String) { text += line + "\n" }

    /// `<name attr="…">` and increases the indentation.
    mutating func open(_ name: String, attributes: [(String, String)] = []) {
        line("<\(name)\(ParsersXMLWriter.attributeText(attributes))>")
        depth += 1
    }

    /// `</name>` and decreases the indentation.
    mutating func close(_ name: String) {
        depth = max(0, depth - 1)
        line("</\(name)>")
    }

    /// `<name attr="…"/>`.
    mutating func empty(_ name: String, attributes: [(String, String)] = []) {
        line("<\(name)\(ParsersXMLWriter.attributeText(attributes))/>")
    }

    /// `<name>escaped text</name>`.
    mutating func leaf(_ name: String, _ value: String, attributes: [(String, String)] = []) {
        line("<\(name)\(ParsersXMLWriter.attributeText(attributes))>\(ParsersXMLText.escape(value))</\(name)>")
    }

    private mutating func line(_ s: String) {
        text += String(repeating: "  ", count: depth) + s + "\n"
    }

    private static func attributeText(_ attributes: [(String, String)]) -> String {
        attributes.map { " \($0.0)=\"\(ParsersXMLText.escape($0.1))\"" }.joined()
    }
}
