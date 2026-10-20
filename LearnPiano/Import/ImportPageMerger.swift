import Foundation

/// The transcription of one image (a page, or half of a dense page), already parsed into a `Score`.
struct ImportPageTranscription: Sendable {
    /// 0-based page index in the document.
    var pageIndex: Int
    /// The page as its own small score (measure indices are page-local).
    var score: Score
    /// Parser diagnostics for this page (page-local measure indices).
    var diagnostics: [ScoreDiagnostic]
    /// Model confidence per page-local measure (nil where the reply did not state one).
    var confidence: [Double?]
    /// The `pickup` value of the reply.
    var pickup: Bool
    /// Raw LPC JSON of the first and the last image segment (the same for an unsplit page); used to join ties across pages.
    var headJSON: Data
    var tailJSON: Data
    /// Errors still present after the repair rounds.
    var unresolvedErrorCount: Int
    /// Repair requests that were sent.
    var repairRounds: Int
    /// Title/composer as printed (empty when not shown).
    var printedTitle: String
    var printedComposer: String

    init(pageIndex: Int, score: Score, diagnostics: [ScoreDiagnostic] = [], confidence: [Double?] = [], pickup: Bool = false,
         headJSON: Data = Data(), tailJSON: Data = Data(), unresolvedErrorCount: Int = 0, repairRounds: Int = 0,
         printedTitle: String = "", printedComposer: String = "") {
        self.pageIndex = pageIndex
        self.score = score
        self.diagnostics = diagnostics
        self.confidence = confidence
        self.pickup = pickup
        self.headJSON = headJSON
        self.tailJSON = tailJSON
        self.unresolvedErrorCount = unresolvedErrorCount
        self.repairRounds = repairRounds
        self.printedTitle = printedTitle
        self.printedComposer = printedComposer
    }

    var measureCount: Int { score.measures.count }
}

/// Pages concatenated into one score.
struct ImportMergedScore: Sendable {
    var score: Score
    /// Diagnostics with measure indices into the merged score.
    var diagnostics: [ScoreDiagnostic]
    /// Confidence per merged measure.
    var confidence: [Double?]
    /// Which merged measures came from which part (same order as the parts).
    var partRanges: [Range<Int>]
}

/// Concatenates per-page scores: renumbers measures, carries key/time/tempo across page boundaries (writing a change
/// on a page's first measure when it differs from what is in force), joins ties that cross a page break, keeps only
/// the last barline final and shifts diagnostics and confidence.
enum ImportPageMerger {
    static func merge(_ parts: [ImportPageTranscription], title fallbackTitle: String = "Imported score", sourceFileName: String? = nil) -> ImportMergedScore {
        guard let first = parts.first else {
            let empty = Score(metadata: ScoreMetadata(title: fallbackTitle, source: .sheetTranscription, sourceFileName: sourceFileName), measures: [])
            return ImportMergedScore(score: empty, diagnostics: [], confidence: [], partRanges: [])
        }
        let title = parts.map { $0.printedTitle }.first { !$0.isEmpty } ?? fallbackTitle
        let composer = parts.map { $0.printedComposer }.first { !$0.isEmpty } ?? ""
        // Pages without music (title page, preface, blank) contribute no measures; the attributes in force at the start
        // come from the first page that has some.
        let opening = parts.first { $0.measureCount > 0 } ?? first
        var merged = Score(metadata: ScoreMetadata(title: title, composer: composer, source: .sheetTranscription, sourceFileName: sourceFileName),
                           initialTime: opening.score.initialTime, initialKey: opening.score.initialKey,
                           initialTempoBPM: opening.score.initialTempoBPM, measures: [])
        var diagnostics: [ScoreDiagnostic] = []
        var confidence: [Double?] = []
        var ranges: [Range<Int>] = []
        /// The last part merged so far that had measures (its tail JSON joins ties into the next music page).
        var previousMusicPart: ImportPageTranscription?

        for part in parts {
            let offset = merged.measures.count
            var pageMeasures = part.score.measures
            var pageDiagnostics = part.diagnostics.filter { !isEmptyMeasuresDiagnostic($0) }

            if offset > 0, !pageMeasures.isEmpty {
                pageMeasures[0].isPickup = false
                // Values in force at the end of what is merged so far.
                let inForceTime = merged.timeSignature(atMeasure: offset - 1)
                let inForceKey = merged.keySignature(atMeasure: offset - 1)
                let inForceTempo = merged.tempoBPM(atMeasure: offset - 1)
                if pageMeasures[0].timeSignature == nil, part.score.initialTime != inForceTime { pageMeasures[0].timeSignature = part.score.initialTime }
                if pageMeasures[0].keySignature == nil, part.score.initialKey != inForceKey { pageMeasures[0].keySignature = part.score.initialKey }
                if pageMeasures[0].tempoBPM == nil, abs(part.score.initialTempoBPM - inForceTempo) > 0.001 { pageMeasures[0].tempoBPM = part.score.initialTempoBPM }

                // Ties across the page break (blank pages in between do not interrupt a tie).
                if let previous = previousMusicPart {
                    let ties = crossPageTies(tailJSON: previous.tailJSON, headJSON: part.headJSON)
                    if !ties.isEmpty {
                        applyTies(ties, last: &merged.measures[offset - 1], first: &pageMeasures[0])
                        let joined = Set(ties.keys)
                        // The parsers reported both ends as unpaired; they are paired now.
                        diagnostics.removeAll { d in
                            d.measureIndex == offset - 1 && joined.contains(voiceKey(hand: d.hand, voice: d.voice)) && d.message.contains("there is no following event in this voice")
                        }
                        pageDiagnostics.removeAll { d in
                            d.measureIndex == 0 && joined.contains(voiceKey(hand: d.hand, voice: d.voice)) && d.message.contains("ends a tie that no previous event starts")
                        }
                    }
                }
            }

            merged.measures.append(contentsOf: pageMeasures)
            for i in 0..<pageMeasures.count { confidence.append(part.confidence.indices.contains(i) ? part.confidence[i] : nil) }
            for d in pageDiagnostics {
                var shifted = d
                shifted.measureIndex = d.measureIndex.map { $0 + offset }
                diagnostics.append(shifted)
            }
            ranges.append(offset..<(offset + pageMeasures.count))
            if !pageMeasures.isEmpty { previousMusicPart = part }
        }

        renumber(&merged)
        return ImportMergedScore(score: merged, diagnostics: diagnostics, confidence: confidence, partRanges: ranges)
    }

