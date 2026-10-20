import Foundation

// MARK: - Raw document model (what the SAX pass produces)

/// A `<note>` as read from the file, before any musical interpretation.
struct ParsersMusicXMLRawNote: Hashable {
    var isChord = false
    var isGrace = false
    var isCue = false
    var isRest = false
    var isUnpitched = false
    var step: String?
    var alter: Double?
    var octave: Int?
    /// `<duration>` in division units; nil when absent (grace notes).
    var duration: Int?
    var voice: String?
    var staff: Int?
    var type: String?
    var dots = 0
    var tieStart = false
    var tieStop = false
    var tiedStart = false
    var tiedStop = false
    var actualNotes: Int?
    var normalNotes: Int?
    var accidental: String?
    var fingering: Int?
    var line = 0
}

/// A `<clef>` inside `<attributes>`.
struct ParsersMusicXMLRawClef: Hashable {
    var number = 1
    var sign: String?
    var line: Int?
}

/// An `<attributes>` block.
struct ParsersMusicXMLRawAttributes: Hashable {
    var divisions: Int?
    var fifths: Int?
    var mode: String?
    var beats: Int?
    var beatType: Int?
    var staves: Int?
    var clefs: [ParsersMusicXMLRawClef] = []
}

/// A `<barline>` with the pieces the model cares about.
struct ParsersMusicXMLRawBarline: Hashable {
    var location = "right"
    var style: String?
    var repeatDirection: String?
    var repeatTimes: Int?
    var endingNumbers: [Int] = []
    var endingType: String?
}

/// Anything inside a measure that affects time or structure, in document order.
enum ParsersMusicXMLRawItem: Hashable {
    case note(ParsersMusicXMLRawNote)
    case backup(Int)
    case forward(Int)
    case attributes(ParsersMusicXMLRawAttributes)
    /// Quarter-note BPM from `<sound tempo>` or a `<metronome>` mark.
    case tempo(Double)
    case barline(ParsersMusicXMLRawBarline)
}

/// A `<measure>` of one part.
struct ParsersMusicXMLRawMeasure: Hashable {
    var number: String
    var implicit = false
    var items: [ParsersMusicXMLRawItem] = []
}

/// A `<part>`.
struct ParsersMusicXMLRawPart: Hashable {
    var id: String
    var measures: [ParsersMusicXMLRawMeasure] = []
}

/// The whole file as read by the SAX pass.
struct ParsersMusicXMLRawDocument {
    var rootElement: String?
    var isTimewise = false
    var workTitle: String?
    var movementTitle: String?
    var composer: String?
    /// `<score-part>` ids in part-list order with their names.
    var partList: [(id: String, name: String)] = []
    var parts: [ParsersMusicXMLRawPart] = []
    /// `<miscellaneous-field name="…">` values from `<identification>` (LearnPiano stores arrangement metadata there).
    var miscellaneous: [String: String] = [:]

    /// Best available title.
    var title: String? {
        let w = workTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let m = movementTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !w.isEmpty { return w }
        if !m.isEmpty { return m }
        return nil
    }
}

// MARK: - SAX delegate

/// Streaming reader for MusicXML (partwise and timewise). It keeps an element stack and converts the
/// document into `ParsersMusicXMLRawDocument` without building a DOM.
final class ParsersMusicXMLSAXDelegate: NSObject, XMLParserDelegate {
    private(set) var document = ParsersMusicXMLRawDocument()
    private var path: [String] = []
    private var text = ""
    private var currentPartIndex: Int?
    private var note: ParsersMusicXMLRawNote?
    private var barline: ParsersMusicXMLRawBarline?
    private var attributes: ParsersMusicXMLRawAttributes?
    private var clef: ParsersMusicXMLRawClef?
    private var inDirection = false
    private var directionSoundTempo: Double?
    private var metronomeBeatUnit: String?
    private var metronomeDots = 0
    private var metronomePerMinute: Double?
    private var creatorType: String?
    private var scorePartID: String?
    private var miscellaneousName: String?
    private var timewiseMeasureNumber = "1"
    private var timewiseImplicit = false
    private var seenPartIDs: [String: Int] = [:]

