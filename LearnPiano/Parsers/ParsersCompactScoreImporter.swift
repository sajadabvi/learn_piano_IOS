import Foundation

/// One machine-readable problem in an LPC document, in the shape the transcription model receives for repair:
/// `{"measure": 3, "voice": "rh", "message": "…"}`. `measure` is the 1-based measure number (null for whole-document
/// problems) and `voice` is `"rh"`, `"lh"`, `"rh2"`, `"lh2"` or `""`.
struct ParsersCompactScoreIssue: Codable, Hashable, Sendable, CustomStringConvertible {
    var measure: Int?
    var voice: String
    var message: String
    /// Not encoded: the JSON sent back to the model only carries the three fields above.
    var severity: DiagnosticSeverity

    init(measure: Int?, voice: String = "", message: String, severity: DiagnosticSeverity = .error) {
        self.measure = measure
        self.voice = voice
        self.message = message
        self.severity = severity
    }

    private enum CodingKeys: String, CodingKey { case measure, voice, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        measure = try c.decodeIfPresent(Int.self, forKey: .measure)
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        message = try c.decode(String.self, forKey: .message)
        severity = .error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(measure, forKey: .measure) // explicit null for whole-document issues
        try c.encode(voice, forKey: .voice)
        try c.encode(message, forKey: .message)
    }

    var description: String {
        let where_ = [measure.map { "m\($0)" }, voice.isEmpty ? nil : voice].compactMap { $0 }.joined(separator: " ")
        return "[\(severity.rawValue)] \(where_.isEmpty ? "" : where_ + ": ")\(message)"
    }

    /// LPC voice name for a hand and Core voice number.
    static func voiceName(hand: Hand?, voice: Int?) -> String {
        guard let hand else { return "" }
        let base = hand == .right ? "rh" : "lh"
        return (voice ?? 1) >= 2 ? base + "2" : base
    }

    /// Converts Core diagnostics (e.g. from `ScoreValidator`) to LPC issues; `measureNumbers[i]` is the LPC number of
    /// notated measure index `i` (defaults to `i + 1`).
    static func from(_ diagnostics: [ScoreDiagnostic], measureNumbers: [Int] = []) -> [ParsersCompactScoreIssue] {
        diagnostics.map { d in
            let number = d.measureIndex.map { i in measureNumbers.indices.contains(i) ? measureNumbers[i] : i + 1 }
            return ParsersCompactScoreIssue(measure: number, voice: voiceName(hand: d.hand, voice: d.voice), message: d.message, severity: d.severity)
        }
    }

