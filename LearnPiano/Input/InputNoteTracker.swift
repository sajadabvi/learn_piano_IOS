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
    /// An onset also needs the positive flux to exceed this multiple of the negative flux (the energy that
    /// vanished): a note ending abruptly splatters energy between partials but loses more than it gains, so
    /// it is not an attack.
    var onsetRiseRatio: Float = 1
    /// An onset frame's spectral energy (sum of squared magnitudes, i.e. the windowed frame's energy) must be at
    /// least this fraction of the previous frame's. A note that stops (damper, release) splatters energy across
    /// bins but lowers the total; an attack never does.
    var onsetMinimumEnergyRatio: Float = 0.9
    /// Frames of flux history used for the adaptive threshold.
    var fluxHistoryFrames: Int = 10
    /// A sounding note whose own salience (energy attributed to it alone, so other notes starting on its
    /// partials do not count) rises by this factor over its pre-onset level within
    /// `retriggerWindowFrames` after a spectral-flux onset is re-attacked (off + on).
    var retriggerSalienceJump: Float = 1.5
    /// Frames after an onset during which a sounding note may be re-attacked. With 75 % frame overlap an
    /// attack spreads over about `fftSize / hop` frames, so the rise is measured across that span.
    var retriggerWindowFrames: Int = 4
    /// While another note sharing low partials with a sounding note (see `InputNoteTracker.sharesLowPartials`)
    /// starts in the same onset window, the sounding note's own-salience rise must reach this larger factor to
    /// count as a re-attack: the new note's partials leak into the sounding note's share, a real re-strike
    /// (damped string, fresh hammer blow) rises far more.
    var retriggerSalienceJumpWithOverlap: Float = 2
    /// A candidate whose first strong frame lies more than this many frames before every onset of the open
    /// onset window belongs to an earlier sound (a sustained note coming back, a chord tone re-emerging as others decay) and can never
    /// confirm on that onset.
    var candidateLeadFrames: Int = 1
    /// A key released less than this long ago that is detected again without its own salience rising by
    /// `retriggerSalienceJump` resumes silently (it was dropped by mistake while still ringing).
    var resumeWindowSeconds: TimeInterval = 0.3
    /// Latency compensation subtracted from the frame time when stamping a note-on (half a hop is typical).
    var onsetTimeOffset: TimeInterval = 0.012
    /// Seconds between consecutive frames (hop / sample rate); `InputPitchPipeline` sets it.
    var framePeriod: TimeInterval = 1024.0 / 44_100
    /// Hz per spectrum bin (sample rate / FFT size); `InputPitchPipeline` sets it.
    var binWidth: Double = 44_100.0 / 4096
    /// A new note must have raised the magnitude at one of its three lowest partials by this factor over the
    /// spectrum just before the onset window opened. A note that was ringing all along but masked (a fifth
    /// chord tone beyond the polyphony limit, a partial-sharing note hidden by louder ones) does not rise
    /// and cannot be mistaken for an attack when an unrelated onset opens the window.
    var onsetPartialRise: Float = 1.4

    init() {}
}

