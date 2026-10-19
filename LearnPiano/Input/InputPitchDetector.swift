import Foundation

/// One fundamental found in a spectrum frame.
struct InputDetectedPitch: Hashable, Sendable {
    /// Nearest MIDI note number at the configured A4.
    var midi: Int
    /// Estimated fundamental frequency in Hz (weighted over the harmonics that were found).
    var frequency: Double
    /// Deviation from equal temperament in cents (−50…50).
    var cents: Double
    /// Harmonic score in linear magnitude units; higher is more confident/louder.
    var salience: Float
    /// Part of `salience` attributed to this note alone by harmonic subtraction (partials shared with other
    /// notes count only up to the note's smooth envelope). Stable when other notes start on its partials.
    var ownSalience: Float
    /// Magnitude of the strongest partial attributed to this note.
    var amplitude: Float
    /// True when the note passes the note-on threshold; false when it only passes the lower hold
    /// (hysteresis) threshold and should keep an already sounding note alive but not start one.
    var isStrong: Bool
}

/// Tunable parameters of the polyphonic detector. Defaults are suitable for an acoustic or digital piano
/// picked up by an iPad microphone.
struct InputPitchDetectorConfiguration: Hashable, Sendable {
    /// Tuning reference for A4 in Hz (415…466 as allowed by `UserSettings`).
    var a4Hertz: Double = 440
    /// 0 (least sensitive, loud notes only) … 1 (most sensitive, quiet notes and more false positives).
    var sensitivity: Double = 0.5
    /// Maximum number of simultaneous fundamentals reported per frame.
    var maxPolyphony: Int = 4
    /// MIDI notes considered (A0…C8 covers the piano).
    var midiRange: ClosedRange<Int> = Pitch.pianoRange
    /// Harmonics that contribute to a candidate's salience.
    var scoringHarmonics: Int = 8
    /// Harmonics removed from the spectrum once a fundamental is accepted (harmonic subtraction).
    var subtractionHarmonics: Int = 16
    /// Frequency tolerance when matching a peak to harmonic `k` of a candidate, as a fraction of `k·f0`
    /// (0.029 ≈ half a semitone). At least half a bin is always allowed.
    var harmonicToleranceRatio: Double = 0.029
    /// Hysteresis: a note already sounding stays detected down to this fraction of the note-on threshold.
    var holdRatio: Float = 0.5
    /// Peaks below this fraction of the frame's loudest bin are ignored.
    var relativeFloor: Float = 0.02
    /// Peaks must exceed this multiple of the mean magnitude (the frame's noise floor).
    var noiseFloorFactor: Float = 5
    /// Later fundamentals in a chord must reach this fraction of the strongest one's salience.
    var minimumPolyphonicRatio: Float = 0.12
    /// Exponent of the harmonic weights `1 / k^p`: lower favours sub-octave candidates, higher favours
    /// upper octaves. 0.6 balances weak piano fundamentals against octave ghosts.
    var harmonicWeightExponent: Double = 0.6
    /// Notes below this frequency are assumed to have a weak fundamental when estimating how much of their
    /// 2nd partial to subtract (≈ B2; tablet microphones roll off below ~120 Hz).
    var weakFundamentalBelowHertz: Double = 125
    /// Octave-error suppression: the octave below replaces a winner when its odd partials (3, 5, 7) reach this
    /// fraction of its even partials (2, 4, 6)…
    var octaveOddEvidenceRatio: Float = 0.3
    /// …and its salience reaches this fraction of the winner's.
    var octaveSalienceRatio: Float = 0.7
    /// A candidate at a harmonic interval above an accepted note (octave, 12th, double octave…) is reported
    /// only when its salience reaches this fraction of the energy attributed to that note.
    var harmonicGhostRatio: Float = 0.3

    init() {}

    /// Absolute magnitude a spectral peak must reach: −36 dBFS at sensitivity 0 down to −66 dBFS at 1.
    var peakFloor: Float {
        let s = max(0, min(1, sensitivity))
        return Float(pow(10, -(36 + 30 * s) / 20))
    }

    /// Minimum salience that starts a note (twice the peak floor, so a lone noise peak never qualifies).
    var onsetSalience: Float { peakFloor * 2 }

    /// Minimum salience that keeps an already sounding note alive.
    var holdSalience: Float { onsetSalience * max(0.05, min(1, holdRatio)) }
}