    private var parentName: String? { path.count >= 2 ? path[path.count - 2] : nil }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let parent = path.last
        path.append(elementName)
        text = ""
        switch elementName {
        case "score-partwise", "score-timewise":
            if document.rootElement == nil {
                document.rootElement = elementName
                document.isTimewise = elementName == "score-timewise"
            }
        case "score-part":
            scorePartID = attributeDict["id"]
            if let id = attributeDict["id"] { document.partList.append((id: id, name: "")) }
        case "creator":
            creatorType = attributeDict["type"]
        case "miscellaneous-field":
            miscellaneousName = attributeDict["name"]
        case "part":
            let id = attributeDict["id"] ?? "P\(document.parts.count + 1)"
            let index: Int
            if let existing = seenPartIDs[id] {
                index = existing
            } else {
                index = document.parts.count
                seenPartIDs[id] = index
                document.parts.append(ParsersMusicXMLRawPart(id: id))
            }
            currentPartIndex = index
            if document.isTimewise, parent == "measure" {
                document.parts[index].measures.append(ParsersMusicXMLRawMeasure(number: timewiseMeasureNumber, implicit: timewiseImplicit))
            }
        case "measure":
            let number = attributeDict["number"] ?? ""
            let implicit = attributeDict["implicit"] == "yes"
            if document.isTimewise, parent == "score-timewise" {
                timewiseMeasureNumber = number
                timewiseImplicit = implicit
            } else if let p = currentPartIndex {
                document.parts[p].measures.append(ParsersMusicXMLRawMeasure(number: number, implicit: implicit))
            }
        case "note":
            var n = ParsersMusicXMLRawNote()
            n.line = parser.lineNumber
            note = n
        case "chord": note?.isChord = true
        case "grace": note?.isGrace = true
        case "cue": note?.isCue = true
        case "rest": note?.isRest = true
        case "unpitched": note?.isUnpitched = true
        case "tie":
            if attributeDict["type"] == "start" { note?.tieStart = true }
            if attributeDict["type"] == "stop" { note?.tieStop = true }
        case "tied":
            if attributeDict["type"] == "start" || attributeDict["type"] == "continue" { note?.tiedStart = true }
            if attributeDict["type"] == "stop" || attributeDict["type"] == "continue" { note?.tiedStop = true }
        case "barline":
            var b = ParsersMusicXMLRawBarline()
            b.location = attributeDict["location"] ?? "right"
            barline = b
        case "repeat":
            barline?.repeatDirection = attributeDict["direction"]
            barline?.repeatTimes = attributeDict["times"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        case "ending":
            barline?.endingType = attributeDict["type"]
            if let numbers = attributeDict["number"] {
                barline?.endingNumbers = numbers.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
            }
        case "direction":
            inDirection = true
            directionSoundTempo = nil
            metronomeBeatUnit = nil
            metronomeDots = 0
            metronomePerMinute = nil
        case "sound":
            if let t = attributeDict["tempo"], let bpm = Double(t.trimmingCharacters(in: .whitespaces)), bpm > 0 {
                if inDirection { directionSoundTempo = bpm } else { appendItem(.tempo(bpm)) }
            }
        case "attributes":
            attributes = ParsersMusicXMLRawAttributes()
        case "clef":
            var c = ParsersMusicXMLRawClef()
            c.number = attributeDict["number"].flatMap { Int($0) } ?? 1
            clef = c
        case "beat-unit-dot":
            metronomeDots += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentName
        switch elementName {
        // Header
        case "work-title": document.workTitle = value
        case "movement-title": document.movementTitle = value
        case "creator":
            if creatorType == "composer" || (creatorType == nil && document.composer == nil), !value.isEmpty, document.composer == nil { document.composer = value }
            creatorType = nil
        case "part-name":
            if parent == "score-part", let id = scorePartID, let idx = document.partList.firstIndex(where: { $0.id == id }) { document.partList[idx].name = value }
        case "score-part": scorePartID = nil
        case "miscellaneous-field":
            if let name = miscellaneousName { document.miscellaneous[name] = value }
            miscellaneousName = nil
        case "part": currentPartIndex = nil

        // Note content
        case "step": if parent == "pitch" { note?.step = value }
        case "alter": if parent == "pitch" { note?.alter = Double(value) }
        case "octave": if parent == "pitch" { note?.octave = Int(value) }
        case "duration":
            let d = Int(value) ?? Int(Double(value) ?? -1)
            switch parent {
            case "note": note?.duration = d
            case "backup": appendItem(.backup(max(0, d)))
            case "forward": appendItem(.forward(max(0, d)))
            default: break
            }
        case "voice": if parent == "note" { note?.voice = value }
        case "staff": if parent == "note" { note?.staff = Int(value) }
        case "type": if parent == "note" { note?.type = value }
        case "dot": if parent == "note" { note?.dots += 1 }
        case "accidental": if parent == "note" { note?.accidental = value }
        case "actual-notes": if parent == "time-modification" { note?.actualNotes = Int(value) }
        case "normal-notes": if parent == "time-modification" { note?.normalNotes = Int(value) }
        case "fingering":
            if parent == "technical", note != nil { note?.fingering = Int(value) ?? ParsersMath.firstNumber(in: value).map { Int($0) } }
        case "note":
            if let n = note { appendItem(.note(n)) }
            note = nil

        // Attributes
        case "divisions": attributes?.divisions = Int(value) ?? Int(Double(value) ?? 0)
        case "fifths": attributes?.fifths = Int(value)
        case "mode": attributes?.mode = value
        case "beats":
            if parent == "time", attributes?.beats == nil {
                // Composite meters such as "3+2" are summed.
                let parts = value.split(separator: "+").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if !parts.isEmpty, parts.allSatisfy({ $0 != nil }) { attributes?.beats = parts.compactMap { $0 }.reduce(0, +) }
            }
        case "beat-type": if parent == "time", attributes?.beatType == nil { attributes?.beatType = Int(value) }
        case "staves": attributes?.staves = Int(value)
        case "sign": if parent == "clef" { clef?.sign = value }
        case "line": if parent == "clef" { clef?.line = Int(value) }
        case "clef":
            if let c = clef { attributes?.clefs.append(c) }
            clef = nil
        case "attributes":
            if let a = attributes { appendItem(.attributes(a)) }
            attributes = nil

        // Directions / tempo
        case "beat-unit": if parent == "metronome" { metronomeBeatUnit = value }
        case "per-minute": if parent == "metronome" { metronomePerMinute = ParsersMath.firstNumber(in: value) }
        case "direction":
            if let bpm = directionSoundTempo {
                appendItem(.tempo(bpm))
            } else if let perMinute = metronomePerMinute, perMinute > 0 {
                let unit = metronomeBeatUnit.flatMap { NoteValue(musicXMLName: $0) } ?? .quarter
                let unitTicks = NoteDuration(value: unit, dots: metronomeDots).ticks
                appendItem(.tempo(perMinute * Double(unitTicks) / Double(Ticks.perQuarter)))
            }
            inDirection = false

        // Barlines
        case "bar-style": barline?.style = value
        case "barline":
            if let b = barline { appendItem(.barline(b)) }
            barline = nil
        default:
            break
        }
        path.removeLast()
        text = ""
    }

    private func appendItem(_ item: ParsersMusicXMLRawItem) {
        guard let p = currentPartIndex, !document.parts[p].measures.isEmpty else { return }
        document.parts[p].measures[document.parts[p].measures.count - 1].items.append(item)
    }
}

// MARK: - Importer

/// Imports MusicXML 3.x/4.0 (`.musicxml`, `.xml`) and compressed MusicXML (`.mxl`) into a Core `Score`.
///
/// Right hand = staff 1 of a two-staff part, left hand = staff 2 (the voice decides instead when the part uses the
/// usual 1–4 / 5–8 voice numbering on both staves, which keeps cross-staff notes in their hand). Next to a two-staff
/// part, a single-staff part goes to the hand its clef suggests; when every part is single-staff, the first is the
/// right hand and the others the left. Parts sharing a hand get disjoint voice numbers (with a warning), so their
/// events never overlap within one voice. Clef changes are reported but not kept (Core has no clef concept).
/// Repeats and volta endings are kept as `Barline`
/// structure so `Score.makeTimeline()` can expand them. Grace notes are dropped. Unsupported or
/// inconsistent content produces measure-numbered diagnostics instead of failing the import.
struct ParsersMusicXMLImporter: ScoreImporter, Sendable {
    var supportedExtensions: [String] { ["musicxml", "xml", "mxl"] }
    var displayName: String { "MusicXML" }

