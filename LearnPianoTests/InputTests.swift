import XCTest
@testable import LearnPiano

// Deterministic tests of the Input module's pure logic: MIDI 1.0 parsing and note mapping, polyphonic pitch
// detection and note tracking on synthetic signals, and the hub's held-note bookkeeping. No hardware, audio
// session or CoreMIDI client is touched.

// MARK: - Signal helpers

/// Synthetic test signals and a seeded random generator so every run produces identical samples.
enum InputTestSignals {
    static let sampleRate = 44_100.0

    /// SplitMix64: tiny, fast, and fully deterministic for a given seed.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A piano-like harmonic tone: every partial `k` of each fundamental has amplitude `amplitude / k`, with a
    /// fixed per-partial phase so the waveform is not a pathological sum of aligned sines. Partials above
    /// 90 % of Nyquist are omitted. `fundamentalGain` scales partial 1 only (to mimic weak bass fundamentals).
    /// `inharmonicity` is the piano string stiffness coefficient B: partial k sits at `k·f0·√(1 + B·k²)`.
    static func tone(_ frequencies: [Double], amplitude: Double = 0.2, harmonics: Int = 8, fundamentalGain: Double = 1,
                     inharmonicity: Double = 0, seconds: Double, sampleRate: Double = sampleRate,
                     decayPerSecond: Double = 0) -> [Float] {
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for (noteIndex, f0) in frequencies.enumerated() {
            for k in 1...harmonics {
                let f = f0 * Double(k) * (1 + inharmonicity * Double(k * k)).squareRoot()
                guard f < sampleRate * 0.45 else { break }
                let a = amplitude / Double(k) * (k == 1 ? fundamentalGain : 1)
                let phase = Double(k * 7 + noteIndex * 3) * 0.37
                let w = 2 * Double.pi * f / sampleRate
                for n in 0..<count {
                    let envelope = decayPerSecond > 0 ? exp(-decayPerSecond * Double(n) / sampleRate) : 1
                    out[n] += Float(a * envelope * sin(w * Double(n) + phase))
                }
            }
        }
        return out
    }

    /// Uniform white noise in −amplitude…amplitude.
    static func noise(amplitude: Float, seconds: Double, seed: UInt64, sampleRate: Double = sampleRate) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    static func silence(seconds: Double, sampleRate: Double = sampleRate) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Adds `part` into `signal` starting `seconds` in, growing `signal` when needed.
    static func mix(_ part: [Float], into signal: inout [Float], at seconds: Double, sampleRate: Double = sampleRate) {
        let start = Int(seconds * sampleRate)
        if signal.count < start + part.count { signal += [Float](repeating: 0, count: start + part.count - signal.count) }
        for (j, value) in part.enumerated() { signal[start + j] += value }
    }

    /// A chord held from 0.2 s for `chordSeconds` with single melody notes struck over it at `melodyTimes`
    /// (piano-like stretched partials, B = 3e-4), followed by 0.5 s of silence.
    static func melodyOverHeldChord(_ chord: [Int], melody: [Int], melodyTimes: [Double], chordSeconds: Double = 3,
                                    chordAmplitude: Double = 0.1, melodyAmplitude: Double = 0.12) -> [Float] {
        var signal = silence(seconds: 0.2)
        mix(tone(chord.map { hz($0) }, amplitude: chordAmplitude, inharmonicity: 3e-4, seconds: chordSeconds, decayPerSecond: 0.6),
            into: &signal, at: 0.2)
        for (midi, time) in zip(melody, melodyTimes) {
            mix(tone([hz(midi)], amplitude: melodyAmplitude, inharmonicity: 3e-4, seconds: 0.5, decayPerSecond: 2), into: &signal, at: time)
        }
        return signal + silence(seconds: 0.5)
    }

    /// Equal-tempered frequency of a MIDI note.
    static func hz(_ midi: Int, a4: Double = 440) -> Double { MusicHelpers.frequency(midi: Double(midi), a4: a4) }

    /// Fundamentals the detector finds in the first 4096 samples, ascending.
    static func detectedMIDI(_ samples: [Float], configuration: InputPitchDetectorConfiguration = InputPitchDetectorConfiguration()) -> [Int] {
        let analyzer = InputSpectrumAnalyzer(fftSize: 4096, sampleRate: sampleRate)!
        var spectrum: [Float] = []
        analyzer.magnitudes(of: Array(samples.prefix(4096)), into: &spectrum)
        let detector = InputPitchDetector(binWidth: analyzer.binWidth, binCount: analyzer.binCount, configuration: configuration)
        return detector.detect(spectrum: spectrum).map(\.midi).sorted()
    }

    /// Runs a whole signal through the microphone pipeline in tap-sized chunks and returns every event.
    static func pipelineEvents(_ samples: [Float], startTime: TimeInterval = 100,
                               configuration: InputPitchDetectorConfiguration = InputPitchDetectorConfiguration()) -> [NoteInputEvent] {
        let pipeline = InputPitchPipeline(sampleRate: sampleRate, fftSize: 4096, hop: 1024, detector: configuration)!
        var events: [NoteInputEvent] = []
        var index = 0
        let chunk = 2048
        while index < samples.count {
            let end = min(samples.count, index + chunk)
            let time = startTime + Double(index) / sampleRate
            for frame in pipeline.process(samples: Array(samples[index..<end]), startTime: time) { events += frame.events }
            index = end
        }
        return events
    }
}

// MARK: - MIDI parsing

