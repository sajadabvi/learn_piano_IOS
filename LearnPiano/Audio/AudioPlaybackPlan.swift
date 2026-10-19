import Foundation

// MARK: - Playback items

/// One sounding pitch of a playback item, with its tie-extended end.
struct AudioPlaybackNote: Equatable, Sendable {
    var midi: Int
    /// Absolute tick at which the note is released (ties extend it through the continuation events).
    var endTick: Ticks
    /// 0…1.
    var velocity: Double
}

/// One `TimelineEvent` prepared for audio: the pitches it *attacks* (tie continuations are not re-struck,
/// they lengthen the earlier attack instead) plus the event index for `onEventStarted`.
struct AudioPlaybackItem: AudioTickPositioned, Equatable, Sendable {
    var tick: Ticks
    /// Index into `PlaybackTimeline.events`.
    var eventIndex: Int
    var hand: Hand
    /// Notes struck at this onset (empty for a pure tie continuation, which still reports `onEventStarted`).
    var notes: [AudioPlaybackNote]
}

/// Builds the audio view of a `PlaybackTimeline`. Pure and deterministic.
enum AudioPlaybackPlan {
    /// Default velocity of right-hand (melody) notes.
    static let defaultRightVelocity = 0.78
    /// Default velocity of left-hand (accompaniment) notes; a little softer so the melody stands out.
    static let defaultLeftVelocity = 0.64

    private struct TieKey: Hashable {
        var hand: Hand
        var voice: Int
        var midi: Int
    }

    /// Items for every non-rest event, in timeline order (sorted by tick).
    ///
    /// Tie handling: a note listed in an event's `pitches` but not in its `attackPitches` continues a tie;
    /// the matching earlier attack (same hand, voice and pitch, still open because it carried `tieStart`)
    /// is lengthened to the continuation's end instead of being struck again.
    static func items(from timeline: PlaybackTimeline,
                      rightVelocity: Double = defaultRightVelocity,
                      leftVelocity: Double = defaultLeftVelocity) -> [AudioPlaybackItem] {
        var items: [AudioPlaybackItem] = []
        items.reserveCapacity(timeline.events.count)
        var open: [TieKey: (item: Int, note: Int)] = [:]
        let ordered = timeline.events.enumerated().sorted { a, b in
            a.element.tick != b.element.tick ? a.element.tick < b.element.tick : a.offset < b.offset
        }
        for (eventIndex, event) in ordered where !event.isRest {
            let attacks = Set(event.attackPitches)
            let velocity = max(0, min(1, event.hand == .right ? rightVelocity : leftVelocity))
            var notes: [AudioPlaybackNote] = []
            var seen = Set<Int>()
            let itemIndex = items.count
            for chordNote in event.notes where seen.insert(chordNote.midi).inserted {
                let key = TieKey(hand: event.hand, voice: event.voice, midi: chordNote.midi)
                if attacks.contains(chordNote.midi) {
                    open.removeValue(forKey: key)
                    notes.append(AudioPlaybackNote(midi: chordNote.midi, endTick: event.endTick, velocity: velocity))
                    if chordNote.tieStart { open[key] = (itemIndex, notes.count - 1) }
                } else if let target = open[key] {
                    let current = items[target.item].notes[target.note].endTick
                    items[target.item].notes[target.note].endTick = max(current, event.endTick)
                    if !chordNote.tieStart { open.removeValue(forKey: key) }
                }
            }
            // Pitches the timeline lists as attacks but that are missing from `notes` (defensive: keeps the
            // audio faithful to `attackPitches`, which is the contract followers rely on).
            for midi in event.attackPitches.sorted() where seen.insert(midi).inserted {
                notes.append(AudioPlaybackNote(midi: midi, endTick: event.endTick, velocity: velocity))
            }
            items.append(AudioPlaybackItem(tick: event.tick, eventIndex: eventIndex, hand: event.hand, notes: notes))
        }
        return items
    }
}

// MARK: - Metronome beats

