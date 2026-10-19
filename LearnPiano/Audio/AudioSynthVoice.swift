import Foundation

// MARK: - Voice state

/// One polyphonic voice of the additive piano model. A voice is a bank of 16 inharmonic partials, each with
/// its own "prompt sound" (fast-decaying) and "aftersound" (slow-decaying) amplitude, plus a short filtered
/// noise burst for the hammer strike. Everything is fixed-size value storage, so the render thread can own
/// an array of these without allocating.
///
/// The model is sustain-free: a held key simply decays naturally; releasing it damps the string with a short
/// release tail (except above F6, where real pianos have no dampers and the note rings out).
struct AudioSynthVoice: AudioVoiceDescribing {
    /// Partials per voice (SIMD lanes).
    static let partialCount = 16
    /// Lowest key that has no damper (F6): note-off is ignored for it and above.
    static let undampedFromMIDI = 89
    /// Below this envelope level a voice counts as silent and is freed.
    static let silenceLevel: Float = 1e-4
    /// Time constant of the damper after a key release (seconds).
    static let releaseSeconds: Float = 0.09
    /// Time constant of the quick damp applied to a voice whose key is struck again (seconds).
    static let restrikeReleaseSeconds: Float = 0.03

    // Allocation bookkeeping
    var isActive: Bool = false
    var midi: Int = 0
    var isReleasing: Bool = false
    /// Monotonic start counter; smaller = older.
    var age: UInt64 = 0
    /// Current peak envelope level (updated once per render block), used for voice stealing.
    var level: Float = 0

    // Oscillator bank (normalized phase 0…1 per partial)
    var phase = SIMD16<Float>(repeating: 0)
    var phaseIncrement = SIMD16<Float>(repeating: 0)
    var ampFast = SIMD16<Float>(repeating: 0)
    var ampSlow = SIMD16<Float>(repeating: 0)
    var decayFast = SIMD16<Float>(repeating: 1)
    var decaySlow = SIMD16<Float>(repeating: 1)

    // Output scaling and attack ramp
    var gain: Float = 0
    var attackRemaining: Int = 0
    var attackGain: Float = 0
    var attackStep: Float = 0

    // Hammer noise burst
    var hammerRemaining: Int = 0
    var hammerAmp: Float = 0
    var hammerDecay: Float = 1
    var hammerLowpass: Float = 0
    var hammerLowpassCoefficient: Float = 0
    var noiseState: UInt32 = 0x9E37_79B9

    /// Idle voice.
    init() {}

    /// Starts (or restrikes) the voice.
    ///
    /// - Parameters:
    ///   - midi: MIDI note number.
    ///   - velocity: 0…1; drives loudness and spectral brightness.
    ///   - sampleRate: render sample rate in Hz.
    ///   - a4: tuning reference in Hz.
    ///   - age: allocation counter from the owner.
    mutating func start(midi: Int, velocity: Float, sampleRate: Float, a4: Float, age: UInt64) {
        let vel = max(0.02, min(1, velocity))
        let f0 = a4 * powf(2, Float(midi - 69) / 12)
        let keyPosition = max(0, min(1, Float(midi - 21) / 87))           // 0 = A0 … 1 = C8
        let inharmonicity: Float = 0.00008 * powf(2, keyPosition * 8)      // ≈8e-5 in the bass … 2e-2 in the treble
        let brightnessExponent: Float = 0.9 + 1.4 * (1 - vel)              // loud = bright, soft = dark
        let hammerPosition: Float = 0.12                                   // strike point along the string
        let tau0 = max(0.3, min(9.0, 5.0 * powf(2, -Float(midi - 48) / 16))) // seconds; bass rings longer
        let nyquistGuard = 0.45 * sampleRate
        let strikeNormalization = 1 / max(0.05, abs(sinf(.pi * hammerPosition)))

        var inc = SIMD16<Float>(repeating: 0)
        var fast = SIMD16<Float>(repeating: 0)
        var slow = SIMD16<Float>(repeating: 0)
        var dFast = SIMD16<Float>(repeating: 1)
        var dSlow = SIMD16<Float>(repeating: 1)
        for i in 0..<AudioSynthVoice.partialCount {
            let n = Float(i + 1)
            let fn = n * f0 * sqrtf(1 + inharmonicity * n * n)
            guard fn < nyquistGuard else { continue }
            let strike = abs(sinf(.pi * n * hammerPosition)) * strikeNormalization
            let amplitude = strike / powf(n, brightnessExponent)
            var tauN = tau0 / (1 + 0.4 * (n - 1))
            tauN /= (1 + fn / 4000)                                        // high frequencies lose energy faster
            let tauFast = tauN * 0.12
            inc[i] = fn / sampleRate
            slow[i] = amplitude * 0.55
            fast[i] = amplitude * 0.75
            dSlow[i] = expf(-1 / (tauN * sampleRate))
            dFast[i] = expf(-1 / (tauFast * sampleRate))
        }

        self.midi = midi
        self.isActive = true
        self.isReleasing = false
        self.age = age
        self.phase = SIMD16<Float>(repeating: 0)
        self.phaseIncrement = inc
        self.ampFast = fast
        self.ampSlow = slow
        self.decayFast = dFast
        self.decaySlow = dSlow
        self.gain = 0.11 * (0.12 + 0.88 * powf(vel, 1.5))
        self.level = (fast + slow).max() * gain

        let attackSamples = max(8, Int(0.002 * sampleRate))
        self.attackRemaining = attackSamples
        self.attackGain = 0
        self.attackStep = 1 / Float(attackSamples)

        self.hammerRemaining = max(16, Int(0.012 * sampleRate))
        self.hammerAmp = 0.09 * vel * vel
        self.hammerDecay = expf(-1 / (0.004 * sampleRate))
        let cutoff = max(800, min(8000, 4 * f0))
        self.hammerLowpassCoefficient = 1 - expf(-2 * .pi * cutoff / sampleRate)
        self.hammerLowpass = 0
        self.noiseState = 0x9E37_79B9 ^ UInt32(truncatingIfNeeded: age &* 2_654_435_761) | 1
    }

