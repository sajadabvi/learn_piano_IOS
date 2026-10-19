import Foundation

/// Quantization grid used by the MIDI importer.
enum ParsersMIDIGrid: Hashable, Sendable {
    /// Picks the coarsest grid that the onsets fit exactly (16th, then 12-per-quarter, 32nd, 24-per-quarter); for
    /// unquantized (performed) files, the 16th grid unless the triplet-aware or 32nd grid fits much better.
    case automatic
    /// 4 positions per quarter.
    case sixteenth
    /// 12 positions per quarter: holds 16ths, eighth triplets and sixteenth triplets.
    case twelvePerQuarter
    /// 8 positions per quarter.
    case thirtySecond
    /// Any number of positions per quarter (must divide 960).
    case divisionsPerQuarter(Int)

    /// Grid step in Core ticks, or nil for `.automatic`.
    var ticks: Ticks? {
        switch self {
        case .automatic: return nil
        case .sixteenth: return Ticks.perQuarter / 4
        case .twelvePerQuarter: return Ticks.perQuarter / 12
        case .thirtySecond: return Ticks.perQuarter / 8
        case .divisionsPerQuarter(let n):
            let d = max(1, min(Ticks.perQuarter, n))
            return Ticks.perQuarter % d == 0 ? Ticks.perQuarter / d : Ticks.perQuarter / 4
        }
    }
}

/// A note after tick conversion and quantization, in Core ticks on the absolute (notated) axis.
struct ParsersMIDINote: Hashable, Sendable {
    var onset: Ticks
    var end: Ticks
    var midi: Int
    /// Index of the (track, channel) stream the note came from.
    var stream: Int
    var duration: Ticks { end - onset }
}

/// Imports Standard MIDI Files (type 0/1) into a two-hand `Score`.
///
/// Pipeline: read the file (`ParsersMIDIFileReader`) → convert ticks to Core ticks → choose a grid and quantize onsets
/// and ends → split hands (two tracks/channels → lower average pitch is the left hand; otherwise a middle-C split
/// that keeps a low note in the right hand when the right hand is idle and the note lies within a sixth of its
/// recent centroid) → per hand, trim small legato overlaps and move held notes that span later attacks into voice 2 →
/// slice each voice at every onset, release and barline into chord/rest events, writing lengths that are not a single
/// note value as tied (or consecutive) dotted/plain/triplet values → measures from the time-signature map (a short
/// first meter segment becomes a pickup), tempo per measure (time-weighted average of the tempo map), key from the
/// key-signature meta event or estimated from the pitch histogram (Krumhansl–Kessler profiles).
struct ParsersMIDIImporter: ScoreImporter, Sendable {
    var supportedExtensions: [String] { ["mid", "midi", "smf", "kar"] }
    var displayName: String { "MIDI" }

    /// Quantization grid.
    var grid: ParsersMIDIGrid
    /// Split point used when the file has a single stream: notes at or above this MIDI number go to the right hand.
    var splitPoint: Int

    init(grid: ParsersMIDIGrid = .automatic, splitPoint: Int = 60) {
        self.grid = grid
        self.splitPoint = splitPoint
    }

    func importScore(data: Data, fileName: String) throws -> ImportResult {
        var log = ParsersDiagnosticLog()
        let content = try ParsersMIDIFileReader.read(data, log: &log)
        return try ParsersMIDIScoreBuilder(content: content, fileName: fileName, grid: grid, splitPoint: splitPoint).build(log: &log)
    }

    // MARK: Pure steps (exposed for tests)

    /// Mean distance (ticks) from each onset to the nearest multiple of `step`.
    static func meanGridError(onsets: [Ticks], step: Ticks) -> Double {
        guard !onsets.isEmpty, step > 0 else { return 0 }
        let total = onsets.reduce(0) { acc, t in
            let r = ((t % step) + step) % step
            return acc + min(r, step - r)
        }
        return Double(total) / Double(onsets.count)
    }