final class InputMIDIParserTests: XCTestCase {
    func testNoteOnAndNoteOff() {
        var parser = InputMIDIParser()
        XCTAssertEqual(parser.parse([0x90, 60, 100, 0x80, 60, 64]), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .noteOff(channel: 0, note: 60, velocity: 64),
        ])
    }

    func testVelocityZeroNoteOnIsNoteOff() {
        var parser = InputMIDIParser()
        XCTAssertEqual(parser.parse([0x93, 72, 0]), [.noteOff(channel: 3, note: 72, velocity: 0)])
    }

    func testRunningStatusWithinOnePacket() {
        var parser = InputMIDIParser()
        // One status byte, then three note-ons' worth of data; the last has velocity 0 (= off).
        XCTAssertEqual(parser.parse([0x90, 60, 100, 64, 90, 60, 0]), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .noteOn(channel: 0, note: 64, velocity: 90),
            .noteOff(channel: 0, note: 60, velocity: 0),
        ])
    }

    func testRunningStatusAcrossPackets() {
        var parser = InputMIDIParser()
        XCTAssertEqual(parser.parse([0x91, 48]), [], "an incomplete message produces nothing yet")
        XCTAssertEqual(parser.parse([80, 52, 81]), [
            .noteOn(channel: 1, note: 48, velocity: 80),
            .noteOn(channel: 1, note: 52, velocity: 81),
        ])
    }

    func testMultiMessagePacketWithMixedTypes() {
        var parser = InputMIDIParser()
        let bytes: [UInt8] = [0x90, 60, 100,   // note on
                              0xB0, 64, 127,   // sustain pedal
                              0xC0, 5,         // program change (one data byte)
                              0x80, 60, 40,    // note off
                              0x9F, 108, 1]    // note on, channel 16, highest piano key
        XCTAssertEqual(parser.parse(bytes), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .other(status: 0xB0, data: [64, 127]),
            .other(status: 0xC0, data: [5]),
            .noteOff(channel: 0, note: 60, velocity: 40),
            .noteOn(channel: 15, note: 108, velocity: 1),
        ])
    }

    func testRealTimeBytesAreTransparent() {
        var parser = InputMIDIParser()
        // Timing clock and active sensing in the middle of a message must not break it or running status.
        XCTAssertEqual(parser.parse([0x90, 0xF8, 60, 0xFE, 100, 0xF8, 62, 70]), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .noteOn(channel: 0, note: 62, velocity: 70),
        ])
    }

    func testSystemExclusiveCancelsRunningStatus() {
        var parser = InputMIDIParser()
        let messages = parser.parse([0x90, 60, 100, 0xF0, 0x7E, 0x01, 0x02, 0xF7, 64, 100, 0x90, 65, 100])
        XCTAssertEqual(messages, [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .noteOn(channel: 0, note: 65, velocity: 100),
        ], "data bytes after SysEx have no running status and are dropped")
    }

    func testSystemCommonDataIsSkipped() {
        var parser = InputMIDIParser()
        // Song position pointer (2 data bytes) must not be mistaken for note data.
        XCTAssertEqual(parser.parse([0xF2, 0x10, 0x20, 0x90, 61, 50]), [.noteOn(channel: 0, note: 61, velocity: 50)])
    }

    func testStrayDataWithoutStatusIsIgnored() {
        var parser = InputMIDIParser()
        XCTAssertEqual(parser.parse([60, 100, 0x90, 60, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
    }

    func testAllNotesOffAndAllSoundOff() {
        var parser = InputMIDIParser()
        XCTAssertEqual(parser.parse([0xB2, 123, 0, 0xB5, 120, 0]), [.allNotesOff(channel: 2), .allNotesOff(channel: 5)])
    }

    func testResetForgetsRunningStatus() {
        var parser = InputMIDIParser()
        _ = parser.parse([0x90, 60, 100])
        parser.reset()
        XCTAssertEqual(parser.parse([62, 100]), [])
    }
}

final class InputMIDINoteMapperTests: XCTestCase {
    func testVelocityIsNormalisedAndTimeIsKept() {
        var mapper = InputMIDINoteMapper()
        let events = mapper.map(.noteOn(channel: 0, note: 60, velocity: 127), time: 12.5)
        XCTAssertEqual(events, [.on(60, velocity: 1, time: 12.5, source: .midi)])
        XCTAssertEqual(mapper.map(.noteOff(channel: 0, note: 60, velocity: 0), time: 13), [.off(60, time: 13, source: .midi)])
        XCTAssertTrue(mapper.heldNotes.isEmpty)
    }

    func testChannelAgnosticLayering() {
        var mapper = InputMIDINoteMapper()
        XCTAssertEqual(mapper.map(.noteOn(channel: 0, note: 64, velocity: 80), time: 1).count, 1)
        XCTAssertEqual(mapper.map(.noteOn(channel: 1, note: 64, velocity: 80), time: 1), [], "the same key on a second channel is not a new attack")
        XCTAssertEqual(mapper.map(.noteOff(channel: 0, note: 64, velocity: 0), time: 2), [], "still held on channel 2")
        XCTAssertEqual(mapper.map(.noteOff(channel: 1, note: 64, velocity: 0), time: 3), [.off(64, time: 3, source: .midi)])
    }

    func testRestrikeOnSameChannelIsANewAttack() {
        var mapper = InputMIDINoteMapper()
        _ = mapper.map(.noteOn(channel: 0, note: 67, velocity: 60), time: 1)
        XCTAssertEqual(mapper.map(.noteOn(channel: 0, note: 67, velocity: 90), time: 2).map(\.kind), [.on])
    }

    func testUnmatchedNoteOffIsDropped() {
        var mapper = InputMIDINoteMapper()
        XCTAssertEqual(mapper.map(.noteOff(channel: 0, note: 50, velocity: 0), time: 1), [])
    }

    func testAllNotesOffReleasesOnlyThatChannel() {
        var mapper = InputMIDINoteMapper()
        _ = mapper.map(.noteOn(channel: 0, note: 60, velocity: 64), time: 1)
        _ = mapper.map(.noteOn(channel: 0, note: 64, velocity: 64), time: 1)
        _ = mapper.map(.noteOn(channel: 9, note: 36, velocity: 64), time: 1)
        XCTAssertEqual(mapper.map(.allNotesOff(channel: 0), time: 4), [.off(60, time: 4, source: .midi), .off(64, time: 4, source: .midi)])
        XCTAssertEqual(mapper.heldNotes, [36])
    }

    func testOtherMessagesProduceNothing() {
        var mapper = InputMIDINoteMapper()
        XCTAssertEqual(mapper.map(.other(status: 0xB0, data: [64, 127]), time: 1), [])
    }

    func testReleaseAll() {
        var mapper = InputMIDINoteMapper()
        _ = mapper.map(.noteOn(channel: 0, note: 72, velocity: 64), time: 1)
        _ = mapper.map(.noteOn(channel: 3, note: 48, velocity: 64), time: 1)
        XCTAssertEqual(mapper.releaseAll(at: 9), [.off(48, time: 9, source: .midi), .off(72, time: 9, source: .midi)])
        XCTAssertTrue(mapper.heldNotes.isEmpty)
    }
}

final class InputMIDIUniversalPacketTests: XCTestCase {
    func testMIDI1ChannelVoiceWordsBecomeBytes() {
        // Type 2, group 0: note on ch 1, key 60, velocity 100; then program change 5 (one data byte).
        let words: [UInt32] = [0x2090_3C64, 0x20C0_0500]
        XCTAssertEqual(InputMIDIUniversalPacket.midi1Bytes(fromWords: words), [0x90, 60, 100, 0xC0, 5])
    }

    func testMIDI2NoteOnNeverBecomesNoteOff() {
        // Type 4 note on with a 16-bit velocity so small that the 7-bit value would be 0.
        let words: [UInt32] = [0x4090_3C00, 0x0001_0000, 0x4090_4000, 0xFFFF_0000]
        XCTAssertEqual(InputMIDIUniversalPacket.midi1Bytes(fromWords: words), [0x90, 60, 1, 0x90, 64, 127])
    }

    func testSystemAndUtilityMessagesAreSkipped() {
        // Utility (type 0), system real-time (type 1), then a MIDI 1.0 note off.
        let words: [UInt32] = [0x0000_0000, 0x10F8_0000, 0x2080_3C40]
        XCTAssertEqual(InputMIDIUniversalPacket.midi1Bytes(fromWords: words), [0x80, 60, 64])
    }

    func testTruncatedMessageIsIgnored() {
        XCTAssertEqual(InputMIDIUniversalPacket.midi1Bytes(fromWords: [UInt32(0x4090_3C00)]), [])
    }
}

final class InputMIDIReceiverTests: XCTestCase {
    func testKeyHeldOnTwoDevicesIsReleasedByTheLast() {
        let receiver = InputMIDIReceiver()
        receiver.register(token: 1)
        receiver.register(token: 2)
        XCTAssertEqual(receiver.handle(bytes: [0x90, 60, 100], time: 1, token: 1).map(\.kind), [.on])
        XCTAssertEqual(receiver.handle(bytes: [0x90, 60, 100], time: 1.1, token: 2).map(\.kind), [.on])
        XCTAssertEqual(receiver.handle(bytes: [0x80, 60, 0], time: 2, token: 1), [], "device 2 still holds the key")
        XCTAssertEqual(receiver.handle(bytes: [0x80, 60, 0], time: 3, token: 2), [.off(60, time: 3, source: .midi)])
    }

    func testRunningStatusIsPerDevice() {
        let receiver = InputMIDIReceiver()
        receiver.register(token: 1)
        receiver.register(token: 2)
        _ = receiver.handle(bytes: [0x90, 60, 100], time: 1, token: 1)
        XCTAssertEqual(receiver.handle(bytes: [62, 100], time: 2, token: 2), [], "device 2 has no running status")
        XCTAssertEqual(receiver.handle(bytes: [62, 100], time: 2, token: 1).map(\.midi), [62])
    }

    func testUnregisterReleasesHeldKeysAndDropsLatePackets() {
        let receiver = InputMIDIReceiver()
        receiver.register(token: 7)
        _ = receiver.handle(bytes: [0x90, 60, 100, 64, 100], time: 1, token: 7)
        XCTAssertEqual(receiver.unregister(token: 7, at: 5), [.off(60, time: 5, source: .midi), .off(64, time: 5, source: .midi)])
        XCTAssertEqual(receiver.handle(bytes: [0x90, 67, 100], time: 6, token: 7), [])
    }

    func testUMPWordsAreParsed() {
        let receiver = InputMIDIReceiver()
        receiver.register(token: 1)
        let events = receiver.handle(words: [UInt32(0x2090_4550)], time: 4, token: 1)
        XCTAssertEqual(events.map(\.midi), [69])
        XCTAssertEqual(events.first?.velocity ?? 0, 80.0 / 127, accuracy: 1e-9)
    }
}

// MARK: - Spectrum and pitch detection

final class InputSpectrumAnalyzerTests: XCTestCase {
    func testRejectsInvalidSizes() {
        XCTAssertNil(InputSpectrumAnalyzer(fftSize: 1000, sampleRate: 44_100))
        XCTAssertNil(InputSpectrumAnalyzer(fftSize: 4096, sampleRate: 0))
    }

    func testFullScaleSineOnABinCentreHasUnitMagnitude() {
        let analyzer = InputSpectrumAnalyzer(fftSize: 4096, sampleRate: 44_100)!
        let bin = 40
        let frequency = Double(bin) * analyzer.binWidth
        let samples = (0..<4096).map { Float(sin(2 * Double.pi * frequency * Double($0) / 44_100)) }
        var spectrum: [Float] = []
        XCTAssertTrue(analyzer.magnitudes(of: samples, into: &spectrum))
        XCTAssertEqual(spectrum.count, 2048)
        XCTAssertEqual(spectrum[bin], 1, accuracy: 0.02)
        XCTAssertEqual(spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] }), bin)
    }

    func testTooFewSamplesYieldsZeros() {
        let analyzer = InputSpectrumAnalyzer(fftSize: 4096, sampleRate: 44_100)!
        var spectrum: [Float] = []
        XCTAssertFalse(analyzer.magnitudes(of: [Float](repeating: 0.5, count: 100), into: &spectrum))
        XCTAssertEqual(spectrum.max(), 0)
    }

    func testRMS() {
        let samples: [Float] = [1, -1, 1, -1]
        XCTAssertEqual(samples.withUnsafeBufferPointer { InputSpectrumAnalyzer.rms($0) }, 1, accuracy: 1e-6)
    }
}

