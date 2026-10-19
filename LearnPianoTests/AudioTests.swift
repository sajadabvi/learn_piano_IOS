import AudioToolbox
import XCTest
@testable import LearnPiano

// MARK: - Helpers

/// Lightweight stand-in for a synth voice, for allocator tests.
private struct StubVoice: AudioVoiceDescribing {
    var isActive: Bool
    var midi: Int
    var isReleasing: Bool
    var level: Float
    var age: UInt64
}

private func makeTimestamp(hostTime: UInt64 = AudioHostClock.now()) -> AudioTimeStamp {
    var ts = AudioTimeStamp()
    ts.mHostTime = hostTime
    ts.mFlags = .hostTimeValid
    return ts
}

/// Renders `frames` samples through a render state and returns them.
@discardableResult
private func render(_ state: AudioSynthRenderState, frames: Int = 256, hostTime: UInt64 = AudioHostClock.now()) -> [Float] {
    var ts = makeTimestamp(hostTime: hostTime)
    var buffer = [Float](repeating: 0, count: frames)
    buffer.withUnsafeMutableBufferPointer { out in
        guard let base = out.baseAddress else { return }
        withUnsafePointer(to: &ts) { state.render(timestamp: $0, frameCount: frames, into: base) }
    }
    return buffer
}

private func pitch(_ name: String) -> Pitch {
    guard let p = Pitch(name: name) else {
        XCTFail("bad pitch \(name)")
        return Pitch(step: .C, octave: 4)
    }
    return p
}

// MARK: - Synth: voice allocation and render state

final class AudioSynthTests: XCTestCase {
    func testAllocatorPrefersFreeVoice() {
        let voices = [
            StubVoice(isActive: true, midi: 60, isReleasing: false, level: 0.5, age: 1),
            StubVoice(isActive: false, midi: 0, isReleasing: false, level: 0, age: 0),
            StubVoice(isActive: true, midi: 64, isReleasing: true, level: 0.01, age: 2),
        ]
        XCTAssertEqual(AudioSynthVoiceAllocator.voiceIndex(forNewNote: 67, in: voices), 1)
    }

    func testAllocatorStealsQuietestReleasingVoiceBeforeHeldOnes() {
        let voices = [
            StubVoice(isActive: true, midi: 60, isReleasing: false, level: 0.001, age: 1),
            StubVoice(isActive: true, midi: 62, isReleasing: true, level: 0.2, age: 2),
            StubVoice(isActive: true, midi: 64, isReleasing: true, level: 0.05, age: 3),
        ]
        // The held voice is quieter overall, but a releasing voice is stolen first.
        XCTAssertEqual(AudioSynthVoiceAllocator.voiceIndex(forNewNote: 67, in: voices), 2)
    }

    func testAllocatorStealsQuietestThenOldest() {
        let voices = [
            StubVoice(isActive: true, midi: 60, isReleasing: false, level: 0.3, age: 5),
            StubVoice(isActive: true, midi: 62, isReleasing: false, level: 0.1, age: 9),
            StubVoice(isActive: true, midi: 64, isReleasing: false, level: 0.1, age: 4),
        ]
        XCTAssertEqual(AudioSynthVoiceAllocator.voiceIndex(forNewNote: 67, in: voices), 2)
        XCTAssertNil(AudioSynthVoiceAllocator.voiceIndex(forNewNote: 60, in: [StubVoice]()))
    }