    /// Fraction of onsets lying within `tolerance` ticks of a multiple of `step`.
    static func fitFraction(onsets: [Ticks], step: Ticks, tolerance: Ticks) -> Double {
        guard !onsets.isEmpty, step > 0 else { return 1 }
        let hits = onsets.filter { t in
            let r = ((t % step) + step) % step
            return min(r, step - r) <= tolerance
        }.count
        return Double(hits) / Double(onsets.count)
    }

    /// The grid `.automatic` chooses for these onsets (Core ticks).
    ///
    /// A sequenced (already quantized) file gets the coarsest grid that at least 99.5 % of its onsets sit on within
    /// 1/96 quarter: the 16th grid, else the triplet-aware 12-per-quarter grid, else the 32nd grid, else the
    /// 24-per-quarter grid that holds 32nds and triplets together. A performed file fits none of them; it gets the 16th
    /// grid, or the 12-per-quarter grid when the 16th grid misses noticeably (> 1/80 quarter on average) and the
    /// triplet-aware grid at least halves the error, or the 32nd grid when it beats both by the same margin.
    static func chooseGrid(onsets: [Ticks]) -> Ticks {
        let sixteenth = Ticks.perQuarter / 4, twelve = Ticks.perQuarter / 12, thirtySecond = Ticks.perQuarter / 8
        let tolerance = Ticks.perQuarter / 96
        for step in [sixteenth, twelve, thirtySecond, Ticks.perQuarter / 24]
        where fitFraction(onsets: onsets, step: step, tolerance: tolerance) >= 0.995 {
            return step
        }
        let e16 = meanGridError(onsets: onsets, step: sixteenth)
        let e12 = meanGridError(onsets: onsets, step: twelve)
        let e32 = meanGridError(onsets: onsets, step: thirtySecond)
        let threshold = Double(Ticks.perQuarter) / 80
        guard e16 > threshold else { return sixteenth }
        if e32 < e12 * 0.5, e32 < e16 * 0.5 { return thirtySecond }
        if e12 < e16 * 0.5 { return twelve }
        return sixteenth
    }

    /// Snaps onsets and ends to the grid. Every note keeps at least one grid step; a note that would run into a later
    /// attack of the same pitch in the same stream is cut there; exact duplicates (same stream, pitch and onset) keep
    /// the longer note. Unisons between streams (both hands on one key) are kept.
    static func quantize(_ notes: [ParsersMIDINote], step: Ticks) -> [ParsersMIDINote] {
        guard step > 0 else { return notes }
        func snap(_ t: Ticks) -> Ticks { Int((Double(t) / Double(step)).rounded()) * step }
        var out = notes.map { n -> ParsersMIDINote in
            var q = n
            q.onset = max(0, snap(n.onset))
            q.end = max(q.onset + step, snap(n.end))
            return q
        }
        out.sort { ($0.stream, $0.midi, $0.onset, -$0.end) < ($1.stream, $1.midi, $1.onset, -$1.end) }
        var cleaned: [ParsersMIDINote] = []
        for n in out {
            if var last = cleaned.last, last.midi == n.midi, last.stream == n.stream {
                if last.onset == n.onset { continue } // duplicate attack: the longer one was kept (sorted first)
                if last.end > n.onset {
                    last.end = n.onset
                    cleaned[cleaned.count - 1] = last
                }
            }
            cleaned.append(n)
        }
        return cleaned.sorted { ($0.onset, $0.midi, $0.stream) < ($1.onset, $1.midi, $1.stream) }
    }