    init() {}

    func importScore(data: Data, fileName: String) throws -> ImportResult {
        let xml: Data
        // Decide by content, not by name: some programs save plain XML with an .mxl extension (and vice versa).
        if ParsersZipArchive.isZip(data: data) {
            xml = try ParsersMusicXMLImporter.unpackMXL(data)
        } else {
            xml = data
        }
        let document = try ParsersMusicXMLImporter.readDocument(xml)
        return try ParsersMusicXMLScoreBuilder(document: document, fileName: fileName).build()
    }

    /// Parses MusicXML text (already unpacked) to a score.
    func importScore(xml: String, fileName: String = "score.musicxml") throws -> ImportResult {
        try importScore(data: Data(xml.utf8), fileName: fileName)
    }

    /// Extracts the root MusicXML file from an `.mxl` ZIP container.
    static func unpackMXL(_ data: Data) throws -> Data {
        let archive: ParsersZipArchive
        do { archive = try ParsersZipArchive(data: data) } catch {
            throw ImportError.malformed("Compressed MusicXML (.mxl): \(error.localizedDescription)")
        }
        var rootPath: String? = nil
        if let container = archive.entry(named: "META-INF/container.xml"), let bytes = try? archive.contents(of: container) {
            rootPath = ParsersMusicXMLContainerReader.rootFilePath(in: bytes)
        }
        let candidate = rootPath.flatMap { archive.entry(named: $0) }
            ?? archive.entries.first { e in
                let lower = e.name.lowercased()
                return !lower.hasPrefix("meta-inf/") && (lower.hasSuffix(".xml") || lower.hasSuffix(".musicxml"))
            }
        guard let entry = candidate else { throw ImportError.malformed("The .mxl archive contains no MusicXML file.") }
        do { return try archive.contents(of: entry) } catch {
            throw ImportError.malformed("Compressed MusicXML (.mxl): \(error.localizedDescription)")
        }
    }

    /// Runs the SAX pass and checks the root element.
    static func readDocument(_ xml: Data) throws -> ParsersMusicXMLRawDocument {
        var data = xml
        // Strip a UTF-8 BOM, which XMLParser rejects in some configurations.
        if data.count >= 3, data[data.startIndex] == 0xEF, data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            data = data.dropFirst(3)
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let delegate = ParsersMusicXMLSAXDelegate()
        parser.delegate = delegate
        let ok = parser.parse()
        if !ok {
            let line = parser.lineNumber
            let reason = parser.parserError?.localizedDescription ?? "XML syntax error"
            throw ImportError.malformed("\(reason) (line \(line))")
        }
        let document = delegate.document
        guard let root = document.rootElement else { throw ImportError.unsupportedFormat("not a MusicXML document") }
        guard root == "score-partwise" || root == "score-timewise" else { throw ImportError.unsupportedFormat("<\(root)> is not a MusicXML score") }
        return document
    }
}

/// Reads `META-INF/container.xml` of an `.mxl` archive to find the root file path.
final class ParsersMusicXMLContainerReader: NSObject, XMLParserDelegate {
    private var path: String?