/// One metronome click on the playback axis.
struct AudioMetronomeBeat: AudioTickPositioned, Equatable, Sendable {
    var tick: Ticks
    /// First pulse of a full measure (accented click).
    var isDownbeat: Bool
    /// 0-based pulse number inside its measure (in compound meters a pulse is a dotted quarter).
    var beatInMeasure: Int
    /// Pulses in a full measure of the meter in force.
    var beatsPerMeasure: Int
}

/// Pure beat generation for the metronome and the count-in.
enum AudioMetronomeBeats {
    /// Clicks for every playback segment (measure occurrence) of a timeline.
    ///
    /// Pulses follow `TimeSignature.pulseTicks` (quarter in x/4, dotted quarter in 6/8, 9/8, 12/8, eighth in
    /// other x/8). Full measures click from their start with an accent on pulse 0. A short *first* segment is
    /// treated as an anacrusis and aligned to its end (so the beat after it is the accented downbeat); any
    /// other short measure is aligned to its start.
    static func beats(segments: [PlaybackSegment], timeSignature: (Ticks) -> TimeSignature) -> [AudioMetronomeBeat] {
        var beats: [AudioMetronomeBeat] = []
        for (index, segment) in segments.enumerated() where segment.length > 0 {
            let meter = timeSignature(segment.startTick)
            let pulse = max(1, meter.pulseTicks)
            let full = max(pulse, meter.measureTicks)
            let perMeasure = max(1, meter.pulsesPerMeasure)
            let start = segment.startTick
            let end = segment.endTick
            if index == 0 && segment.length < full {
                let virtualStart = end - full
                var k = max(0, Int((Double(start - virtualStart) / Double(pulse)).rounded(.up)))
                while virtualStart + k * pulse < end {
                    beats.append(AudioMetronomeBeat(tick: virtualStart + k * pulse, isDownbeat: false, beatInMeasure: k % perMeasure, beatsPerMeasure: perMeasure))
                    k += 1
                }
            } else {
                var k = 0
                while start + k * pulse < end {
                    beats.append(AudioMetronomeBeat(tick: start + k * pulse, isDownbeat: k == 0, beatInMeasure: k % perMeasure, beatsPerMeasure: perMeasure))
                    k += 1
                }
            }
        }
        return beats
    }

    /// Clicks for a whole timeline; a timeline without segments clicks the meter at tick 0 throughout.
    static func beats(timeline: PlaybackTimeline, timeSignature: (Ticks) -> TimeSignature) -> [AudioMetronomeBeat] {
        if timeline.segments.isEmpty {
            guard timeline.totalTicks > 0 else { return [] }
            let segment = PlaybackSegment(measureIndex: 0, pass: 1, startTick: 0, length: timeline.totalTicks)
            let meter = timeSignature(0)
            // One synthetic segment per measure so downbeats repeat.
            var segments: [PlaybackSegment] = []
            var t = 0
            let length = max(1, meter.measureTicks)
            while t < segment.endTick {
                segments.append(PlaybackSegment(measureIndex: segments.count, pass: 1, startTick: t, length: min(length, segment.endTick - t)))
                t += length
            }
            return beats(segments: segments, timeSignature: timeSignature)
        }
        return beats(segments: timeline.segments, timeSignature: timeSignature)
    }

    /// Clicks of a count-in: `measures` full measures of `timeSignature` starting at tick 0.
    static func countInBeats(measures: Int, timeSignature: TimeSignature) -> [AudioMetronomeBeat] {
        let count = max(0, measures)
        let pulse = max(1, timeSignature.pulseTicks)
        let perMeasure = max(1, timeSignature.pulsesPerMeasure)
        return (0..<(count * perMeasure)).map { k in
            AudioMetronomeBeat(tick: k * pulse, isDownbeat: k % perMeasure == 0, beatInMeasure: k % perMeasure, beatsPerMeasure: perMeasure)
        }
    }

    /// Seconds between two count-in clicks at a quarter-note `bpm` and practice `speed`.
    static func countInPulseSeconds(timeSignature: TimeSignature, bpm: Double, speed: Double) -> Double {
        let quarterSeconds = 60.0 / max(10, min(400, bpm.isFinite ? bpm : 100))
        return Double(timeSignature.pulseTicks) / Double(Ticks.perQuarter) * quarterSeconds / max(0.05, speed.isFinite ? speed : 1)
    }
}