/// Polyphonic fundamental estimation for one magnitude spectrum.
///
/// Pipeline per frame: pick spectral peaks above an adaptive floor (with parabolic interpolation of the
/// peak frequency), score every MIDI note in range by a weighted sum of the residual peak magnitudes found
/// at its harmonics (a harmonic-sum variant of the harmonic product spectrum that tolerates missing
/// partials), accept the best candidate, subtract its estimated harmonic energy (harmonic subtraction with
/// spectral smoothness) and repeat up to `maxPolyphony` times. Candidates must show their fundamental or both their 2nd and 3rd harmonic, which
/// rejects sub-harmonic ghosts; an accepted note is moved down an octave when the lower octave shows its own
/// fundamental and 3rd harmonic (weak-fundamental octave error).
///
/// Not thread-safe; one instance per processing queue.
final class InputPitchDetector {
    /// A spectral peak after interpolation.
    struct Peak: Hashable, Sendable {
        var frequency: Double
        var amplitude: Float
    }

    /// Current parameters. Changing `a4Hertz` or `midiRange` rebuilds the candidate table.
    var configuration: InputPitchDetectorConfiguration {
        didSet { if configuration.a4Hertz != oldValue.a4Hertz || configuration.midiRange != oldValue.midiRange { rebuildCandidates() } }
    }
    /// Bin width of the spectra this detector will receive.
    let binWidth: Double
    /// Number of bins per spectrum.
    let binCount: Int
    /// Highest frequency represented.
    var nyquist: Double { Double(binCount) * binWidth }

    private var candidateFrequencies: [Double] = []
    private var harmonicWeights: [Float] = []
    private var peaks: [Peak] = []
    /// Amplitude of each peak not yet explained by an accepted note (harmonic subtraction state).
    private var residual: [Float] = []
    /// Floor used for the most recent frame (exposed for level/velocity calculations).
    private(set) var lastFloor: Float = 0
    /// Peaks of the most recent frame, mostly for debugging/visualisation.
    var lastPeaks: [Peak] { peaks }

    init(binWidth: Double, binCount: Int, configuration: InputPitchDetectorConfiguration = InputPitchDetectorConfiguration()) {
        self.binWidth = binWidth
        self.binCount = binCount
        self.configuration = configuration
        rebuildCandidates()
    }

    private func rebuildCandidates() {
        candidateFrequencies = configuration.midiRange.map { MusicHelpers.frequency(midi: Double($0), a4: configuration.a4Hertz) }
        let count = max(configuration.scoringHarmonics, configuration.subtractionHarmonics, 1)
        harmonicWeights = (1...count).map { Float(1 / pow(Double($0), configuration.harmonicWeightExponent)) }
    }

    // MARK: Peaks

    /// Finds local maxima above the adaptive floor and refines them by parabolic interpolation.
    func pickPeaks(in spectrum: [Float]) -> [Peak] {
        peaks.removeAll(keepingCapacity: true)
        guard spectrum.count >= 4 else { return peaks }
        let count = min(spectrum.count, binCount)
        var sum: Float = 0
        var maxValue: Float = 0
        for i in 1..<count {
            sum += spectrum[i]
            if spectrum[i] > maxValue { maxValue = spectrum[i] }
        }
        let mean = sum / Float(count - 1)
        let floor = max(configuration.peakFloor, configuration.noiseFloorFactor * mean, configuration.relativeFloor * maxValue)
        lastFloor = floor
        guard maxValue > floor else { return peaks }
        let lowest = configuration.midiRange.lowerBound
        let minFrequency = MusicHelpers.frequency(midi: Double(lowest), a4: configuration.a4Hertz) / 1.06
        let minBin = max(1, Int(minFrequency / binWidth))
        let maxBin = count - 2
        guard minBin < maxBin else { return peaks }
        for i in minBin...maxBin {
            let c = spectrum[i]
            guard c > floor, c > spectrum[i - 1], c >= spectrum[i + 1] else { continue }
            let a = spectrum[i - 1], b = spectrum[i + 1]
            let denominator = a - 2 * c + b
            var offset: Float = 0
            if denominator < 0 { offset = 0.5 * (a - b) / denominator }
            offset = max(-0.5, min(0.5, offset))
            let amplitude = c - 0.25 * (a - b) * offset
            peaks.append(Peak(frequency: (Double(i) + Double(offset)) * binWidth, amplitude: max(c, amplitude)))
        }
        return peaks
    }

    // MARK: Detection