    /// The `full-path` of the first `<rootfile>`, or nil.
    static func rootFilePath(in data: Data) -> String? {
        let reader = ParsersMusicXMLContainerReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        return reader.path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile", path == nil, let p = attributeDict["full-path"] { path = p }
    }
}

// MARK: - Score builder

/// Turns the raw document into a `Score`, merging parts and staves into the two hands.
struct ParsersMusicXMLScoreBuilder {
    let document: ParsersMusicXMLRawDocument
    let fileName: String

    /// Result of processing one measure of one part.
    private struct PartMeasure {
        var events: [MeasureEvent] = []
        var time: TimeSignature?
        var key: KeySignature?
        var tempo: Double?
        var barline = Barline.plain
        var numberText = ""
        var implicit = false
        var hasNotes = false
        /// Furthest position reached by notes, rests and `<forward>` (ticks), used for pickup detection.
        var furthest: Ticks = 0
    }

    /// Facts about a part gathered before building.
    private struct PartProfile {
        var part: ParsersMusicXMLRawPart
        var hasPitchedNotes: Bool
        var usesTwoStaves: Bool
        var firstClefIsBass: Bool
        /// Raw voice ids per hand, in a stable order; index + 1 = Core voice number (used when the ids are not conventional).
        var voiceIDs: [Hand: [String]]
        /// The part follows the usual numbering (voices 1–4 on staff 1, 5–8 on staff 2), so the voice decides the hand
        /// and a note whose staff disagrees is cross-staff writing.
        var conventionalVoices: Bool
        /// Per hand: every voice id is numeric and inside the conventional range, so the Core voice is the id itself
        /// (minus 4 on the lower staff).
        var conventionalVoiceNumbers: [Hand: Bool]
    }

    init(document: ParsersMusicXMLRawDocument, fileName: String) {
        self.document = document
        self.fileName = fileName
    }

    /// Builds the score, or throws `ImportError.empty` when the file holds no notes.
    func build() throws -> ImportResult {
        var log = ParsersDiagnosticLog()
        let orderedParts = orderParts()
        let profiles = orderedParts.map { profile(of: $0) }
        let notedProfiles = profiles.filter { $0.hasPitchedNotes }
        guard !notedProfiles.isEmpty else { throw ImportError.empty }
        let layout = PartLayout(notedPartCount: notedProfiles.count, hasGrandStaffPart: notedProfiles.contains { $0.usesTwoStaves })

        // Parts that share a hand get disjoint voice numbers: each later part's voices are numbered after the highest
        // voice the earlier parts used in that hand (so a melody part plus a grand-staff piano part never collide).
        var perPart: [[PartMeasure]] = []
        var voiceBase: [Hand: Int] = [.right: 0, .left: 0]
        var handOwners: [Hand: [String]] = [.right: [], .left: []]
        for (rank, profile) in notedProfiles.enumerated() {
            let processed = processPart(profile, rank: rank, layout: layout, voiceOffset: voiceBase, log: &log)
            perPart.append(processed.measures)
            for hand in Hand.allCases {
                let used = processed.maxVoice[hand] ?? 0
                guard used > 0 else { continue }
                voiceBase[hand, default: 0] += used
                handOwners[hand, default: []].append(partLabel(profile.part))
            }
        }
        for hand in Hand.allCases {
            let owners = handOwners[hand] ?? []
            if owners.count > 1 {
                let list = owners.map { "\"\($0)\"" }.joined(separator: ", ")
                log.add(.warning, "Parts \(list) are all placed in the \(hand.displayName.lowercased()); each later part's voices are numbered after the earlier ones'.")
            }
        }
        let measureCount = perPart.map { $0.count }.max() ?? 0
        if Set(perPart.map { $0.count }).count > 1 {
            log.add(.warning, "Parts have different measure counts (\(perPart.map { $0.count })); missing measures are treated as empty.")
        }

        var measures: [Measure] = []
        var initialTime: TimeSignature? = nil
        var initialKey: KeySignature? = nil
        var initialTempo: Double? = nil
        var effectiveTime = TimeSignature.common
        var effectiveKey = KeySignature.cMajor
        var effectiveTempo = 100.0
        var anyNotes = false

        for i in 0..<measureCount {
            let slices = perPart.compactMap { $0.indices.contains(i) ? $0[i] : nil }
            let events = slices.flatMap { $0.events }
            let time = slices.compactMap { $0.time }.first
            let key = slices.compactMap { $0.key }.first
            let tempo = slices.compactMap { $0.tempo }.first
            var barline = Barline.plain
            for s in slices {
                barline.repeatForward = barline.repeatForward || s.barline.repeatForward
                if barline.repeatBackwardTimes == nil { barline.repeatBackwardTimes = s.barline.repeatBackwardTimes }
                if barline.endings.isEmpty { barline.endings = s.barline.endings }
                barline.isFinal = barline.isFinal || s.barline.isFinal
            }
            let numberText = slices.first?.numberText ?? ""
            let implicit = slices.contains { $0.implicit }
            anyNotes = anyNotes || slices.contains { $0.hasNotes }

            var measureTime: TimeSignature? = nil
            var measureKey: KeySignature? = nil
            var measureTempo: Double? = nil
            if i == 0 {
                initialTime = time
                initialKey = key
                initialTempo = tempo
                effectiveTime = time ?? .common
                effectiveKey = key ?? .cMajor
                effectiveTempo = tempo ?? 100
            } else {
                if let t = time, t != effectiveTime { measureTime = t; effectiveTime = t }
                if let k = key, k != effectiveKey { measureKey = k; effectiveKey = k }
                if let b = tempo, abs(b - effectiveTempo) > 0.001 { measureTempo = b; effectiveTempo = b }
            }

            let parsedNumber = Int(numberText.trimmingCharacters(in: .whitespaces))
            let content = events.map { $0.end }.max() ?? 0
            let reached = max(content, slices.map { $0.furthest }.max() ?? 0)
            var isPickup = false
            if i == 0 {
                // An anacrusis: the first measure is shorter than the meter (whether or not it is flagged implicit).
                isPickup = reached > 0 && reached < effectiveTime.measureTicks
            } else if implicit, reached > 0, reached < effectiveTime.measureTicks {
                // A measure split around a repeat or section break (`implicit="yes"` mid-score) keeps its short length.
                isPickup = true
            }
            let number = parsedNumber ?? (isPickup ? 0 : i + 1)
            if content > effectiveTime.measureTicks {
                log.add(.error, measureIndex: i, "Measure holds \(content) ticks but the meter \(effectiveTime) allows \(effectiveTime.measureTicks).")
            }
            measures.append(Measure(number: number, timeSignature: measureTime, keySignature: measureKey, tempoBPM: measureTempo, isPickup: isPickup, events: events, barline: barline))
        }

        guard anyNotes else { throw ImportError.empty }
        if initialTime == nil { log.add(.warning, measureIndex: 0, "No time signature found; assuming 4/4.") }
        if initialTempo == nil { log.add(.info, measureIndex: 0, "No tempo marking found; using 100 BPM.") }

        let title = document.title ?? ParsersMusicXMLScoreBuilder.titleFromFileName(fileName)
        let misc = document.miscellaneous
        let metadata = ScoreMetadata(
            title: title,
            composer: document.composer ?? "",
            arrangementLabel: misc[ParsersMusicXMLExporter.fieldArrangement] ?? "",
            difficulty: misc[ParsersMusicXMLExporter.fieldDifficulty].flatMap { Difficulty(rawValue: $0) },
            genre: misc[ParsersMusicXMLExporter.fieldGenre] ?? "",
            source: .musicXML,
            sourceFileName: fileName,
            notes: misc[ParsersMusicXMLExporter.fieldNotes] ?? ""
        )
        let score = Score(metadata: metadata, initialTime: initialTime ?? .common, initialKey: initialKey ?? .cMajor, initialTempoBPM: initialTempo ?? 100, measures: measures)
        return ImportResult(score: score, diagnostics: log.result)
    }

