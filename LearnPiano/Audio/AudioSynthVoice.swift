import Foundation

// MARK: - Voice state

/// One polyphonic voice of the additive piano model. A voice is a bank of up to 16 inharmonic partials, each
/// with its own "prompt sound" (fast-decaying) and "aftersound" (slow-decaying) amplitude, plus a short
/// filtered noise burst for the hammer strike.
///
/// The model is sustain-free: a held key simply decays naturally; releasing it damps the string with a short
/// release tail (except above F6, where real pianos have no dampers and the note rings out).
///
/// **Render cost.** The render loop is built to stay cheap even in unoptimized (Debug) builds:
/// - Each partial is a complex rotator (`x + iy` multiplied by `e^{iω}` every sample: four multiplies, two
///   adds), re-normalized once per sub-block, instead of a phase accumulator plus a sine approximation.
/// - Envelopes advance once per `subBlockLength`-sample sub-block and are ramped linearly inside it, so the
///   per-sample work is one multiply-add per partial for the amplitude.
/// - Partials at or above 0.45 × the sample rate are never generated (`activePartialCount` is fixed by
///   `start`), and partials that have decayed below `partialFloor` are dropped from the top of the bank.
/// - All partial state lives in a caller-owned flat `Float` buffer (`bank`), processed with plain scalar
///   loops four partials at a time (independent dependency chains, no generic SIMD calls).
///
/// The voice is plain-old-data apart from the `bank` pointer, so the render thread can own an array of them
/// without allocating; the owner (`AudioSynthRenderState`) allocates and frees the banks.
struct AudioSynthVoice: AudioVoiceDescribing {
    /// Maximum partials per voice.
    static let partialCount = 16
    /// Partials processed together in the inner loop.
    static let partialGroupSize = 4
    /// Envelope update period in samples; amplitudes are ramped linearly inside a sub-block.
    static let subBlockLength = 32
    /// Floats a voice's `bank` must hold.
    static let bankFloats = BankField.count * partialCount
    /// Lowest key that has no damper (F6): note-off is ignored for it and above.
    static let undampedFromMIDI = 89
    /// Below this envelope level a voice counts as silent and is freed.
    static let silenceLevel: Float = 1e-4
    /// A partial whose amplitude falls below this level (−120 dB) is no longer generated.
    static let partialFloor: Float = 1e-6
    /// Time constant of the damper after a key release (seconds).
    static let releaseSeconds: Float = 0.09
    /// Time constant of the quick damp applied to a voice whose key is struck again (seconds).
    static let restrikeReleaseSeconds: Float = 0.03

    /// Rows of the struct-of-arrays partial bank; row `f` holds `partialCount` floats at `f * partialCount`.
    enum BankField: Int, CaseIterable {
        /// cos ω of the partial's per-sample rotation.
        case cosine
        /// sin ω of the partial's per-sample rotation.
        case sine
        /// Rotator real part.
        case x
        /// Rotator imaginary part (the partial's output waveform, starting at 0).
        case y
        /// Prompt-sound envelope at the end of the current sub-block (gain included).
        case envelopeFast
        /// Aftersound envelope at the end of the current sub-block (gain included).
        case envelopeSlow
        /// Prompt-sound decay over one sub-block.
        case blockDecayFast
        /// Aftersound decay over one sub-block.
        case blockDecaySlow
        /// Current (ramped) amplitude.
        case amplitude
        /// Amplitude increment per sample inside the current sub-block.
        case amplitudeStep

        /// Number of rows.
        static let count = allCases.count
    }

    // Allocation bookkeeping
    var isActive: Bool = false
    var midi: Int = 0
    var isReleasing: Bool = false
    /// Monotonic start counter; smaller = older.
    var age: UInt64 = 0
    /// Current peak partial amplitude (updated once per sub-block), used for voice stealing.
    var level: Float = 0
    /// Render-queue tag of the producer that struck the note (anonymous note-offs release only their own tag).
    var tag: UInt32 = 0
    /// Identity of the strike (0 = anonymous); a note-off naming it releases only this voice.
    var strikeID: UInt32 = 0
    /// Partials below the Nyquist guard, fixed at `start`.
    private(set) var activePartialCount = 0

    /// Partial state; `bankFloats` floats owned by the caller.
    let bank: UnsafeMutablePointer<Float>
    /// Groups of `partialGroupSize` partials still generated (shrinks as the top partials decay away).
    private var activeGroups = 0
    /// Samples left in the current sub-block (0 = start a new one before rendering).
    private var subBlockLeft = 0

