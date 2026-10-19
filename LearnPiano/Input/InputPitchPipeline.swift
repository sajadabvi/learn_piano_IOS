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

    /// Tracker parameters (confirmation frames, release frames…). `framePeriod` always follows the hop.
    var trackerConfiguration: InputNoteTrackerConfiguration {
        get { tracker.configuration }
        set {
            var configuration = newValue
            configuration.framePeriod = Double(hop) / sampleRate
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
        tracker = InputNoteTracker(configuration: trackerConfiguration)
        spectrum = [Float](repeating: 0, count: analyzer.binCount)
        buffer.reserveCapacity(fftSize * 4)
    }

    /// Appends samples whose first sample occurred at `startTime` and analyses every completed hop.
    ///
    /// `startTime` is only used to (re)anchor the clock when the internal buffer is empty, so small jitter
    /// in the caller's timestamps does not disturb frame times; a gap after a dropout re-anchors naturally.
    func process(samples: UnsafeBufferPointer<Float>, startTime: TimeInterval) -> [FrameResult] {
        guard let base = samples.baseAddress, !samples.isEmpty else { return [] }
        if readIndex >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
            bufferStartTime = startTime
        }
        buffer.append(contentsOf: UnsafeBufferPointer(start: base, count: samples.count))
        var results: [FrameResult] = []
        while buffer.count - readIndex >= fftSize {
            let frameEndTime = bufferStartTime + Double(fftSize) / sampleRate
            buffer.withUnsafeBufferPointer { whole in
                guard let wholeBase = whole.baseAddress else { return }
                let frame = UnsafeBufferPointer(start: wholeBase + readIndex, count: fftSize)
                analyzer.magnitudes(of: frame, into: &spectrum)
                let pitches = detector.detect(spectrum: spectrum)
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
        return offs
    }

    /// Clears all state including tracker history.
    func reset() {
        tracker.reset()
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
    }
}