    /// Derives a title from a file name ("fur-elise__beginner.musicxml" → "fur-elise beginner").
    static func titleFromFileName(_ fileName: String) -> String {
        var base = (fileName as NSString).lastPathComponent
        if let dot = base.lastIndex(of: ".") { base = String(base[..<dot]) }
        let cleaned = base.replacingOccurrences(of: "__", with: " ").replacingOccurrences(of: "_", with: " ")
        return cleaned.isEmpty ? "Imported score" : cleaned
    }

    /// How single-staff parts are distributed over the hands.
    private struct PartLayout {
        var notedPartCount: Int
        /// Some part is a two-staff (grand staff) piano part; single-staff parts are then placed by their clef.
        var hasGrandStaffPart: Bool
    }

    /// Display name of a part for messages: its `<part-name>` when present, otherwise its id.
    private func partLabel(_ part: ParsersMusicXMLRawPart) -> String {
        let name = document.partList.first { $0.id == part.id }?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? part.id : name
    }

    // MARK: Part analysis

    private func orderParts() -> [ParsersMusicXMLRawPart] {
        var ordered: [ParsersMusicXMLRawPart] = []
        for entry in document.partList {
            if let p = document.parts.first(where: { $0.id == entry.id }) { ordered.append(p) }
        }
        for p in document.parts where !ordered.contains(where: { $0.id == p.id }) { ordered.append(p) }
        return ordered
    }

