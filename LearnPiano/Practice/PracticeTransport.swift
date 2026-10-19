import Foundation

// MARK: - Clock-driven transport (used when no audio player is attached, and by tests/harness)

/// A silent transport that advances a playback position from the injected clock at tempo × speed.
///
/// `PracticeSession` uses it for Just Play and Listen when no `ScorePlaybackControlling` player is attached
/// (unit tests, the macOS harness, previews), so timed modes behave exactly as with audio. Loop regions wrap
/// like the audio player's `loopTicks` (end exclusive); without a loop the position stops at `endTick`.
struct PracticeVirtualTransport {
    let timeline: PlaybackTimeline
    /// Playback speed multiplier (0.25…1.0).
    var speed: Double
    /// Loop region in playback ticks (end exclusive), nil = none.
    var loopTicks: Range<Ticks>?
    private(set) var isPlaying = false
    /// Position when the transport was last started/paused/seeked.
    private var anchorTick: Double = 0
    /// Clock time matching `anchorTick` while playing.
    private var anchorTime: TimeInterval = 0

    init(timeline: PlaybackTimeline, speed: Double, loopTicks: Range<Ticks>? = nil) {
        self.timeline = timeline
        self.speed = speed
        self.loopTicks = loopTicks
    }

    /// End of the material (the timeline's last tick).
    var endTick: Double { Double(timeline.totalTicks) }

    /// Starts moving from `tick` at clock time `now`.
    mutating func play(fromTick tick: Double, now: TimeInterval) {
        anchorTick = tick
        anchorTime = now
        isPlaying = true
    }

    /// Freezes the position at `now`.
    mutating func pause(now: TimeInterval) {
        guard isPlaying else { return }
        anchorTick = position(now: now)
        isPlaying = false
    }

    /// Stops and rewinds to `tick`.
    mutating func stop(atTick tick: Double) {
        isPlaying = false
        anchorTick = tick
    }

    /// Jumps to `tick`, keeping the play/pause state.
    mutating func seek(toTick tick: Double, now: TimeInterval) {
        anchorTick = tick
        anchorTime = now
    }

    /// Changes the speed without a jump in position.
    mutating func setSpeed(_ newSpeed: Double, now: TimeInterval) {
        anchorTick = position(now: now)
        anchorTime = now
        speed = newSpeed
    }

    /// Fractional playback tick at clock time `now` (loop-wrapped, clamped to the end without a loop).
    func position(now: TimeInterval) -> Double {
        guard isPlaying else { return anchorTick }
        let startSeconds = Self.seconds(atFractionalTick: anchorTick, in: timeline, speed: speed)
        let seconds = startSeconds + max(0, now - anchorTime)
        let raw = timeline.tick(atSeconds: seconds, speed: speed)
        if let loop = loopTicks, !loop.isEmpty, raw >= Double(loop.upperBound), anchorTick < Double(loop.upperBound) {
            let lowerSeconds = timeline.seconds(atTick: loop.lowerBound, speed: speed)
            let upperSeconds = timeline.seconds(atTick: loop.upperBound, speed: speed)
            let length = upperSeconds - lowerSeconds
            guard length > 0 else { return Double(loop.lowerBound) }
            let past = (seconds - upperSeconds).truncatingRemainder(dividingBy: length)
            return timeline.tick(atSeconds: lowerSeconds + past, speed: speed)
        }
        return min(raw, endTick)
    }

    /// Whether the transport has played to the end of the material (never true while looping).
    func reachedEnd(now: TimeInterval) -> Bool {
        guard isPlaying, loopTicks == nil else { return false }
        return position(now: now) >= endTick
    }

    /// Seconds from tick 0 to a fractional tick at a speed (linear inside one tick).
    static func seconds(atFractionalTick tick: Double, in timeline: PlaybackTimeline, speed: Double) -> Double {
        let whole = Int(tick.rounded(.down))
        let fraction = tick - Double(whole)
        let base = timeline.seconds(atTick: whole, speed: speed)
        guard fraction > 0 else { return base }
        return base + fraction * (timeline.seconds(atTick: whole + 1, speed: speed) - base)
    }
}

// MARK: - Phrase navigation

/// Splits a score into phrases (in notated measure indices) for the "next/previous phrase" transport buttons.
///
/// A phrase starts at measure 0 (or 1 after a pickup), at every forward repeat, after every backward repeat
/// or final barline, and otherwise every `phraseMeasures` measures since the previous start.
enum PracticePhraseNavigator {
    /// Default phrase length in measures.
    static let defaultPhraseMeasures = 4

    /// Sorted notated measure indices where phrases start.
    static func phraseStarts(of score: Score, phraseMeasures: Int = defaultPhraseMeasures) -> [Int] {
        guard !score.measures.isEmpty else { return [] }
        let length = max(1, phraseMeasures)
        var starts: [Int] = [0]
        // A pickup is its own (short) phrase; the first full measure then starts counting.
        let pickup = score.measures[0].isPickup
        if pickup, score.measures.count > 1 { starts.append(1) }
        var sinceStart = pickup ? 0 : 1
        for i in score.measures.indices.dropFirst() {
            let m = score.measures[i]
            let previous = score.measures[i - 1].barline
            let boundary = m.barline.repeatForward || previous.repeatBackwardTimes != nil || previous.isFinal
            if boundary || sinceStart >= length {
                if starts.last != i { starts.append(i) }
                sinceStart = 1
            } else {
                sinceStart += 1
            }
        }
        return starts
    }

    /// Start of the phrase after the one containing `measure`, or nil at the last phrase.
    static func nextPhraseStart(after measure: Int, starts: [Int]) -> Int? {
        starts.first { $0 > measure }
    }

    /// "Previous" behaves like a media player: back to the start of the current phrase when the position is
    /// past its first beat, otherwise to the start of the previous phrase.
    static func previousPhraseStart(from measure: Int, tickInMeasure: Ticks, beatTicks: Ticks, starts: [Int]) -> Int {
        guard let current = starts.last(where: { $0 <= measure }) else { return starts.first ?? 0 }
        if measure > current || tickInMeasure > beatTicks { return current }
        return starts.last(where: { $0 < current }) ?? current
    }
}

// MARK: - Speed

/// Speed rules for the practice transport.
enum PracticeSpeedRules {
    /// Slowest and fastest practice speeds.
    static let range: ClosedRange<Double> = 0.25...1.0
    /// Granularity of the speed slider.
    static let step = 0.05

    /// Clamps to `range` and snaps to multiples of `step`.
    static func snap(_ speed: Double) -> Double {
        guard speed.isFinite else { return range.upperBound }
        let clamped = min(range.upperBound, max(range.lowerBound, speed))
        let snapped = (clamped / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, (snapped * 1000).rounded() / 1000))
    }

    /// The next preset (`PracticeSpeed`) faster (`up`) or slower than `speed`; stays put at the ends.
    static func preset(from speed: Double, up: Bool) -> Double {
        let presets = PracticeSpeed.allCases.map { $0.rawValue }.sorted()
        if up { return presets.first { $0 > speed + 1e-9 } ?? presets.last ?? speed }
        return presets.last { $0 < speed - 1e-9 } ?? presets.first ?? speed
    }
}
