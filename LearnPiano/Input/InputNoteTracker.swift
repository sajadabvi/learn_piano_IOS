import Foundation

/// Parameters of the frame-to-frame note tracker. Frame counts assume ~23 ms per hop (1024 @ 44.1 kHz).
struct InputNoteTrackerConfiguration: Hashable, Sendable {
    /// Consecutive frames a fundamental must be present (above the onset threshold) before a note-on.
    var framesToConfirmOn: Int = 3
    /// Consecutive frames a fundamental must be absent before a note-off.
    var framesToRelease: Int = 4
    /// Frames after a spectral-flux onset during which a new note may start.
    var onsetWindowFrames: Int = 8
    /// A note is never released before it has sounded this long (avoids chatter at the attack).
    var minimumNoteSeconds: TimeInterval = 0.08
    /// The same key cannot start again this soon after its release.
    var retriggerGapSeconds: TimeInterval = 0.06
    /// Spectral flux must exceed this multiple of its recent mean to count as an onset.
    var fluxThresholdFactor: Float = 1.6
    /// Spectral flux must also exceed this absolute value (compressed-magnitude units).
    var fluxAbsoluteFloor: Float = 6
    /// Frames of flux history used for the adaptive threshold.
    var fluxHistoryFrames: Int = 10
    /// A sounding note whose own salience (energy attributed to it alone, so other notes starting on its
    /// partials do not count) rises by this factor over its pre-onset level within
    /// `retriggerWindowFrames` after a spectral-flux onset is re-attacked (off + on).
    var retriggerSalienceJump: Float = 1.5
    /// Frames after an onset during which a sounding note may be re-attacked. With 75 % frame overlap an
    /// attack spreads over about `fftSize / hop` frames, so the rise is measured across that span.
    var retriggerWindowFrames: Int = 4
    /// Latency compensation subtracted from the frame time when stamping a note-on (half a hop is typical).
    var onsetTimeOffset: TimeInterval = 0.012
    /// Seconds between consecutive frames (hop / sample rate); `InputPitchPipeline` sets it.
    var framePeriod: TimeInterval = 1024.0 / 44_100

    init() {}
}

/// Turns per-frame pitch detections into `NoteInputEvent`s with onset gating, confirmation, hysteresis
/// and minimum durations so a sustained piano note is reported exactly once.
///
/// Onsets come from spectral flux: the sum of positive magnitude changes over bins above the noise floor,
/// log-compressed so a soft new note is not drowned by amplitude wobble of a loud sustained one.
/// A note-on is emitted when a fundamental has been present for `framesToConfirmOn` frames inside the onset
/// window; a note-off when it has been missing for `framesToRelease` frames. The detector's `isStrong`
/// flag supplies the hysteresis: weak detections keep notes alive but never start them.
///
/// Not thread-safe; one instance per processing queue.
final class InputNoteTracker {
    /// Bookkeeping for a sounding note.
    struct ActiveNote: Hashable, Sendable {
        var onTime: TimeInterval
        var missingFrames: Int
        var lastSalience: Float
        /// `InputDetectedPitch.ownSalience` of the three most recent frames in which the note was detected
        /// (newest last). Its minimum is the re-attack baseline: a re-struck key is damped first, so the
        /// level dips right before the new attack.
        var recentOwnSalience: [Float]
        /// Consecutive frames, since the last onset, in which the note exceeded the re-attack threshold.
        var retriggerHits: Int
        var peakSalience: Float
        var velocity: Double
        /// Salience just before the most recent onset; nil when no re-attack is pending.
        var retriggerBaseline: Float?
    }

    /// Current parameters (applied from the next frame on).
    var configuration: InputNoteTrackerConfiguration
    /// Notes currently reported as sounding, keyed by MIDI number.
    private(set) var activeNotes: [Int: ActiveNote] = [:]
    /// Spectral flux of the most recent frame.
    private(set) var lastFlux: Float = 0
    /// Time of the most recent detected onset.
    private(set) var lastOnsetTime: TimeInterval?
    /// Frames processed so far.
    private(set) var frameCount = 0