final class InputPitchDetectorTests: XCTestCase {
    typealias S = InputTestSignals

    func testA4WithHarmonics() {
        XCTAssertEqual(S.detectedMIDI(S.tone([440], seconds: 0.1)), [69])
    }

    func testPureSineIsDetected() {
        XCTAssertEqual(S.detectedMIDI(S.tone([S.hz(72)], harmonics: 1, seconds: 0.1)), [72])
    }

    func testCMajorTriad() {
        XCTAssertEqual(S.detectedMIDI(S.tone([S.hz(60), S.hz(64), S.hz(67)], amplitude: 0.15, seconds: 0.1)), [60, 64, 67])
    }

    func testFourNoteChord() {
        // C3 G3 E4 C5 (open voicing as a pianist plays it with both hands).
        let notes = [48, 55, 64, 72]
        XCTAssertEqual(S.detectedMIDI(S.tone(notes.map { S.hz($0) }, amplitude: 0.12, seconds: 0.1)), notes)
    }

    func testOctaveErrorSuppressionForWeakFundamental() {
        // A2 whose fundamental is 12 dB down, as a tablet microphone records bass notes: must stay A2, not A3.
        XCTAssertEqual(S.detectedMIDI(S.tone([S.hz(45)], fundamentalGain: 0.25, seconds: 0.1)), [45])
    }

    func testExtremesOfThePianoRange() {
        XCTAssertEqual(S.detectedMIDI(S.tone([S.hz(108)], harmonics: 2, seconds: 0.1)), [108], "C8")
        XCTAssertEqual(S.detectedMIDI(S.tone([S.hz(33)], seconds: 0.1)), [33], "A1")
    }

    func testA4Calibration() {
        // 415 Hz is G#4 at A4 = 440 but A4 when the piano is tuned to baroque pitch.
        let signal = S.tone([415], seconds: 0.1)
        XCTAssertEqual(S.detectedMIDI(signal), [68])
        var calibrated = InputPitchDetectorConfiguration()
        calibrated.a4Hertz = 415
        XCTAssertEqual(S.detectedMIDI(signal, configuration: calibrated), [69])
    }

    func testSensitivityThreshold() {
        // About −50 dBFS: heard at maximum sensitivity, ignored at minimum.
        let quiet = S.tone([S.hz(67)], amplitude: 0.003, seconds: 0.1)
        var sensitive = InputPitchDetectorConfiguration()
        sensitive.sensitivity = 1
        var deaf = InputPitchDetectorConfiguration()
        deaf.sensitivity = 0
        XCTAssertEqual(S.detectedMIDI(quiet, configuration: sensitive), [67])
        XCTAssertEqual(S.detectedMIDI(quiet, configuration: deaf), [])
    }

    func testStretchedPianoPartials() {
        // Real piano strings are stiff: upper partials run sharp (B ≈ 4e-4 around middle C).
        let chord = S.tone([S.hz(60), S.hz(64), S.hz(67)], amplitude: 0.15, inharmonicity: 4e-4, seconds: 0.1)
        XCTAssertEqual(S.detectedMIDI(chord), [60, 64, 67])
    }

    func testToneInBackgroundNoise() {
        let tone = S.tone([S.hz(62)], amplitude: 0.2, seconds: 0.1)
        let noise = S.noise(amplitude: 0.02, seconds: 0.1, seed: 9)
        XCTAssertEqual(S.detectedMIDI(zip(tone, noise).map { $0 + $1 }), [62])
    }

    func testWhiteNoiseHasNoDetections() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            XCTAssertEqual(S.detectedMIDI(S.noise(amplitude: 0.3, seconds: 0.1, seed: seed)), [], "seed \(seed)")
        }
    }

    func testSilenceHasNoDetections() {
        XCTAssertEqual(S.detectedMIDI(S.silence(seconds: 0.1)), [])
    }

    func testPolyphonyLimit() {
        var configuration = InputPitchDetectorConfiguration()
        configuration.maxPolyphony = 2
        let chord = S.tone([S.hz(60), S.hz(64), S.hz(67)], amplitude: 0.15, seconds: 0.1)
        XCTAssertEqual(S.detectedMIDI(chord, configuration: configuration).count, 2)
    }

    func testOpenTriadIsNotCollapsedIntoASubOctave() {
        // C3-G3-E4 are partials 2, 3 and 5 of C2; the chord must stay three notes, not a phantom C2.
        let chord = S.tone([48, 55, 64].map { S.hz($0) }, amplitude: 0.12, inharmonicity: 3e-4, seconds: 0.1)
        XCTAssertEqual(S.detectedMIDI(chord), [48, 55, 64])
    }

    func testSoundingNoteIsNeverDemotedToAPhantomSubOctave() {
        // Every frame of a sustained open triad, analysed with the tracker's sounding set, keeps C3 (not C2).
        let analyzer = InputSpectrumAnalyzer(fftSize: 4096, sampleRate: S.sampleRate)!
        let detector = InputPitchDetector(binWidth: analyzer.binWidth, binCount: analyzer.binCount)
        let signal = S.tone([48, 55, 64].map { S.hz($0) }, amplitude: 0.12, inharmonicity: 3e-4, seconds: 1.5)
        var spectrum: [Float] = []
        var start = 0
        while start + 4096 <= signal.count {
            analyzer.magnitudes(of: Array(signal[start..<(start + 4096)]), into: &spectrum)
            let found = Set(detector.detect(spectrum: spectrum, sounding: [48, 55, 64]).map(\.midi))
            XCTAssertFalse(found.contains(36), "phantom C2 at sample \(start)")
            XCTAssertTrue(found.isSuperset(of: [48, 55, 64]), "chord tone lost at sample \(start): \(found.sorted())")
            start += 1024
        }
    }

    func testCentsReportTuningDeviation() {
        let analyzer = InputSpectrumAnalyzer(fftSize: 4096, sampleRate: S.sampleRate)!
        var spectrum: [Float] = []
        // 20 cents sharp of A4.
        analyzer.magnitudes(of: S.tone([440 * pow(2, 20.0 / 1200)], seconds: 0.1), into: &spectrum)
        let detector = InputPitchDetector(binWidth: analyzer.binWidth, binCount: analyzer.binCount)
        let pitch = detector.detect(spectrum: spectrum).first
        XCTAssertEqual(pitch?.midi, 69)
        XCTAssertEqual(pitch?.cents ?? 0, 20, accuracy: 8)
    }
}

