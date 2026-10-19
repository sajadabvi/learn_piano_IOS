import Foundation

// MARK: - Tick-positioned items

/// Anything placed on the playback tick axis that the lookahead scheduler can emit (score events, clicks).
protocol AudioTickPositioned {
    /// Absolute playback tick of the item's onset.
    var tick: Ticks { get }
}

// MARK: - Tempo helpers

/// Fractional-tick extensions of the Core `TempoMap` (which converts integer ticks only).
enum AudioTempoMath {
    /// Seconds from tick 0 to a fractional tick at `speed`.
    static func seconds(atFractionalTick tick: Double, in map: TempoMap, speed: Double) -> Double {
        guard tick.isFinite, tick > 0 else { return 0 }
        let whole = Ticks(tick.rounded(.down))
        let fraction = tick - Double(whole)
        let base = map.seconds(at: whole, speed: speed)
        guard fraction > 0 else { return base }
        let secondsPerTick = 60.0 / map.bpm(at: whole) / Double(Ticks.perQuarter) / max(0.01, speed)
        return base + fraction * secondsPerTick
    }
}

// MARK: - Transport mapper

/// Pure, value-type mapping between *elapsed transport seconds* (time since the transport started, on a
/// continuous axis that keeps growing across loop wraps) and *playback ticks*, for one run of the
/// transport: a start tick, a tempo map, a speed multiplier and an optional loop region.
///
/// The run is divided into *laps*. Lap 0 goes from `startTick` to the loop end (or to `endTick` without a
/// loop); every later lap replays the loop region `loop.lowerBound ..< loop.upperBound`. A loop is only in
/// effect when the start lies before its end; starting before the loop plays into it and then wraps.
struct AudioTransportMapper: Equatable, Sendable {
    let tempoMap: TempoMap
    /// Practice speed multiplier (clamped to 0.05…4).
    let speed: Double
    /// Tick where elapsed time 0 lies.
    let startTick: Ticks
    /// End of the material (the timeline's `totalTicks`).
    let endTick: Ticks
    /// The loop region actually in effect (validated and clamped to the material), or nil.
    let loop: Range<Ticks>?
    /// Seconds from `startTick` to the end of lap 0.
    let firstLapDuration: Double
    /// Seconds of one loop lap (0 without a loop).
    let lapDuration: Double

    /// - Parameters:
    ///   - tempoMap: the timeline's tempo map.
    ///   - speed: practice speed multiplier.
    ///   - startTick: where the run starts (clamped into `0...endTick`).
    ///   - endTick: end of the material.
    ///   - loop: requested loop region; ignored when empty, outside the material, or already behind the start.
    init(tempoMap: TempoMap, speed: Double, startTick: Ticks, endTick: Ticks, loop: Range<Ticks>?) {
        let end = max(0, endTick)
        let start = max(0, min(startTick, end))
        let s = max(0.05, min(4, speed.isFinite ? speed : 1))
        var effectiveLoop: Range<Ticks>? = nil
        if let loop {
            let lower = max(0, loop.lowerBound)
            let upper = min(loop.upperBound, end)
            if upper > lower, start < upper { effectiveLoop = lower..<upper }
        }
        self.tempoMap = tempoMap
        self.speed = s
        self.startTick = start
        self.endTick = end
        self.loop = effectiveLoop
        let firstEnd = effectiveLoop?.upperBound ?? end
        self.firstLapDuration = max(0, tempoMap.seconds(at: firstEnd, speed: s) - tempoMap.seconds(at: start, speed: s))
        if let effectiveLoop {
            self.lapDuration = max(0, tempoMap.seconds(at: effectiveLoop.upperBound, speed: s) - tempoMap.seconds(at: effectiveLoop.lowerBound, speed: s))
        } else {
            self.lapDuration = 0
        }
    }

    /// Whether the run wraps around a loop region.
    var isLooping: Bool { loop != nil && lapDuration > 0 }

    /// Elapsed seconds at which the run reaches `endTick`, or nil when it loops forever.
    var finishElapsed: Double? { isLooping ? nil : firstLapDuration }

    /// Elapsed seconds at which a lap begins.
    func lapStartElapsed(_ lap: Int) -> Double {
        guard lap > 0, isLooping else { return 0 }
        return firstLapDuration + Double(lap - 1) * lapDuration
    }

    /// Tick range covered by a lap (end exclusive).
    func lapTickRange(_ lap: Int) -> Range<Ticks> {
        guard let loop, isLooping else { return startTick..<max(startTick, endTick) }
        return lap == 0 ? startTick..<loop.upperBound : loop
    }

    /// Lap that contains an elapsed time.
    func lapIndex(atElapsed elapsed: Double) -> Int {
        guard isLooping, elapsed >= firstLapDuration else { return 0 }
        let laps = ((elapsed - firstLapDuration) / lapDuration).rounded(.down)
        return 1 + Int(min(laps, Double(Int.max / 4)))
    }

