import Foundation

// MARK: - Playback timeline

/// One occurrence of a notated measure in playback order (repeats expanded).
public struct PlaybackSegment: Hashable, Codable, Sendable {
    public var measureIndex: Int
    /// 1-based pass through a repeated section (1 on the first time through).
    public var pass: Int
    /// Absolute playback tick where this occurrence starts.
    public var startTick: Ticks
    public var length: Ticks
    public var endTick: Ticks { startTick + length }
}

/// One chord/rest event placed on the absolute playback axis.
public struct TimelineEvent: Hashable, Codable, Identifiable, Sendable {
    /// Unique per occurrence: "<segmentIndex>:<event uuid>".
    public var id: String
    public var sourceEventID: UUID
    public var segmentIndex: Int
    public var measureIndex: Int
    public var pass: Int
    /// Absolute playback onset.
    public var tick: Ticks
    public var duration: Ticks
    public var hand: Hand
    public var voice: Int
    public var notes: [ChordNote]
    /// All sounding MIDI pitches (including tie continuations).
    public var pitches: [Int]
    /// MIDI pitches struck at this onset; empty for rests and pure tie continuations. THIS is what a follower expects.
    public var attackPitches: [Int]

    public var endTick: Ticks { tick + duration }
    public var isRest: Bool { pitches.isEmpty }
}

/// All attacks that happen at one playback tick (across hands). The unit of progress for Wait Mode.
public struct TimelineStep: Hashable, Codable, Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var tick: Ticks
    public var measureIndex: Int
    public var pass: Int
    public var events: [TimelineEvent]

    /// Pitches expected from the learner for the selected hands (deduplicated, sorted).
    public func attackPitches(for hands: HandSelection) -> [Int] {
        Array(Set(events.filter { hands.includes($0.hand) }.flatMap { $0.attackPitches })).sorted()
    }

    /// Events of the hands the app plays for the learner.
    public func events(for hands: HandSelection) -> [TimelineEvent] { events.filter { hands.includes($0.hand) } }

    /// Longest duration among the step's events (used for rest/advance timing).
    public var maxDuration: Ticks { events.map { $0.duration }.max() ?? 0 }
}

/// A score flattened into playback order with repeats expanded, plus tempo and measure lookup.
public struct PlaybackTimeline: Hashable, Codable, Sendable {
    public var scoreID: UUID
    public var segments: [PlaybackSegment]
    /// Every event (rests included) sorted by tick, then hand (right first), then voice.
    public var events: [TimelineEvent]
    /// Attack groups per tick, sorted by tick. Rest-only ticks have no step.
    public var steps: [TimelineStep]
    public var tempoMap: TempoMap
    public var totalTicks: Ticks

    // MARK: Lookup