    func testPolyphonyIsCappedAndNewestNotesSurvive() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        for midi in 40..<80 { queue.push(.noteOn(midi, velocity: 0.8)) }
        render(state)
        XCTAssertEqual(state.activeVoiceCount, 32)
        let held = state.heldMIDINotes
        XCTAssertEqual(held.count, 32)
        XCTAssertTrue(held.contains(79), "the most recent note must have a voice")
        XCTAssertEqual(state.pendingCommandCount, 0)
    }

    func testRestrikeDampsOldVoiceAndKeepsOneHeldVoice() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        queue.push(.noteOn(60, velocity: 0.8))
        render(state)
        queue.push(.noteOn(60, velocity: 0.8))
        render(state)
        XCTAssertEqual(state.heldMIDINotes, [60])
        XCTAssertEqual(state.activeVoiceCount, 2, "old voice rings out briefly while the new strike starts")
    }

    func testNoteOffReleasesAndVoiceEventuallyFrees() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        queue.push(.noteOn(60, velocity: 1))
        render(state)
        queue.push(.noteOff(60))
        render(state)
        XCTAssertEqual(state.heldMIDINotes, [])
        for _ in 0..<(48_000 * 3 / 512) { render(state, frames: 512) }
        XCTAssertEqual(state.activeVoiceCount, 0)
    }

    func testSimultaneousCommandsApplyInArrivalOrder() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        queue.push(.noteOn(62, velocity: 0.8))
        render(state)
        // An older release followed by a new strike of the same key at the same instant: the key stays down.
        queue.push(.noteOff(62))
        queue.push(.noteOn(62, velocity: 0.8))
        render(state)
        XCTAssertEqual(state.heldMIDINotes, [62])
        // Strike then release at the same instant: nothing stays down.
        queue.push(.noteOn(64, velocity: 0.8))
        queue.push(.noteOff(64))
        render(state)
        XCTAssertFalse(state.heldMIDINotes.contains(64))
    }

    func testFutureCommandsWaitAndCanBeCancelledByTag() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        let now = AudioHostClock.now()
        let later = AudioHostClock.hostTime(forSeconds: AudioHostClock.seconds(forHostTime: now) + 10)
        queue.push(.noteOn(60, velocity: 0.8, hostTime: later, tag: 1))
        queue.push(.noteOn(64, velocity: 0.8, hostTime: later, tag: 2))
        render(state, hostTime: now)
        XCTAssertEqual(state.pendingCommandCount, 2)
        XCTAssertEqual(state.activeVoiceCount, 0)
        queue.push(.cancelPending(tag: 1))
        render(state, hostTime: now)
        XCTAssertEqual(state.pendingCommandCount, 1)
        queue.push(.flushPending(tag: 2))
        render(state, hostTime: now)
        XCTAssertEqual(state.pendingCommandCount, 0)
        XCTAssertEqual(state.activeVoiceCount, 0)
    }

    func testCommandLandsOnItsSampleFrame() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        let bufferHost = AudioHostClock.now()
        let bufferSeconds = AudioHostClock.seconds(forHostTime: bufferHost)
        // Due 100 frames into a 256-frame buffer.
        let due = AudioHostClock.hostTime(forSeconds: bufferSeconds + 100.5 / 48_000)
        queue.push(.noteOn(69, velocity: 1, hostTime: due))
        let out = render(state, frames: 256, hostTime: bufferHost)
        XCTAssertTrue(out[0..<99].allSatisfy { $0 == 0 }, "silence before the scheduled frame")
        XCTAssertTrue(out[100..<256].contains { $0 != 0 }, "sound after the scheduled frame")
    }

    func testOutputIsBoundedForDenseChords() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 48, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        for midi in stride(from: 24, to: 96, by: 2) { queue.push(.noteOn(midi, velocity: 1)) }
        var peak: Float = 0
        for _ in 0..<20 { peak = max(peak, render(state, frames: 512).map { abs($0) }.max() ?? 0) }
        XCTAssertGreaterThan(peak, 0.01)
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testVelocityDrivesLoudness() {
        var soft = AudioSynthVoice()
        var loud = AudioSynthVoice()
        soft.start(midi: 60, velocity: 0.2, sampleRate: 48_000, a4: 440, age: 1)
        loud.start(midi: 60, velocity: 1.0, sampleRate: 48_000, a4: 440, age: 2)
        XCTAssertGreaterThan(loud.level, soft.level)
    }

    func testUndampedTrebleIgnoresNormalReleaseButNotRestrike() {
        var voice = AudioSynthVoice()
        voice.start(midi: 100, velocity: 0.8, sampleRate: 48_000, a4: 440, age: 1)
        voice.release(sampleRate: 48_000)
        XCTAssertFalse(voice.isReleasing)
        voice.release(sampleRate: 48_000, force: true)
        XCTAssertTrue(voice.isReleasing)
    }

    func testCommandQueueIsFIFOAndBounded() {
        let queue = AudioCommandQueue(capacity: 10)   // rounds up to 16
        for i in 0..<16 { XCTAssertTrue(queue.push(.noteOn(i, velocity: 0.5))) }
        XCTAssertFalse(queue.push(.noteOn(99, velocity: 0.5)), "full queue drops")
        for i in 0..<16 { XCTAssertEqual(queue.pop()?.midi, UInt8(i)) }
        XCTAssertNil(queue.pop())
        XCTAssertTrue(queue.isEmpty)
    }

    func testSoundFontDiscoveryIgnoresOtherFiles() throws {
        let urls = AudioPianoSynth.discoverSoundFonts(fileManager: .default, bundle: Bundle(for: AudioSynthTests.self))
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension.lowercased() == "sf2" })
    }
}

// MARK: - Player scheduling math

final class AudioTransportMapperTests: XCTestCase {
    private let tempo120 = TempoMap(bpm: 120)

