import Foundation

/// Complete microphone analysis chain without any audio I/O: sample accumulation → hop-wise FFT →
/// polyphonic pitch detection → note tracking. `InputMicrophoneSource` feeds it from the engine tap;
/// tests feed it synthetic signals.
///
/// Not thread-safe; drive it from one serial queue.
final class InputPitchPipeline {
    /// Everything produced by one hop.
    struct FrameResult: Sendable {
        /// Time in seconds of the frame's last sample.
        var time: TimeInterval
        /// Note events emitted by the tracker for this frame.
        var events: [NoteInputEvent]
        /// Fundamentals detected in this frame, strongest first.
        var pitches: [InputDetectedPitch]
        /// RMS level of the frame (0…1).
        var rms: Float
        /// Spectral flux of the frame.
        var flux: Float
    }

    /// Sample rate the pipeline was built for.
    let sampleRate: Double
    /// Samples per analysis frame.
    let fftSize: Int
    /// Samples between consecutive frames.
    let hop: Int

    private let analyzer: InputSpectrumAnalyzer
    private let detector: InputPitchDetector
    private let tracker: InputNoteTracker
    private var spectrum: [Float]
    private var buffer: [Float] = []
    private var readIndex = 0
    private var bufferStartTime: TimeInterval = 0

    /// Detector parameters (A4, sensitivity, polyphony…).
    var detectorConfiguration: InputPitchDetectorConfiguration {
        get { detector.configuration }
        set { detector.configuration = newValue }
    }

    /// Tracker parameters (confirmation frames, release frames…). `framePeriod` and `binWidth` always follow
    /// the hop and FFT size.
    var trackerConfiguration: InputNoteTrackerConfiguration {
        get { tracker.configuration }
        set {
            var configuration = newValue
            configuration.framePeriod = Double(hop) / sampleRate
            configuration.binWidth = analyzer.binWidth
            tracker.configuration = configuration
        }
    }

    /// Notes the tracker currently reports as sounding.
    var activeNotes: Set<Int> { Set(tracker.activeNotes.keys) }

    /// Fails for a non-power-of-two `fftSize`, a non-positive sample rate, or a hop outside `1...fftSize`.
    init?(sampleRate: Double, fftSize: Int = 4096, hop: Int = 1024,
          detector detectorConfiguration: InputPitchDetectorConfiguration = InputPitchDetectorConfiguration(),
          tracker trackerConfiguration: InputNoteTrackerConfiguration = InputNoteTrackerConfiguration()) {
        guard hop >= 1, hop <= fftSize, let analyzer = InputSpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate) else { return nil }
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = hop
        self.analyzer = analyzer
        detector = InputPitchDetector(binWidth: analyzer.binWidth, binCount: analyzer.binCount, configuration: detectorConfiguration)
        var trackerConfiguration = trackerConfiguration
        trackerConfiguration.framePeriod = Double(hop) / sampleRate
        trackerConfiguration.binWidth = analyzer.binWidth
        tracker = InputNoteTracker(configuration: trackerConfiguration)
        spectrum = [Float](repeating: 0, count: analyzer.binCount)
        buffer.reserveCapacity(fftSize * 4)
    }

    /// Timestamp disagreement (seconds) below which the caller's `startTime` is treated as jitter and ignored.
    static let reanchorTolerance: TimeInterval = 0.002

    /// Appends samples whose first sample occurred at `startTime` and analyses every completed hop.
    ///
    /// Frame times follow the sample clock, re-anchored to the caller's clock on every call: the time the
    /// new chunk should start at (the buffered samples' start plus their duration) is compared with
    /// `startTime`. A disagreement within `reanchorTolerance` is jitter and ignored; a larger one (sample
    /// clock drift against the host clock) shifts the buffered samples' time. A disagreement of more than one
    /// hop is a discontinuity (dropout, interruption): the stale samples are discarded and the tracker's onset
    /// history is cleared so the jump is not mistaken for an attack.
    func process(samples: UnsafeBufferPointer<Float>, startTime: TimeInterval) -> [FrameResult] {
        guard let base = samples.baseAddress, !samples.isEmpty else { return [] }
        let pending = buffer.count - readIndex
        if pending <= 0 {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
            bufferStartTime = startTime
        } else {
            let expectedStart = bufferStartTime + Double(pending) / sampleRate
            let disagreement = startTime - expectedStart
            if abs(disagreement) > Double(hop) / sampleRate {
                buffer.removeAll(keepingCapacity: true)
                readIndex = 0
                bufferStartTime = startTime
                tracker.resetOnsetHistory()
            } else if abs(disagreement) > Self.reanchorTolerance {
                bufferStartTime += disagreement
            }
        }
        buffer.append(contentsOf: UnsafeBufferPointer(start: base, count: samples.count))
        var results: [FrameResult] = []
        while buffer.count - readIndex >= fftSize {
            let frameEndTime = bufferStartTime + Double(fftSize) / sampleRate
            buffer.withUnsafeBufferPointer { whole in
                guard let wholeBase = whole.baseAddress else { return }
                let frame = UnsafeBufferPointer(start: wholeBase + readIndex, count: fftSize)
                analyzer.magnitudes(of: frame, into: &spectrum)
                let pitches = detector.detect(spectrum: spectrum, sounding: Set(tracker.activeNotes.keys),
                                              reference: tracker.onsetReferenceSpectrum)
                let events = tracker.process(spectrum: spectrum, noiseFloor: detector.lastFloor, pitches: pitches, time: frameEndTime)
                results.append(FrameResult(time: frameEndTime, events: events, pitches: pitches,
                                           rms: InputSpectrumAnalyzer.rms(frame), flux: tracker.lastFlux))
            }
            readIndex += hop
            bufferStartTime += Double(hop) / sampleRate
        }
        if readIndex > fftSize * 4 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        return results
    }

    /// Array convenience for `process(samples:startTime:)`.
    func process(samples: [Float], startTime: TimeInterval) -> [FrameResult] {
        samples.withUnsafeBufferPointer { process(samples: $0, startTime: startTime) }
    }

    /// Releases every sounding note and clears the sample buffer (the detector keeps its configuration).
    func flush(at time: TimeInterval) -> [NoteInputEvent] {
        let offs = tracker.releaseAll(at: time)
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
        tracker.resetOnsetHistory()
        return offs
    }

    /// Clears all state including tracker history.
    func reset() {
        tracker.reset()
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
    }
}