// MARK: - Note tracking (onsets, hysteresis, durations)

final class InputPitchPipelineTests: XCTestCase {
    typealias S = InputTestSignals

    func testSingleNoteProducesOneOnAndOneOff() {
        let signal = S.silence(seconds: 0.3) + S.tone([440], seconds: 0.8, decayPerSecond: 1.5) + S.silence(seconds: 0.5)
        let events = S.pipelineEvents(signal, startTime: 100)
        XCTAssertEqual(events.map(\.kind), [.on, .off])
        XCTAssertEqual(events.map(\.midi), [69, 69])
        XCTAssertTrue(events.allSatisfy { $0.source == .microphone })
        // The note-on is stamped near the attack (0.3 s into the signal), not at confirmation time.
        let onTime = events[0].time - 100
        XCTAssertEqual(onTime, 0.3, accuracy: 0.06)
        // The note-off comes after the tone ended (1.1 s) and within the release hysteresis.
        let offTime = events[1].time - 100
        XCTAssertGreaterThan(offTime, 1.1)
        XCTAssertLessThan(offTime, 1.1 + 0.3)
    }

    func testSustainedNoteIsNotRetriggered() {
        // Two seconds of a slowly decaying note with mild amplitude wobble must stay a single note-on.
        var signal = S.tone([S.hz(60)], seconds: 2, decayPerSecond: 0.8)
        for n in signal.indices { signal[n] *= Float(1 + 0.08 * sin(2 * Double.pi * 3 * Double(n) / S.sampleRate)) }
        let events = S.pipelineEvents(S.silence(seconds: 0.2) + signal)
        XCTAssertEqual(events.filter { $0.kind == .on }.map(\.midi), [60])
    }

    func testTriadOnsetEmitsAllThreeNotes() {
        let chord = S.tone([S.hz(60), S.hz(64), S.hz(67)], amplitude: 0.15, seconds: 0.7, decayPerSecond: 1.5)
        let events = S.pipelineEvents(S.silence(seconds: 0.25) + chord + S.silence(seconds: 0.4))
        XCTAssertEqual(Set(events.filter { $0.kind == .on }.map(\.midi)), [60, 64, 67])
        XCTAssertEqual(events.filter { $0.kind == .on }.count, 3)
        XCTAssertEqual(Set(events.filter { $0.kind == .off }.map(\.midi)), [60, 64, 67])
    }

    func testRepeatedNoteAfterSilenceIsTwoAttacks() {
        let note = S.tone([S.hz(64)], seconds: 0.4, decayPerSecond: 2)
        let signal = S.silence(seconds: 0.2) + note + S.silence(seconds: 0.35) + note + S.silence(seconds: 0.4)
        let ons = S.pipelineEvents(signal).filter { $0.kind == .on }
        XCTAssertEqual(ons.map(\.midi), [64, 64])
    }

    func testRestrikeWhileSoundingIsANewAttack() {
        // The key is struck again before the first note has died away (no silence in between): the hammer
        // damps the vibrating string and a fresh attack follows, which must be reported as a second note-on.
        for midi in [60, 69] {
            let first = S.tone([S.hz(midi)], amplitude: 0.3, inharmonicity: 3e-4, seconds: 1.5, decayPerSecond: 2.5)
            let second = S.tone([S.hz(midi)], amplitude: 0.3, inharmonicity: 3e-4, seconds: 1.0, decayPerSecond: 2.5)
            var signal = S.silence(seconds: 0.2) + first
            let restrike = Int(0.7 * S.sampleRate)
            for i in restrike..<signal.count { signal[i] *= Float(exp(-20 * Double(i - restrike) / S.sampleRate)) }
            for (j, value) in second.enumerated() where restrike + j < signal.count { signal[restrike + j] += value }
            let ons = S.pipelineEvents(signal + S.silence(seconds: 0.3), startTime: 0).filter { $0.kind == .on }
            XCTAssertEqual(ons.map(\.midi), [midi, midi], "MIDI \(midi)")
            if ons.count == 2 { XCTAssertEqual(ons[1].time, 0.7, accuracy: 0.08, "MIDI \(midi)") }
        }
    }

    func testMelodyOfDistinctNotes() {
        var signal = S.silence(seconds: 0.2)
        for midi in [60, 62, 64, 65, 67] {
            signal += S.tone([S.hz(midi)], seconds: 0.35, decayPerSecond: 2) + S.silence(seconds: 0.12)
        }
        let ons = S.pipelineEvents(signal + S.silence(seconds: 0.3)).filter { $0.kind == .on }
        XCTAssertEqual(ons.map(\.midi), [60, 62, 64, 65, 67])
    }

    func testHeldChordIsNotReleasedOrRetriggeredWhileItRings() {
        // A static C3-G3-E4 for 3 s: three note-ons at the attack, and every release after the chord ends.
        let chord = S.tone([48, 55, 64].map { S.hz($0) }, amplitude: 0.12, inharmonicity: 3e-4, seconds: 3)
        let events = S.pipelineEvents(S.silence(seconds: 0.2) + chord + S.silence(seconds: 0.4), startTime: 0)
        XCTAssertEqual(events.filter { $0.kind == .on }.map(\.midi).sorted(), [48, 55, 64])
        XCTAssertTrue(events.filter { $0.kind == .off }.allSatisfy { $0.time > 3.15 }, "\(events)")
    }

    func testHeldChordPlusLaterNoteYieldsExactlyThatNoteOn() {
        // Five-note chords exceed the polyphony limit, so one tone is masked and resurfaces as the others decay;
        // neither it nor any other chord tone may fire when the unrelated note opens an onset window.
        for (chord, newNote) in [([48, 55, 60, 64, 67], 72), ([43, 50, 59, 62, 67], 76)] {
            var signal = S.silence(seconds: 0.2) + S.tone(chord.map { S.hz($0) }, amplitude: 0.1, seconds: 3, decayPerSecond: 0.7)
            S.mix(S.tone([S.hz(newNote)], amplitude: 0.15, seconds: 1, decayPerSecond: 1), into: &signal, at: 1.8)
            let ons = S.pipelineEvents(signal + S.silence(seconds: 0.3), startTime: 0).filter { $0.kind == .on }
            let late = ons.filter { $0.time > 1 }
            XCTAssertEqual(late.map(\.midi), [newNote], "chord \(chord)")
            if let on = late.first { XCTAssertEqual(on.time, 1.8, accuracy: 0.08) }
        }
    }

    func testMelodyOverHeldChordYieldsExactlyTheMelodyNoteOns() {
        // The melody shares partials with the held chord (G4 is the 12th of C3, C5 the double octave of C3…):
        // only the melody's attacks may be reported, and no chord tone may be released before the chord ends.
        let times = [0.9, 1.5, 2.1]
        let cases: [([Int], [Int])] = [([48, 55, 64], [67, 69, 71]), ([48, 55, 64], [72, 74, 76]), ([43, 50, 59], [72, 74, 76]),
                                       ([41, 48, 57], [84, 83, 81]), ([38, 45, 53], [76, 79, 77]), ([45, 52, 60], [67, 69, 71])]
        for (chord, melody) in cases {
            let events = S.pipelineEvents(S.melodyOverHeldChord(chord, melody: melody, melodyTimes: times), startTime: 0)
            let ons = events.filter { $0.kind == .on }
            XCTAssertEqual(ons.filter { $0.time < 0.5 }.map(\.midi).sorted(), chord.sorted(), "\(chord) + \(melody)")
            XCTAssertEqual(ons.filter { $0.time >= 0.5 }.map(\.midi), melody, "\(chord) + \(melody)")
            for (on, time) in zip(ons.filter { $0.time >= 0.5 }, times) {
                XCTAssertEqual(on.time, time, accuracy: 0.08, "\(chord) + \(melody)")
            }
            let earlyOffs = events.filter { $0.kind == .off && chord.contains($0.midi) && $0.time < 3.15 }
            XCTAssertEqual(earlyOffs, [], "\(chord) + \(melody)")
        }
    }