    /// Detects up to `maxPolyphony` fundamentals in a magnitude spectrum, strongest first.
    func detect(spectrum: [Float]) -> [InputDetectedPitch] {
        _ = pickPeaks(in: spectrum)
        guard !peaks.isEmpty else { return [] }
        residual = peaks.map(\.amplitude)
        var results: [InputDetectedPitch] = []
        /// Energy attributed to each accepted note by harmonic subtraction (parallel to `results`).
        var ownSaliences: [Float] = []
        /// Candidate indices already accepted or rejected as ghosts in this frame.
        var decided: Set<Int> = []
        var firstSalience: Float = 0
        let cfg = configuration
        for _ in 0..<max(1, cfg.maxPolyphony) {
            guard var best = bestCandidate(excluding: decided) else { break }
            // Octave-error suppression: a note with a weak fundamental can lose to its upper octave, whose
            // harmonics are exactly the even partials of the true note. Move down while the lower octave has a
            // (possibly weak) fundamental of its own, shows odd partials (3, 5, 7) the upper note cannot explain
            // and scores nearly as well. Requiring the fundamental keeps close-position triads (whose notes are
            // partials 2, 3 and 5 of the octave below) from collapsing into a phantom bass note.
            var corrections = 0
            while corrections < 2, !decided.contains(best.index - 12), let lower = scoreCandidate(index: best.index - 12),
                  lower.hasFundamental, lower.oddEvidence > 0,
                  lower.oddEvidence >= cfg.octaveOddEvidenceRatio * lower.evenEvidence,
                  lower.salience >= best.salience * cfg.octaveSalienceRatio {
                best = lower
                corrections += 1
            }
            let threshold = results.isEmpty ? cfg.holdSalience : max(cfg.holdSalience, firstSalience * cfg.minimumPolyphonicRatio)
            guard best.salience >= threshold else { break }
            // Harmonic ghosts: what remains of an accepted note's partials after subtraction can masquerade as a
            // note at a harmonic interval above it. Such candidates must carry a real share of energy.
            let midiCandidate = cfg.midiRange.lowerBound + best.index
            let isGhost = zip(results, ownSaliences).contains { accepted, own in
                InputPitchDetector.harmonicIntervals.contains(midiCandidate - accepted.midi)
                    && best.salience < own * cfg.harmonicGhostRatio
            }
            decided.insert(best.index)
            if isGhost {
                consume(candidateIndex: best.index)
                continue
            }
            if results.isEmpty { firstSalience = best.salience }
            let own = consume(candidateIndex: best.index)
            ownSaliences.append(own)
            let midi = cfg.midiRange.lowerBound + best.index
            let nominal = candidateFrequencies[best.index]
            let cents = max(-50, min(50, 1200 * log2(best.frequency / nominal)))
            results.append(InputDetectedPitch(midi: midi, frequency: best.frequency, cents: cents, salience: best.salience,
                                              ownSalience: own, amplitude: best.amplitude, isStrong: best.salience >= cfg.onsetSalience))
        }
        return results
    }

    /// Semitone distances of partials 2…8 above a fundamental (octave, 12th, double octave, 17th, 19th,
    /// 21st (≈ minor 7th), triple octave), where the residue of an accepted note can fake another note.
    static let harmonicIntervals: Set<Int> = [12, 19, 24, 28, 31, 34, 36]

    /// Score of one candidate.
    private struct CandidateScore {
        var index: Int
        var salience: Float
        var frequency: Double
        var amplitude: Float
        var hasFundamental: Bool
        /// Residual amplitude at partials 3, 5 and 7 (cannot belong to the octave above).
        var oddEvidence: Float
        /// Residual amplitude at partials 2, 4 and 6 (shared with the octave above).
        var evenEvidence: Float
    }

    /// Highest-salience candidate that passes the gating rule and has not been decided on in this frame,
    /// or nil when none scores above zero.
    private func bestCandidate(excluding decided: Set<Int>) -> CandidateScore? {
        var best: CandidateScore?
        for index in candidateFrequencies.indices where !decided.contains(index) {
            guard let score = scoreCandidate(index: index) else { continue }
            if let b = best, b.salience >= score.salience { continue }
            best = score
        }
        return best
    }

    /// Scores candidate `index` against the residual peak amplitudes; nil when gated out or out of range.
    private func scoreCandidate(index: Int) -> CandidateScore? {
        guard candidateFrequencies.indices.contains(index) else { return nil }
        let f0 = candidateFrequencies[index]
        let cfg = configuration
        var salience: Float = 0
        var weightedFrequency = 0.0
        var weightSum: Float = 0
        var amplitude: Float = 0
        var hasFundamental = false
        var hasSecond = false
        var hasThird = false
        var oddEvidence: Float = 0
        var evenEvidence: Float = 0
        for k in 1...max(1, cfg.scoringHarmonics) {
            let target = f0 * Double(k)
            if target >= nyquist { break }
            guard let peakIndex = matchingPeak(near: target, harmonic: k) else { continue }
            let peak = peaks[peakIndex]
            let available = residual[peakIndex]
            let w = harmonicWeights[k - 1]
            salience += available * w
            weightedFrequency += peak.frequency / Double(k) * Double(available * w)
            weightSum += available * w
            amplitude = max(amplitude, available)
            switch k {
            case 1: hasFundamental = true
            case 2: hasSecond = true
            case 3: hasThird = true
            default: break
            }
            switch k {
            case 3, 5, 7: oddEvidence += available
            case 2, 4, 6: evenEvidence += available
            default: break
            }
        }
        guard salience > 0, hasFundamental || (hasSecond && hasThird) else { return nil }
        let frequency = weightSum > 0 ? weightedFrequency / Double(weightSum) : f0
        return CandidateScore(index: index, salience: salience, frequency: frequency, amplitude: amplitude,
                              hasFundamental: hasFundamental, oddEvidence: oddEvidence, evenEvidence: evenEvidence)
    }