    // Attack ramp
    private var attackRemaining: Int = 0
    private var attackGain: Float = 0
    private var attackStep: Float = 0

    // Hammer noise burst
    private var hammerRemaining: Int = 0
    private var hammerAmp: Float = 0
    private var hammerDecay: Float = 1
    private var hammerLowpass: Float = 0
    private var hammerLowpassCoefficient: Float = 0
    private var noiseState: UInt32 = 0x9E37_79B9

    /// An idle voice whose partial state lives in `bank` (at least `bankFloats` floats, caller-owned).
    init(bank: UnsafeMutablePointer<Float>) {
        self.bank = bank
    }

    @inline(__always)
    private func row(_ field: BankField) -> UnsafeMutablePointer<Float> {
        bank + field.rawValue * AudioSynthVoice.partialCount
    }

    /// Starts (or restrikes) the voice.
    ///
    /// - Parameters:
    ///   - midi: MIDI note number.
    ///   - velocity: 0…1; drives loudness and spectral brightness.
    ///   - sampleRate: render sample rate in Hz.
    ///   - a4: tuning reference in Hz.
    ///   - age: allocation counter from the owner.
    ///   - tag: producer tag of the strike.
    ///   - strikeID: strike identity (0 = anonymous).
    mutating func start(midi: Int, velocity: Float, sampleRate: Float, a4: Float, age: UInt64, tag: UInt32 = 0, strikeID: UInt32 = 0) {
        let partials = AudioSynthVoice.partialCount
        let vel = max(0.02, min(1, velocity))
        let f0 = a4 * powf(2, Float(midi - 69) / 12)
        let keyPosition = max(0, min(1, Float(midi - 21) / 87))           // 0 = A0 … 1 = C8
        let inharmonicity: Float = 0.00008 * powf(2, keyPosition * 8)      // ≈8e-5 in the bass … 2e-2 in the treble
        let brightnessExponent: Float = 0.9 + 1.4 * (1 - vel)              // loud = bright, soft = dark
        let hammerPosition: Float = 0.12                                   // strike point along the string
        let tau0 = max(0.3, min(9.0, 5.0 * powf(2, -Float(midi - 48) / 16))) // seconds; bass rings longer
        let nyquistGuard = 0.45 * sampleRate
        let strikeNormalization = 1 / max(0.05, abs(sinf(.pi * hammerPosition)))
        let block = Float(AudioSynthVoice.subBlockLength)
        let gain: Float = 0.11 * (0.12 + 0.88 * powf(vel, 1.5))

        let cosine = row(.cosine), sine = row(.sine), x = row(.x), y = row(.y)
        let envFast = row(.envelopeFast), envSlow = row(.envelopeSlow)
        let decayFast = row(.blockDecayFast), decaySlow = row(.blockDecaySlow)
        let amplitude = row(.amplitude), step = row(.amplitudeStep)

        var count = 0
        var peak: Float = 0
        var k = 0
        while k < partials {
            let n = Float(k + 1)
            let fn = n * f0 * sqrtf(1 + inharmonicity * n * n)
            // Partial frequencies rise monotonically with n, so the first one past the guard ends the bank.
            if count == k && fn < nyquistGuard {
                let strike = abs(sinf(.pi * n * hammerPosition)) * strikeNormalization
                let partialAmplitude = strike / powf(n, brightnessExponent)
                var tauN = tau0 / (1 + 0.4 * (n - 1))
                tauN /= (1 + fn / 4000)                                    // high frequencies lose energy faster
                let tauFast = tauN * 0.12
                let omega = 2 * Float.pi * fn / sampleRate
                cosine[k] = cosf(omega)
                sine[k] = sinf(omega)
                envFast[k] = partialAmplitude * 0.75 * gain
                envSlow[k] = partialAmplitude * 0.55 * gain
                decayFast[k] = expf(-block / (tauFast * sampleRate))
                decaySlow[k] = expf(-block / (tauN * sampleRate))
                count += 1
            } else {
                // Unused lane: a silent, non-rotating partial (keeps the 4-wide groups branch-free).
                cosine[k] = 1
                sine[k] = 0
                envFast[k] = 0
                envSlow[k] = 0
                decayFast[k] = 1
                decaySlow[k] = 1
            }
            x[k] = 1
            y[k] = 0
            amplitude[k] = envFast[k] + envSlow[k]
            step[k] = 0
            peak = max(peak, amplitude[k])
            k += 1
        }

        self.midi = midi
        self.isActive = true
        self.isReleasing = false
        self.age = age
        self.tag = tag
        self.strikeID = strikeID
        self.activePartialCount = count
        self.activeGroups = (count + AudioSynthVoice.partialGroupSize - 1) / AudioSynthVoice.partialGroupSize
        self.subBlockLeft = 0
        self.level = peak

        let attackSamples = max(8, Int(0.002 * sampleRate))
        self.attackRemaining = attackSamples
        self.attackGain = 0
        self.attackStep = 1 / Float(attackSamples)

        self.hammerRemaining = max(16, Int(0.012 * sampleRate))
        self.hammerAmp = 0.09 * vel * vel * gain                     // partial amplitudes include `gain` too
        self.hammerDecay = expf(-1 / (0.004 * sampleRate))
        let cutoff = max(800, min(8000, 4 * f0))
        self.hammerLowpassCoefficient = 1 - expf(-2 * .pi * cutoff / sampleRate)
        self.hammerLowpass = 0
        self.noiseState = 0x9E37_79B9 ^ UInt32(truncatingIfNeeded: age &* 2_654_435_761) | 1
    }