    /// The parser's whole-document error for a reply with no measures, which is how the model answers for a page
    /// without music; such pages are simply skipped.
    static func isEmptyMeasuresDiagnostic(_ d: ScoreDiagnostic) -> Bool {
        d.measureIndex == nil && isEmptyMeasuresMessage(d.message)
    }

    static func isEmptyMeasuresMessage(_ message: String) -> Bool {
        message.contains("\"measures\" is empty")
    }

    /// Display numbers continue across pages (a pickup is measure 0); only the very last barline is final.
    static func renumber(_ score: inout Score) {
        let pickup = score.measures.first?.isPickup ?? false
        let last = score.measures.count - 1
        for i in score.measures.indices {
            score.measures[i].number = pickup ? i : i + 1
            score.measures[i].barline.isFinal = i == last
        }
    }

    // MARK: Ties across pages

    /// LPC voice key for a hand/voice ("rh", "lh", "rh2", "lh2"); "" when the hand is unknown.
    static func voiceKey(hand: Hand?, voice: Int?) -> String {
        guard let hand else { return "" }
        let base = hand == .right ? "rh" : "lh"
        return (voice ?? 1) >= 2 ? base + "2" : base
    }

    private static let voiceSpecs: [(key: String, hand: Hand, voice: Int)] = [("rh", .right, 1), ("lh", .left, 1), ("rh2", .right, 2), ("lh2", .left, 2)]

    /// Pitches (MIDI) per voice key where the last event of the previous image starts a tie and the first event of the
    /// next image ends one with the same pitch.
    static func crossPageTies(tailJSON: Data, headJSON: Data) -> [String: Set<Int>] {
        guard let tail = try? JSONSerialization.jsonObject(with: tailJSON) as? [String: Any],
              let head = try? JSONSerialization.jsonObject(with: headJSON) as? [String: Any],
              let lastMeasure = (tail["measures"] as? [Any])?.last as? [String: Any],
              let firstMeasure = (head["measures"] as? [Any])?.first as? [String: Any] else { return [:] }
        var out: [String: Set<Int>] = [:]
        for spec in voiceSpecs {
            guard let ending = (lastMeasure[spec.key] as? [Any])?.last as? [String: Any],
                  let starting = (firstMeasure[spec.key] as? [Any])?.first as? [String: Any] else { continue }
            let endTie = ending["tie"] as? String ?? ""
            let startTie = starting["tie"] as? String ?? ""
            guard endTie == "start" || endTie == "both", startTie == "stop" || startTie == "both" else { continue }
            let a = Set(midis(ending["p"]))
            let b = Set(midis(starting["p"]))
            let common = a.intersection(b)
            if !common.isEmpty { out[spec.key] = common }
        }
        return out
    }

    private static func midis(_ value: Any?) -> [Int] {
        ((value as? [Any]) ?? []).compactMap { ($0 as? String).flatMap { Pitch(name: $0) }?.midi }
    }

    /// Marks the tie on the last event of each voice in `last` and the first event of the same voice in `first`.
    static func applyTies(_ ties: [String: Set<Int>], last: inout Measure, first: inout Measure) {
        for spec in voiceSpecs {
            guard let pitches = ties[spec.key] else { continue }
            let lastIndex = last.events.indices.filter { last.events[$0].hand == spec.hand && last.events[$0].voice == spec.voice }
                .max { last.events[$0].onset < last.events[$1].onset }
            let firstIndex = first.events.indices.filter { first.events[$0].hand == spec.hand && first.events[$0].voice == spec.voice }
                .min { first.events[$0].onset < first.events[$1].onset }
            guard let li = lastIndex, let fi = firstIndex else { continue }
            for k in last.events[li].notes.indices where pitches.contains(last.events[li].notes[k].midi) { last.events[li].notes[k].tieStart = true }
            for k in first.events[fi].notes.indices where pitches.contains(first.events[fi].notes[k].midi) { first.events[fi].notes[k].tieStop = true }
        }
    }

    // MARK: Confidence

    /// Confidence buckets for the review strip.
    enum ConfidenceLevel: Equatable, Sendable {
        case high, medium, low, unknown
    }

    static let lowConfidenceThreshold = 0.6
    static let highConfidenceThreshold = 0.85

    static func level(_ confidence: Double?) -> ConfidenceLevel {
        guard let c = confidence else { return .unknown }
        if c >= highConfidenceThreshold { return .high }
        if c >= lowConfidenceThreshold { return .medium }
        return .low
    }

    /// Confidence with measures that still have errors capped at `cap` (they are highlighted for review).
    static func markingErrors(_ confidence: [Double?], errors: [ScoreDiagnostic], measureCount: Int, cap: Double = 0.3) -> [Double?] {
        var out = (0..<measureCount).map { confidence.indices.contains($0) ? confidence[$0] : nil }
        for e in errors where e.severity == .error {
            guard let m = e.measureIndex, out.indices.contains(m) else { continue }
            out[m] = min(out[m] ?? cap, cap)
        }
        return out
    }
}
