import Foundation

/// Structural checks every imported or authored score goes through. Produces measure-numbered diagnostics; never throws.
public enum ScoreValidator {
    /// Runs all checks.
    public static func validate(_ score: Score) -> [ScoreDiagnostic] {
        var out: [ScoreDiagnostic] = []
        if score.measures.isEmpty { out.append(ScoreDiagnostic(.error, message: "The score has no measures.")) }
        if !score.hasNotes(for: .right) && !score.hasNotes(for: .left) { out.append(ScoreDiagnostic(.error, message: "The score has no notes.")) }

        var openTies: [String: Set<Int>] = [:] // hand-voice -> midi with pending tie
        for (i, m) in score.measures.enumerated() {
            let ts = score.timeSignature(atMeasure: i)
            let expected = ts.measureTicks
            let content = m.contentLength
            if content == 0 { out.append(ScoreDiagnostic(.warning, measureIndex: i, message: "Empty measure.")) }
            if content > expected { out.append(ScoreDiagnostic(.error, measureIndex: i, message: "Measure holds \(content) ticks but the meter \(ts) allows \(expected).")) }
            if content < expected, !m.isPickup, i != score.measures.count - 1, content > 0 {
                out.append(ScoreDiagnostic(.warning, measureIndex: i, message: "Measure is under-filled (\(content)/\(expected) ticks)."))
            }
            // Per hand/voice: events must not overlap.
            let groups = Dictionary(grouping: m.events) { "\($0.hand.rawValue)-\($0.voice)" }
            for (key, evs) in groups {
                let sorted = evs.sorted { $0.onset < $1.onset }
                for (a, b) in zip(sorted, sorted.dropFirst()) where a.end > b.onset {
                    out.append(ScoreDiagnostic(.error, measureIndex: i, hand: a.hand, voice: a.voice, message: "Overlapping events at tick \(b.onset) in voice \(key)."))
                }
                for e in sorted {
                    let pending = openTies[key] ?? []
                    for n in e.notes {
                        if n.tieStop && !pending.contains(n.midi) {
                            out.append(ScoreDiagnostic(.warning, measureIndex: i, hand: e.hand, voice: e.voice, message: "Tie ends on \(n.pitch.name) without a matching start; it will be played as a new note."))
                        }
                        if !Pitch.pianoRange.contains(n.midi) {
                            out.append(ScoreDiagnostic(.error, measureIndex: i, hand: e.hand, voice: e.voice, message: "\(n.pitch.name) is outside the 88-key range."))
                        }
                    }
                    let dupes = Dictionary(grouping: e.midiPitches) { $0 }.filter { $0.value.count > 1 }
                    if !dupes.isEmpty { out.append(ScoreDiagnostic(.warning, measureIndex: i, hand: e.hand, voice: e.voice, message: "Chord repeats a pitch.")) }
                    if let lo = e.midiPitches.min(), let hi = e.midiPitches.max(), hi - lo > 16 {
                        out.append(ScoreDiagnostic(.warning, measureIndex: i, hand: e.hand, voice: e.voice, message: "Chord spans \(hi - lo) semitones – wider than a 10th."))
                    }
                    openTies[key] = Set(e.notes.filter { $0.tieStart }.map { $0.midi })
                }
            }
            if let times = m.barline.repeatBackwardTimes, times > 8 { out.append(ScoreDiagnostic(.warning, measureIndex: i, message: "Repeat plays \(times) times.")) }
        }
        for (key, pending) in openTies where !pending.isEmpty {
            out.append(ScoreDiagnostic(.warning, message: "Tie in voice \(key) never ends (pitches \(pending.sorted())); it will simply stop."))
        }
        return out.sorted { ($0.measureIndex ?? -1, $0.severity > $1.severity ? 0 : 1) < ($1.measureIndex ?? -1, 0) }
    }

    /// Fixes what can be fixed mechanically: drops out-of-range notes, clamps over-full measures by trimming the last events,
    /// clears dangling tie stops. Returns the repaired score and what was changed.
    public static func repair(_ score: Score) -> (score: Score, changes: [ScoreDiagnostic]) {
        var s = score
        var changes: [ScoreDiagnostic] = []
        var openTies: [String: Set<Int>] = [:]
        for i in s.measures.indices {
            let limit = s.timeSignature(atMeasure: i).measureTicks
            var events = s.measures[i].events
            for j in events.indices {
                let before = events[j].notes.count
                events[j].notes.removeAll { !Pitch.pianoRange.contains($0.midi) }
                if events[j].notes.count != before { changes.append(ScoreDiagnostic(.info, measureIndex: i, message: "Removed \(before - events[j].notes.count) out-of-range note(s).")) }
                let key = "\(events[j].hand.rawValue)-\(events[j].voice)"
                let pending = openTies[key] ?? []
                for k in events[j].notes.indices where events[j].notes[k].tieStop && !pending.contains(events[j].notes[k].midi) {
                    events[j].notes[k].tieStop = false
                }
                openTies[key] = Set(events[j].notes.filter { $0.tieStart }.map { $0.midi })
                if !s.measures[i].isPickup, events[j].end > limit {
                    if events[j].onset >= limit {
                        events[j].duration = 0
                    } else {
                        events[j].duration = limit - events[j].onset
                    }
                    changes.append(ScoreDiagnostic(.info, measureIndex: i, message: "Trimmed an event that ran past the barline."))
                }
            }
            let dropped = events.filter { $0.duration <= 0 }.count
            if dropped > 0 { changes.append(ScoreDiagnostic(.info, measureIndex: i, message: "Dropped \(dropped) event(s) starting after the barline.")) }
            events.removeAll { $0.duration <= 0 }
            s.measures[i].events = events
        }
        return (s, changes)
    }
}