    /// Assigns each note to a hand.
    ///
    /// - `streamHands` (from track names such as "Left hand" or "RH") decides when it names a hand for every stream.
    /// - With exactly two streams, the stream with the lower average pitch is the left hand (on a tie, the second).
    /// - Otherwise notes at or above `splitPoint` are right-hand notes; a lower note is still given to the right hand
    ///   when nothing in the right hand is sounding or starting at its onset and it lies within a major sixth
    ///   (9 semitones) below the right hand's recent centroid.
    static func assignHands(_ notes: [ParsersMIDINote], streamCount: Int, splitPoint: Int = 60, streamHands: [Int: Hand] = [:]) -> [Hand] {
        let used = Set(notes.map { $0.stream })
        if !used.isEmpty, used.allSatisfy({ streamHands[$0] != nil }) {
            return notes.map { streamHands[$0.stream] ?? .right }
        }
        if streamCount == 2 {
            var sums = [0.0, 0.0], counts = [0.0, 0.0]
            for n in notes where n.stream < 2 { sums[n.stream] += Double(n.midi); counts[n.stream] += 1 }
            if counts[0] > 0, counts[1] > 0 {
                let leftStream = sums[0] / counts[0] < sums[1] / counts[1] ? 0 : 1
                return notes.map { $0.stream == leftStream ? .left : .right }
            }
        }
        // Process in onset order, higher pitches first, so the right hand's notes at an onset are seen before low notes.
        let order = notes.indices.sorted { (notes[$0].onset, -notes[$0].midi) < (notes[$1].onset, -notes[$1].midi) }
        var hands = [Hand](repeating: .right, count: notes.count)
        let upper = notes.filter { $0.midi >= splitPoint }.map { Double($0.midi) }
        var centroid = upper.isEmpty ? Double(splitPoint + 7) : upper.reduce(0, +) / Double(upper.count)
        var rightBusyUntil: Ticks = Int.min
        var rightOnsets = Set<Ticks>()
        for i in order {
            let n = notes[i]
            var hand: Hand = n.midi >= splitPoint ? .right : .left
            if hand == .left {
                let idle = rightBusyUntil <= n.onset && !rightOnsets.contains(n.onset)
                if idle && centroid - Double(n.midi) <= 9 { hand = .right }
            }
            hands[i] = hand
            if hand == .right {
                centroid = 0.75 * centroid + 0.25 * Double(n.midi)
                rightBusyUntil = max(rightBusyUntil, n.end)
                rightOnsets.insert(n.onset)
            }
        }
        return hands
    }

    /// The hand a track name refers to ("Left hand", "LH", "Bass", "Piano RH", "Treble"…), or nil.
    static func hand(forTrackName name: String) -> Hand? {
        let lower = name.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && $0 != "." }).map(String.init))
        if lower.contains("left") || lower.contains("links") || lower.contains("bass") || words.contains("lh") || words.contains("l.h.") || words.contains("l.h") { return .left }
        if lower.contains("right") || lower.contains("rechts") || lower.contains("treble") || words.contains("rh") || words.contains("r.h.") || words.contains("r.h") { return .right }
        return nil
    }

    /// Estimates the key from a duration-weighted pitch-class histogram (index 0 = C) using the Krumhansl–Kessler
    /// key profiles; nil for an empty histogram.
    static func estimateKey(histogram: [Double]) -> KeySignature? {
        guard histogram.count == 12, histogram.contains(where: { $0 > 0 }) else { return nil }
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
        }
        var best: (score: Double, tonic: Int, minor: Bool) = (-2, 0, false)
        for tonic in 0..<12 {
            let rotated = (0..<12).map { histogram[(tonic + $0) % 12] }
            let maj = correlation(rotated, major), min = correlation(rotated, minor)
            if maj > best.score { best = (maj, tonic, false) }
            if min > best.score { best = (min, tonic, true) }
        }
        let majorTonic = best.minor ? (best.tonic + 3) % 12 : best.tonic
        var fifths = (majorTonic * 7) % 12
        if fifths > 6 { fifths -= 12 }
        return KeySignature(fifths: fifths, mode: best.minor ? .minor : .major)
    }
}