    /// Key released: start the damper tail (ignored for undamped treble keys, which ring out). Takes effect at
    /// the next sub-block boundary (at most `subBlockLength` samples later).
    ///
    /// - Parameter force: damp even an undamped treble key, with a shorter tail. Used when the same key is
    ///   struck again (the new strike replaces the string's previous vibration) so restrikes never click.
    mutating func release(sampleRate: Float, force: Bool = false) {
        guard isActive else { return }
        let block = Float(AudioSynthVoice.subBlockLength)
        let lanes = activeGroups * AudioSynthVoice.partialGroupSize
        let decayFast = row(.blockDecayFast), decaySlow = row(.blockDecaySlow)
        if force {
            let damp = expf(-block / (AudioSynthVoice.restrikeReleaseSeconds * sampleRate))
            isReleasing = true
            var k = 0
            while k < lanes {
                decayFast[k] = damp
                decaySlow[k] = damp
                k += 1
            }
            hammerRemaining = 0
            return
        }
        guard !isReleasing, midi < AudioSynthVoice.undampedFromMIDI else { return }
        isReleasing = true
        let releaseCoefficient = expf(-block / (AudioSynthVoice.releaseSeconds * sampleRate))
        var k = 0
        while k < lanes {
            decayFast[k] *= releaseCoefficient
            decaySlow[k] *= releaseCoefficient
            k += 1
        }
    }

    /// Hard stop (no tail), used when the engine resets.
    mutating func kill() {
        isActive = false
        isReleasing = false
        level = 0
        activeGroups = 0
        subBlockLeft = 0
        attackRemaining = 0
        hammerRemaining = 0
        strikeID = 0
    }

    /// Advances the envelopes by one sub-block: sets each partial's linear ramp towards its next envelope
    /// value, re-normalizes the rotators, updates `level`, drops fully decayed top partials and frees the voice
    /// once it is silent.
    private mutating func beginSubBlock() {
        let x = row(.x), y = row(.y)
        let envFast = row(.envelopeFast), envSlow = row(.envelopeSlow)
        let decayFast = row(.blockDecayFast), decaySlow = row(.blockDecaySlow)
        let amplitude = row(.amplitude), step = row(.amplitudeStep)
        let inverseBlock = 1 / Float(AudioSynthVoice.subBlockLength)
        let lanes = activeGroups * AudioSynthVoice.partialGroupSize
        var peak: Float = 0
        var k = 0
        while k < lanes {
            let fast = envFast[k] * decayFast[k]
            let slow = envSlow[k] * decaySlow[k]
            envFast[k] = fast
            envSlow[k] = slow
            let current = amplitude[k]
            step[k] = (fast + slow - current) * inverseBlock
            if current > peak { peak = current }
            // One Newton step towards |x + iy| = 1 cancels the rotation's rounding drift.
            let xk = x[k], yk = y[k]
            let correction = 1.5 - 0.5 * (xk * xk + yk * yk)
            x[k] = xk * correction
            y[k] = yk * correction
            k += 1
        }
        level = peak
        // Envelopes only decay, so a group whose partials are all below the floor stays inaudible for good.
        let group = AudioSynthVoice.partialGroupSize
        while activeGroups > 0 {
            let base = (activeGroups - 1) * group
            var audible = false
            var j = 0
            while j < group {
                if amplitude[base + j] >= AudioSynthVoice.partialFloor { audible = true }
                j += 1
            }
            if audible { break }
            activeGroups -= 1
        }
        subBlockLeft = AudioSynthVoice.subBlockLength
        if level < AudioSynthVoice.silenceLevel && attackRemaining == 0 && hammerRemaining == 0 {
            isActive = false
            isReleasing = false
            level = 0
            strikeID = 0
        }
    }