    func testTicksToSecondsUnderSpeed() {
        let full = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 7680, loop: nil)
        XCTAssertEqual(full.elapsed(atTick: 960, lap: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(full.finishElapsed ?? -1, 4.0, accuracy: 1e-9)
        let half = AudioTransportMapper(tempoMap: tempo120, speed: 0.5, startTick: 0, endTick: 7680, loop: nil)
        XCTAssertEqual(half.elapsed(atTick: 960, lap: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(half.tick(atElapsed: 1.5), 1440, accuracy: 1e-6)
        XCTAssertEqual(half.finishElapsed ?? -1, 8.0, accuracy: 1e-9)
    }

    func testStartTickOffset() {
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 960, endTick: 7680, loop: nil)
        XCTAssertEqual(m.elapsed(atTick: 1920, lap: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.tick(atElapsed: 0), 960, accuracy: 1e-9)
        XCTAssertEqual(m.tick(atElapsed: 100), 7680, accuracy: 1e-9, "clamped to the end")
    }

    func testTempoChange() {
        let map = TempoMap(events: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 1920, bpm: 60)])
        let m = AudioTransportMapper(tempoMap: map, speed: 1, startTick: 0, endTick: 3840, loop: nil)
        // 1920 ticks at 120 bpm = 1 s, then 480 ticks at 60 bpm = 0.5 s.
        XCTAssertEqual(m.tick(atElapsed: 1.5), 2400, accuracy: 1e-6)
        XCTAssertEqual(m.elapsed(atTick: 2400, lap: 0), 1.5, accuracy: 1e-9)
        let slow = AudioTransportMapper(tempoMap: map, speed: 0.5, startTick: 0, endTick: 3840, loop: nil)
        XCTAssertEqual(slow.elapsed(atTick: 2400, lap: 0), 3.0, accuracy: 1e-9)
        XCTAssertEqual(AudioTempoMath.seconds(atFractionalTick: 1920 + 480.5, in: map, speed: 1), 1.5 + 0.5 / 960, accuracy: 1e-9)
    }

    func testLoopWrap() {
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 7680, loop: 960..<2880)
        XCTAssertTrue(m.isLooping)
        XCTAssertNil(m.finishElapsed)
        XCTAssertEqual(m.firstLapDuration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(m.lapDuration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(m.tick(atElapsed: 1.49), 2860.8, accuracy: 1e-6)
        XCTAssertEqual(m.tick(atElapsed: 1.5), 960, accuracy: 1e-6, "wraps to the loop start")
        XCTAssertEqual(m.tick(atElapsed: 2.0), 1920, accuracy: 1e-6)
        XCTAssertEqual(m.lapIndex(atElapsed: 2.6), 2)
        XCTAssertEqual(m.tick(atElapsed: 2.6), 1152, accuracy: 1e-6)
        XCTAssertEqual(m.elapsed(atTick: 1920, lap: 3), 4.0, accuracy: 1e-9)
    }

    func testLoopIgnoredWhenStartIsPastItOrInvalid() {
        let past = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 3000, endTick: 7680, loop: 960..<2880)
        XCTAssertFalse(past.isLooping)
        let empty = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 7680, loop: 960..<960)
        XCTAssertFalse(empty.isLooping)
        let clamped = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 3840, loop: 1920..<9999)
        XCTAssertEqual(clamped.loop, 1920..<3840)
    }

    func testCursorEmitsOccurrencesAcrossLoopLaps() {
        let beats = [0, 960, 1920, 2880].map { AudioMetronomeBeat(tick: $0, isDownbeat: false, beatInMeasure: 0, beatsPerMeasure: 4) }
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 3840, loop: 960..<2880)
        var cursor = m.cursor(for: beats, atElapsed: 0)
        let first = m.advance(&cursor, items: beats, until: 3.0)
        XCTAssertEqual(first.map(\.itemIndex), [0, 1, 2, 1, 2, 1])
        XCTAssertEqual(first.map(\.lap), [0, 0, 0, 1, 1, 2])
        let onsets = first.map(\.onsetElapsed)
        for (actual, expected) in zip(onsets, [0, 0.5, 1.0, 1.5, 2.0, 2.5]) { XCTAssertEqual(actual, expected, accuracy: 1e-9) }
        // Continuing picks up exactly where it stopped.
        let next = m.advance(&cursor, items: beats, until: 3.6)
        XCTAssertEqual(next.map(\.itemIndex), [2, 1])
        XCTAssertEqual(next.first?.onsetElapsed ?? -1, 3.0, accuracy: 1e-9)
        XCTAssertFalse(cursor.isFinished)
    }

    func testCursorFinishesWithoutLoop() {
        let beats = [0, 960, 1920].map { AudioMetronomeBeat(tick: $0, isDownbeat: false, beatInMeasure: 0, beatsPerMeasure: 4) }
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 2, startTick: 0, endTick: 2880, loop: nil)
        var cursor = m.cursor(for: beats, atElapsed: 0)
        let all = m.advance(&cursor, items: beats, until: 100)
        XCTAssertEqual(all.map(\.onsetElapsed), [0, 0.25, 0.5])
        XCTAssertTrue(cursor.isFinished)
        XCTAssertTrue(m.advance(&cursor, items: beats, until: 200).isEmpty)
    }

    func testCursorPositionedMidRun() {
        let beats = (0..<8).map { AudioMetronomeBeat(tick: $0 * 960, isDownbeat: false, beatInMeasure: 0, beatsPerMeasure: 4) }
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 7680, loop: 0..<1920)
        // 2.2 s = lap 2 (lap 0: 0-1 s, lap 1: 1-2 s), 0.2 s into it: next beat is tick 960 of lap 2 at 2.5 s.
        var cursor = m.cursor(for: beats, atElapsed: 2.2)
        XCTAssertEqual(cursor.lap, 2)
        let next = m.advance(&cursor, items: beats, until: 3.01)
        XCTAssertEqual(next.map(\.itemIndex), [1, 0])
        XCTAssertEqual(next.first?.onsetElapsed ?? -1, 2.5, accuracy: 1e-9)
    }

    func testReleaseIsCutAtLoopEndAndHasMinimumLength() {
        let m = AudioTransportMapper(tempoMap: tempo120, speed: 1, startTick: 0, endTick: 7680, loop: 0..<1920)
        // A whole note starting at 960 in lap 1 (onset 1.5 s) is cut at the lap end (2.0 s).
        XCTAssertEqual(m.releaseElapsed(endTick: 4800, lap: 1, onsetElapsed: 1.5), 2.0, accuracy: 1e-9)
        XCTAssertEqual(m.releaseElapsed(endTick: 960, lap: 0, onsetElapsed: 0.5), 0.53, accuracy: 1e-9)
    }

    func testPlaybackPlanExtendsTiesAndSkipsRests() {
        let c4 = pitch("C4"), e4 = pitch("E4"), g2 = pitch("G2")
        let m1 = Measure(number: 1, events: [
            MeasureEvent(onset: 0, duration: 3840, notes: [ChordNote(pitch: c4, tieStart: true)], hand: .right),
            MeasureEvent(onset: 0, duration: 3840, notes: [ChordNote(pitch: g2)], hand: .left),
        ])
        let m2 = Measure(number: 2, events: [
            MeasureEvent(onset: 0, duration: 1920, notes: [ChordNote(pitch: c4, tieStop: true)], hand: .right),
            MeasureEvent(onset: 1920, duration: 1920, notes: [ChordNote(pitch: e4)], hand: .right),
            MeasureEvent(onset: 0, duration: 3840, notes: [], hand: .left),
        ])
        let score = Score(metadata: ScoreMetadata(title: "Tie"), initialTempoBPM: 120, measures: [m1, m2])
        let timeline = score.makeTimeline()
        let items = AudioPlaybackPlan.items(from: timeline)
        XCTAssertEqual(items.map(\.tick), [0, 0, 3840, 5760])
        let rightFirst = items[0]
        XCTAssertEqual(rightFirst.hand, .right)
        XCTAssertEqual(rightFirst.notes.map(\.midi), [60])
        XCTAssertEqual(rightFirst.notes.first?.endTick, 5760, "tie extends through the continuation")
        XCTAssertEqual(rightFirst.notes.first?.velocity ?? 0, AudioPlaybackPlan.defaultRightVelocity, accuracy: 1e-9)
        XCTAssertEqual(items[1].hand, .left)
        XCTAssertEqual(items[1].notes.first?.velocity ?? 0, AudioPlaybackPlan.defaultLeftVelocity, accuracy: 1e-9)
        XCTAssertTrue(items[2].notes.isEmpty, "continuation is not re-struck")
        XCTAssertEqual(items[3].notes.map(\.midi), [64])
        XCTAssertEqual(timeline.events[items[3].eventIndex].tick, 5760)
    }

    func testPlaybackJobSchedulesAudibleHandWithExactHostTimes() {
        let score = ScoreBuilder.make(title: "Two hands", tempo: 120,
                                      right: [[(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)]],
                                      left: [[(["C3"], 1920), (["G2"], 1920)]])
        let timeline = score.makeTimeline()
        let items = AudioPlaybackPlan.items(from: timeline)
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 1, startTick: 0, endTick: timeline.totalTicks, loop: nil)
        let anchor = 1_000.0
        var reported: [Hand] = []
        let job = AudioPlaybackJob(mapper: mapper, anchorHostSeconds: anchor, items: items, audibleHands: .left, tag: 7) { item, _ in
            reported.append(item.hand)
        }
        let queue = AudioCommandQueue()
        let sink = AudioRenderCommandSink(queue: queue)
        func drain() -> [AudioRenderCommand] {
            var out: [AudioRenderCommand] = []
            while let c = queue.pop() { out.append(c) }
            return out
        }

        XCTAssertFalse(job.pump(untilHostSeconds: anchor + 0.6, sink: sink))
        let first = drain()
        XCTAssertEqual(first.map(\.kind), [.noteOn])
        XCTAssertEqual(first.first?.midi, 48)
        XCTAssertEqual(first.first?.tag, 7)
        XCTAssertEqual(first.first?.hostTime, AudioHostClock.hostTime(forSeconds: anchor))

        XCTAssertFalse(job.pump(untilHostSeconds: anchor + 1.2, sink: sink))
        let second = drain()
        // The release of C3 and the strike of G2 share an instant: the release is queued first.
        XCTAssertEqual(second.map(\.kind), [.noteOff, .noteOn])
        XCTAssertEqual(second.map(\.midi), [48, 43])
        XCTAssertEqual(second.map(\.hostTime), [AudioHostClock.hostTime(forSeconds: anchor + 1.0), AudioHostClock.hostTime(forSeconds: anchor + 1.0)])

        XCTAssertTrue(job.pump(untilHostSeconds: anchor + 10, sink: sink), "finished once every release is queued")
        let third = drain()
        XCTAssertEqual(third.map(\.kind), [.noteOff])
        XCTAssertEqual(third.first?.midi, 43)
        XCTAssertEqual(reported, [.left, .left], "only audible events are reported")
    }

    func testPlaybackJobCancelReleasesHeldNotes() {
        let score = ScoreBuilder.make(title: "Long", tempo: 60, right: [[(["C4", "E4"], 3840)]])
        let timeline = score.makeTimeline()
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 1, startTick: 0, endTick: timeline.totalTicks, loop: nil)
        let job = AudioPlaybackJob(mapper: mapper, anchorHostSeconds: 50, items: AudioPlaybackPlan.items(from: timeline),
                                   audibleHands: .both, tag: 3) { _, _ in }
        let queue = AudioCommandQueue()
        let sink = AudioRenderCommandSink(queue: queue)
        _ = job.pump(untilHostSeconds: 50.1, sink: sink)
        while queue.pop() != nil {}
        XCTAssertEqual(job.cancel(releaseSounding: true, cutoffHostSeconds: 0, sink: sink), [], "a hard cancel owes nothing")
        var kinds: [AudioRenderCommand.Kind] = []
        var midis: Set<UInt8> = []
        while let c = queue.pop() {
            kinds.append(c.kind)
            if c.kind == .noteOff { midis.insert(c.midi); XCTAssertEqual(c.hostTime, 0, "released now") }
        }
        XCTAssertEqual(kinds.first, .flushPending)
        XCTAssertEqual(midis, [60, 64])
        XCTAssertTrue(job.pump(untilHostSeconds: 100, sink: sink), "a cancelled job schedules nothing more")
        XCTAssertNil(queue.pop())
    }

    func testMutedPlaybackStillAdvances() {
        let score = ScoreBuilder.make(title: "Mute", tempo: 120, right: [[(["C4"], 3840)]])
        let timeline = score.makeTimeline()
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 1, startTick: 0, endTick: timeline.totalTicks, loop: nil)
        let job = AudioPlaybackJob(mapper: mapper, anchorHostSeconds: 0, items: AudioPlaybackPlan.items(from: timeline),
                                   audibleHands: nil, tag: 1) { _, _ in XCTFail("muted events are not reported") }
        let queue = AudioCommandQueue()
        XCTAssertTrue(job.pump(untilHostSeconds: 5, sink: AudioRenderCommandSink(queue: queue)))
        XCTAssertNil(queue.pop())
    }

    @MainActor
    func testPlayerStoppedStatePositioning() {
        let synth = AudioPianoSynth()
        let player = AudioScorePlayer(synth: synth)
        let score = ScoreBuilder.make(title: "Scale", tempo: 120, right: [[(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)],
                                                                       [(["G4"], 3840)]])
        player.load(timeline: score.makeTimeline())
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.positionTick, 0)
        player.seek(toTick: 1920)
        XCTAssertEqual(player.positionTick, 1920)
        player.seek(toTick: 99_999)
        XCTAssertEqual(player.positionTick, 7680, "seek clamps to the end")
        player.loopTicks = 960..<2880
        player.stop()
        XCTAssertEqual(player.positionTick, 960, "stop rewinds to the loop start")
        player.speed = 10
        XCTAssertEqual(player.speed, 2.0, "speed is clamped")
        XCTAssertEqual(player.remainingSeconds, 1.75, accuracy: 1e-9)
    }
}