/// Builds the `Score` from parsed MIDI content (see `ParsersMIDIImporter`).
struct ParsersMIDIScoreBuilder {
    let content: ParsersMIDIFileContent
    let fileName: String
    let grid: ParsersMIDIGrid
    let splitPoint: Int

    /// One notated measure slot on the absolute tick axis.
    struct MeasureSlot: Hashable {
        var start: Ticks
        var length: Ticks
        var time: TimeSignature
        var end: Ticks { start + length }
    }

    /// Builds the score, logging every simplification it made.
    func build(log: inout ParsersDiagnosticLog) throws -> ImportResult {
        let ppq = Double(content.ticksPerQuarter)
        func core(_ t: Int) -> Ticks { Int((Double(t) * Double(Ticks.perQuarter) / ppq).rounded()) }

        // Streams (track, channel) numbered in track order, and notes in Core ticks.
        var drums = 0, shifted = 0
        var streamIDs: [Int: Int] = [:]
        var streamHands: [Int: Hand] = [:]
        for key in Set(content.notes.filter { $0.channel != 9 }.map { $0.track * 16 + $0.channel }).sorted() {
            let stream = streamIDs.count
            streamIDs[key] = stream
            if let name = content.trackNames[key / 16], let hand = ParsersMIDIImporter.hand(forTrackName: name) { streamHands[stream] = hand }
        }
        var raw: [ParsersMIDINote] = []
        for n in content.notes {
            if n.channel == 9 { drums += 1; continue }
            let stream = streamIDs[n.track * 16 + n.channel] ?? 0
            var midi = n.pitch
            if !Pitch.pianoRange.contains(midi) {
                while midi < Pitch.pianoRange.lowerBound { midi += 12 }
                while midi > Pitch.pianoRange.upperBound { midi -= 12 }
                shifted += 1
            }
            raw.append(ParsersMIDINote(onset: core(n.start), end: core(n.end), midi: midi, stream: stream))
        }
        if drums > 0 { log.add(.info, "\(drums) percussion note(s) on MIDI channel 10 were skipped.") }
        if shifted > 0 { log.add(.warning, "\(shifted) note(s) outside the piano range were moved by octaves.") }
        guard !raw.isEmpty else { throw ImportError.empty }

        // Quantize.
        let step = grid.ticks ?? ParsersMIDIImporter.chooseGrid(onsets: raw.map { $0.onset })
        let residual = ParsersMIDIImporter.meanGridError(onsets: raw.map { $0.onset }, step: step)
        if grid == .automatic {
            let name: String
            switch step {
            case Ticks.perQuarter / 12: name = "a triplet-aware 12-per-quarter grid"
            case Ticks.perQuarter / 8: name = "a 32nd-note grid"
            case Ticks.perQuarter / 24: name = "a 24-per-quarter grid (32nds and triplets)"
            default: name = "a 16th-note grid"
            }
            log.add(.info, "Timing was quantized to \(name).")
        }
        if residual > Double(step) / 4 {
            log.add(.warning, "The file looks like a live performance (onsets are off the grid by \(Int(residual)) ticks on average); check the rhythm.")
        }
        let notes = ParsersMIDIImporter.quantize(raw, step: step)

        // Hands.
        let streamCount = Set(notes.map { $0.stream }).count
        if streamCount > 2 { log.add(.info, "The file has \(streamCount) tracks/channels with notes; hands were split by pitch.") }
        let hands = ParsersMIDIImporter.assignHands(notes, streamCount: streamCount, splitPoint: splitPoint, streamHands: streamHands)

        // Measures from the meter map.
        let lastEnd = notes.map { $0.end }.max() ?? 0
        let (slots, pickup) = measureSlots(until: lastEnd, step: step, core: core, log: &log)

        // Keys.
        var keyChanges: [(tick: Ticks, key: KeySignature)] = content.keys.map { (core($0.tick), KeySignature(fifths: $0.fifths, mode: $0.minor ? .minor : .major)) }
        if keyChanges.isEmpty || keyChanges[0].tick > 0 {
            var histogram = [Double](repeating: 0, count: 12)
            for n in notes { histogram[n.midi % 12] += Double(n.duration) }
            if let k = ParsersMIDIImporter.estimateKey(histogram: histogram) {
                keyChanges.insert((0, k), at: 0)
                if content.keys.isEmpty { log.add(.info, "No key signature in the file; estimated \(k.displayName) from the notes.") }
            }
        }
        func key(at tick: Ticks) -> KeySignature {
            var k = KeySignature.cMajor
            for c in keyChanges where c.tick <= tick { k = c.key }
            return k
        }

        // Voices per hand.
        var perMeasure = [[MeasureEvent]](repeating: [], count: slots.count)
        for hand in Hand.allCases {
            var handNotes = zip(notes, hands).filter { $0.1 == hand }.map { $0.0 }
            handNotes = ParsersMIDIScoreBuilder.trimLegato(handNotes, step: step)
            let (voice1, voice2) = ParsersMIDIScoreBuilder.separateVoices(handNotes, step: step)
            let v1 = ParsersMIDIScoreBuilder.voiceEvents(voice1, hand: hand, voice: 1, slots: slots, keyAt: key, keepRestMeasures: true)
            let v2 = ParsersMIDIScoreBuilder.voiceEvents(voice2, hand: hand, voice: 2, slots: slots, keyAt: key, keepRestMeasures: false)
            for i in slots.indices { perMeasure[i] += v1[i] + v2[i] }
        }

        // Tempo per measure: time-weighted average of the MIDI tempo map.
        let tempoMap = TempoMap(events: content.tempos.map { TempoEvent(tick: core($0.tick), bpm: $0.bpm) }.ifEmpty([TempoEvent(tick: 0, bpm: 120)]))
        if content.tempos.isEmpty && !content.isSMPTE { log.add(.info, "No tempo in the file; using the MIDI default of 120 BPM.") }
        var measures: [Measure] = []
        var effectiveTempo = 120.0
        var initialTempo = 120.0
        var effectiveKey = key(at: 0)
        var effectiveTime = slots.first?.time ?? .common
        let initialTime = pickup ? (slots.count > 1 ? slots[1].time : slots[0].time) : (slots.first?.time ?? .common)
        for (i, slot) in slots.enumerated() {
            let seconds = tempoMap.seconds(from: slot.start, length: slot.length)
            let bpm = seconds > 0 ? (Double(slot.length) / Double(Ticks.perQuarter)) / seconds * 60 : 120
            let rounded = (bpm * 100).rounded() / 100
            var tempo: Double? = nil
            if i == 0 { effectiveTempo = rounded; initialTempo = rounded } else if abs(rounded - effectiveTempo) / effectiveTempo > 0.005 { tempo = rounded; effectiveTempo = rounded }
            var time: TimeSignature? = nil
            if i == 0 { effectiveTime = initialTime } else if slot.time != effectiveTime { time = slot.time; effectiveTime = slot.time }
            var keySig: KeySignature? = nil
            let k = key(at: slot.start)
            if i > 0, k != effectiveKey { keySig = k; effectiveKey = k }
            let isPickup = i == 0 && pickup
            measures.append(Measure(number: pickup ? i : i + 1, timeSignature: time, keySignature: keySig, tempoBPM: tempo, isPickup: isPickup,
                                    events: perMeasure[i], barline: i == slots.count - 1 ? Barline(isFinal: true) : .plain))
        }

        let trackTitle = content.trackNames.keys.sorted().compactMap { content.trackNames[$0] }.first { !$0.isEmpty }
        let title = trackTitle ?? ParsersMusicXMLScoreBuilder.titleFromFileName(fileName)
        let score = Score(metadata: ScoreMetadata(title: title, source: .midi, sourceFileName: fileName),
                          initialTime: initialTime, initialKey: key(at: 0), initialTempoBPM: initialTempo,
                          measures: measures)
        return ImportResult(score: score, diagnostics: log.result)
    }