    func testNoiseProducesNoEvents() {
        let signal = S.noise(amplitude: 0.2, seconds: 1.5, seed: 42)
        XCTAssertEqual(S.pipelineEvents(signal), [])
    }

    func testFlushReleasesSoundingNotes() {
        let pipeline = InputPitchPipeline(sampleRate: S.sampleRate)!
        let signal = S.silence(seconds: 0.2) + S.tone([440], seconds: 0.5)
        var ons: [NoteInputEvent] = []
        for frame in pipeline.process(samples: signal, startTime: 0) { ons += frame.events }
        XCTAssertEqual(ons.map(\.midi), [69])
        XCTAssertEqual(pipeline.activeNotes, [69])
        XCTAssertEqual(pipeline.flush(at: 9), [.off(69, time: 9, source: .microphone)])
        XCTAssertTrue(pipeline.activeNotes.isEmpty)
    }

    func testFrameTimesFollowTheSampleClock() {
        let pipeline = InputPitchPipeline(sampleRate: S.sampleRate)!
        let frames = pipeline.process(samples: S.silence(seconds: 0.2), startTime: 50)
        XCTAssertEqual(frames.count, (Int(0.2 * S.sampleRate) - 4096) / 1024 + 1)
        XCTAssertEqual(frames.first?.time ?? 0, 50 + 4096 / S.sampleRate, accuracy: 1e-9)
        if frames.count > 1 {
            XCTAssertEqual(frames[1].time - frames[0].time, 1024 / S.sampleRate, accuracy: 1e-9)
        }
    }

    func testFrameTimesReanchorAfterAGap() {
        let pipeline = InputPitchPipeline(sampleRate: S.sampleRate)!
        let chunk = 2048
        let chunkSeconds = Double(chunk) / S.sampleRate
        var time = 0.0
        for _ in 0..<20 {
            _ = pipeline.process(samples: S.silence(seconds: chunkSeconds), startTime: time)
            time += chunkSeconds
        }
        // A 0.5 s dropout: the stale samples are discarded and the clock restarts at the new chunk.
        time += 0.5
        let resumed = time
        var frames: [InputPitchPipeline.FrameResult] = []
        for _ in 0..<4 {
            frames += pipeline.process(samples: [Float](repeating: 0, count: chunk), startTime: time)
            time += chunkSeconds
        }
        XCTAssertEqual(frames.first?.time ?? 0, resumed + 4096 / S.sampleRate, accuracy: 1e-6)
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertEqual(b.time - a.time, 1024 / S.sampleRate, accuracy: 1e-9) }
        XCTAssertTrue(frames.allSatisfy { $0.events.isEmpty })
    }

    func testFrameTimesFollowHostClockDrift() {
        // The caller's clock runs 3 ms per chunk ahead of the sample clock (clock drift, exaggerated).
        let pipeline = InputPitchPipeline(sampleRate: S.sampleRate)!
        let chunk = 2048
        let chunkSeconds = Double(chunk) / S.sampleRate
        let drift = 0.003
        /// Host time of global sample index `i` (the start of sample i).
        func hostTime(ofSample i: Int) -> Double {
            let c = max(0, i - 1) / chunk
            return Double(c) * (chunkSeconds + drift) + Double(i - c * chunk) / S.sampleRate
        }
        var frames: [InputPitchPipeline.FrameResult] = []
        for c in 0..<40 {
            frames += pipeline.process(samples: [Float](repeating: 0, count: chunk), startTime: Double(c) * (chunkSeconds + drift))
        }
        XCTAssertGreaterThan(frames.count, 70)
        for (j, frame) in frames.enumerated() {
            XCTAssertEqual(frame.time, hostTime(ofSample: 4096 + j * 1024), accuracy: 0.0025, "frame \(j)")
        }
    }

    func testTimestampJitterDoesNotMoveFrameTimes() {
        let pipeline = InputPitchPipeline(sampleRate: S.sampleRate)!
        let chunkSeconds = 2048 / S.sampleRate
        var frames: [InputPitchPipeline.FrameResult] = []
        for c in 0..<20 {
            // ±0.8 ms: a 1.6 ms swing, inside `InputPitchPipeline.reanchorTolerance`.
            let jitter = c % 2 == 0 ? 0.0008 : -0.0008
            frames += pipeline.process(samples: [Float](repeating: 0, count: 2048), startTime: 10 + Double(c) * chunkSeconds + jitter)
        }
        XCTAssertEqual(frames.first?.time ?? 0, 10.0008 + 4096 / S.sampleRate, accuracy: 1e-9)
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertEqual(b.time - a.time, 1024 / S.sampleRate, accuracy: 1e-9) }
    }

    func testInvalidConfigurationsFail() {
        XCTAssertNil(InputPitchPipeline(sampleRate: S.sampleRate, fftSize: 3000))
        XCTAssertNil(InputPitchPipeline(sampleRate: S.sampleRate, fftSize: 4096, hop: 0))
    }
}

final class InputMicrophoneProcessorTests: XCTestCase {
    func testFrameSizesFollowTheHardwareRate() {
        XCTAssertEqual(InputMicrophoneProcessor.frameSizes(forSampleRate: 44_100).fftSize, 4096)
        XCTAssertEqual(InputMicrophoneProcessor.frameSizes(forSampleRate: 48_000).hop, 1024)
        XCTAssertEqual(InputMicrophoneProcessor.frameSizes(forSampleRate: 96_000).fftSize, 8192)
    }

    func testMeterLevel() {
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 0).level, 0)
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 0).decibels, -120)
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 1).level, 1, accuracy: 1e-9)
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 0.001).level, 0, accuracy: 1e-6)
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 0.1).decibels, -20, accuracy: 1e-6)
        XCTAssertEqual(InputMicrophoneProcessor.meterLevel(rms: 0.1).level, 40.0 / 60, accuracy: 1e-6)
    }

    func testVelocityFromAmplitude() {
        XCTAssertEqual(InputNoteTracker.velocity(forAmplitude: 0), 0.2)
        XCTAssertEqual(InputNoteTracker.velocity(forAmplitude: 1), 1)
        XCTAssertLessThan(InputNoteTracker.velocity(forAmplitude: 0.01), InputNoteTracker.velocity(forAmplitude: 0.1))
    }
}

// MARK: - Note tracker on synthetic frames

final class InputNoteTrackerTests: XCTestCase {
    /// Hz per bin of the default tracker configuration (44.1 kHz, 4096-point FFT).
    let binWidth = 44_100.0 / 4096
    let noiseFloor: Float = 0.001

    /// A flat spectrum (no flux between identical frames) with `raised` bins set to `level`.
    func spectrum(raised: ClosedRange<Int>? = nil, level: Float = 0.5) -> [Float] {
        var bins = [Float](repeating: 0.01, count: 2048)
        if let raised { for i in raised { bins[i] = level } }
        return bins
    }

    func pitch(_ midi: Int, salience: Float = 0.1, own: Float? = nil, strong: Bool = true) -> InputDetectedPitch {
        InputDetectedPitch(midi: midi, frequency: MusicHelpers.frequency(midi: Double(midi), a4: 440), cents: 0,
                           salience: salience, ownSalience: own ?? salience, amplitude: salience, isStrong: strong)
    }

