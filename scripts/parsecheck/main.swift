import Foundation

/// macOS harness for the Parsers module.
///
/// Build and run:
///   xcrun swiftc -swift-version 5 -parse-as-library -o /tmp/parsecheck \
///     LearnPiano/Core/*.swift LearnPiano/Parsers/*.swift scripts/parsecheck/main.swift && /tmp/parsecheck
///
/// It parses every bundled `Content/Songs/*.musicxml`, prints per file the measure count, events per hand, the playback
/// length in ticks and every diagnostic (importer + `ScoreValidator`), round-trips every file through
/// export → import comparing the playback timelines, and exercises the MXL, Standard MIDI File and LPC importers on data
/// derived from the bundled songs. Exits non-zero if any file fails to parse, reports an error, or fails a round trip.
@main
struct ParseCheck {
    static func main() {
        let root = repositoryRoot()
        let songs = root.appendingPathComponent("LearnPiano/Content/Songs")
        let files = ((try? FileManager.default.contentsOfDirectory(at: songs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "musicxml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            print("No .musicxml files found under \(songs.path)")
            exit(2)
        }

        var failures: [String] = []
        let importer = ParsersMusicXMLImporter()
        let exporter = ParsersMusicXMLExporter()
        var parsed: [(name: String, score: Score)] = []

        print("== MusicXML import (\(files.count) files)")
        for url in files {
            let name = url.lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let result = try importer.importScore(data: data, fileName: name)
                let score = result.score
                let timeline = score.makeTimeline()
                let rh = score.allEvents.filter { $0.hand == .right && !$0.isRest }.count
                let lh = score.allEvents.filter { $0.hand == .left && !$0.isRest }.count
                let diagnostics = result.diagnostics + ScoreValidator.validate(score)
                let errors = diagnostics.filter { $0.severity == .error }
                let status = errors.isEmpty ? "ok  " : "FAIL"
                print("\(status) \(name): \(score.measures.count) measures, RH \(rh) events, LH \(lh) events, \(timeline.totalTicks) ticks, \(timeline.steps.count) steps, \(score.initialTime) \(score.initialKey.displayName) \(ParsersMusicXMLExporter.format(score.initialTempoBPM)) BPM")
                for d in diagnostics { print("       \(d)") }
                if !errors.isEmpty { failures.append("\(name): \(errors.count) error diagnostic(s)") }
                parsed.append((name, score))
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        print("\n== Round trip export → import")
        for (name, score) in parsed {
            do {
                let xml = exporter.exportData(score)
                let again = try importer.importScore(data: xml, fileName: name).score
                if let diff = compareTimelines(score.makeTimeline(), again.makeTimeline()) {
                    print("FAIL \(name): \(diff)")
                    failures.append("round trip \(name): \(diff)")
                } else if again.measures.count != score.measures.count || again.measures.map(\.isPickup) != score.measures.map(\.isPickup) {
                    print("FAIL \(name): measure structure changed")
                    failures.append("round trip \(name): measure structure changed")
                } else {
                    print("ok   \(name)")
                }
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                failures.append("round trip \(name): \(error.localizedDescription)")
            }
        }

        print("\n== MXL (in-memory ZIP, deflate and stored)")
        if let first = parsed.first(where: { $0.name.hasPrefix("fur-elise__advanced") }) ?? parsed.first,
           let xml = try? Data(contentsOf: songs.appendingPathComponent(first.name)) {
            let container = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><container><rootfiles><rootfile full-path=\"score/song.musicxml\" media-type=\"application/vnd.recordare.musicxml+xml\"/></rootfiles></container>".utf8)
            for deflate in [true, false] {
                let zip = ParsersZipArchive.build(entries: [("mimetype", Data("application/vnd.recordare.musicxml".utf8)), ("META-INF/container.xml", container), ("score/song.musicxml", xml)], deflate: deflate)
                do {
                    let viaZip = try importer.importScore(data: zip, fileName: "song.mxl").score
                    if let diff = compareTimelines(first.score.makeTimeline(), viaZip.makeTimeline()) {
                        print("FAIL \(first.name) (\(deflate ? "deflate" : "stored"), \(zip.count) bytes): \(diff)")
                        failures.append("mxl \(first.name): \(diff)")
                    } else {
                        print("ok   \(first.name) via .mxl (\(deflate ? "deflate" : "stored"), \(zip.count) bytes)")
                    }
                } catch {
                    print("FAIL \(first.name) via .mxl: \(error.localizedDescription)")
                    failures.append("mxl \(first.name): \(error.localizedDescription)")
                }
            }
        }

        print("\n== Standard MIDI File (written from each score's timeline, re-imported)")
        let midiImporter = ParsersMIDIImporter()
        for (name, score) in parsed {
            let smf = HarnessSMFWriter.write(score)
            do {
                let result = try midiImporter.importScore(data: smf, fileName: name.replacingOccurrences(of: ".musicxml", with: ".mid"))
                let original = attacks(score.makeTimeline())
                let imported = attacks(result.score.makeTimeline())
                let matched = original.intersection(imported).count
                let pct = original.isEmpty ? 100.0 : 100.0 * Double(matched) / Double(original.count)
                let extra = imported.subtracting(original).count
                let errors = (result.diagnostics + ScoreValidator.validate(result.score)).filter { $0.severity == .error }
                let tag = errors.isEmpty ? "ok  " : "FAIL"
                print("\(tag) \(name): \(result.score.measures.count) measures, \(result.score.initialTime) \(result.score.initialKey.displayName) \(ParsersMusicXMLExporter.format(result.score.initialTempoBPM)) BPM, attacks matched \(String(format: "%.1f", pct))% (\(matched)/\(original.count), \(extra) extra)")
                for d in errors { print("       \(d)") }
                if !errors.isEmpty { failures.append("midi \(name): \(errors.count) error(s)") }
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                failures.append("midi \(name): \(error.localizedDescription)")
            }
        }

        print("\n== LPC (each score written as lpc-1 JSON, validated and re-imported)")
        let lpcImporter = ParsersCompactScoreImporter()
        for (name, score) in parsed {
            guard let json = HarnessLPCWriter.write(score) else {
                print("skip \(name): not expressible in LPC (more than two voices per hand or a tick grid finer than 96 per quarter)")
                continue
            }
            do {
                let parsedLPC = try lpcImporter.parse(json: json, fileName: name)
                let original = attacks(score.makeTimeline())
                let imported = attacks(parsedLPC.importResult.score.makeTimeline())
                let same = original == imported && score.makeTimeline().totalTicks == parsedLPC.importResult.score.makeTimeline().totalTicks
                let tag = parsedLPC.isValid && same ? "ok  " : "FAIL"
                print("\(tag) \(name): \(parsedLPC.errors.count) error(s), \(parsedLPC.issues.count - parsedLPC.errors.count) warning(s), attacks \(same ? "identical" : "DIFFER")")
                for issue in parsedLPC.issues { print("       \(issue)") }
                if !(parsedLPC.isValid && same) { failures.append("lpc \(name)") }
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                failures.append("lpc \(name): \(error.localizedDescription)")
            }
        }

        print("\n== Summary")
        if failures.isEmpty {
            print("All \(files.count) files parsed cleanly and round-tripped.")
            exit(0)
        }
        for f in failures { print("FAIL \(f)") }
        exit(1)
    }

    /// Compares two timelines event by event; returns a description of the first difference, or nil when equal.
    static func compareTimelines(_ a: PlaybackTimeline, _ b: PlaybackTimeline) -> String? {
        if a.totalTicks != b.totalTicks { return "total ticks \(a.totalTicks) vs \(b.totalTicks)" }
        let segA = a.segments.map { "\($0.measureIndex)/\($0.pass)@\($0.startTick)+\($0.length)" }
        let segB = b.segments.map { "\($0.measureIndex)/\($0.pass)@\($0.startTick)+\($0.length)" }
        if segA != segB { return "segments differ (\(segA.count) vs \(segB.count))" }
        let tempoA = a.tempoMap.events.map { "\($0.tick):\($0.bpm)" }
        let tempoB = b.tempoMap.events.map { "\($0.tick):\($0.bpm)" }
        if tempoA != tempoB { return "tempo maps differ: \(tempoA.prefix(4)) vs \(tempoB.prefix(4))" }
        let evA = a.events.map(signature).sorted()
        let evB = b.events.map(signature).sorted()
        if evA.count != evB.count { return "event count \(evA.count) vs \(evB.count)" }
        for (x, y) in zip(evA, evB) where x != y { return "event \(x) vs \(y)" }
        let stA = a.steps.map { "\($0.tick):\($0.attackPitches(for: .both))" }
        let stB = b.steps.map { "\($0.tick):\($0.attackPitches(for: .both))" }
        if stA != stB { return "steps differ" }
        return nil
    }

    /// A comparable text form of one timeline event (onset, length, hand, voice, staff, pitches, attacks, ties, fingering).
    static func signature(_ e: TimelineEvent) -> String {
        let notes = e.notes.map { "\($0.pitch.name)\($0.tieStart ? "~" : "")\($0.tieStop ? "^" : "")\($0.fingering.map { "f\($0)" } ?? "")" }
        return "\(String(format: "%09d", e.tick)) d\(e.duration) \(e.hand.rawValue) v\(e.voice) [\(notes.joined(separator: ","))] a\(e.attackPitches)"
    }

    /// Every attack as "tick hand midi" (what a learner has to press, and when).
    static func attacks(_ t: PlaybackTimeline) -> Set<String> {
        var out = Set<String>()
        for e in t.events { for p in e.attackPitches { out.insert("\(e.tick) \(e.hand.rawValue) \(p)") } }
        return out
    }

    /// The repository root: two levels above this script's directory, or the working directory when run from there.
    static func repositoryRoot() -> URL {
        let fm = FileManager.default
        var candidates: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        let script = URL(fileURLWithPath: #filePath)
        candidates.append(script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("LearnPiano/Content/Songs").path) { return c }
        return candidates[candidates.count - 1]
    }
}

/// Writes a type-1 Standard MIDI File (480 ticks per quarter) from a score's playback timeline: a conductor track with
/// tempo, time-signature and key-signature meta events, then one track per hand (right hand on channel 1, left on 2).
/// A pickup measure gets its own short time signature, the way notation programs export anacruses.
enum HarnessSMFWriter {
    static func write(_ score: Score) -> Data {
        let ppq = 480
        let timeline = score.makeTimeline()
        func t(_ ticks: Ticks) -> Int { ticks * ppq / Ticks.perQuarter }
        var conductor: [(Int, [UInt8])] = []
        for e in timeline.tempoMap.events {
            let us = Int((60_000_000.0 / e.bpm).rounded())
            conductor.append((t(e.tick), [0xFF, 0x51, 0x03, UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]))
        }
        var previousTime: TimeSignature? = nil
        var previousKey: KeySignature? = nil
        for seg in timeline.segments {
            let m = score.measures[seg.measureIndex]
            var ts = score.timeSignature(atMeasure: seg.measureIndex)
            if m.isPickup {
                let sixteenths = seg.length / 240
                ts = TimeSignature(beats: max(1, sixteenths), beatType: 16)
            }
            if ts != previousTime {
                let power = UInt8(Int(log2(Double(ts.beatType))))
                conductor.append((t(seg.startTick), [0xFF, 0x58, 0x04, UInt8(ts.beats), power, 24, 8]))
                previousTime = ts
            }
            let key = score.keySignature(atMeasure: seg.measureIndex)
            if key != previousKey {
                conductor.append((t(seg.startTick), [0xFF, 0x59, 0x02, UInt8(bitPattern: Int8(key.fifths)), key.mode == .minor ? 1 : 0]))
                previousKey = key
            }
        }
        var tracks = [track(conductor.sorted { $0.0 < $1.0 }, name: score.metadata.title)]
        for (channel, hand) in [Hand.right, Hand.left].enumerated() {
            var events: [(Int, [UInt8])] = []
            // Sounding spans per pitch: merge tie continuations into the note they continue.
            var open: [Int: Int] = [:] // midi -> start tick
            for e in timeline.events where e.hand == hand && !e.isRest {
                for n in e.notes {
                    let continues = n.tieStop && open[n.midi] != nil
                    if !continues { open[n.midi] = e.tick }
                    if !n.tieStart, let start = open[n.midi] {
                        events.append((t(start), [0x90 | UInt8(channel), UInt8(n.midi), 80]))
                        events.append((t(e.endTick), [0x80 | UInt8(channel), UInt8(n.midi), 0]))
                        open[n.midi] = nil
                    }
                }
            }
            for (midi, start) in open {
                events.append((t(start), [0x90 | UInt8(channel), UInt8(midi), 80]))
                events.append((t(timeline.totalTicks), [0x80 | UInt8(channel), UInt8(midi), 0]))
            }
            // Note-offs before note-ons at the same tick.
            events.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1[0] & 0xF0) < ($1.1[0] & 0xF0) }
            tracks.append(track(events, name: hand.displayName))
        }
        var out: [UInt8] = Array("MThd".utf8) + be32(6) + [0, 1] + be16(tracks.count) + be16(ppq)
        for tr in tracks { out += Array("MTrk".utf8) + be32(tr.count) + tr }
        return Data(out)
    }

    private static func track(_ events: [(Int, [UInt8])], name: String) -> [UInt8] {
        var out: [UInt8] = [0x00, 0xFF, 0x03] + vlq(name.utf8.count) + Array(name.utf8)
        var last = 0
        for (tick, bytes) in events {
            out += vlq(tick - last) + bytes
            last = tick
        }
        return out + [0x00, 0xFF, 0x2F, 0x00]
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return bytes
    }

    private static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

/// Writes a score as an `lpc-1` document in the hand-authoring form (the reverse of `ParsersCompactScoreImporter`),
/// or nil when the score uses more than two voices per hand or a grid finer than 96 divisions per quarter.
enum HarnessLPCWriter {
    static func write(_ score: Score) -> String? {
        let unit = ParsersMusicXMLExporter.tickUnit(for: score)
        let divisions = Ticks.perQuarter / unit
        guard divisions <= 96, !score.allEvents.contains(where: { $0.voice > 2 }) else { return nil }
        var measures: [[String: Any]] = []
        for (i, m) in score.measures.enumerated() {
            var obj: [String: Any] = ["n": i + 1]
            if i > 0, let t = m.timeSignature { obj["time"] = t.description }
            if i > 0, let k = m.keySignature { obj["key"] = k.fifths }
            if i > 0, let b = m.tempoBPM { obj["tempo"] = b }
            let length = score.measureLength(at: i)
            for (key, hand, voice) in [("rh", Hand.right, 1), ("lh", Hand.left, 1), ("rh2", Hand.right, 2), ("lh2", Hand.left, 2)] {
                let events = m.events.filter { $0.hand == hand && $0.voice == voice }.sorted { $0.onset < $1.onset }
                if events.isEmpty && voice == 2 { continue }
                var list: [[String: Any]] = []
                var cursor: Ticks = 0
                func rest(_ ticks: Ticks) { if ticks > 0 { list.append(["p": [String](), "d": ticks / unit]) } }
                for e in events {
                    rest(e.onset - cursor)
                    var item: [String: Any] = ["p": e.notes.map { $0.pitch.name }, "d": e.duration / unit]
                    let starts = e.notes.contains { $0.tieStart }, stops = e.notes.contains { $0.tieStop }
                    if starts || stops { item["tie"] = starts && stops ? "both" : (starts ? "start" : "stop") }
                    if let t = e.notated?.tuplet { item["t"] = [t.actual, t.normal] }
                    let fingers = e.notes.prefix { $0.fingering != nil }.compactMap { $0.fingering }
                    if !fingers.isEmpty, !e.notes.isEmpty { item["f"] = fingers }
                    if e.drawnOnOtherStaff { item["s"] = hand == .left ? "up" : "down" }
                    list.append(item)
                    cursor = max(cursor, e.end)
                }
                // A pickup or final measure may stay short; any other measure is padded with a rest.
                if !(m.isPickup) && i != score.measures.count - 1 { rest(length - cursor) }
                if list.isEmpty { rest(length) }
                obj[key] = list
            }
            obj["confidence"] = 1
            measures.append(obj)
        }
        let doc: [String: Any] = [
            "format": "lpc-1", "title": score.metadata.title, "composer": score.metadata.composer,
            "divisions": divisions, "time": score.initialTime.description, "key": score.initialKey.fifths,
            "tempo": score.initialTempoBPM, "pickup": score.measures.first?.isPickup ?? false, "measures": measures,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