    /// Lays out measures from the time-signature meta events up to `end`. A first meter that lasts exactly one measure
    /// and is shorter than the next meter is treated as a pickup. A meter change that does not fall on a barline is
    /// moved to the next barline.
    private func measureSlots(until end: Ticks, step: Ticks, core: (Int) -> Ticks, log: inout ParsersDiagnosticLog) -> ([MeasureSlot], Bool) {
        var changes: [(tick: Ticks, time: TimeSignature)] = []
        for m in content.meters {
            let t = core(m.tick)
            let ts = TimeSignature(beats: m.numerator, beatType: m.denominator)
            if let last = changes.last, last.tick == t { changes[changes.count - 1] = (t, ts) } else { changes.append((t, ts)) }
        }
        if changes.isEmpty {
            log.add(.info, "No time signature in the file; using 4/4.")
            changes = [(0, .common)]
        } else if changes[0].tick > 0 {
            changes.insert((0, .common), at: 0)
        }
        var slots: [MeasureSlot] = []
        var current = changes[0].time
        var next = 1
        var t: Ticks = 0
        var warnedMisaligned = false
        let limit = max(end, 1)
        while t < limit {
            while next < changes.count, changes[next].tick <= t {
                if changes[next].tick < t, !warnedMisaligned {
                    warnedMisaligned = true
                    log.add(.warning, measureIndex: slots.count, "A time signature change falls inside a measure; it was moved to the next barline.")
                }
                current = changes[next].time
                next += 1
            }
            slots.append(MeasureSlot(start: t, length: current.measureTicks, time: current))
            t += current.measureTicks
        }
        var pickup = false
        if slots.count >= 2, changes.count >= 2, changes[1].tick == slots[0].length, slots[0].length < slots[1].length {
            pickup = true
        }
        return (slots, pickup)
    }