/// Turns per-frame pitch detections into `NoteInputEvent`s with onset gating, confirmation, hysteresis
/// and minimum durations so a sustained piano note is reported exactly once.
///
/// Onsets come from spectral flux: the sum of positive magnitude changes over bins above the noise floor,
/// log-compressed so a soft new note is not drowned by amplitude wobble of a loud sustained one.
/// A note-on is emitted when a fundamental has been present for `framesToConfirmOn` frames inside the onset
/// window and first appeared at (or just before) that onset; a note-off when it has been missing for
/// `framesToRelease` frames. The detector's `isStrong` flag supplies the hysteresis: weak detections keep
/// notes alive but never start them. A note released by mistake that comes back without a fresh attack
/// resumes without a second note-on.
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

    /// A strong detection of a key that is not sounding yet.
    struct Candidate: Hashable, Sendable {
        /// Consecutive frames with a strong detection (reset by a weak or missing frame).
        var strongFrames: Int
        /// `frameCount` of the first strong detection; kept while the key stays detected, so a sound that
        /// predates an onset stays recognisable as stale.
        var firstFrame: Int
        /// Consecutive frames without any detection; the candidate is forgotten after two.
        var missingFrames: Int
    }

    /// A recently released key that may resume silently.
    private struct Release {
        var time: TimeInterval
        var note: ActiveNote
    }

    /// Current parameters (applied from the next frame on).
    var configuration: InputNoteTrackerConfiguration
    /// Notes currently reported as sounding, keyed by MIDI number.
    private(set) var activeNotes: [Int: ActiveNote] = [:]
    /// Keys detected strongly that are not sounding yet.
    private(set) var candidates: [Int: Candidate] = [:]
    /// Spectral flux of the most recent frame.
    private(set) var lastFlux: Float = 0
    /// Time of the most recent detected onset.
    private(set) var lastOnsetTime: TimeInterval?
    /// Frames processed so far.
    private(set) var frameCount = 0

    /// The magnitude spectrum from just before the open onset window, or nil when no window is open (feed it
    /// to `InputPitchDetector.detect(spectrum:sounding:reference:)`).
    var onsetReferenceSpectrum: [Float]? {
        openOnsetFrames.isEmpty || preOnsetSpectrum.isEmpty ? nil : preOnsetSpectrum
    }

    /// Frames of the onsets whose window is still open, oldest first (one attack can trigger two onsets).
    private var openOnsetFrames: [Int] = []
    private var lastOffTime: [Int: TimeInterval] = [:]
    private var recentReleases: [Int: Release] = [:]
    /// Keys whose note-on was emitted in the current onset window.
    private var startedInWindow: Set<Int> = []
    private var previousCompressed: [Float] = []
    /// Linear spectrum of the previous frame, and of the frame before the open onset window began.
    private var previousSpectrum: [Float] = []
    private var preOnsetSpectrum: [Float] = []
    private var compressed: [Float] = []
    private var fluxHistory: [Float] = []
    private var previousFlux: Float = 0
    private var previousEnergy: Float = 0
    private var framesSinceOnset = Int.max / 2

    init(configuration: InputNoteTrackerConfiguration = InputNoteTrackerConfiguration()) {
        self.configuration = configuration
    }

    /// Forgets all state without emitting events.
    func reset() {
        activeNotes.removeAll()
        candidates.removeAll()
        lastOffTime.removeAll()
        recentReleases.removeAll()
        startedInWindow.removeAll()
        lastOnsetTime = nil
        openOnsetFrames.removeAll()
        framesSinceOnset = Int.max / 2
        frameCount = 0
        resetOnsetHistory()
    }

    /// Forgets the spectral-flux history (previous spectrum and adaptive threshold) so the next frame cannot
    /// register an onset against audio from before a discontinuity. Sounding notes are kept.
    func resetOnsetHistory() {
        previousCompressed.removeAll()
        previousSpectrum.removeAll()
        preOnsetSpectrum.removeAll()
        compressed.removeAll()
        fluxHistory.removeAll()
        previousFlux = 0
        previousEnergy = 0
        lastFlux = 0
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
        let cfg = configuration
        let onset = detectOnset(spectrum: spectrum, noiseFloor: noiseFloor)
        let framesSinceOnsetBeforeThisFrame = framesSinceOnset &+ 1
        framesSinceOnset = onset ? 0 : framesSinceOnsetBeforeThisFrame
        openOnsetFrames.removeAll { frameCount - $0 > cfg.onsetWindowFrames }
        if onset, openOnsetFrames.isEmpty { preOnsetSpectrum = previousSpectrum }
        defer { previousSpectrum = spectrum }
        if onset {
            lastOnsetTime = time
            if framesSinceOnsetBeforeThisFrame > cfg.onsetWindowFrames { startedInWindow.removeAll() }
            openOnsetFrames.append(frameCount)
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

        resumeMistakenReleases(detected: detected, time: time)
        updateCandidates(detected: detected)

        // Note-ons: confirmed candidates that started with the onset that opened the window.
        if framesSinceOnset <= cfg.onsetWindowFrames, let onsetFrame = openOnsetFrames.first {
            for midi in candidates.keys.sorted() {
                guard let candidate = candidates[midi], candidate.strongFrames >= cfg.framesToConfirmOn,
                      candidate.firstFrame >= onsetFrame - cfg.candidateLeadFrames,
                      let pitch = detected[midi], hasRisen(pitch, in: spectrum) else { continue }
                if let off = lastOffTime[midi], time - off < cfg.retriggerGapSeconds { continue }
                let velocity = InputNoteTracker.velocity(forAmplitude: pitch.amplitude)
                // Stamp the attack, not the confirmation: the onset that opened the window, unless the note only
                // appeared well after it (a frame of slack covers detection lagging the flux peak).
                let firstSeen = time - Double(candidate.strongFrames - 1) * cfg.framePeriod
                let onTime = max(lastOnsetTime ?? firstSeen, firstSeen - cfg.framePeriod) - cfg.onsetTimeOffset
                events.append(.on(midi, velocity: velocity, time: onTime, source: .microphone))
                activeNotes[midi] = ActiveNote(onTime: onTime, missingFrames: 0, lastSalience: pitch.salience, recentOwnSalience: [pitch.ownSalience], retriggerHits: 0, peakSalience: pitch.salience, velocity: velocity, retriggerBaseline: nil)
                candidates[midi] = nil
                recentReleases[midi] = nil
                startedInWindow.insert(midi)
            }
        }

        // Sounding notes: re-attacks, releases.
        for midi in activeNotes.keys.sorted() {
            guard var note = activeNotes[midi] else { continue }
            if framesSinceOnset > cfg.retriggerWindowFrames { note.retriggerBaseline = nil }
            if let pitch = detected[midi] {
                let sustainedLongEnough = time - note.onTime >= cfg.minimumNoteSeconds
                // The onset frame itself is skipped (its spectrum is smeared by the attack transient), and the
                // rise must hold for two consecutive frames so beating between partials cannot fake it. A new
                // note sharing partials with this one raises the bar (its energy leaks into this note's share).
                var confirmedRetrigger = false
                if let baseline = note.retriggerBaseline, framesSinceOnset >= 1, !startedInWindow.contains(midi) {
                    let jump = hasOverlappingNewNote(midi) ? cfg.retriggerSalienceJumpWithOverlap : cfg.retriggerSalienceJump
                    if sustainedLongEnough, pitch.isStrong, pitch.ownSalience >= baseline * jump {
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
                    startedInWindow.insert(midi)
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
                    recentReleases[midi] = Release(time: time, note: note)
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
        candidates.removeAll()
        recentReleases.removeAll()
        startedInWindow.removeAll()
        openOnsetFrames.removeAll()
        return offs
    }

    /// Whether two keys share one of their six lowest partials (within 30 cents), so energy of one leaks into
    /// the other's harmonic share: octaves, twelfths, fifths, fourths, thirds, sixths and their compounds.
    static func sharesLowPartials(_ a: Int, _ b: Int) -> Bool {
        guard a != b else { return true }
        let semitones = Double(abs(a - b))
        for j in 1...6 {
            for k in 1...6 where j > k {
                // Partial j of the lower key against partial k of the upper key.
                let intervalCents = 1200 * log2(Double(j) / Double(k))
                if abs(intervalCents - 100 * semitones) < 30 { return true }
            }
        }
        return false
    }

    // MARK: Private

    /// Whether the magnitude at one of the pitch's three lowest partials rose by `onsetPartialRise` over the
    /// spectrum just before the open onset window (true when no such reference exists, e.g. after silence
    /// or a discontinuity).
    private func hasRisen(_ pitch: InputDetectedPitch, in spectrum: [Float]) -> Bool {
        let reference = preOnsetSpectrum
        guard reference.count == spectrum.count, configuration.binWidth > 0 else { return true }
        return (1...3).contains { k in
            InputPitchDetector.hasRisen(at: pitch.frequency * Double(k), in: spectrum, over: reference,
                                        binWidth: configuration.binWidth, ratio: configuration.onsetPartialRise)
        }
    }

    /// Whether a note sharing low partials with `midi` started, or is about to start, in this onset window.
    private func hasOverlappingNewNote(_ midi: Int) -> Bool {
        if startedInWindow.contains(where: { $0 != midi && InputNoteTracker.sharesLowPartials($0, midi) }) { return true }
        guard let onsetFrame = openOnsetFrames.first else { return false }
        return candidates.contains { key, candidate in
            key != midi && candidate.firstFrame >= onsetFrame - configuration.candidateLeadFrames
                && InputNoteTracker.sharesLowPartials(key, midi)
        }
    }

    /// Puts back keys released less than `resumeWindowSeconds` ago that are detected again without a fresh
    /// attack of their own (no onset in the re-attack window, or no own-salience rise over the level at the
    /// release). No event is emitted: the key was never really released.
    private func resumeMistakenReleases(detected: [Int: InputDetectedPitch], time: TimeInterval) {
        let cfg = configuration
        for (midi, release) in recentReleases {
            if time - release.time > cfg.resumeWindowSeconds {
                recentReleases[midi] = nil
                continue
            }
            guard let pitch = detected[midi], activeNotes[midi] == nil else { continue }
            let level = release.note.recentOwnSalience.last ?? 0
            let freshAttack = framesSinceOnset <= cfg.retriggerWindowFrames && pitch.isStrong
                && pitch.ownSalience >= level * cfg.retriggerSalienceJump
            recentReleases[midi] = nil
            if freshAttack { continue }
            var note = release.note
            note.missingFrames = 0
            note.retriggerBaseline = nil
            note.retriggerHits = 0
            note.recentOwnSalience = [pitch.ownSalience]
            note.lastSalience = pitch.salience
            activeNotes[midi] = note
            candidates[midi] = nil
        }
    }

    /// Advances the candidate bookkeeping for keys that are not sounding.
    private func updateCandidates(detected: [Int: InputDetectedPitch]) {
        for (midi, var candidate) in candidates {
            if activeNotes[midi] != nil {
                candidates[midi] = nil
                continue
            }
            if let pitch = detected[midi] {
                candidate.missingFrames = 0
                candidate.strongFrames = pitch.isStrong ? candidate.strongFrames + 1 : 0
                candidates[midi] = candidate
            } else {
                candidate.missingFrames += 1
                candidate.strongFrames = 0
                candidates[midi] = candidate.missingFrames >= 2 ? nil : candidate
            }
        }
        for (midi, pitch) in detected where pitch.isStrong && activeNotes[midi] == nil && candidates[midi] == nil {
            candidates[midi] = Candidate(strongFrames: 1, firstFrame: frameCount, missingFrames: 0)
        }
    }

    /// Spectral-flux onset detection with a noise gate, log compression and an adaptive threshold.
    private func detectOnset(spectrum: [Float], noiseFloor: Float) -> Bool {
        let count = spectrum.count
        if compressed.count != count { compressed = [Float](repeating: 0, count: count) }
        let gate = max(noiseFloor, Float.leastNormalMagnitude)
        var flux: Float = 0
        var fall: Float = 0
        var energy: Float = 0
        let hasPrevious = previousCompressed.count == count
        for i in 0..<count {
            let value = spectrum[i]
            energy += value * value
            let c: Float = value > gate ? log(1 + value / gate) : 0
            compressed[i] = c
            if hasPrevious {
                let delta = c - previousCompressed[i]
                if delta > 0, value > gate { flux += delta } else if delta < 0 { fall -= delta }
            }
        }
        swap(&previousCompressed, &compressed)
        if !hasPrevious { flux = 0 }
        let cfg = configuration
        let mean: Float = fluxHistory.isEmpty ? 0 : fluxHistory.reduce(0, +) / Float(fluxHistory.count)
        let threshold = max(cfg.fluxAbsoluteFloor, cfg.fluxThresholdFactor * mean)
        let isOnset = flux > threshold && flux > previousFlux && flux > cfg.onsetRiseRatio * fall
            && energy >= cfg.onsetMinimumEnergyRatio * previousEnergy && framesSinceOnset >= 1
        previousEnergy = energy
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