    private var candidateFrames: [Int: Int] = [:]
    private var lastOffTime: [Int: TimeInterval] = [:]
    private var previousCompressed: [Float] = []
    private var compressed: [Float] = []
    private var fluxHistory: [Float] = []
    private var previousFlux: Float = 0
    private var framesSinceOnset = Int.max / 2

    init(configuration: InputNoteTrackerConfiguration = InputNoteTrackerConfiguration()) {
        self.configuration = configuration
    }

    /// Forgets all state without emitting events.
    func reset() {
        activeNotes.removeAll()
        candidateFrames.removeAll()
        lastOffTime.removeAll()
        previousCompressed.removeAll()
        compressed.removeAll()
        fluxHistory.removeAll()
        previousFlux = 0
        lastFlux = 0
        lastOnsetTime = nil
        framesSinceOnset = Int.max / 2
        frameCount = 0
    }

    /// Processes one analysis frame.
    /// - Parameters:
    ///   - spectrum: linear magnitude spectrum of the frame.
    ///   - noiseFloor: magnitude below which bins are ignored for onset detection (the detector's floor).
    ///   - pitches: fundamentals the detector found in this frame.
    ///   - time: time in seconds of the frame's last sample.
    /// - Returns: note events in emission order (offs before ons when both occur for one key).
    func process(spectrum: [Float], noiseFloor: Float, pitches: [InputDetectedPitch], time: TimeInterval) -> [NoteInputEvent] {
        frameCount += 1
        let onset = detectOnset(spectrum: spectrum, noiseFloor: noiseFloor)
        framesSinceOnset = onset ? 0 : framesSinceOnset &+ 1
        if onset {
            lastOnsetTime = time
            // Arm every sounding note for a possible re-attack, remembering its level before the onset.
            for (midi, note) in activeNotes {
                var armed = note
                armed.retriggerBaseline = note.recentOwnSalience.min()
                armed.retriggerHits = 0
                activeNotes[midi] = armed
            }
        }
        var events: [NoteInputEvent] = []
        let detected = Dictionary(pitches.map { ($0.midi, $0) }, uniquingKeysWith: { a, b in a.salience >= b.salience ? a : b })
        let cfg = configuration

        // Candidates: strong detections that are not sounding yet.
        for (midi, _) in candidateFrames where detected[midi]?.isStrong != true || activeNotes[midi] != nil {
            candidateFrames[midi] = nil
        }
        for pitch in pitches where pitch.isStrong && activeNotes[pitch.midi] == nil {
            candidateFrames[pitch.midi, default: 0] += 1
        }

        // Note-ons: confirmed candidates inside the onset window.
        if framesSinceOnset <= cfg.onsetWindowFrames {
            for midi in candidateFrames.keys.sorted() {
                guard let frames = candidateFrames[midi], frames >= cfg.framesToConfirmOn, let pitch = detected[midi] else { continue }
                if let off = lastOffTime[midi], time - off < cfg.retriggerGapSeconds { continue }
                let velocity = InputNoteTracker.velocity(forAmplitude: pitch.amplitude)
                // Stamp the attack, not the confirmation: the onset that opened the window, unless the note only
                // appeared well after it (a frame of slack covers detection lagging the flux peak).
                let firstSeen = time - Double(frames - 1) * cfg.framePeriod
                let onTime = max(lastOnsetTime ?? firstSeen, firstSeen - cfg.framePeriod) - cfg.onsetTimeOffset
                events.append(.on(midi, velocity: velocity, time: onTime, source: .microphone))
                activeNotes[midi] = ActiveNote(onTime: onTime, missingFrames: 0, lastSalience: pitch.salience, recentOwnSalience: [pitch.ownSalience], retriggerHits: 0, peakSalience: pitch.salience, velocity: velocity, retriggerBaseline: nil)
                candidateFrames[midi] = nil
            }
        }

        // Sounding notes: re-attacks, releases.
        for midi in activeNotes.keys.sorted() {
            guard var note = activeNotes[midi] else { continue }
            if framesSinceOnset > cfg.retriggerWindowFrames { note.retriggerBaseline = nil }
            if let pitch = detected[midi] {
                let sustainedLongEnough = time - note.onTime >= cfg.minimumNoteSeconds
                // The onset frame itself is skipped (its spectrum is smeared by the attack transient), and the
                // rise must hold for two consecutive frames so beating between partials cannot fake it.
                var confirmedRetrigger = false
                if let baseline = note.retriggerBaseline, framesSinceOnset >= 1 {
                    if sustainedLongEnough, pitch.isStrong, pitch.ownSalience >= baseline * cfg.retriggerSalienceJump {
                        note.retriggerHits += 1
                        confirmedRetrigger = note.retriggerHits >= 2
                    } else {
                        note.retriggerHits = 0
                    }
                }
                if confirmedRetrigger {
                    let retriggerTime = max(note.onTime, (lastOnsetTime ?? time) - cfg.onsetTimeOffset)
                    events.append(.off(midi, time: retriggerTime, source: .microphone))
                    let velocity = InputNoteTracker.velocity(forAmplitude: pitch.amplitude)
                    events.append(.on(midi, velocity: velocity, time: retriggerTime, source: .microphone))
                    note.onTime = retriggerTime
                    note.peakSalience = pitch.salience
                    note.velocity = velocity
                    note.retriggerBaseline = nil
                }
                note.missingFrames = 0
                note.lastSalience = pitch.salience
                note.recentOwnSalience.append(pitch.ownSalience)
                if note.recentOwnSalience.count > 3 { note.recentOwnSalience.removeFirst() }
                note.peakSalience = max(note.peakSalience, pitch.salience)
                activeNotes[midi] = note
            } else {
                note.missingFrames += 1
                if note.missingFrames >= cfg.framesToRelease, time - note.onTime >= cfg.minimumNoteSeconds {
                    events.append(.off(midi, time: time, source: .microphone))
                    activeNotes[midi] = nil
                    lastOffTime[midi] = time
                } else {
                    activeNotes[midi] = note
                }
            }
        }
        return events
    }