    // MARK: Voices

    /// Removes small legato overlaps: a note that runs into the next attack of the same hand by at most one grid step
    /// or a quarter of its length is cut at that attack.
    static func trimLegato(_ notes: [ParsersMIDINote], step: Ticks) -> [ParsersMIDINote] {
        let onsets = Array(Set(notes.map { $0.onset })).sorted()
        return notes.map { n in
            var m = n
            // First attack strictly after this note's onset.
            var lo = 0, hi = onsets.count
            while lo < hi { let mid = (lo + hi) / 2; if onsets[mid] <= n.onset { lo = mid + 1 } else { hi = mid } }
            if lo < onsets.count {
                let nextOnset = onsets[lo]
                let overlap = n.end - nextOnset
                if overlap > 0, overlap <= max(step, n.duration / 4) { m.end = nextOnset }
            }
            return m
        }
    }

    /// Splits a hand into a main voice and a second voice holding notes that sustain across later attacks
    /// (e.g. a held bass note under moving eighths). Voice 2 takes such a note only while it is free.
    static func separateVoices(_ notes: [ParsersMIDINote], step: Ticks) -> ([ParsersMIDINote], [ParsersMIDINote]) {
        let onsets = Array(Set(notes.map { $0.onset })).sorted()
        var voice1: [ParsersMIDINote] = []
        var voice2: [ParsersMIDINote] = []
        var voice2BusyUntil: Ticks = Int.min
        var voice2Group: (onset: Ticks, end: Ticks)? = nil
        for n in notes.sorted(by: { ($0.onset, $0.midi) < ($1.onset, $1.midi) }) {
            let spansAttack = onsets.contains { $0 > n.onset && $0 <= n.end - step }
            // Notes attacked together with identical length join the same voice-2 chord.
            if let g = voice2Group, g.onset == n.onset, g.end == n.end, spansAttack {
                voice2.append(n)
                continue
            }
            if spansAttack, voice2BusyUntil <= n.onset {
                voice2.append(n)
                voice2BusyUntil = n.end
                voice2Group = (n.onset, n.end)
            } else {
                voice1.append(n)
            }
        }
        return (voice1, voice2)
    }