    /// Compact, deterministic JSON array of issues (sorted keys).
    static func json(_ issues: [ParsersCompactScoreIssue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(issues), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// Everything the LPC importer found: the score (always built, best effort), all issues, and per-measure confidence.
struct ParsersCompactScoreParseResult: Hashable, Sendable {
    /// Score + Core diagnostics (errors are measure-indexed, hand/voice-tagged).
    var importResult: ImportResult
    /// Every issue in document order, errors and warnings.
    var issues: [ParsersCompactScoreIssue]
    /// Transcription confidence per notated measure index (nil when the measure did not state one).
    var confidence: [Double?]

    /// Error-level issues only; empty means the document is valid.
    var errors: [ParsersCompactScoreIssue] { issues.filter { $0.severity == .error } }
    var isValid: Bool { errors.isEmpty }
    /// The errors as the JSON array sent back to the transcription model.
    var errorsJSON: String { ParsersCompactScoreIssue.json(errors) }
}

/// Imports the LearnPiano Compact score format `lpc-1` (docs/import-format.md) — the JSON the sheet-transcription model
/// emits and the hand-authoring format for exercises — into a `Score`.
///
/// Both the schema form (every key present, `""` / `[]` / `0` meaning absent) and the hand-authoring form (optional
/// keys omitted) are accepted. All validation rules of the format are enforced; problems are reported as measure-numbered
/// `ParsersCompactScoreIssue`s (and as Core diagnostics on the `ImportResult`) instead of failing, so the Import module can
/// send them back to the model for repair. Only input that is not a JSON object at all throws.
struct ParsersCompactScoreImporter: ScoreImporter, Sendable {
    var supportedExtensions: [String] { ["lpc", "json"] }
    var displayName: String { "LearnPiano compact score" }

    /// The measure number the first measure must carry (1 for a standalone document).
    var firstMeasureNumber: Int
    /// Whether this document ends the piece. In the page-by-page transcription flow every page but the last passes
    /// false: the last measure of such a page is not the end of the piece, so it must be complete.
    var isFinalPage: Bool
    /// Whether the piece starts with a pickup, when this document is a later page (the pickup is declared on page 1).
    /// nil uses the document's own `"pickup"` field.
    var pieceHasPickup: Bool?

    /// - Parameters:
    ///   - firstMeasureNumber: the number the first measure must carry (pages after the first continue the count).
    ///   - isFinalPage: false for every page of a multi-page transcription except the last.
    ///   - pieceHasPickup: the `"pickup"` value of page 1 when this is a later page; nil for a standalone document.
    init(firstMeasureNumber: Int = 1, isFinalPage: Bool = true, pieceHasPickup: Bool? = nil) {
        self.firstMeasureNumber = firstMeasureNumber
        self.isFinalPage = isFinalPage
        self.pieceHasPickup = pieceHasPickup
    }

    func importScore(data: Data, fileName: String) throws -> ImportResult {
        try parse(data: data, fileName: fileName).importResult
    }

    /// Parses and validates an LPC document.
    func parse(data: Data, fileName: String = "score.lpc") throws -> ParsersCompactScoreParseResult {
        let root = try ParsersCompactScoreImporter.jsonObject(data)
        var reader = ParsersCompactScoreReader(root: root, fileName: fileName, firstMeasureNumber: firstMeasureNumber,
                                               isFinalPage: isFinalPage, pieceHasPickup: pieceHasPickup)
        return reader.read()
    }

    /// Parses and validates LPC text.
    func parse(json: String, fileName: String = "score.lpc") throws -> ParsersCompactScoreParseResult {
        try parse(data: Data(json.utf8), fileName: fileName)
    }

    /// Decodes the top-level JSON object. Text around the object (e.g. a Markdown code fence) is tolerated.
    static func jsonObject(_ data: Data) throws -> [String: Any] {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            guard let dict = obj as? [String: Any] else { throw ImportError.malformed("An LPC document must be a JSON object.") }
            return dict
        }
        let text = String(decoding: data, as: UTF8.self)
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
           let obj = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)), let dict = obj as? [String: Any] {
            return dict
        }
        throw ImportError.malformed("The LPC document is not valid JSON.")
    }
}

/// One pass over a decoded LPC document (see `ParsersCompactScoreImporter`).
struct ParsersCompactScoreReader {
    /// A validated event before ticks are assigned.
    private struct LPCEvent {
        var pitches: [Pitch]
        var explicitNatural: [Bool]
        var units: Int
        var tie: String
        var tuplet: Tuplet?
        var fingering: [Int]
        var crossStaff: Bool
    }

    /// The four voice keys with their hand and Core voice number.
    private static let voices: [(key: String, hand: Hand, voice: Int, required: Bool)] = [
        ("rh", .right, 1, true), ("lh", .left, 1, true), ("rh2", .right, 2, false), ("lh2", .left, 2, false),
    ]

    let root: [String: Any]
    let fileName: String
    let firstMeasureNumber: Int
    /// See `ParsersCompactScoreImporter.isFinalPage`.
    let isFinalPage: Bool
    /// See `ParsersCompactScoreImporter.pieceHasPickup`.
    let pieceHasPickup: Bool?
    private var issues: [ParsersCompactScoreIssue] = []
    private var diagnostics: [ScoreDiagnostic] = []

    init(root: [String: Any], fileName: String, firstMeasureNumber: Int, isFinalPage: Bool = true, pieceHasPickup: Bool? = nil) {
        self.root = root
        self.fileName = fileName
        self.firstMeasureNumber = firstMeasureNumber
        self.isFinalPage = isFinalPage
        self.pieceHasPickup = pieceHasPickup
    }

    /// Records an issue (and its Core diagnostic twin).
    private mutating func report(_ severity: DiagnosticSeverity, measureIndex: Int?, voice: String = "", _ message: String) {
        let number = measureIndex.map { firstMeasureNumber + $0 }
        issues.append(ParsersCompactScoreIssue(measure: number, voice: voice, message: message, severity: severity))
        let spec = ParsersCompactScoreReader.voices.first { $0.key == voice }
        diagnostics.append(ScoreDiagnostic(severity, measureIndex: measureIndex, hand: spec?.hand, voice: spec?.voice, message: message))
    }

