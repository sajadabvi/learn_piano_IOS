import Foundation

/// Off-main half of the microphone source: owns the pitch pipeline on a serial queue, turns tap buffers
/// into note events and level readings, and throttles UI snapshots.
///
/// Thread-safety: every mutable property is confined to `queue`; the public methods only enqueue work, so
/// they may be called from the audio tap thread or the main actor.
final class InputMicrophoneProcessor: @unchecked Sendable {
    /// What the UI shows; published at most `snapshotInterval` apart, and immediately when notes change.
    struct Snapshot: Sendable, Equatable {
        /// Meter level 0…1 (−60 dBFS … 0 dBFS, fast attack, slow release).
        var level: Double
        /// Current RMS level in dBFS (−120 for silence).
        var decibels: Double
        /// Notes the tracker currently reports as sounding, ascending.
        var soundingNotes: [Int]
        /// Notes started since the previous snapshot, ascending (empty when none).
        var newNotes: [Int]
    }

    /// The serial queue all analysis runs on.
    let queue = DispatchQueue(label: "LearnPiano.InputMicrophone", qos: .userInteractive)
    /// Minimum spacing of level-only snapshots (30 Hz is plenty for a meter).
    var snapshotInterval: TimeInterval = 1.0 / 30

    private let deliverEvents: @Sendable ([NoteInputEvent]) -> Void
    private let publish: @Sendable (Snapshot) -> Void
    private var pipeline: InputPitchPipeline?
    private var detectorConfiguration = InputPitchDetectorConfiguration()
    private var trackerConfiguration = InputNoteTrackerConfiguration()
    private var meter: Double = 0
    private var lastPublishTime: TimeInterval = -.infinity
    private var pendingNewNotes: Set<Int> = []
    private var lastPublished: Snapshot?

    /// - Parameters:
    ///   - deliverEvents: receives note events on the processing queue, in order.
    ///   - publish: receives UI snapshots on the processing queue (the caller hops to the main actor).
    init(deliverEvents: @escaping @Sendable ([NoteInputEvent]) -> Void, publish: @escaping @Sendable (Snapshot) -> Void) {
        self.deliverEvents = deliverEvents
        self.publish = publish
    }

    /// Analysis frame and hop for a hardware rate: 4096/1024 at 44.1–48 kHz, doubled at 88.2 kHz and above
    /// so frequency resolution (~11 Hz) and frame period (~23 ms) stay the same.
    static func frameSizes(forSampleRate sampleRate: Double) -> (fftSize: Int, hop: Int) {
        sampleRate > 60_000 ? (8192, 2048) : (4096, 1024)
    }

    /// Maps an RMS amplitude to a 0…1 meter value (−60 dBFS → 0, 0 dBFS → 1) and its dBFS value.
    static func meterLevel(rms: Float) -> (level: Double, decibels: Double) {
        guard rms > 0 else { return (0, -120) }
        let decibels = max(-120, 20 * log10(Double(rms)))
        return (max(0, min(1, (decibels + 60) / 60)), decibels)
    }

    /// (Re)builds the pipeline for a sample rate. Called before the tap starts delivering.
    func prepare(sampleRate: Double) {
        queue.async { [self] in
            let sizes = Self.frameSizes(forSampleRate: sampleRate)
            if let existing = pipeline, existing.sampleRate == sampleRate, existing.fftSize == sizes.fftSize {
                existing.reset()
            } else {
                pipeline = InputPitchPipeline(sampleRate: sampleRate, fftSize: sizes.fftSize, hop: sizes.hop,
                                              detector: detectorConfiguration, tracker: trackerConfiguration)
            }
            meter = 0
            pendingNewNotes.removeAll()
        }
    }

    /// Applies new detector settings (A4, sensitivity) from the next frame on.
    func update(detector configuration: InputPitchDetectorConfiguration) {
        queue.async { [self] in
            detectorConfiguration = configuration
            pipeline?.detectorConfiguration = configuration
        }
    }

    /// Queues mono samples whose first sample was captured at `startTime` (Input clock seconds).
    func enqueue(samples: [Float], startTime: TimeInterval) {
        queue.async { [self] in process(samples: samples, startTime: startTime) }
    }

    /// Releases every sounding note (stop, interruption, route change) and resets the meter.
    func flush(at time: TimeInterval) {
        queue.async { [self] in
            if let offs = pipeline?.flush(at: time), !offs.isEmpty { deliverEvents(offs) }
            meter = 0
            pendingNewNotes.removeAll()
            lastPublishTime = -.infinity
            emit(Snapshot(level: 0, decibels: -120, soundingNotes: [], newNotes: []), force: true)
        }
    }

    /// Runs on `queue`.
    private func process(samples: [Float], startTime: TimeInterval) {
        guard let pipeline else { return }
        let frames = pipeline.process(samples: samples, startTime: startTime)
        guard let lastFrame = frames.last else { return }
        var events: [NoteInputEvent] = []
        var peakRMS: Float = 0
        for frame in frames {
            events += frame.events
            peakRMS = max(peakRMS, frame.rms)
        }
        if !events.isEmpty { deliverEvents(events) }
        for event in events where event.kind == .on { pendingNewNotes.insert(event.midi) }

        // Meter ballistics: instant attack, ~20 dB/s release at 43 frames/s.
        let reading = Self.meterLevel(rms: peakRMS)
        meter = max(reading.level, meter - 0.008 * Double(frames.count))
        let snapshot = Snapshot(level: meter, decibels: reading.decibels,
                                soundingNotes: pipeline.activeNotes.sorted(), newNotes: pendingNewNotes.sorted())
        emit(snapshot, force: !events.isEmpty, time: lastFrame.time)
    }

    /// Publishes when forced (notes changed) or when the throttle interval has passed.
    private func emit(_ snapshot: Snapshot, force: Bool, time: TimeInterval = InputClock.now) {
        guard force || time - lastPublishTime >= snapshotInterval else { return }
        guard snapshot != lastPublished else { return }
        lastPublishTime = time
        lastPublished = snapshot
        pendingNewNotes.removeAll()
        publish(snapshot)
    }
}