    /// Slices one voice at every onset, release and barline into chord/rest events per measure. Notes that continue
    /// past a slice boundary are tied; slices that are not a single note value are written as tied (or, for rests,
    /// consecutive) values. A measure with no notes in this voice gets one whole-measure rest (voice 1) or nothing (voice 2).
    static func voiceEvents(_ notes: [ParsersMIDINote], hand: Hand, voice: Int, slots: [MeasureSlot],
                            keyAt: (Ticks) -> KeySignature, keepRestMeasures: Bool) -> [[MeasureEvent]] {
        var out = [[MeasureEvent]](repeating: [], count: slots.count)
        guard !slots.isEmpty else { return out }
        let sorted = notes.sorted { ($0.onset, $0.midi) < ($1.onset, $1.midi) }
        for (mi, slot) in slots.enumerated() {
            let inside = sorted.filter { $0.onset < slot.end && $0.end > slot.start }
            if inside.isEmpty {
                if keepRestMeasures {
                    out[mi].append(MeasureEvent(onset: 0, duration: slot.length, notated: NoteDuration.exact(ticks: slot.length), notes: [], hand: hand, voice: voice))
                }
                continue
            }
            var boundaries = Set<Ticks>([slot.start, slot.end])
            for n in inside {
                if n.onset > slot.start { boundaries.insert(n.onset) }
                if n.end < slot.end { boundaries.insert(n.end) }
            }
            let cuts = boundaries.sorted()
            let key = keyAt(slot.start)
            var events: [MeasureEvent] = []
            var pendingRest: (start: Ticks, end: Ticks)? = nil
            func flushRest() {
                guard let r = pendingRest else { return }
                pendingRest = nil
                var at = r.start - slot.start
                for piece in ParsersDurationSplitter.split(ticks: r.end - r.start, onset: at, beatTicks: slot.time.beatTicks) {
                    events.append(MeasureEvent(onset: at, duration: piece.ticks, notated: piece.notated, notes: [], hand: hand, voice: voice))
                    at += piece.ticks
                }
            }
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                var sounding: [Int: (tieStop: Bool, tieStart: Bool)] = [:]
                for n in inside where n.onset <= a && n.end > a {
                    let stop = n.onset < a
                    let start = n.end > b
                    if let existing = sounding[n.midi] {
                        sounding[n.midi] = (existing.tieStop && stop, existing.tieStart || start)
                    } else {
                        sounding[n.midi] = (stop, start)
                    }
                }
                if sounding.isEmpty {
                    if let r = pendingRest { pendingRest = (r.start, b) } else { pendingRest = (a, b) }
                    continue
                }
                flushRest()
                let pieces = ParsersDurationSplitter.split(ticks: b - a, onset: a - slot.start, beatTicks: slot.time.beatTicks)
                var at = a - slot.start
                for (pi, piece) in pieces.enumerated() {
                    let chord = sounding.keys.sorted().map { midi -> ChordNote in
                        let flags = sounding[midi] ?? (false, false)
                        return ChordNote(pitch: Pitch(midi: midi, in: key),
                                         tieStart: pi < pieces.count - 1 || flags.tieStart,
                                         tieStop: pi > 0 || flags.tieStop)
                    }
                    events.append(MeasureEvent(onset: at, duration: piece.ticks, notated: piece.notated, notes: chord, hand: hand, voice: voice))
                    at += piece.ticks
                }
            }
            flushRest()
            out[mi] = events
        }
        return out
    }
}

private extension Array {
    /// The array itself, or `fallback` when it is empty.
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}
