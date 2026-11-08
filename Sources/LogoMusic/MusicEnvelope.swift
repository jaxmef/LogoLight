import Foundation
import LogoCore

/// Turns audio levels into a brightness that pulses with the beat.
struct MusicEnvelope {
    static let floor = 0.12      // glow during silence
    static let attack = 0.004    // seconds; near-instant, so beats reach the peak
    static let release = 0.18    // seconds

    private var peak: Float = 1e-3
    private var envelope = 0.0

    /// - Parameters:
    ///   - level: loudness since the last call (linear RMS).
    ///   - silent: no audio for a while; fades to the floor.
    ///   - dt: seconds since the last call.
    ///   - maxBrightness: peak brightness, same scale as `LogoController.dutyPercent(forBrightness:)`.
    mutating func next(level: Float, silent: Bool, dt: Double, maxBrightness: Double) -> Double {
        // Automatic gain: the running peak decays ~6 dB per 2 s, so quiet and loud tracks both use the full range.
        peak = max(level, peak * Float(pow(0.5, dt / 2)), 1e-3)
        let target = silent ? 0 : Double(min(level / peak, 1))
        let tau = target > envelope ? Self.attack : Self.release
        envelope += (target - envelope) * (1 - exp(-dt / tau))

        // With a low peak setting, lower the floor too, so the logo still pulses.
        let lo = min(Self.floor, max(LogoController.minBrightness, maxBrightness * 0.5))
        return lo + (max(maxBrightness, lo) - lo) * envelope
    }
}
