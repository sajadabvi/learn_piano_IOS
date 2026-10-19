import Accelerate
import Foundation

/// Hann-windowed real FFT producing a linear magnitude spectrum, built on vDSP.
///
/// Magnitudes are normalised so that a full-scale sine (amplitude 1.0) that falls on a bin centre yields a
/// magnitude of about 1.0 in that bin, independent of the FFT size. Bin `i` is centred at `i × binWidth` Hz;
/// bin 0 (DC) is forced to zero because nothing musical lives there.
///
/// Instances own their scratch buffers and are **not** thread-safe: use one per processing queue.
final class InputSpectrumAnalyzer {
    /// Number of samples per analysis frame (a power of two).
    let fftSize: Int
    /// Sample rate of the signal being analysed.
    let sampleRate: Double
    /// Number of magnitude bins produced (`fftSize / 2`).
    let binCount: Int
    /// Width of one bin in Hz.
    var binWidth: Double { sampleRate / Double(fftSize) }
    /// Highest representable frequency.
    var nyquist: Double { sampleRate / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private var scale: Float

    /// Fails when `fftSize` is not a power of two ≥ 64 or the sample rate is not positive.
    init?(fftSize: Int = 4096, sampleRate: Double) {
        guard fftSize >= 64, fftSize & (fftSize - 1) == 0, sampleRate > 0 else { return nil }
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.binCount = fftSize / 2
        self.log2n = log2n
        self.setup = setup
        window = .allocate(capacity: fftSize)
        windowed = .allocate(capacity: fftSize)
        real = .allocate(capacity: fftSize / 2)
        imag = .allocate(capacity: fftSize / 2)
        windowed.initialize(repeating: 0, count: fftSize)
        real.initialize(repeating: 0, count: fftSize / 2)
        imag.initialize(repeating: 0, count: fftSize / 2)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        // zrip output is 2× the DFT; a Hann window sums to N/2; a sine splits between ±f: peak = A·N/2 → ×2/N.
        scale = 2 / Float(fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        real.deallocate()
        imag.deallocate()
    }

    /// Computes the magnitude spectrum of the first `fftSize` samples of `samples` into `out`.
    ///
    /// `out` is resized to `binCount` when needed. Returns false (leaving `out` zeroed) when fewer than
    /// `fftSize` samples were supplied.
    @discardableResult
    func magnitudes(of samples: UnsafeBufferPointer<Float>, into out: inout [Float]) -> Bool {
        if out.count != binCount { out = [Float](repeating: 0, count: binCount) }
        guard let base = samples.baseAddress, samples.count >= fftSize else {
            for i in out.indices { out[i] = 0 }
            return false
        }
        vDSP_vmul(base, 1, window, 1, windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { complexInput in
            vDSP_ctoz(complexInput, 2, &split, 1, vDSP_Length(binCount))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        out.withUnsafeMutableBufferPointer { outPtr in
            guard let outBase = outPtr.baseAddress else { return }
            vDSP_zvabs(&split, 1, outBase, 1, vDSP_Length(binCount))
            vDSP_vsmul(outBase, 1, &scale, outBase, 1, vDSP_Length(binCount))
        }
        out[0] = 0 // DC and Nyquist are packed into bin 0 by zrip; neither is musically useful.
        return true
    }

    /// Array convenience for `magnitudes(of:into:)`.
    @discardableResult
    func magnitudes(of samples: [Float], into out: inout [Float]) -> Bool {
        samples.withUnsafeBufferPointer { magnitudes(of: $0, into: &out) }
    }

    /// Root-mean-square level of a block of samples (0 for an empty block).
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(base, 1, &value, vDSP_Length(samples.count))
        return value
    }

    /// Frequency in Hz at the centre of a (possibly fractional) bin index.
    func frequency(ofBin bin: Double) -> Double { bin * binWidth }

    /// Fractional bin index for a frequency in Hz.
    func bin(ofFrequency hertz: Double) -> Double { hertz / binWidth }
}