    /// Writes `count` samples of the partial bank into `scratch[0..<count]` (overwriting it). `count` must
    /// not exceed the samples left in the current sub-block.
    private func renderPartials(count: Int, into scratch: UnsafeMutablePointer<Float>) {
        var i = 0
        while i < count {
            scratch[i] = 0
            i += 1
        }
        let cosine = row(.cosine), sine = row(.sine), x = row(.x), y = row(.y)
        let amplitude = row(.amplitude), step = row(.amplitudeStep)
        var g = 0
        while g < activeGroups {
            let b = g * AudioSynthVoice.partialGroupSize
            let c0 = cosine[b], c1 = cosine[b + 1], c2 = cosine[b + 2], c3 = cosine[b + 3]
            let s0 = sine[b], s1 = sine[b + 1], s2 = sine[b + 2], s3 = sine[b + 3]
            var x0 = x[b], x1 = x[b + 1], x2 = x[b + 2], x3 = x[b + 3]
            var y0 = y[b], y1 = y[b + 1], y2 = y[b + 2], y3 = y[b + 3]
            var a0 = amplitude[b], a1 = amplitude[b + 1], a2 = amplitude[b + 2], a3 = amplitude[b + 3]
            let d0 = step[b], d1 = step[b + 1], d2 = step[b + 2], d3 = step[b + 3]
            var n = 0
            while n < count {
                let nx0 = x0 * c0 - y0 * s0
                y0 = x0 * s0 + y0 * c0
                x0 = nx0
                let nx1 = x1 * c1 - y1 * s1
                y1 = x1 * s1 + y1 * c1
                x1 = nx1
                let nx2 = x2 * c2 - y2 * s2
                y2 = x2 * s2 + y2 * c2
                x2 = nx2
                let nx3 = x3 * c3 - y3 * s3
                y3 = x3 * s3 + y3 * c3
                x3 = nx3
                a0 += d0
                a1 += d1
                a2 += d2
                a3 += d3
                scratch[n] += (a0 * y0 + a1 * y1) + (a2 * y2 + a3 * y3)
                n += 1
            }
            x[b] = x0; x[b + 1] = x1; x[b + 2] = x2; x[b + 3] = x3
            y[b] = y0; y[b + 1] = y1; y[b + 2] = y2; y[b + 3] = y3
            amplitude[b] = a0; amplitude[b + 1] = a1; amplitude[b + 2] = a2; amplitude[b + 3] = a3
            g += 1
        }
    }

    /// Adds `count` samples starting at `out[start]`. `scratch` must hold at least `subBlockLength` floats
    /// and is clobbered. Real-time safe.
    mutating func render(into out: UnsafeMutablePointer<Float>, start: Int, count: Int, scratch: UnsafeMutablePointer<Float>) {
        guard isActive, count > 0 else { return }
        var done = 0
        while done < count {
            if subBlockLeft == 0 {
                beginSubBlock()
                guard isActive else { return }
            }
            let n = min(subBlockLeft, count - done)
            renderPartials(count: n, into: scratch)
            let target = out + start + done
            var i = 0
            if attackRemaining == 0 && hammerRemaining == 0 {
                while i < n {
                    target[i] += scratch[i]
                    i += 1
                }
            } else {
                while i < n {
                    var s = scratch[i]
                    if attackRemaining > 0 {
                        attackGain += attackStep
                        attackRemaining -= 1
                        s *= attackGain
                    }
                    if hammerRemaining > 0 {
                        // xorshift32 noise through a one-pole low-pass.
                        var r = noiseState
                        r ^= r << 13
                        r ^= r >> 17
                        r ^= r << 5
                        noiseState = r
                        let white = Float(Int32(bitPattern: r)) * (1.0 / 2_147_483_648.0)
                        hammerLowpass += hammerLowpassCoefficient * (white - hammerLowpass)
                        s += hammerLowpass * hammerAmp
                        hammerAmp *= hammerDecay
                        hammerRemaining -= 1
                    }
                    target[i] += s
                    i += 1
                }
            }
            subBlockLeft -= n
            done += n
        }
    }
}