    private func profile(of part: ParsersMusicXMLRawPart) -> PartProfile {
        var pitched = false
        var twoStaves = false
        var firstClefIsBass = false
        var sawClef = false
        for m in part.measures {
            for item in m.items {
                switch item {
                case .attributes(let a):
                    if let s = a.staves, s >= 2 { twoStaves = true }
                    if a.clefs.contains(where: { $0.number >= 2 }) { twoStaves = true }
                    if !sawClef, let first = a.clefs.first(where: { $0.number == 1 }) ?? a.clefs.first {
                        sawClef = true
                        firstClefIsBass = first.sign == "F"
                    }
                case .note(let n):
                    if !n.isRest && !n.isGrace && !n.isUnpitched && n.step != nil { pitched = true }
                    if let s = n.staff, s >= 2 { twoStaves = true }
                default: break
                }
            }
        }
        let notes = part.measures.flatMap { m in m.items.compactMap { item -> ParsersMusicXMLRawNote? in
            if case .note(let n) = item, !n.isGrace, !n.isCue { return n }
            return nil
        } }
        let conventional = twoStaves && ParsersMusicXMLScoreBuilder.usesConventionalVoices(notes)
        // Collect voice ids per hand (hand depends on the staff layout only; part rank is applied later).
        var rawVoices: [Hand: [String]] = [.right: [], .left: []]
        for n in notes {
            let hand: Hand
            if conventional, let v = Int(n.voice ?? "") {
                hand = v <= 4 ? .right : .left
            } else {
                hand = twoStaves ? ((n.staff ?? 1) >= 2 ? .left : .right) : .right
            }
            let v = n.voice ?? "1"
            if !(rawVoices[hand] ?? []).contains(v) { rawVoices[hand, default: []].append(v) }
        }
        var conventionalNumbers: [Hand: Bool] = [:]
        for hand in Hand.allCases {
            let ids = (rawVoices[hand] ?? []).sorted { a, b in
                if let x = Int(a), let y = Int(b) { return x < y }
                return a < b
            }
            rawVoices[hand] = ids
            let base = (twoStaves && hand == .left) ? 4 : 0
            conventionalNumbers[hand] = ids.allSatisfy { id in Int(id).map { (base + 1)...(base + 4) ~= $0 } ?? false }
        }
        return PartProfile(part: part, hasPitchedNotes: pitched, usesTwoStaves: twoStaves, firstClefIsBass: firstClefIsBass,
                           voiceIDs: rawVoices, conventionalVoices: conventional, conventionalVoiceNumbers: conventionalNumbers)
    }

    /// Whether a two-staff part follows the usual voice numbering (voices 1–4 on staff 1, 5–8 on staff 2), so that the
    /// voice decides the hand and a note whose staff disagrees is cross-staff writing.
    ///
    /// Agreement is measured per staff, so a part dominated by right-hand notes cannot outvote a lower staff that uses
    /// voice 2: every voice id must be numeric (1–8), at least 80 % of the staff-1 notes must use voices 1–4, at least
    /// 50 % of the staff-2 notes must use voices 5–8, and at least one staff-2 note must use voices 5–8. Otherwise the
    /// staff decides the hand.
    static func usesConventionalVoices(_ notes: [ParsersMusicXMLRawNote]) -> Bool {
        guard !notes.isEmpty else { return false }
        let allNumeric = notes.allSatisfy { n in Int(n.voice ?? "").map { (1...8).contains($0) } ?? false }
        guard allNumeric else { return false }
        func voice(_ n: ParsersMusicXMLRawNote) -> Int { Int(n.voice ?? "") ?? 0 }
        let upper = notes.filter { ($0.staff ?? 1) == 1 }
        let lower = notes.filter { $0.staff == 2 }
        let upperAgreeing = upper.filter { (1...4).contains(voice($0)) }.count
        let lowerAgreeing = lower.filter { (5...8).contains(voice($0)) }.count
        guard lowerAgreeing >= 1 else { return false }
        return Double(upperAgreeing) >= 0.8 * Double(upper.count) && Double(lowerAgreeing) >= 0.5 * Double(lower.count)
    }

    // MARK: Part processing