    /// Bins around the fundamental of `midi` (the bin nearest to it and one either side).
    func bins(of midi: Int) -> ClosedRange<Int> {
        let center = Int((MusicHelpers.frequency(midi: Double(midi), a4: 440) / binWidth).rounded())
        return (center - 1)...(center + 1)
    }

    func testStrongDetectionWithoutOnsetNeverStartsANote() {
        let tracker = InputNoteTracker()
        var events: [NoteInputEvent] = []
        for frame in 0..<30 {
            events += tracker.process(spectrum: spectrum(), noiseFloor: noiseFloor, pitches: [pitch(60)], time: Double(frame) * 0.023)
        }
        XCTAssertEqual(events, [])
    }

    func testStaleCandidateDoesNotFireOnAnUnrelatedOnset() {
        // 60 has been detected (but never confirmed: no onset) for 20 frames; then 72 is struck.
        let tracker = InputNoteTracker()
        var events: [NoteInputEvent] = []
        var time = 0.0
        for _ in 0..<20 {
            events += tracker.process(spectrum: spectrum(), noiseFloor: noiseFloor, pitches: [pitch(60)], time: time)
            time += 0.023
        }
        for _ in 0..<6 {
            events += tracker.process(spectrum: spectrum(raised: bins(of: 72)), noiseFloor: noiseFloor,
                                      pitches: [pitch(60), pitch(72, salience: 0.2)], time: time)
            time += 0.023
        }
        XCTAssertEqual(events.map(\.kind), [.on])
        XCTAssertEqual(events.map(\.midi), [72])
    }

    func testMaskedNoteWhoseSpectrumDidNotRiseIsNotAnAttack() {
        // 55 only becomes detectable after the onset (it was masked) but its partials did not gain energy.
        let tracker = InputNoteTracker()
        var events: [NoteInputEvent] = []
        var time = 0.0
        for _ in 0..<10 {
            events += tracker.process(spectrum: spectrum(), noiseFloor: noiseFloor, pitches: [], time: time)
            time += 0.023
        }
        events += tracker.process(spectrum: spectrum(raised: bins(of: 72)), noiseFloor: noiseFloor, pitches: [pitch(72)], time: time)
        time += 0.023
        for _ in 0..<6 {
            events += tracker.process(spectrum: spectrum(raised: bins(of: 72)), noiseFloor: noiseFloor,
                                      pitches: [pitch(72), pitch(55)], time: time)
            time += 0.023
        }
        XCTAssertEqual(events.map(\.midi), [72])
        XCTAssertNil(tracker.activeNotes[55])
    }

    /// Strikes 64 at frame 2, keeps it for 9 frames, drops it for 4 (a mistaken release), then returns it.
    func runMistakenRelease(reattack: Bool) -> (events: [NoteInputEvent], tracker: InputNoteTracker) {
        let tracker = InputNoteTracker()
        var events: [NoteInputEvent] = []
        var time = 0.0
        func frame(_ spectrum: [Float], _ pitches: [InputDetectedPitch]) {
            events += tracker.process(spectrum: spectrum, noiseFloor: noiseFloor, pitches: pitches, time: time)
            time += 0.023
        }
        frame(spectrum(), [])
        for _ in 0..<9 { frame(spectrum(raised: bins(of: 64)), [pitch(64)]) }
        for _ in 0..<4 { frame(spectrum(raised: bins(of: 64)), []) }
        if reattack {
            // A fresh hammer blow: the spectrum jumps again and the note's own salience triples.
            for _ in 0..<5 { frame(spectrum(raised: bins(of: 64), level: 5), [pitch(64, salience: 0.3)]) }
        } else {
            for _ in 0..<5 { frame(spectrum(raised: bins(of: 64)), [pitch(64)]) }
        }
        return (events, tracker)
    }

    func testMistakenReleaseResumesWithoutANewNoteOn() {
        let (events, tracker) = runMistakenRelease(reattack: false)
        XCTAssertEqual(events.map(\.kind), [.on, .off])
        XCTAssertEqual(Array(tracker.activeNotes.keys), [64], "the key is sounding again, silently")
    }

    func testReattackAfterReleaseIsANewNoteOn() {
        let (events, _) = runMistakenRelease(reattack: true)
        XCTAssertEqual(events.map(\.kind), [.on, .off, .on])
        XCTAssertEqual(Set(events.map(\.midi)), [64])
    }

    func testFallingEnergyIsNotAnOnset() {
        // Broadband splatter while the total energy drops (a note being cut off) must not open an onset window.
        let tracker = InputNoteTracker()
        var loud = spectrum()
        for i in 100..<110 { loud[i] = 1 }
        var splatter = [Float](repeating: 0.02, count: 2048)
        for i in 100..<110 { splatter[i] = 0.2 }
        var events: [NoteInputEvent] = []
        var time = 0.0
        for _ in 0..<5 {
            events += tracker.process(spectrum: loud, noiseFloor: noiseFloor, pitches: [], time: time)
            time += 0.023
        }
        for _ in 0..<5 {
            events += tracker.process(spectrum: splatter, noiseFloor: noiseFloor, pitches: [pitch(67)], time: time)
            time += 0.023
        }
        XCTAssertNil(tracker.lastOnsetTime)
        XCTAssertEqual(events, [])
    }

    func testSharedLowPartials() {
        XCTAssertTrue(InputNoteTracker.sharesLowPartials(48, 60), "octave")
        XCTAssertTrue(InputNoteTracker.sharesLowPartials(48, 67), "twelfth")
        XCTAssertTrue(InputNoteTracker.sharesLowPartials(48, 55), "fifth")
        XCTAssertTrue(InputNoteTracker.sharesLowPartials(60, 64), "major third")
        XCTAssertFalse(InputNoteTracker.sharesLowPartials(60, 61), "semitone")
        XCTAssertFalse(InputNoteTracker.sharesLowPartials(60, 62), "whole tone")
    }
}

// MARK: - Held-note bookkeeping

final class InputHeldNoteTrackerTests: XCTestCase {
    func testOnAndOff() {
        var tracker = InputHeldNoteTracker()
        XCTAssertNotNil(tracker.apply(.on(60, time: 1, source: .midi)))
        XCTAssertEqual(tracker.heldNotes, [60])
        XCTAssertEqual(tracker.holdDuration(of: 60, at: 1.5) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertNotNil(tracker.apply(.off(60, time: 2, source: .midi)))
        XCTAssertTrue(tracker.heldNotes.isEmpty)
        XCTAssertNil(tracker.holdDuration(of: 60, at: 3))
    }

    func testKeyHeldByTwoSourcesIsForwardedOnce() {
        var tracker = InputHeldNoteTracker()
        XCTAssertNotNil(tracker.apply(.on(64, time: 1, source: .midi)))
        XCTAssertNil(tracker.apply(.on(64, time: 1.02, source: .microphone)), "the microphone hearing the MIDI piano is a duplicate")
        XCTAssertNil(tracker.apply(.off(64, time: 2, source: .midi)), "still held by the microphone")
        XCTAssertTrue(tracker.isHeld(64))
        XCTAssertEqual(tracker.apply(.off(64, time: 2.1, source: .microphone)), .off(64, time: 2.1, source: .microphone))
        XCTAssertFalse(tracker.isHeld(64))
    }

    func testReattackFromTheSameSourceRefreshesOnTime() {
        var tracker = InputHeldNoteTracker()
        _ = tracker.apply(.on(67, time: 1, source: .microphone))
        XCTAssertNotNil(tracker.apply(.on(67, time: 3, source: .microphone)))
        XCTAssertEqual(tracker.onTimes[67], 3)
    }

    func testStrayOffIsDropped() {
        var tracker = InputHeldNoteTracker()
        XCTAssertNil(tracker.apply(.off(70, time: 1, source: .midi)))
        _ = tracker.apply(.on(70, time: 1, source: .midi))
        XCTAssertNil(tracker.apply(.off(70, time: 2, source: .virtualKeyboard)), "a source that does not hold the key cannot release it")
        XCTAssertTrue(tracker.isHeld(70))
    }

    func testReleaseAllFromOneSource() {
        var tracker = InputHeldNoteTracker()
        _ = tracker.apply(.on(60, time: 1, source: .midi))
        _ = tracker.apply(.on(62, time: 1, source: .microphone))
        _ = tracker.apply(.on(64, time: 1, source: .midi))
        XCTAssertEqual(tracker.releaseAll(from: .midi, at: 5).map(\.midi), [60, 64])
        XCTAssertEqual(tracker.heldNotes, [62])
    }

    func testReleaseEverything() {
        var tracker = InputHeldNoteTracker()
        _ = tracker.apply(.on(48, time: 1, source: .midi))
        _ = tracker.apply(.on(48, time: 1, source: .microphone))
        _ = tracker.apply(.on(50, time: 1, source: .virtualKeyboard))
        let released = tracker.releaseAll(at: 4)
        XCTAssertEqual(released.map(\.midi), [48, 50], "one note-off per key, not per source")
        XCTAssertTrue(released.allSatisfy { $0.kind == .off && $0.time == 4 })
        XCTAssertTrue(tracker.heldNotes.isEmpty)
    }
}

final class InputHubRouterTests: XCTestCase {
    func testDropsEverythingUntilRunning() {
        let router = InputHubRouter(selection: .midi)
        XCTAssertTrue(router.receive(.on(60, time: 1, source: .midi)).events.isEmpty)
        router.isRunning = true
        XCTAssertEqual(router.receive(.on(60, time: 2, source: .midi)).events.map(\.midi), [60])
    }