    /// Fractional playback tick reached after `elapsed` seconds (clamped to the material; wraps inside the loop).
    func tick(atElapsed elapsed: Double) -> Double {
        let e = max(0, elapsed.isFinite ? elapsed : 0)
        let lap = lapIndex(atElapsed: e)
        let range = lapTickRange(lap)
        let local = e - lapStartElapsed(lap)
        let base = tempoMap.seconds(at: range.lowerBound, speed: speed)
        let t = tempoMap.tick(atSeconds: base + local, speed: speed)
        return max(Double(range.lowerBound), min(t, Double(range.upperBound)))
    }

    /// Elapsed seconds at which a tick plays within a lap.
    func elapsed(atTick tick: Ticks, lap: Int) -> Double {
        let range = lapTickRange(lap)
        return lapStartElapsed(lap) + tempoMap.seconds(at: tick, speed: speed) - tempoMap.seconds(at: range.lowerBound, speed: speed)
    }

    /// Elapsed release time of a note that starts at `onsetElapsed` in `lap` and is notated to end at `endTick`.
    /// Notes are cut at the end of their lap (so nothing hangs over a loop wrap) and last at least `minimumSeconds`.
    func releaseElapsed(endTick: Ticks, lap: Int, onsetElapsed: Double, minimumSeconds: Double = 0.03) -> Double {
        let range = lapTickRange(lap)
        let clipped = min(endTick, range.upperBound)
        var release = elapsed(atTick: max(clipped, range.lowerBound), lap: lap)
        if !isLooping, let finish = finishElapsed { release = min(release, max(finish, onsetElapsed + minimumSeconds)) }
        return max(release, onsetElapsed + minimumSeconds)
    }
}

// MARK: - Cursor over items

/// Position of the lookahead scheduler inside a list of tick-sorted items, for one `AudioTransportMapper`.
struct AudioScheduleCursor: Equatable, Sendable {
    /// Lap being emitted.
    var lap: Int = 0
    /// Next item index inside the lap; nil means "not positioned yet for this lap".
    var index: Int?
    /// No more occurrences will ever be produced (the run does not loop and reached its end).
    var isFinished = false
}

/// One emission of an item: which item, in which lap, at which elapsed time.
struct AudioScheduledOccurrence: Equatable, Sendable {
    var itemIndex: Int
    var lap: Int
    var onsetElapsed: Double
}

extension AudioTransportMapper {
    /// Index of the first item with `tick >= tick` (items sorted by tick).
    static func firstIndex<Item: AudioTickPositioned>(atOrAfter tick: Ticks, in items: [Item]) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].tick < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// A cursor positioned on the first occurrence whose onset is at or after `elapsed`.
    func cursor<Item: AudioTickPositioned>(for items: [Item], atElapsed elapsed: Double) -> AudioScheduleCursor {
        let e = max(0, elapsed)
        if let finish = finishElapsed, e > finish { return AudioScheduleCursor(lap: 0, index: items.count, isFinished: true) }
        let lap = lapIndex(atElapsed: e)
        let range = lapTickRange(lap)
        let approximate = Ticks(tick(atElapsed: e).rounded(.down))
        var index = AudioTransportMapper.firstIndex(atOrAfter: max(range.lowerBound, approximate), in: items)
        while index < items.count, items[index].tick < range.upperBound, self.elapsed(atTick: items[index].tick, lap: lap) < e - 1e-9 {
            index += 1
        }
        return AudioScheduleCursor(lap: lap, index: index, isFinished: false)
    }

    /// Emits every occurrence with onset before `limit` (elapsed seconds), advancing `cursor`. Items must be
    /// sorted by tick. Wraps through loop laps as needed; stops after `maxCount` occurrences.
    func advance<Item: AudioTickPositioned>(_ cursor: inout AudioScheduleCursor, items: [Item], until limit: Double, maxCount: Int = 4096) -> [AudioScheduledOccurrence] {
        var result: [AudioScheduledOccurrence] = []
        while !cursor.isFinished && result.count < maxCount {
            let range = lapTickRange(cursor.lap)
            let index = cursor.index ?? AudioTransportMapper.firstIndex(atOrAfter: range.lowerBound, in: items)
            cursor.index = index
            if index < items.count, items[index].tick < range.upperBound {
                let onset = elapsed(atTick: items[index].tick, lap: cursor.lap)
                guard onset < limit else { break }
                result.append(AudioScheduledOccurrence(itemIndex: index, lap: cursor.lap, onsetElapsed: onset))
                cursor.index = index + 1
            } else {
                guard isLooping else { cursor.isFinished = true; break }
                guard lapStartElapsed(cursor.lap + 1) < limit else { break }
                cursor.lap += 1
                cursor.index = nil
            }
        }
        return result
    }
}