    /// Converts one part's measures. `voiceOffset` is added to every Core voice number of the given hand (the voices
    /// earlier parts already use there); the result reports the highest voice this part used per hand, before the offset.
    private func processPart(_ profile: PartProfile, rank: Int, layout: PartLayout, voiceOffset: [Hand: Int],
                             log: inout ParsersDiagnosticLog) -> (measures: [PartMeasure], maxVoice: [Hand: Int]) {
        var out: [PartMeasure] = []
        var maxVoice: [Hand: Int] = [:]
        var converter: ParsersTickConverter? = nil
        var openEndings: [Int] = []
        var warnedStaff3 = false
        var droppedGrace = 0
        var droppedCue = 0
        /// Clef in force per staff number, to report clef changes (Core has no clef concept: staff 1 is drawn in treble
        /// clef and staff 2 in bass clef, and a staff's notes keep their hand whatever its clef).
        var clefByStaff: [Int: ParsersMusicXMLRawClef] = [:]
        var clefChangeMeasures: [Int] = []

        /// Hand for a note of this part and whether it is drawn on the other hand's staff (cross-staff writing).
        func placement(staff: Int?, voice: String?) -> (hand: Hand, crossStaff: Bool) {
            if profile.usesTwoStaves {
                if let s = staff, s >= 3, !warnedStaff3 {
                    warnedStaff3 = true
                    log.add(.warning, "Part \(profile.part.id) uses more than two staves; staff \(s) is merged into the left hand.")
                }
                let staffHand: Hand = (staff ?? 1) >= 2 ? .left : .right
                if profile.conventionalVoices, let v = Int(voice ?? ""), (1...8).contains(v) {
                    let voiceHand: Hand = v <= 4 ? .right : .left
                    return (voiceHand, voiceHand != staffHand)
                }
                return (staffHand, false)
            }
            // Next to a grand-staff piano part, a single-staff part (a melody, a bass line) goes where its clef puts it.
            if layout.hasGrandStaffPart || layout.notedPartCount < 2 { return (profile.firstClefIsBass ? .left : .right, false) }
            // Only single-staff parts: the first is the right hand, the others the left.
            return (rank == 0 ? .right : .left, false)
        }

        /// Core voice number (1 = main) for a raw voice id. Single-staff parts always report the voices under the hand they map to.
        func voiceNumber(_ raw: String?, hand: Hand) -> Int {
            let lookupHand: Hand = profile.usesTwoStaves ? hand : .right
            if profile.conventionalVoiceNumbers[lookupHand] == true, let v = Int(raw ?? "1") {
                return (profile.usesTwoStaves && lookupHand == .left) ? v - 4 : v
            }
            let ids = profile.voiceIDs[lookupHand] ?? []
            if let idx = ids.firstIndex(of: raw ?? "1") { return idx + 1 }
            return 1
        }

        for (mi, raw) in profile.part.measures.enumerated() {
            var pm = PartMeasure()
            pm.numberText = raw.number
            pm.implicit = raw.implicit
            var cursor: Double = 0
            var events: [MeasureEvent] = []
            var lastEventIndex: Int? = nil
            var measureEndings = openEndings
            var closeEndingsAfter = false

            for item in raw.items {
                switch item {
                case .attributes(let a):
                    for clef in a.clefs {
                        if let previous = clefByStaff[clef.number], previous.sign != clef.sign || previous.line != clef.line,
                           clefChangeMeasures.last != mi {
                            clefChangeMeasures.append(mi)
                        }
                        clefByStaff[clef.number] = clef
                    }
                    if let d = a.divisions {
                        if d > 0 { converter = ParsersTickConverter(divisions: d) } else { log.add(.error, measureIndex: mi, "Invalid <divisions> value \(d).") }
                    }
                    if let f = a.fifths {
                        let mode: KeySignature.Mode = a.mode?.lowercased() == "minor" ? .minor : .major
                        pm.key = KeySignature(fifths: f, mode: mode)
                        if abs(f) > 7 { log.add(.warning, measureIndex: mi, "Key signature with \(f) fifths was clamped.") }
                    }
                    if let b = a.beats, let t = a.beatType, b > 0, t > 0 {
                        pm.time = TimeSignature(beats: b, beatType: t)
                    } else if a.beats != nil || a.beatType != nil {
                        log.add(.warning, measureIndex: mi, "Incomplete <time> element ignored.")
                    }
                case .tempo(let bpm):
                    if pm.tempo == nil { pm.tempo = bpm } else { log.add(.info, measureIndex: mi, "Only the first tempo marking in a measure is used.") }
                case .barline(let b):
                    if b.repeatDirection == "forward" { pm.barline.repeatForward = true }
                    if b.repeatDirection == "backward" { pm.barline.repeatBackwardTimes = max(2, b.repeatTimes ?? 2) }
                    // A thick closing bar is a final barline unless it is just the look of a backward repeat.
                    if (b.style == "light-heavy" || b.style == "heavy-heavy"), b.location != "left", b.repeatDirection != "backward" {
                        pm.barline.isFinal = true
                    }
                    switch b.endingType {
                    case "start":
                        let numbers = b.endingNumbers.isEmpty ? [1] : b.endingNumbers
                        openEndings = numbers
                        measureEndings = numbers
                    case "stop", "discontinue":
                        if measureEndings.isEmpty { measureEndings = b.endingNumbers.isEmpty ? openEndings : b.endingNumbers }
                        closeEndingsAfter = true
                    default: break
                    }
                case .backup(let d):
                    guard let c = converter else { log.add(.error, measureIndex: mi, "<backup> before <divisions> is defined."); continue }
                    cursor -= Double(d) * c.ticksPerUnit
                    if cursor < -0.5 {
                        log.add(.warning, measureIndex: mi, "<backup> moved before the start of the measure; clamped.")
                        cursor = 0
                    }
                case .forward(let d):
                    guard let c = converter else { log.add(.error, measureIndex: mi, "<forward> before <divisions> is defined."); continue }
                    cursor += Double(d) * c.ticksPerUnit
                    pm.furthest = max(pm.furthest, Int(cursor.rounded()))
                case .note(let n):
                    if n.isGrace { droppedGrace += 1; continue }
                    if n.isCue { droppedCue += 1; continue }
                    guard let c = converter else {
                        log.add(.error, measureIndex: mi, "Note at line \(n.line) appears before <divisions> is defined; skipped.")
                        continue
                    }
                    let place = placement(staff: n.staff, voice: n.voice)
                    let noteHand = place.hand
                    let partVoice = voiceNumber(n.voice, hand: noteHand)
                    let noteVoice = partVoice + (voiceOffset[noteHand] ?? 0)
                    // Pitch
                    var chordNote: ChordNote? = nil
                    if !n.isRest {
                        if n.isUnpitched {
                            log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "Unpitched note treated as a rest.")
                        } else if let stepName = n.step, let step = Step(name: stepName), let octave = n.octave {
                            let alterValue = n.alter ?? 0
                            let alter = Int(alterValue.rounded())
                            if abs(alterValue - Double(alter)) > 0.01 {
                                log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "Microtonal alteration \(alterValue) rounded to \(alter).")
                            }
                            let pitch = Pitch(step: step, alter: max(-2, min(2, alter)), octave: octave)
                            if !Pitch.pianoRange.contains(pitch.midi) {
                                log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "\(pitch.name) is outside the 88-key range.")
                            }
                            chordNote = ChordNote(
                                pitch: pitch,
                                tieStart: n.tieStart || n.tiedStart,
                                tieStop: n.tieStop || n.tiedStop,
                                fingering: n.fingering,
                                accidental: n.accidental.flatMap { ParsersMath.accidental(musicXML: $0) }
                            )
                        } else {
                            log.add(.error, measureIndex: mi, hand: noteHand, voice: noteVoice, "Note at line \(n.line) has no usable <pitch>; skipped.")
                            if !n.isChord, let d = n.duration { cursor += Double(d) * c.ticksPerUnit }
                            continue
                        }
                    }
                    if n.isChord {
                        if let idx = lastEventIndex, let cn = chordNote {
                            if events[idx].isRest {
                                log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "A <chord/> note follows a rest; it was started as its own event.")
                            } else {
                                if events[idx].notes.contains(where: { $0.midi == cn.midi }) {
                                    log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "Chord repeats \(cn.pitch.name).")
                                }
                                var notes = events[idx].notes
                                notes.append(cn)
                                events[idx].notes = notes.sorted { $0.pitch < $1.pitch }
                                continue
                            }
                        } else if chordNote == nil {
                            continue // a chord rest carries no information
                        } else {
                            log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "<chord/> without a preceding note at line \(n.line); treated as a normal note.")
                        }
                        // Fall through: start a new event at the chord position (cursor is already past the previous note).
                        guard let d = n.duration, d > 0 else { continue }
                        let previousOnset = lastEventIndex.map { events[$0].onset } ?? Int(cursor.rounded())
                        let span = c.span(from: Double(previousOnset), units: d)
                        if let cn = chordNote {
                            events.append(MeasureEvent(onset: span.onset, duration: max(1, span.end - span.onset), notated: notated(for: n, ticks: span.end - span.onset), notes: [cn], hand: noteHand, voice: noteVoice, drawnOnOtherStaff: place.crossStaff))
                            pm.furthest = max(pm.furthest, span.end)
                            lastEventIndex = events.count - 1
                            pm.hasNotes = true
                        }
                        continue
                    }
                    guard let d = n.duration else {
                        log.add(.error, measureIndex: mi, hand: noteHand, voice: noteVoice, "Note at line \(n.line) has no <duration>; skipped.")
                        continue
                    }
                    let span = c.span(from: cursor, units: d)
                    let ticks = span.end - span.onset
                    cursor += Double(d) * c.ticksPerUnit
                    if ticks <= 0 {
                        log.add(.warning, measureIndex: mi, hand: noteHand, voice: noteVoice, "Note at line \(n.line) has a zero duration; skipped.")
                        continue
                    }
                    let notes = chordNote.map { [$0] } ?? []
                    events.append(MeasureEvent(onset: span.onset, duration: ticks, notated: notated(for: n, ticks: ticks), notes: notes, hand: noteHand, voice: noteVoice, drawnOnOtherStaff: place.crossStaff))
                    pm.furthest = max(pm.furthest, span.end)
                    lastEventIndex = events.count - 1
                    if !notes.isEmpty { pm.hasNotes = true }
                }
            }

            pm.barline.endings = measureEndings
            if closeEndingsAfter { openEndings = [] }
            for e in events {
                maxVoice[e.hand] = max(maxVoice[e.hand] ?? 0, e.voice - (voiceOffset[e.hand] ?? 0))
            }
            pm.events = events
            out.append(pm)
        }
        if droppedGrace > 0 { log.add(.info, "\(droppedGrace) grace note(s) were dropped (they are not practised).") }
        if droppedCue > 0 { log.add(.info, "\(droppedCue) cue note(s) were dropped.") }
        if let first = clefChangeMeasures.first {
            let where_ = clefChangeMeasures.count == 1 ? "measure \(first + 1)" : "\(clefChangeMeasures.count) places (first in measure \(first + 1))"
            log.add(.info, measureIndex: first, "Part \(partLabel(profile.part)) changes clef in \(where_); clef changes are not kept (staff 1 is shown in treble clef, staff 2 in bass clef), and the notes keep their hand and pitch.")
        }
        if converter == nil { log.add(.error, measureIndex: 0, "Part \(profile.part.id) never defines <divisions>.") }
        return (out, maxVoice)
    }

    /// The notated value for a note when `<type>` (+ dots + tuplet) matches its tick length exactly; otherwise nil so
    /// Core can fall back to `NoteDuration.exact`.
    private func notated(for n: ParsersMusicXMLRawNote, ticks: Ticks) -> NoteDuration? {
        guard let typeName = n.type, let value = NoteValue(musicXMLName: typeName) else { return nil }
        var tuplet: Tuplet? = nil
        if let a = n.actualNotes, let b = n.normalNotes, a > 0, b > 0, a != b { tuplet = Tuplet(actual: a, normal: b) }
        let nd = NoteDuration(value: value, dots: n.dots, tuplet: tuplet)
        return nd.ticks == ticks ? nd : nil
    }
}