    func testFiltersBySelection() {
        let router = InputHubRouter(selection: .midi)
        router.isRunning = true
        XCTAssertTrue(router.receive(.on(60, time: 1, source: .microphone)).events.isEmpty)
        XCTAssertEqual(router.receive(.on(61, time: 1, source: .virtualKeyboard)).events.count, 1, "the on-screen keyboard is always accepted")
        XCTAssertTrue(router.receive(.on(200, time: 1, source: .midi)).events.isEmpty, "out-of-range MIDI numbers are dropped")
    }

    func testSnapshotTracksHeldNotesWithOnTimes() {
        let router = InputHubRouter(selection: .both)
        router.isRunning = true
        _ = router.receive(.on(60, time: 1, source: .midi))
        let routed = router.receive(.on(67, time: 1.5, source: .microphone))
        XCTAssertEqual(routed.snapshot.heldOnTimes, [60: 1, 67: 1.5])
        let released = router.receive(.off(60, time: 2, source: .midi))
        XCTAssertEqual(released.snapshot.heldOnTimes, [67: 1.5])
        XCTAssertGreaterThan(released.snapshot.sequence, routed.snapshot.sequence)
    }

    func testChangingSelectionReleasesDeselectedKinds() {
        let router = InputHubRouter(selection: .both)
        router.isRunning = true
        _ = router.receive(.on(60, time: 1, source: .midi))
        _ = router.receive(.on(64, time: 1, source: .microphone))
        let routed = router.setEnabledKinds(InputHubSelection.midi.enabledKinds, at: 3)
        XCTAssertEqual(routed.events, [.off(64, time: 3, source: .microphone)])
        XCTAssertEqual(Set(router.heldOnTimes.keys), [60])
    }

    func testFansOutToHandlersAndStreams() async {
        let router = InputHubRouter(selection: .midi)
        router.isRunning = true
        let received = InputLockedValue<[NoteInputEvent]>([])
        let primary = InputLockedValue<[NoteInputEvent]>([])
        router.onEvent = { event in primary.withValue { $0.append(event) } }
        let id = router.addHandler { event in received.withValue { $0.append(event) } }
        let (stream, continuation) = AsyncStream.makeStream(of: NoteInputEvent.self)
        let streamID = router.addContinuation(continuation)

        _ = router.receive(.on(60, time: 1, source: .midi))
        _ = router.receive(.off(60, time: 2, source: .midi))
        router.removeHandler(id)
        _ = router.receive(.on(62, time: 3, source: .midi))
        router.removeContinuation(streamID)

        XCTAssertEqual(primary.value.map(\.midi), [60, 60, 62])
        XCTAssertEqual(received.value.map(\.kind), [.on, .off], "removed handlers receive nothing more")
        var streamed: [NoteInputEvent] = []
        for await event in stream { streamed.append(event) }
        XCTAssertEqual(streamed.map(\.midi), [60, 60, 62])
    }

    func testMicrophoneEchoOfAReleasedMIDIKeyIsDropped() {
        // A staccato key: MIDI on 1.0, MIDI off 1.1; the microphone's note-on (stamped 1.02) arrives after the off.
        let router = InputHubRouter(selection: .both)
        router.isRunning = true
        XCTAssertEqual(router.receive(.on(60, time: 1.0, source: .midi)).events.count, 1)
        XCTAssertEqual(router.receive(.off(60, time: 1.1, source: .midi)).events.count, 1)
        XCTAssertTrue(router.receive(.on(60, time: 1.02, source: .microphone)).events.isEmpty)
        XCTAssertTrue(router.receive(.off(60, time: 1.4, source: .microphone)).events.isEmpty, "its off is swallowed too")
        XCTAssertTrue(router.heldOnTimes.isEmpty)
    }

    func testMicrophoneEchoWhileTheMIDIKeyIsHeld() {
        let router = InputHubRouter(selection: .both)
        router.isRunning = true
        _ = router.receive(.on(62, time: 1, source: .midi))
        XCTAssertTrue(router.receive(.on(62, time: 1.8, source: .microphone)).events.isEmpty, "a pedal-sustained re-detection")
        XCTAssertTrue(router.receive(.on(74, time: 1.08, source: .microphone)).events.isEmpty, "its octave ghost")
        XCTAssertEqual(router.receive(.off(62, time: 2, source: .midi)).events, [.off(62, time: 2, source: .midi)],
                       "the MIDI release is forwarded at once")
        XCTAssertTrue(router.receive(.off(62, time: 2.2, source: .microphone)).events.isEmpty)
    }

    func testMicrophoneNoteFarFromMIDIIsForwarded() {
        let router = InputHubRouter(selection: .both)
        router.isRunning = true
        _ = router.receive(.on(60, time: 1, source: .midi))
        _ = router.receive(.off(60, time: 1.1, source: .midi))
        XCTAssertEqual(router.receive(.on(60, time: 2, source: .microphone)).events.map(\.midi), [60])
        XCTAssertEqual(router.receive(.on(61, time: 1.05, source: .microphone)).events.map(\.midi), [61], "a different key")
        XCTAssertEqual(router.receive(.off(60, time: 2.5, source: .microphone)).events.map(\.kind), [.off])
    }

    func testMIDIEchoRuleNeedsMIDIEnabled() {
        let router = InputHubRouter(selection: .microphone)
        router.isRunning = true
        _ = router.receive(.on(60, time: 1, source: .midi))
        XCTAssertEqual(router.receive(.on(60, time: 1.02, source: .microphone)).events.count, 1)
    }

    func testAppSoundingSuppressesMicrophoneEchoes() {
        let router = InputHubRouter(selection: .microphone)
        router.isRunning = true
        router.noteAppSounding(pitches: [48, 52], from: 10, until: 10.5)
        XCTAssertTrue(router.receive(.on(48, time: 10.2, source: .microphone)).events.isEmpty, "the pitch itself")
        XCTAssertTrue(router.receive(.off(48, time: 10.4, source: .microphone)).events.isEmpty, "and its release")
        XCTAssertTrue(router.receive(.on(60, time: 10.6, source: .microphone)).events.isEmpty, "the octave, within the tail")
        XCTAssertTrue(router.receive(.on(67, time: 10.1, source: .microphone)).events.isEmpty, "the twelfth")
        XCTAssertEqual(router.receive(.on(62, time: 10.3, source: .microphone)).events.map(\.midi), [62], "not a partial")
        XCTAssertEqual(router.receive(.on(52, time: 10.8, source: .microphone)).events.map(\.midi), [52], "after the tail")
        XCTAssertEqual(router.receive(.on(48, time: 10.2, source: .virtualKeyboard)).events.map(\.midi), [48],
                       "other sources are never gated")
    }