// MARK: - Metronome beats

final class AudioMetronomeTests: XCTestCase {
    private func segments(count: Int, length: Ticks) -> [PlaybackSegment] {
        (0..<count).map { PlaybackSegment(measureIndex: $0, pass: 1, startTick: $0 * length, length: length) }
    }

    func testFourFour() {
        let meter = TimeSignature(beats: 4, beatType: 4)
        let beats = AudioMetronomeBeats.beats(segments: segments(count: 2, length: 3840)) { _ in meter }
        XCTAssertEqual(beats.map(\.tick), [0, 960, 1920, 2880, 3840, 4800, 5760, 6720])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, false, false, true, false, false, false])
        XCTAssertEqual(beats.map(\.beatInMeasure), [0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertTrue(beats.allSatisfy { $0.beatsPerMeasure == 4 })
    }

    func testThreeFour() {
        let meter = TimeSignature(beats: 3, beatType: 4)
        let beats = AudioMetronomeBeats.beats(segments: segments(count: 2, length: 2880)) { _ in meter }
        XCTAssertEqual(beats.map(\.tick), [0, 960, 1920, 2880, 3840, 4800])
        XCTAssertEqual(beats.filter(\.isDownbeat).map(\.tick), [0, 2880])
    }

    func testSixEightClicksDottedQuarters() {
        let meter = TimeSignature(beats: 6, beatType: 8)
        XCTAssertEqual(meter.measureTicks, 2880)
        let beats = AudioMetronomeBeats.beats(segments: segments(count: 2, length: 2880)) { _ in meter }
        XCTAssertEqual(beats.map(\.tick), [0, 1440, 2880, 4320])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, true, false])
        XCTAssertTrue(beats.allSatisfy { $0.beatsPerMeasure == 2 })
    }

    func testPickupAlignsToItsEnd() {
        let meter = TimeSignature.common
        let segs = [PlaybackSegment(measureIndex: 0, pass: 1, startTick: 0, length: 960),
                    PlaybackSegment(measureIndex: 1, pass: 1, startTick: 960, length: 3840)]
        let beats = AudioMetronomeBeats.beats(segments: segs) { _ in meter }
        XCTAssertEqual(beats.first, AudioMetronomeBeat(tick: 0, isDownbeat: false, beatInMeasure: 3, beatsPerMeasure: 4))
        XCTAssertEqual(beats.dropFirst().first?.tick, 960)
        XCTAssertEqual(beats.dropFirst().first?.isDownbeat, true)
    }

    func testMeterChangeFollowsProvider() {
        let segs = [PlaybackSegment(measureIndex: 0, pass: 1, startTick: 0, length: 3840),
                    PlaybackSegment(measureIndex: 1, pass: 1, startTick: 3840, length: 2880)]
        let beats = AudioMetronomeBeats.beats(segments: segs) { tick in tick < 3840 ? .common : TimeSignature(beats: 3, beatType: 4) }
        XCTAssertEqual(beats.count, 7)
        XCTAssertEqual(beats.filter(\.isDownbeat).map(\.tick), [0, 3840])
    }

    func testBeatsFromTimelineWithRepeat() {
        var score = ScoreBuilder.make(title: "Waltz", time: TimeSignature(beats: 3, beatType: 4), tempo: 120,
                                      right: [[(["C4"], 2880)], [(["E4"], 2880)]])
        score.measures[1].barline = Barline(repeatBackwardTimes: 2)
        let timeline = score.makeTimeline()
        XCTAssertEqual(timeline.segments.count, 4)
        let beats = AudioMetronomeBeats.beats(timeline: timeline) { _ in TimeSignature(beats: 3, beatType: 4) }
        XCTAssertEqual(beats.count, 12)
        XCTAssertEqual(beats.filter(\.isDownbeat).map(\.tick), [0, 2880, 5760, 8640])
    }

    func testCountInBeatsAndTiming() {
        let sixEight = AudioMetronomeBeats.countInBeats(measures: 1, timeSignature: TimeSignature(beats: 6, beatType: 8))
        XCTAssertEqual(sixEight.map(\.tick), [0, 1440])
        XCTAssertEqual(sixEight.map(\.isDownbeat), [true, false])
        let fourFour = AudioMetronomeBeats.countInBeats(measures: 2, timeSignature: .common)
        XCTAssertEqual(fourFour.count, 8)
        XCTAssertEqual(fourFour.filter(\.isDownbeat).map(\.tick), [0, 3840])
        XCTAssertTrue(AudioMetronomeBeats.countInBeats(measures: 0, timeSignature: .common).isEmpty)

        XCTAssertEqual(AudioMetronomeBeats.countInPulseSeconds(timeSignature: .common, bpm: 120, speed: 0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(AudioMetronomeBeats.countInPulseSeconds(timeSignature: TimeSignature(beats: 6, beatType: 8), bpm: 60, speed: 1), 1.5, accuracy: 1e-9)
        XCTAssertEqual(AudioMetronomeBeats.countInPulseSeconds(timeSignature: TimeSignature(beats: 3, beatType: 4), bpm: 90, speed: 1), 2.0 / 3.0, accuracy: 1e-9)

        // The count-in run uses the same mapper as playback: 2 measures of 4/4 at 120 bpm last 4 s.
        let mapper = AudioTransportMapper(tempoMap: TempoMap(bpm: 120), speed: 1, startTick: 0, endTick: fourFour.count * 960, loop: nil)
        XCTAssertEqual(mapper.finishElapsed ?? -1, 4.0, accuracy: 1e-9)
    }
}

// MARK: - Volumes, unisons and seamless re-time hand-overs

/// Pops every command waiting in `queue`.
private func drainCommands(_ queue: AudioCommandQueue) -> [AudioRenderCommand] {
    var out: [AudioRenderCommand] = []
    while let c = queue.pop() { out.append(c) }
    return out
}

/// What the render thread ends up executing from a command stream: every tagged `cancelPending` with a cutoff
/// removes the earlier timed commands of its tag due at or after the cutoff. Control commands are dropped.
private func effectiveTimedCommands(_ stream: [AudioRenderCommand]) -> [AudioRenderCommand] {
    var kept: [AudioRenderCommand] = []
    for command in stream {
        switch command.kind {
        case .cancelPending where command.hostTime != 0:
            kept.removeAll { $0.tag == command.tag && $0.hostTime >= command.hostTime }
        case .noteOn, .noteOff, .click:
            kept.append(command)
        default:
            break
        }
    }
    return kept
}

final class AudioHandOverTests: XCTestCase {
    @MainActor
    func testMasterVolumeClampsWithoutRecursing() {
        let synth = AudioPianoSynth()
        synth.masterVolume = 0.5
        XCTAssertEqual(synth.masterVolume, 0.5)
        synth.masterVolume = 3
        XCTAssertEqual(synth.masterVolume, 1)
        synth.masterVolume = -2
        XCTAssertEqual(synth.masterVolume, 0)
        synth.masterVolume = .nan
        XCTAssertEqual(synth.masterVolume, 0.9)
    }

    @MainActor
    func testPlaybackVolumeClampsOnStoppedPlayer() {
        let player = AudioScorePlayer(synth: AudioPianoSynth())
        player.playbackVolume = 0.5
        XCTAssertEqual(player.playbackVolume, 0.5)
        player.playbackVolume = 3
        XCTAssertEqual(player.playbackVolume, 1.5)
        player.playbackVolume = -1
        XCTAssertEqual(player.playbackVolume, 0)
        player.playbackVolume = .infinity
        XCTAssertEqual(player.playbackVolume, 1)
        XCTAssertFalse(player.isPlaying)
    }

    func testCancelWithCutoffDropsOnlyTheTagsFuture() {
        let queue = AudioCommandQueue()
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        let base = AudioHostClock.nowSeconds + 100
        func host(_ t: Double) -> UInt64 { AudioHostClock.hostTime(forSeconds: base + t) }
        queue.push(.noteOn(60, velocity: 0.8, hostTime: host(1.0), tag: 1))   // before the cutoff: kept
        queue.push(.noteOff(60, hostTime: host(3.0), tag: 1))                 // after: dropped
        queue.push(.noteOn(62, velocity: 0.8, hostTime: host(2.0), tag: 1))   // exactly at it: dropped
        queue.push(.click(accented: true, hostTime: host(2.5), tag: 1))       // after: dropped
        queue.push(.noteOn(64, velocity: 0.8, hostTime: host(2.5), tag: 2))   // other producer: kept
        render(state, hostTime: host(0))
        XCTAssertEqual(state.pendingCommandCount, 5)
        queue.push(.cancelPending(tag: 1, cutoffHostTime: host(2.0)))
        render(state, hostTime: host(0))
        XCTAssertEqual(state.pendingCommandCount, 2)
        render(state, hostTime: host(1.5))
        XCTAssertEqual(state.heldMIDINotes, [60])
        render(state, hostTime: host(3.5))
        XCTAssertEqual(state.heldMIDINotes, [60, 64], "the dropped release is the producer's to re-supply")
    }

    /// RH half-note C4 and LH quarter-note C4 struck together: the key is struck once and released once, when
    /// the half note ends (the quarter's release must not cut it).
    func testUnisonOverlapReleasesOnceAtTheLongestEnd() {
        let score = ScoreBuilder.make(title: "Unison", tempo: 120,
                                      right: [[(["C4"], 1920), ([], 1920)]],
                                      left: [[(["C4"], 960), ([], 2880)]])
        let timeline = score.makeTimeline()
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 1, startTick: 0, endTick: timeline.totalTicks, loop: nil)
        let anchor = AudioHostClock.nowSeconds + 100
        let job = AudioPlaybackJob(mapper: mapper, anchorHostSeconds: anchor, items: AudioPlaybackPlan.items(from: timeline),
                                   audibleHands: .both, tag: 1) { _, _ in }
        let queue = AudioCommandQueue()
        let sink = AudioRenderCommandSink(queue: queue)
        XCTAssertTrue(job.pump(untilHostSeconds: anchor + 10, sink: sink))
        let commands = drainCommands(queue)
        let ons = commands.filter { $0.kind == .noteOn }
        let offs = commands.filter { $0.kind == .noteOff }
        XCTAssertEqual(ons.map(\.midi), [60], "a unison is struck once")
        XCTAssertEqual(offs.map(\.midi), [60], "and released once")
        XCTAssertEqual(AudioHostClock.seconds(forHostTime: offs.first?.hostTime ?? 0) - anchor, 1.0, accuracy: 1e-6)

        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        for c in commands { queue.push(c) }
        render(state, hostTime: AudioHostClock.hostTime(forSeconds: anchor + 0.6))
        XCTAssertEqual(state.heldMIDINotes, [60], "the half note still sounds after the quarter ends")
        render(state, hostTime: AudioHostClock.hostTime(forSeconds: anchor + 1.1))
        XCTAssertEqual(state.heldMIDINotes, [])
    }

    /// A re-time from speed 1 to speed 2 at a cutoff: the old job keeps what lies before it, the new job plays
    /// everything from it on, notes sounding across it end on time, and a key the new run strikes again is not
    /// cut by the old run's (stale) release.
    func testRetimeHandOverLosesNothingDuplicatesNothingAndLeavesNoStaleRelease() {
        // 120 BPM: 1920 ticks per second at speed 1.
        let score = ScoreBuilder.make(title: "Hand-over", tempo: 120,
                                      right: [[(["C4"], 1920), (["C4"], 960), (["D4"], 960)]],
                                      left: [[([], 1320), (["G3"], 120), (["A3"], 480), (["A3"], 960), ([], 960)]])
        let timeline = score.makeTimeline()
        let items = AudioPlaybackPlan.items(from: timeline)
        let a = AudioHostClock.nowSeconds + 100
        func host(_ t: Double) -> UInt64 { AudioHostClock.hostTime(forSeconds: a + t) }
        let queue = AudioCommandQueue()
        let sink = AudioRenderCommandSink(queue: queue)
        let state = AudioSynthRenderState(voiceCount: 32, sampleRate: 48_000, a4Hertz: 440, queue: queue)
        var reported: [(job: Int, tick: Ticks, host: Double)] = []

        // Old run: speed 1, pumped 120 ms ahead of "now" = 0.70 s; the render thread has reached 0.68 s.
        let oldMapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 1, startTick: 0, endTick: timeline.totalTicks, loop: nil)
        let oldJob = AudioPlaybackJob(mapper: oldMapper, anchorHostSeconds: a, items: items, audibleHands: .both, tag: 1,
                                      clock: { a + 0.6 }) { item, host in reported.append((1, item.tick, host)) }
        XCTAssertFalse(oldJob.pump(untilHostSeconds: a + 0.82, sink: sink))
        let firstBatch = drainCommands(queue)
        for c in firstBatch { queue.push(c) }
        render(state, hostTime: host(0.68))

        // Re-time at 0.70 s (tick 1344) to speed 2.
        let cutoff = a + 0.7
        XCTAssertEqual(oldMapper.tick(atElapsed: 0.7), 1344, accuracy: 1e-6)
        let newMapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: 2, startTick: 1344, endTick: timeline.totalTicks, loop: nil)
        let newJob = AudioPlaybackJob(mapper: newMapper, anchorHostSeconds: cutoff, items: items, audibleHands: .both, tag: 1,
                                      clock: { a + 0.6 }) { item, host in reported.append((2, item.tick, host)) }
        let owed = oldJob.cancel(releaseSounding: false, cutoffHostSeconds: cutoff, sink: sink)
        XCTAssertEqual(owed.map(\.midi).sorted(), [55, 60], "G3 and the C4 half note sound across the cutoff")
        XCTAssertTrue(newJob.adopt(owed))
        XCTAssertTrue(newJob.pump(untilHostSeconds: a + 10, sink: sink))
        XCTAssertTrue(oldJob.pump(untilHostSeconds: a + 10, sink: sink), "the old job schedules nothing more")
        let secondBatch = drainCommands(queue)

        // What the render thread executes, in seconds after the anchor.
        let effective = effectiveTimedCommands(firstBatch + secondBatch)
        func events(_ kind: AudioRenderCommand.Kind) -> [String] {
            var timed: [(midi: Int, seconds: Double)] = []
            for command in effective where command.kind == kind {
                timed.append((Int(command.midi), AudioHostClock.seconds(forHostTime: command.hostTime) - a))
            }
            timed.sort { lhs, rhs in
                if abs(lhs.seconds - rhs.seconds) > 1e-6 { return lhs.seconds < rhs.seconds }
                return lhs.midi < rhs.midi
            }
            return timed.map { entry in "\(entry.midi)@" + String(format: "%.4f", entry.seconds) }
        }
        XCTAssertEqual(events(.noteOn), ["60@0.0000", "55@0.6875", "57@0.7250", "57@0.8500", "60@0.8500", "62@1.1000"],
                       "every note is struck exactly once, at its old-speed time before the cutoff and new-speed time after it")
        XCTAssertEqual(events(.noteOff), ["55@0.7500", "57@0.8500", "57@1.1000", "60@1.1000", "62@1.3500"],
                       "G3 ends on its old time; the C4 restruck at 0.85 is not cut by the old half note's release at 1.0")
        // UI callbacks: the old run's reports from the cutoff on are filtered out by the run generations.
        var runs = AudioRunGenerations()
        let oldGeneration = runs.advance(keepingPreviousBefore: nil)
        let newGeneration = runs.advance(keepingPreviousBefore: cutoff)
        let delivered = reported.filter { runs.accepts(generation: $0.job == 1 ? oldGeneration : newGeneration, hostSeconds: $0.host) }
        XCTAssertEqual(delivered.filter { $0.job == 1 }.map(\.tick), [0, 1320], "the old run reports only what it played")
        XCTAssertEqual(delivered.filter { $0.job == 2 }.map(\.tick), [1440, 1920, 1920, 2880])

        // And the render thread agrees.
        for c in secondBatch { queue.push(c) }
        let checkpoints: [(Double, [Int])] = [(0.70, [55, 60]), (0.74, [55, 57, 60]), (0.80, [57, 60]), (0.90, [57, 60]),
                                              (1.05, [57, 60]), (1.15, [62]), (1.40, [])]
        for (t, held) in checkpoints {
            render(state, hostTime: host(t))
            XCTAssertEqual(state.heldMIDINotes, held, "held keys at \(t) s")
        }
    }

    func testUnadoptedOwedReleasesCollapseToTheLatestPerKey() {
        let queue = AudioCommandQueue()
        let sink = AudioRenderCommandSink(queue: queue)
        let base = AudioHostClock.nowSeconds + 100
        AudioLookaheadScheduler.push([
            AudioOwedNoteOff(midi: 60, onsetHostSeconds: base, hostSeconds: base + 2, tag: 1),
            AudioOwedNoteOff(midi: 60, onsetHostSeconds: base, hostSeconds: base + 1, tag: 1),
            AudioOwedNoteOff(midi: 64, onsetHostSeconds: base, hostSeconds: base + 1.5, tag: 1),
        ], to: sink)
        let commands = drainCommands(queue)
        XCTAssertEqual(commands.map(\.kind), [.noteOff, .noteOff])
        XCTAssertEqual(commands.map(\.midi), [64, 60])
        XCTAssertEqual(commands.last?.hostTime, AudioHostClock.hostTime(forSeconds: base + 2))
    }

    func testClickJobsAdoptNothing() {
        let mapper = AudioTransportMapper(tempoMap: TempoMap(bpm: 120), speed: 1, startTick: 0, endTick: 3840, loop: nil)
        let job = AudioClickJob(mapper: mapper, anchorHostSeconds: 0, beats: [], tag: 2, enabled: AudioAtomicFlag(true)) { _, _, _ in }
        XCTAssertFalse(job.adopt([AudioOwedNoteOff(midi: 60, onsetHostSeconds: 0, hostSeconds: 1, tag: 2)]))
    }

    func testRunGenerationsKeepReplacedRunsUntilTheirCutoff() {
        var runs = AudioRunGenerations()
        let first = runs.advance(keepingPreviousBefore: nil)
        XCTAssertTrue(runs.accepts(generation: first, hostSeconds: 50))
        let second = runs.advance(keepingPreviousBefore: 10)
        XCTAssertTrue(runs.accepts(generation: first, hostSeconds: 9.99), "played before the hand-over")
        XCTAssertFalse(runs.accepts(generation: first, hostSeconds: 10), "replaced from the cutoff on")
        XCTAssertTrue(runs.accepts(generation: second, hostSeconds: 10))
        let third = runs.advance(keepingPreviousBefore: nil)
        XCTAssertFalse(runs.accepts(generation: first, hostSeconds: 1), "a stop discards every earlier run")
        XCTAssertFalse(runs.accepts(generation: second, hostSeconds: 1))
        XCTAssertTrue(runs.accepts(generation: third, hostSeconds: 1))
        for _ in 0..<(AudioRunGenerations.retainedRuns + 2) { _ = runs.advance(keepingPreviousBefore: 1_000) }
        XCTAssertFalse(runs.accepts(generation: third, hostSeconds: 1), "very old runs are forgotten")
    }
}