    /// Releases every sounding note (used when the microphone stops).
    func releaseAll(at time: TimeInterval) -> [NoteInputEvent] {
        let offs = activeNotes.keys.sorted().map { NoteInputEvent.off($0, time: time, source: .microphone) }
        for midi in activeNotes.keys { lastOffTime[midi] = time }
        activeNotes.removeAll()
        candidateFrames.removeAll()
        return offs
    }

    /// Spectral-flux onset detection with a noise gate, log compression and an adaptive threshold.
    private func detectOnset(spectrum: [Float], noiseFloor: Float) -> Bool {
        let count = spectrum.count
        if compressed.count != count { compressed = [Float](repeating: 0, count: count) }
        let gate = max(noiseFloor, Float.leastNormalMagnitude)
        var flux: Float = 0
        let hasPrevious = previousCompressed.count == count
        for i in 0..<count {
            let value = spectrum[i]
            let c: Float = value > gate ? log(1 + value / gate) : 0
            compressed[i] = c
            if hasPrevious {
                let delta = c - previousCompressed[i]
                if delta > 0, value > gate { flux += delta }
            }
        }
        swap(&previousCompressed, &compressed)
        if !hasPrevious { flux = 0 }
        let cfg = configuration
        let mean: Float = fluxHistory.isEmpty ? 0 : fluxHistory.reduce(0, +) / Float(fluxHistory.count)
        let threshold = max(cfg.fluxAbsoluteFloor, cfg.fluxThresholdFactor * mean)
        let isOnset = flux > threshold && flux > previousFlux && framesSinceOnset >= 1
        fluxHistory.append(flux)
        if fluxHistory.count > max(1, cfg.fluxHistoryFrames) { fluxHistory.removeFirst(fluxHistory.count - cfg.fluxHistoryFrames) }
        previousFlux = flux
        lastFlux = flux
        return isOnset
    }

    /// Maps a partial magnitude (full scale = 1) to a 0.2…1 velocity: −60 dBFS → 0.2, −6 dBFS → 1.
    static func velocity(forAmplitude amplitude: Float) -> Double {
        guard amplitude > 0 else { return 0.2 }
        let dB = 20 * log10(Double(amplitude))
        return max(0.2, min(1, 0.2 + (dB + 60) / 54 * 0.8))
    }
}