    /// Key released: start the damper tail (ignored for undamped treble keys, which ring out).
    ///
    /// - Parameter force: damp even an undamped treble key, with a shorter tail. Used when the same key is
    ///   struck again (the new strike replaces the string's previous vibration) so restrikes never click.
    mutating func release(sampleRate: Float, force: Bool = false) {
        guard isActive else { return }
        if force {
            let damp = expf(-1 / (AudioSynthVoice.restrikeReleaseSeconds * sampleRate))
            isReleasing = true
            decaySlow = SIMD16<Float>(repeating: damp)
            decayFast = SIMD16<Float>(repeating: damp)
            hammerRemaining = 0
            return
        }
        guard !isReleasing, midi < AudioSynthVoice.undampedFromMIDI else { return }
        isReleasing = true
        let releaseCoefficient = expf(-1 / (AudioSynthVoice.releaseSeconds * sampleRate))
        decaySlow = decaySlow * releaseCoefficient
        decayFast = decayFast * releaseCoefficient
    }

    /// Hard stop (no tail), used when the engine resets.
    mutating func kill() {
        isActive = false
        isReleasing = false
        level = 0
        ampFast = SIMD16<Float>(repeating: 0)
        ampSlow = SIMD16<Float>(repeating: 0)
        hammerRemaining = 0
    }

    /// Adds `count` samples starting at `out[start]`. Real-time safe.
    @inline(__always)
    mutating func render(into out: UnsafeMutablePointer<Float>, start: Int, count: Int) {
        guard isActive, count > 0 else { return }
        let two = SIMD16<Float>(repeating: 2)
        let one = SIMD16<Float>(repeating: 1)
        let four = SIMD16<Float>(repeating: 4)
        let c0 = SIMD16<Float>(repeating: 0.775)
        let c1 = SIMD16<Float>(repeating: 0.225)
        var p = phase
        var aF = ampFast
        var aS = ampSlow
        let dF = decayFast
        let dS = decaySlow
        let inc = phaseIncrement
        var i = start
        let end = start + count
        while i < end {
            p += inc
            p -= p.rounded(.down)
            // Parabolic sine approximation of sin(2πp) on normalized phase (error < 0.1 %).
            let t = p * two - one
            var y = four * t * (one - pointwiseMax(t, -t))
            y = y * (c0 + c1 * pointwiseMax(y, -y))
            aF = aF * dF
            aS = aS * dS
            var s = ((aF + aS) * y).sum()
            if attackRemaining > 0 {
                attackGain += attackStep
                attackRemaining -= 1
                s *= attackGain
            }
            if hammerRemaining > 0 {
                // xorshift32 noise through a one-pole low-pass.
                var x = noiseState
                x ^= x << 13
                x ^= x >> 17
                x ^= x << 5
                noiseState = x
                let white = Float(Int32(bitPattern: x)) * (1.0 / 2_147_483_648.0)
                hammerLowpass += hammerLowpassCoefficient * (white - hammerLowpass)
                s += hammerLowpass * hammerAmp
                hammerAmp *= hammerDecay
                hammerRemaining -= 1
            }
            out[i] += s * gain
            i += 1
        }
        phase = p
        ampFast = aF
        ampSlow = aS
        level = (aF + aS).max() * gain
        if level < AudioSynthVoice.silenceLevel && attackRemaining == 0 && hammerRemaining == 0 {
            isActive = false
            isReleasing = false
            level = 0
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