    /// Index of the peak with the largest residual amplitude within tolerance of `target`, or nil when
    /// no peak with energy left lies there.
    private func matchingPeak(near target: Double, harmonic k: Int) -> Int? {
        let tolerance = max(0.5 * binWidth, configuration.harmonicToleranceRatio * target)
        let minimumResidual = lastFloor * 0.5
        var best: Int?
        for (i, peak) in peaks.enumerated() {
            if peak.frequency < target - tolerance { continue }
            if peak.frequency > target + tolerance { break }
            guard residual[i] > minimumResidual else { continue }
            if let b = best, residual[b] >= residual[i] { continue }
            best = i
        }
        return best
    }

    /// Harmonic subtraction with spectral smoothness: removes from each harmonic peak of an accepted note the
    /// energy the note itself plausibly contributes, so partials shared with other notes keep the rest.
    ///
    /// A note's harmonic amplitudes form a smooth envelope, so the share of partial `k ≥ 2` is bounded by
    /// the smallest envelope estimate obtained from the matched partials `j ∈ k−2 … k+2` scaled to position
    /// `k` by `√(j/k)`; a peak louder than that (because another note's fundamental or low partial coincides
    /// with it) keeps the excess. The wide neighbourhood matters for octave doublings, which inflate every
    /// even partial of the lower note. Bass notes (below `weakFundamentalBelowHertz`) have weak fundamentals
    /// on a tablet microphone, so their fundamental is never used as a neighbour and their 2nd partial is
    /// bounded by `max(mean(a_1, a_3), a_3, 2·a_3 − a_4)` instead (the last term extrapolates the falling
    /// envelope). The fundamental itself is removed entirely.
    ///
    /// - Returns: the note's own salience, i.e. the weighted energy attributed to it (comparable with
    ///   `CandidateScore.salience`, but not inflated by partials shared with other notes).
    @discardableResult
    private func consume(candidateIndex index: Int) -> Float {
        let f0 = candidateFrequencies[index]
        let count = max(1, configuration.subtractionHarmonics)
        var matched: [Int?] = []
        var amplitudes: [Float] = []
        matched.reserveCapacity(count)
        amplitudes.reserveCapacity(count)
        for k in 1...count {
            let target = f0 * Double(k)
            if target >= nyquist { break }
            let peakIndex = matchingPeak(near: target, harmonic: k)
            matched.append(peakIndex)
            amplitudes.append(peakIndex.map { residual[$0] } ?? 0)
        }
        var own: Float = 0
        for (offset, peakIndex) in matched.enumerated() {
            guard let peakIndex else { continue }
            var share = amplitudes[offset]
            let isBass = f0 < configuration.weakFundamentalBelowHertz
            if offset == 1, isBass, amplitudes.count > 2 {
                // Bass: the fundamental is unreliable, so extrapolate the 2nd partial from the 3rd and 4th.
                let a1 = amplitudes[0], a3 = amplitudes[2]
                let extrapolated: Float = amplitudes.count > 3 ? 2 * a3 - amplitudes[3] : 0
                share = min(share, max((a1 + a3) / 2, a3, extrapolated))
            } else if offset >= 1 {
                // Envelope estimate: each matched partial within two positions either side, scaled to this
                // position by √(j/k) (between a flat and a 1/k envelope); the smallest estimate wins, so
                // neighbours inflated by other notes are ignored. Bass fundamentals are skipped.
                let k = Float(offset + 1)
                let lowest = isBass ? 1 : 0
                var estimate = Float.greatestFiniteMagnitude
                for neighbour in max(lowest, offset - 2)...min(amplitudes.count - 1, offset + 2)
                    where neighbour != offset && matched[neighbour] != nil {
                    estimate = min(estimate, amplitudes[neighbour] * (Float(neighbour + 1) / k).squareRoot())
                }
                if estimate < .greatestFiniteMagnitude { share = min(share, estimate) }
            }
            residual[peakIndex] = max(0, residual[peakIndex] - share)
            if offset < configuration.scoringHarmonics { own += share * harmonicWeights[offset] }
        }
        return own
    }
}