    func testClearAppSounding() {
        let router = InputHubRouter(selection: .microphone)
        router.isRunning = true
        router.noteAppSounding(pitches: [70], from: 5, until: 6)
        router.clearAppSounding()
        XCTAssertEqual(router.receive(.on(70, time: 5.5, source: .microphone)).events.count, 1)
    }

    func testSelectionMapping() {
        XCTAssertEqual(InputHubSelection(preferred: .midi), .midi)
        XCTAssertEqual(InputHubSelection(preferred: .microphone), .microphone)
        XCTAssertEqual(InputHubSelection(preferred: .virtualKeyboard), .onScreenOnly)
        XCTAssertEqual(InputHubSelection.both.enabledKinds, [.midi, .microphone, .virtualKeyboard])
        XCTAssertEqual(InputHubSelection.both.preferredKind, .midi)
    }
}

final class InputVirtualKeyboardSourceTests: XCTestCase {
    func testDeliversOnlyWhileRunningAndReleasesOnStop() {
        let source = InputVirtualKeyboardSource()
        let delivered = InputLockedValue<[NoteInputEvent]>([])
        source.onEvent = { event in delivered.withValue { $0.append(event) } }
        source.press(60, at: 1)
        XCTAssertTrue(delivered.value.isEmpty)
        source.start()
        XCTAssertEqual(source.state, .running)
        source.press(60, at: 2)
        source.press(64, at: 2)
        source.release(60, at: 3)
        XCTAssertEqual(source.pressedKeys, [64])
        source.stop()
        XCTAssertEqual(source.state, .idle)
        XCTAssertEqual(delivered.value.map(\.kind), [.on, .on, .off, .off])
        XCTAssertEqual(delivered.value.last?.midi, 64)
        XCTAssertTrue(delivered.value.allSatisfy { $0.source == .virtualKeyboard })
    }

    func testRelabelsForwardedEvents() {
        let source = InputVirtualKeyboardSource()
        let delivered = InputLockedValue<[NoteInputEvent]>([])
        source.onEvent = { event in delivered.withValue { $0.append(event) } }
        source.start()
        source.send(.on(72, time: 5, source: .midi))
        XCTAssertEqual(delivered.value, [.on(72, time: 5, source: .virtualKeyboard)])
    }
}

// MARK: - InputHub (main actor; app target only)

@MainActor
final class InputHubTests: XCTestCase {
    func testOnScreenKeyboardInjectionUpdatesHeldNotes() {
        let hub = InputHub(selection: .onScreenOnly)
        var mainActorEvents: [NoteInputEvent] = []
        let subscription = hub.addMainActorHandler { mainActorEvents.append($0) }
        hub.start()
        XCTAssertTrue(hub.isRunning)

        hub.inject(.on(60, velocity: 0.9, time: 10, source: .virtualKeyboard))
        hub.inject(.on(64, time: 10.2, source: .virtualKeyboard))
        XCTAssertEqual(hub.heldNotes, [60, 64])
        XCTAssertEqual(hub.heldNoteOnTimes[60], 10)
        XCTAssertEqual(hub.lastNoteOn?.midi, 64)

        hub.inject(.off(60, time: 11, source: .virtualKeyboard))
        XCTAssertEqual(hub.heldNotes, [64])
        XCTAssertEqual(mainActorEvents.map(\.kind), [.on, .on, .off])
        XCTAssertEqual(hub.recentEvents.count, 3)

        hub.stop()
        XCTAssertFalse(hub.isRunning)
        XCTAssertTrue(hub.heldNotes.isEmpty, "stopping releases every held key")
        XCTAssertEqual(mainActorEvents.last?.kind, .off)
        XCTAssertEqual(mainActorEvents.last?.midi, 64)
        subscription.cancel()
    }

    func testDeselectedHardwareIsFilteredAndReleased() {
        let hub = InputHub(selection: .both)
        hub.start()
        hub.inject(.on(60, time: 1, source: .midi))
        hub.inject(.on(67, time: 1, source: .microphone))
        XCTAssertEqual(hub.heldNotes, [60, 67])
        hub.select(.midi)
        XCTAssertEqual(hub.heldNotes, [60], "the microphone's keys are released when it is deselected")
        hub.inject(.on(69, time: 2, source: .microphone))
        XCTAssertEqual(hub.heldNotes, [60])
        XCTAssertEqual(hub.selection, .midi)
        XCTAssertEqual(hub.kind, .midi)
        hub.stop()
    }

    func testDuplicateKeyFromTwoSourcesIsDeliveredOnce() {
        let hub = InputHub(selection: .both)
        var events: [NoteInputEvent] = []
        let subscription = hub.addMainActorHandler { events.append($0) }
        hub.start()
        hub.inject(.on(62, time: 1, source: .midi))
        hub.inject(.on(62, time: 1.01, source: .microphone))
        hub.inject(.off(62, time: 2, source: .midi))
        XCTAssertTrue(hub.heldNotes.isEmpty, "the microphone echo never held the key")
        hub.inject(.off(62, time: 2.05, source: .microphone))
        XCTAssertTrue(hub.heldNotes.isEmpty)
        XCTAssertEqual(events.map(\.kind), [.on, .off])
        subscription.cancel()
        hub.stop()
    }

    func testAsyncStreamDeliversInjectedEvents() async {
        let hub = InputHub(selection: .onScreenOnly)
        let stream = hub.events()
        hub.start()
        hub.virtualKeyboard.press(71, at: 3)
        hub.virtualKeyboard.release(71, at: 4)
        var received: [NoteInputEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        XCTAssertEqual(received.map(\.kind), [.on, .off])
        XCTAssertEqual(received.map(\.midi), [71, 71])
        hub.stop()
    }

    func testCallbackAPIReceivesEventsOnTheSourceThread() {
        let hub = InputHub(selection: .onScreenOnly)
        let received = InputLockedValue<[Int]>([])
        let subscription = hub.addHandler { event in received.withValue { $0.append(event.midi) } }
        hub.start()
        hub.virtualKeyboard.press(50, at: 1)
        XCTAssertEqual(received.value, [50])
        subscription.cancel()
        hub.virtualKeyboard.press(52, at: 2)
        XCTAssertEqual(received.value, [50], "a cancelled subscription receives nothing")
        hub.stop()
    }

    func testAppPlaybackIsNotReportedAsTheLearnersNotes() {
        let hub = InputHub(selection: .microphone)
        var events: [NoteInputEvent] = []
        let subscription = hub.addMainActorHandler { events.append($0) }
        hub.start()
        hub.noteAppSounding(ImmediateChord(pitches: [43, 47], durationSeconds: 1), at: 20)
        hub.inject(.on(43, time: 20.1, source: .microphone))
        hub.inject(.on(55, time: 20.1, source: .microphone))
        hub.inject(.on(64, time: 20.2, source: .microphone))
        XCTAssertEqual(events.map(\.midi), [64], "43 is the app's note and 55 its octave; 64 is the learner's")
        subscription.cancel()
        hub.stop()
    }

    func testCoreProtocolConformance() {
        let hub = InputHub(selection: .onScreenOnly)
        let source: any NoteInputSource = hub
        var delivered: [NoteInputEvent] = []
        source.onEvent = { delivered.append($0) }
        source.start()
        XCTAssertEqual(source.state, .running)
        hub.inject(.on(60, time: 1, source: .virtualKeyboard))
        XCTAssertEqual(delivered.map(\.midi), [60])
        source.stop()
        XCTAssertEqual(source.state, .idle)
    }
}