    /// Segment containing a playback tick (the last segment for ticks at/after the end).
    public func segmentIndex(atTick tick: Ticks) -> Int {
        guard !segments.isEmpty else { return 0 }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].startTick <= tick { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Notated measure index and tick within that measure for a playback tick.
    public func measurePosition(atTick tick: Ticks) -> (measureIndex: Int, tickInMeasure: Ticks, pass: Int) {
        guard !segments.isEmpty else { return (0, 0, 1) }
        let s = segments[segmentIndex(atTick: tick)]
        return (s.measureIndex, max(0, tick - s.startTick), s.pass)
    }

    /// Playback tick where a notated measure first starts (pass 1), or nil if it is never played.
    public func startTick(ofMeasure index: Int, pass: Int = 1) -> Ticks? {
        segments.first { $0.measureIndex == index && $0.pass == pass }?.startTick
            ?? segments.first { $0.measureIndex == index }?.startTick
    }

    /// Playback tick range covering a notated measure range on its first pass (end exclusive).
    public func tickRange(of range: MeasureRange) -> Range<Ticks>? {
        guard let start = startTick(ofMeasure: range.start),
              let endSeg = segments.first(where: { $0.measureIndex == range.end && $0.startTick >= start }) ?? segments.first(where: { $0.measureIndex == range.end })
        else { return nil }
        return start..<max(start + 1, endSeg.endTick)
    }

    /// Index of the first step at or after a tick (steps.count if none).
    public func stepIndex(atOrAfter tick: Ticks) -> Int {
        var lo = 0, hi = steps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if steps[mid].tick < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Steps that contain at least one attack for the selected hands.
    public func steps(for hands: HandSelection) -> [TimelineStep] {
        steps.filter { !$0.attackPitches(for: hands).isEmpty }
    }

    /// Events sounding at a tick (onset <= tick < end).
    public func events(soundingAt tick: Ticks) -> [TimelineEvent] {
        events.filter { !$0.isRest && $0.tick <= tick && tick < $0.endTick }
    }

    /// Events whose onset lies in a half-open tick range.
    public func events(in range: Range<Ticks>) -> [TimelineEvent] {
        events.filter { range.contains($0.tick) }
    }

    public func seconds(atTick tick: Ticks, speed: Double = 1.0) -> Double { tempoMap.seconds(at: tick, speed: speed) }
    public func tick(atSeconds s: Double, speed: Double = 1.0) -> Double { tempoMap.tick(atSeconds: s, speed: speed) }
    public func totalSeconds(speed: Double = 1.0) -> Double { tempoMap.seconds(at: totalTicks, speed: speed) }
}

// MARK: - Building

public extension Score {
    /// Playback order of (measureIndex, pass) honoring forward/backward repeats and volta endings.
    /// Unknown or malformed repeat structures degrade to linear order; the result is capped to avoid runaway loops.
    func playbackOrder(expandRepeats: Bool = true) -> [(measureIndex: Int, pass: Int)] {
        guard expandRepeats else { return measures.indices.map { ($0, 1) } }
        var order: [(Int, Int)] = []
        var i = 0
        var repeatStart = 0
        var pass = 1
        let cap = max(1, measures.count) * 12
        while i < measures.count && order.count < cap {
            let m = measures[i]
            if m.barline.repeatForward { repeatStart = i; if order.last.map({ $0.0 < i }) ?? true, pass > 1, !(order.contains { $0.0 == i }) { pass = 1 } }
            if !m.barline.endings.isEmpty && !m.barline.endings.contains(pass) {
                i += 1
                continue
            }
            order.append((i, pass))
            if let times = m.barline.repeatBackwardTimes, pass < times {
                pass += 1
                i = repeatStart
                continue
            }
            if m.barline.repeatBackwardTimes != nil { pass = 1 }
            i += 1
        }
        if order.isEmpty { order = measures.indices.map { ($0, 1) } }
        return order.map { (measureIndex: $0.0, pass: $0.1) }
    }

    /// Flattens the score into a `PlaybackTimeline`.
    func makeTimeline(expandRepeats: Bool = true) -> PlaybackTimeline {
        let order = playbackOrder(expandRepeats: expandRepeats)
        var segments: [PlaybackSegment] = []
        var events: [TimelineEvent] = []
        var tempoEvents: [TempoEvent] = [TempoEvent(tick: 0, bpm: initialTempoBPM)]
        var cursor: Ticks = 0
        // Previous event per (hand, voice) in playback order, to validate tie continuations.
        var lastSounding: [String: Set<Int>] = [:]

        for (segIndex, item) in order.enumerated() {
            let m = measures[item.measureIndex]
            let length = measureLength(at: item.measureIndex)
            segments.append(PlaybackSegment(measureIndex: item.measureIndex, pass: item.pass, startTick: cursor, length: length))
            if let bpm = m.tempoBPM { tempoEvents.append(TempoEvent(tick: cursor, bpm: bpm)) }
            // Also carry the effective tempo at a repeat jump so the map stays correct after jumping back.
            if segIndex > 0, m.tempoBPM == nil {
                let effective = tempoBPM(atMeasure: item.measureIndex)
                let prev = order[segIndex - 1].measureIndex
                if tempoBPM(atMeasure: prev) != effective { tempoEvents.append(TempoEvent(tick: cursor, bpm: effective)) }
            }
            for e in m.events {
                let key = "\(e.hand.rawValue)-\(e.voice)"
                let previous = lastSounding[key] ?? []
                let attacks = e.notes.filter { !($0.tieStop && previous.contains($0.midi)) }.map { $0.midi }
                let te = TimelineEvent(
                    id: "\(segIndex):\(e.id.uuidString)",
                    sourceEventID: e.id,
                    segmentIndex: segIndex,
                    measureIndex: item.measureIndex,
                    pass: item.pass,
                    tick: cursor + e.onset,
                    duration: e.duration,
                    hand: e.hand,
                    voice: e.voice,
                    notes: e.notes,
                    pitches: e.midiPitches,
                    attackPitches: Array(Set(attacks)).sorted()
                )
                events.append(te)
                lastSounding[key] = Set(e.notes.filter { $0.tieStart }.map { $0.midi })
            }
            cursor += length
        }
        events.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.hand != b.hand { return a.hand == .right }
            return a.voice < b.voice
        }
        var steps: [TimelineStep] = []
        var byTick: [Ticks: [TimelineEvent]] = [:]
        for e in events where !e.attackPitches.isEmpty { byTick[e.tick, default: []].append(e) }
        for (idx, tick) in byTick.keys.sorted().enumerated() {
            let evs = byTick[tick] ?? []
            steps.append(TimelineStep(index: idx, tick: tick, measureIndex: evs[0].measureIndex, pass: evs[0].pass, events: evs))
        }
        return PlaybackTimeline(scoreID: id, segments: segments, events: events, steps: steps, tempoMap: TempoMap(events: tempoEvents), totalTicks: cursor)
    }
}
