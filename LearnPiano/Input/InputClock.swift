import Darwin
import Foundation

/// Converts mach host time (the clock CoreMIDI packets and `AVAudioTime` carry) to monotonic seconds.
///
/// Every Input source stamps its `NoteInputEvent`s with this clock so events from a MIDI keyboard, the
/// microphone and the on-screen keyboard are directly comparable. The origin is arbitrary (system boot)
/// and the clock does not advance while the device sleeps, exactly like `ProcessInfo.systemUptime`, which
/// Core's `SystemPracticeClock` uses.
enum InputClock {
    /// Numerator/denominator that turn mach ticks into nanoseconds.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Seconds for a mach host-time value. A host time of 0 (CoreMIDI's "now") maps to the current time.
    static func seconds(hostTime: UInt64) -> TimeInterval {
        if hostTime == 0 { return now }
        let tb = timebase
        guard tb.denom != 0 else { return TimeInterval(hostTime) / 1e9 }
        // Computed in Double to avoid overflowing UInt64 when multiplying by the numerator.
        return TimeInterval(hostTime) * TimeInterval(tb.numer) / TimeInterval(tb.denom) / 1e9
    }

    /// Mach host-time value for a time in seconds on this clock (inverse of `seconds(hostTime:)`).
    static func hostTime(seconds: TimeInterval) -> UInt64 {
        let tb = timebase
        guard tb.numer != 0, seconds > 0 else { return 0 }
        return UInt64(seconds * 1e9 * TimeInterval(tb.denom) / TimeInterval(tb.numer))
    }

    /// The current monotonic time in seconds.
    static var now: TimeInterval { seconds(hostTime: mach_absolute_time()) }
}