    // MARK: Reading

    mutating func read() -> ParsersCompactScoreParseResult {
        // Rule 1: header fields.
        let format = root["format"] as? String
        if format != "lpc-1" {
            report(.error, measureIndex: nil, format == nil ? "\"format\" is missing; it must be \"lpc-1\"." : "\"format\" is \"\(format ?? "")\"; it must be \"lpc-1\".")
        }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let composer = (root["composer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var divisions = 4
        switch ParsersCompactScoreReader.integer(root["divisions"]) {
        case .some(let d) where (1...96).contains(d): divisions = d
        case .some(let d): report(.error, measureIndex: nil, "\"divisions\" is \(d); it must be between 1 and 96.")
        case .none: report(.error, measureIndex: nil, "\"divisions\" is missing or not an integer.")
        }
        let converter = ParsersTickConverter(divisions: divisions)

        var time = TimeSignature.common
        if let t = root["time"] as? String, let parsed = TimeSignature(string: t) { time = parsed } else {
            report(.error, measureIndex: nil, "\"time\" must be a string like \"3/4\" (found \(ParsersCompactScoreReader.describe(root["time"]))).")
        }
        var key = KeySignature.cMajor
        if root["key"] == nil {
            report(.warning, measureIndex: nil, "\"key\" is missing; C major / A minor (0) is assumed.")
        } else if let k = ParsersCompactScoreReader.integer(root["key"]), (-7...7).contains(k) {
            key = KeySignature(fifths: k)
        } else {
            report(.error, measureIndex: nil, "\"key\" must be an integer from -7 to 7 (found \(ParsersCompactScoreReader.describe(root["key"]))).")
        }
        var tempo = 100.0
        if root["tempo"] == nil {
            report(.warning, measureIndex: nil, "\"tempo\" is missing; 100 BPM is assumed.")
        } else if let t = ParsersCompactScoreReader.number(root["tempo"]), (20...300).contains(t) {
            tempo = t
        } else {
            report(.error, measureIndex: nil, "\"tempo\" must be a number of quarter beats per minute from 20 to 300 (found \(ParsersCompactScoreReader.describe(root["tempo"]))).")
        }
        let pickup = (root["pickup"] as? Bool) ?? false
        if root["pickup"] != nil, !(root["pickup"] is Bool) { report(.warning, measureIndex: nil, "\"pickup\" should be true or false; false is assumed.") }

        guard let rawMeasures = root["measures"] as? [Any] else {
            report(.error, measureIndex: nil, "\"measures\" is missing or not an array.")
            return finish(title: title, composer: composer, time: time, key: key, tempo: tempo, measures: [], confidence: [])
        }
        if rawMeasures.isEmpty { report(.error, measureIndex: nil, "\"measures\" is empty.") }

        // First pass: validate every measure and collect its voices.
        var effectiveTime = time
        var effectiveKey = key
        var effectiveTempo = tempo
        var built: [(number: Int, time: TimeSignature?, key: KeySignature?, tempo: Double?, measureUnits: Int, voices: [String: [LPCEvent]])] = []
        var confidence: [Double?] = []
        let lastIndex = rawMeasures.count - 1
        // Rule 3 exceptions: the pickup itself, and the final measure of the piece when it completes a pickup.
        let shortFinalAllowed = isFinalPage && (pieceHasPickup ?? pickup)

        for (i, rawMeasure) in rawMeasures.enumerated() {
            let expected = firstMeasureNumber + i
            guard let m = rawMeasure as? [String: Any] else {
                report(.error, measureIndex: i, "Measure \(expected) is not a JSON object.")
                built.append((expected, nil, nil, nil, 0, [:]))
                confidence.append(nil)
                continue
            }
            // Rule 2: numbering.
            var number = expected
            if let n = ParsersCompactScoreReader.integer(m["n"]) {
                number = n
                if n != expected { report(.error, measureIndex: i, "Measure number is \(n) but \(expected) was expected; measures must be numbered \(firstMeasureNumber)…N in order with no gaps.") }
            } else {
                report(.error, measureIndex: i, "\"n\" (the measure number) is missing or not an integer; expected \(expected).")
            }
            // Optional changes.
            var measureTime: TimeSignature? = nil
            if let t = m["time"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                if let parsed = TimeSignature(string: t.trimmingCharacters(in: .whitespaces)) {
                    if parsed != effectiveTime { measureTime = parsed; effectiveTime = parsed }
                } else {
                    report(.error, measureIndex: i, "\"time\" \"\(t)\" is not a time signature like \"3/4\".")
                }
            } else if m["time"] != nil, !(m["time"] is String) {
                report(.error, measureIndex: i, "\"time\" must be a string like \"3/4\".")
            }
            var measureKey: KeySignature? = nil
            if m["key"] != nil {
                if let k = ParsersCompactScoreReader.integer(m["key"]), (-7...7).contains(k) {
                    let ks = KeySignature(fifths: k)
                    if ks != effectiveKey { measureKey = ks; effectiveKey = ks }
                } else if !(m["key"] is String && (m["key"] as? String) == "") {
                    report(.error, measureIndex: i, "\"key\" must be an integer from -7 to 7 (found \(ParsersCompactScoreReader.describe(m["key"]))).")
                }
            }
            var measureTempo: Double? = nil
            if m["tempo"] != nil {
                if let t = ParsersCompactScoreReader.number(m["tempo"]) {
                    if t == 0 {
                        // Schema form: 0 means "no change".
                    } else if (20...300).contains(t) {
                        if abs(t - effectiveTempo) > 0.001 { measureTempo = t; effectiveTempo = t }
                    } else {
                        report(.error, measureIndex: i, "\"tempo\" is \(ParsersMusicXMLExporter.format(t)); it must be from 20 to 300.")
                    }
                } else if !(m["tempo"] is String && (m["tempo"] as? String) == "") {
                    report(.error, measureIndex: i, "\"tempo\" must be a number (found \(ParsersCompactScoreReader.describe(m["tempo"]))).")
                }
            }
            if let c = ParsersCompactScoreReader.number(m["confidence"]) {
                if !(0...1).contains(c) { report(.warning, measureIndex: i, "\"confidence\" \(c) is outside 0…1; it was clamped.") }
                confidence.append(max(0, min(1, c)))
            } else {
                confidence.append(nil)
            }

            // Measure length in division units.
            let numerator = effectiveTime.beats * 4 * divisions
            var measureUnits = numerator / effectiveTime.beatType
            if numerator % effectiveTime.beatType != 0 {
                report(.error, measureIndex: i, "A \(effectiveTime) measure is not a whole number of divisions with \"divisions\": \(divisions); use a multiple of \(effectiveTime.beatType / ParsersMath.gcd(effectiveTime.beatType, effectiveTime.beats * 4)).")
                measureUnits = Int((Double(numerator) / Double(effectiveTime.beatType)).rounded())
            }

            // Voices (rules 3, 4, 6, 7).
            var voices: [String: [LPCEvent]] = [:]
            var voiceLengths: [String: Int] = [:]
            for spec in ParsersCompactScoreReader.voices {
                guard let rawVoice = m[spec.key] else {
                    if spec.required { report(.error, measureIndex: i, voice: spec.key, "Voice \"\(spec.key)\" is missing; write a rest that fills the measure when the hand is silent.") }
                    continue
                }
                guard let list = rawVoice as? [Any] else {
                    report(.error, measureIndex: i, voice: spec.key, "Voice \"\(spec.key)\" must be an array of events.")
                    continue
                }
                if list.isEmpty {
                    if spec.required { report(.error, measureIndex: i, voice: spec.key, "Voice \"\(spec.key)\" is empty; write a rest that fills the measure when the hand is silent.") }
                    continue
                }
                var events: [LPCEvent] = []
                var total = 0
                for (k, rawEvent) in list.enumerated() {
                    if let e = readEvent(rawEvent, index: k, measureIndex: i, voice: spec.key, hand: spec.hand) {
                        events.append(e)
                        total += e.units
                    }
                }
                voices[spec.key] = events
                voiceLengths[spec.key] = total
                // Rule 3: voice length.
                let allowShort = (i == 0 && pickup) || (i == lastIndex && shortFinalAllowed)
                if total > measureUnits {
                    report(.error, measureIndex: i, voice: spec.key, "Voice \"\(spec.key)\" lasts \(total) divisions but a \(effectiveTime) measure holds \(measureUnits) (divisions = \(divisions)).")
                } else if total < measureUnits, !allowShort {
                    report(.error, measureIndex: i, voice: spec.key, "Voice \"\(spec.key)\" lasts \(total) divisions but a \(effectiveTime) measure needs \(measureUnits) (divisions = \(divisions)); add the missing notes or rests.")
                }
            }
            if i == 0, pickup, Set(voiceLengths.values).count > 1 {
                report(.warning, measureIndex: i, "The pickup's voices have different lengths (\(voiceLengths.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))).")
            }
            built.append((number, measureTime, measureKey, measureTempo, measureUnits, voices))
        }

        // A change written on the first measure is the document's starting value: fold it into the initial values so
        // the score does not carry a measure-0 override (Core would give it precedence over the initial values anyway).
        if !built.isEmpty {
            if let t = built[0].time { time = t; built[0].time = nil }
            if let k = built[0].key { key = k; built[0].key = nil }
            if let b = built[0].tempo { tempo = b; built[0].tempo = nil }
        }

        // Rule 5: ties pair up with the next event of the same voice (across barlines).
        var tieStarts: [String: Set<Int>] = [:] // "measure:voice:event" -> MIDI numbers that start a tie
        var tieStops: [String: Set<Int>] = [:]
        for spec in ParsersCompactScoreReader.voices {
            var sequence: [(measure: Int, index: Int, event: LPCEvent)] = []
            for (mi, b) in built.enumerated() {
                for (k, e) in (b.voices[spec.key] ?? []).enumerated() { sequence.append((mi, k, e)) }
            }
            for (pos, item) in sequence.enumerated() where !item.event.pitches.isEmpty {
                let tie = item.event.tie
                if tie == "start" || tie == "both" {
                    let partner = pos + 1 < sequence.count ? sequence[pos + 1] : nil
                    let mine = Set(item.event.pitches.map { $0.midi })
                    let common = partner.map { mine.intersection($0.event.pitches.map { $0.midi }) } ?? []
                    if let p = partner, (p.event.tie == "stop" || p.event.tie == "both"), !common.isEmpty {
                        tieStarts["\(item.measure):\(spec.key):\(item.index)"] = common
                        tieStops["\(p.measure):\(spec.key):\(p.index)"] = common
                    } else {
                        let names = item.event.pitches.map { $0.name }.joined(separator: ", ")
                        let reason: String
                        if let p = partner {
                            if common.isEmpty { reason = "the next event in this voice does not contain the same pitch" } else { reason = "the next event in this voice (measure \(firstMeasureNumber + p.measure)) does not have \"tie\": \"stop\" or \"both\"" }
                        } else {
                            reason = "there is no following event in this voice"
                        }
                        report(.error, measureIndex: item.measure, voice: spec.key, "Event \(item.index + 1) (\(names)) starts a tie but \(reason).")
                    }
                }
            }
            for item in sequence where (item.event.tie == "stop" || item.event.tie == "both") && !item.event.pitches.isEmpty {
                if tieStops["\(item.measure):\(spec.key):\(item.index)"] == nil {
                    report(.warning, measureIndex: item.measure, voice: spec.key, "Event \(item.index + 1) ends a tie that no previous event starts; it is played as a new note.")
                }
            }
        }

        // Build measures.
        var measures: [Measure] = []
        for (mi, b) in built.enumerated() {
            var events: [MeasureEvent] = []
            var timeHere = time
            for j in 0...mi { if let t = built[j].time { timeHere = t } }
            for spec in ParsersCompactScoreReader.voices {
                var cursor = 0.0
                for (k, e) in (b.voices[spec.key] ?? []).enumerated() {
                    let span = converter.span(from: cursor, units: e.units)
                    cursor += Double(e.units) * converter.ticksPerUnit
                    let ticks = span.end - span.onset
                    guard ticks > 0 else { continue }
                    let starts = tieStarts["\(mi):\(spec.key):\(k)"] ?? []
                    let stops = tieStops["\(mi):\(spec.key):\(k)"] ?? []
                    let fingering = e.fingering
                    func notes(first: Bool, last: Bool) -> [ChordNote] {
                        e.pitches.enumerated().map { idx, p in
                            ChordNote(pitch: p,
                                      tieStart: !last || starts.contains(p.midi),
                                      tieStop: !first || stops.contains(p.midi),
                                      fingering: first && idx < fingering.count ? fingering[idx] : nil,
                                      accidental: e.explicitNatural[idx] ? .natural : nil)
                        }
                    }
                    if let nd = ParsersCompactScoreReader.notated(ticks: ticks, tuplet: e.tuplet) {
                        events.append(MeasureEvent(onset: span.onset, duration: ticks, notated: nd, notes: notes(first: true, last: true), hand: spec.hand, voice: spec.voice, drawnOnOtherStaff: e.crossStaff))
                    } else {
                        // Not a single note value: written as tied values (notes) or consecutive rests.
                        let pieces = ParsersDurationSplitter.split(ticks: ticks, onset: span.onset, beatTicks: timeHere.beatTicks)
                        var at = span.onset
                        for (pi, piece) in pieces.enumerated() {
                            let chord = e.pitches.isEmpty ? [] : notes(first: pi == 0, last: pi == pieces.count - 1)
                            events.append(MeasureEvent(onset: at, duration: piece.ticks, notated: piece.notated, notes: chord, hand: spec.hand, voice: spec.voice, drawnOnOtherStaff: e.crossStaff))
                            at += piece.ticks
                        }
                    }
                }
            }
            measures.append(Measure(number: b.number, timeSignature: b.time, keySignature: b.key, tempoBPM: b.tempo,
                                    isPickup: mi == 0 && pickup, events: events,
                                    barline: mi == built.count - 1 ? Barline(isFinal: true) : .plain))
        }
        return finish(title: title, composer: composer, time: time, key: key, tempo: tempo, measures: measures, confidence: confidence)
    }

    private func finish(title: String, composer: String, time: TimeSignature, key: KeySignature, tempo: Double, measures: [Measure], confidence: [Double?]) -> ParsersCompactScoreParseResult {
        let metadata = ScoreMetadata(title: title.isEmpty ? ParsersMusicXMLScoreBuilder.titleFromFileName(fileName) : title,
                                     composer: composer, source: .compactJSON, sourceFileName: fileName)
        let score = Score(metadata: metadata, initialTime: time, initialKey: key, initialTempoBPM: tempo, measures: measures)
        return ParsersCompactScoreParseResult(importResult: ImportResult(score: score, diagnostics: diagnostics), issues: issues, confidence: confidence)
    }

    /// Validates one event (rules 4, 6, 7). Returns nil when it is unusable (its length is then unknown).
    private mutating func readEvent(_ raw: Any, index k: Int, measureIndex i: Int, voice: String, hand: Hand) -> LPCEvent? {
        let label = "Event \(k + 1)"
        guard let e = raw as? [String: Any] else {
            report(.error, measureIndex: i, voice: voice, "\(label) is not a JSON object.")
            return nil
        }
        // d
        guard let d = ParsersCompactScoreReader.integer(e["d"]), d > 0 else {
            report(.error, measureIndex: i, voice: voice, "\(label): \"d\" must be a positive integer number of divisions (found \(ParsersCompactScoreReader.describe(e["d"]))).")
            return nil
        }
        // p
        var pitches: [Pitch] = []
        var naturals: [Bool] = []
        if let list = e["p"] as? [Any] {
            for item in list {
                guard let name = item as? String, let pitch = Pitch(name: name), (-2...2).contains(pitch.alter) else {
                    report(.error, measureIndex: i, voice: voice, "\(label): pitch \(ParsersCompactScoreReader.describe(item)) is not scientific pitch notation like \"C4\", \"F#3\" or \"Bb2\".")
                    continue
                }
                guard Pitch.pianoRange.contains(pitch.midi) else {
                    report(.error, measureIndex: i, voice: voice, "\(label): \(name) (MIDI \(pitch.midi)) is outside the piano range A0…C8.")
                    continue
                }
                if pitches.contains(where: { $0.midi == pitch.midi }) {
                    report(.error, measureIndex: i, voice: voice, "\(label): the chord lists \(name) twice.")
                    continue
                }
                pitches.append(pitch)
                naturals.append(name.dropFirst().hasPrefix("n"))
            }
        } else {
            report(.error, measureIndex: i, voice: voice, "\(label): \"p\" must be an array of pitch names ([] for a rest).")
        }
        // tie
        var tie = ""
        if let t = e["tie"] {
            if let s = t as? String, ["", "start", "stop", "both"].contains(s) { tie = s } else {
                report(.error, measureIndex: i, voice: voice, "\(label): \"tie\" must be \"\", \"start\", \"stop\" or \"both\".")
            }
        }
        // t
        var tuplet: Tuplet? = nil
        if let t = e["t"] {
            let ints = (t as? [Any])?.map { ParsersCompactScoreReader.integer($0) }
            if let ints, ints.isEmpty {
                // absent
            } else if let ints, ints.count == 2, let a = ints[0], let n = ints[1], a > 0, n > 0 {
                tuplet = Tuplet(actual: a, normal: n)
            } else {
                report(.error, measureIndex: i, voice: voice, "\(label): \"t\" must be two positive integers [actual, normal], e.g. [3, 2].")
            }
        }
        // f
        var fingering: [Int] = []
        if let f = e["f"] {
            if let list = f as? [Any] {
                for item in list {
                    if let n = ParsersCompactScoreReader.integer(item), (1...5).contains(n) { fingering.append(n) } else {
                        report(.error, measureIndex: i, voice: voice, "\(label): fingering \(ParsersCompactScoreReader.describe(item)) must be 1…5.")
                    }
                }
                let pitchCount = (e["p"] as? [Any])?.count ?? 0
                if list.count > pitchCount {
                    report(.error, measureIndex: i, voice: voice, "\(label): \(list.count) fingering(s) for \(pitchCount) pitch(es); \"f\" may not be longer than \"p\".")
                }
            } else {
                report(.error, measureIndex: i, voice: voice, "\(label): \"f\" must be an array of fingers 1…5.")
            }
        }
        // s
        var crossStaff = false
        if let s = e["s"] {
            switch s as? String {
            case "": break
            case "up":
                if hand == .left { crossStaff = true } else { report(.warning, measureIndex: i, voice: voice, "\(label): \"s\": \"up\" only applies to left-hand events; ignored.") }
            case "down":
                if hand == .right { crossStaff = true } else { report(.warning, measureIndex: i, voice: voice, "\(label): \"s\": \"down\" only applies to right-hand events; ignored.") }
            default:
                report(.error, measureIndex: i, voice: voice, "\(label): \"s\" must be \"\", \"up\" or \"down\".")
            }
        }
        let isRest = (e["p"] as? [Any])?.isEmpty ?? false
        if isRest, !tie.isEmpty || !fingering.isEmpty || crossStaff {
            report(.warning, measureIndex: i, voice: voice, "\(label) is a rest; its \"tie\", \"f\" and \"s\" are ignored.")
            tie = ""
            fingering = []
            crossStaff = false
        }
        // Rule 7: chord span.
        if let lo = pitches.map({ $0.midi }).min(), let hi = pitches.map({ $0.midi }).max(), hi - lo > 16 {
            report(.warning, measureIndex: i, voice: voice, "\(label): the chord spans \(hi - lo) semitones, wider than a 10th.")
        }
        return LPCEvent(pitches: pitches, explicitNatural: naturals, units: d, tie: tie, tuplet: tuplet, fingering: fingering, crossStaff: crossStaff)
    }

    // MARK: Value helpers

    /// The notated value for a length: the matching tuplet value when `t` is given, otherwise a plain, dotted or triplet value.
    static func notated(ticks: Ticks, tuplet: Tuplet?) -> NoteDuration? {
        if let t = tuplet {
            for v in NoteValue.allCases where v.rawValue >= 0 {
                for dots in 0...1 {
                    let nd = NoteDuration(value: v, dots: dots, tuplet: t)
                    if nd.ticks == ticks { return nd }
                }
            }
        }
        return NoteDuration.exact(ticks: ticks)
    }

    /// An integer from a JSON number (4 or 4.0, not 4.5 and not a boolean).
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    /// A finite number from a JSON number (not a boolean).
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBoolean(n), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Short description of a JSON value for messages.
    static func describe(_ value: Any?) -> String {
        guard let value else { return "nothing" }
        if let s = value as? String { return "\"\(s)\"" }
        if let n = value as? NSNumber { return isBoolean(n) ? (n.boolValue ? "true" : "false") : n.stringValue }
        if value is [Any] { return "an array" }
        if value is [String: Any] { return "an object" }
        if value is NSNull { return "null" }
        return "\(value)"
    }
}