// MARK: - Allocation

/// The subset of voice state the allocator looks at. `AudioSynthVoice` conforms; tests can use it directly
/// or with a lighter stand-in.
protocol AudioVoiceDescribing {
    var isActive: Bool { get }
    var midi: Int { get }
    var isReleasing: Bool { get }
    /// Current envelope level (0 = silent).
    var level: Float { get }
    /// Allocation counter; smaller = started earlier.
    var age: UInt64 { get }
}

/// Pure voice-allocation policy (no state): decides which voice a new note takes.
///
/// Order of preference:
/// 1. Any free voice.
/// 2. The quietest voice that is already releasing.
/// 3. The quietest voice overall; ties go to the oldest.
///
/// A restruck key does not reuse its old voice: the render state damps the old voice quickly and the new
/// strike gets a fresh voice, so the two overlap for a few milliseconds instead of clicking.
enum AudioSynthVoiceAllocator {
    /// Index of the voice to use for a new note. Returns nil only for an empty collection.
    static func voiceIndex<C: RandomAccessCollection>(forNewNote midi: Int, in voices: C) -> C.Index? where C.Element: AudioVoiceDescribing {
        guard !voices.isEmpty else { return nil }
        var releasing: C.Index? = nil
        var releasingLevel: Float = .greatestFiniteMagnitude
        var releasingAge: UInt64 = .max
        var quietest: C.Index? = nil
        var quietestLevel: Float = .greatestFiniteMagnitude
        var quietestAge: UInt64 = .max

        var i = voices.startIndex
        while i < voices.endIndex {
            let v = voices[i]
            if !v.isActive { return i }
            if v.isReleasing, v.level < releasingLevel || (v.level == releasingLevel && v.age < releasingAge) {
                releasing = i
                releasingLevel = v.level
                releasingAge = v.age
            }
            if v.level < quietestLevel || (v.level == quietestLevel && v.age < quietestAge) {
                quietest = i
                quietestLevel = v.level
                quietestAge = v.age
            }
            i = voices.index(after: i)
        }
        return releasing ?? quietest ?? voices.startIndex
    }
}

// MARK: - Metronome click voice

/// A short tonal click (sine burst with a noise transient). One instance is enough; a new click restarts it.
struct AudioClickVoice {
    var isActive = false
    var phase: Float = 0
    var increment: Float = 0
    var amp: Float = 0
    var decay: Float = 1
    var noiseAmp: Float = 0
    var noiseDecay: Float = 1
    var noiseState: UInt32 = 0x1234_5678

    /// Silences the click immediately.
    mutating func reset() {
        isActive = false
        amp = 0
        noiseAmp = 0
    }

    /// Starts a click. Accented clicks are higher and louder.
    mutating func trigger(accented: Bool, sampleRate: Float) {
        isActive = true
        phase = 0
        increment = (accented ? 1800 : 1200) / sampleRate
        amp = accented ? 0.55 : 0.36
        decay = expf(-1 / ((accented ? 0.030 : 0.022) * sampleRate))
        noiseAmp = accented ? 0.25 : 0.18
        noiseDecay = expf(-1 / (0.0025 * sampleRate))
    }

    /// Adds `count` samples starting at `out[start]`. Real-time safe.
    @inline(__always)
    mutating func render(into out: UnsafeMutablePointer<Float>, start: Int, count: Int) {
        guard isActive, count > 0 else { return }
        var i = start
        let end = start + count
        while i < end {
            phase += increment
            if phase >= 1 { phase -= 1 }
            let t = phase * 2 - 1
            var y = 4 * t * (1 - abs(t))
            y *= 0.775 + 0.225 * abs(y)
            var x = noiseState
            x ^= x << 13
            x ^= x >> 17
            x ^= x << 5
            noiseState = x
            let white = Float(Int32(bitPattern: x)) * (1.0 / 2_147_483_648.0)
            out[i] += y * amp + white * noiseAmp
            amp *= decay
            noiseAmp *= noiseDecay
            i += 1
        }
        if amp < 1e-4 { isActive = false }
    }
}
