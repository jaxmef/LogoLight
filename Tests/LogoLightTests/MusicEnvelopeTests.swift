import Testing
import LogoCore
@testable import LogoMusic

/// Brightness over time for a 120 BPM beat: one loud tick per beat, quiet in between.
private func play(loudness: Float, maxBrightness: Double, seconds: Double = 6) -> [Double] {
    var env = MusicEnvelope()
    let dt = 0.016
    return (0..<Int(seconds / dt)).map { i in
        let onBeat = i % 31 == 0
        return env.next(level: onBeat ? loudness : loudness * 0.05, silent: false, dt: dt, maxBrightness: maxBrightness)
    }
}

@Test func silenceSettlesAtTheFloor() {
    var env = MusicEnvelope()
    var b = 1.0
    for _ in 0..<200 { b = env.next(level: 0, silent: true, dt: 0.016, maxBrightness: 0.8) }
    #expect(abs(b - MusicEnvelope.floor) < 0.01)
}

@Test func beatsReachThePeakAndFallBackBetween() {
    let tail = play(loudness: 0.3, maxBrightness: 0.8).suffix(100)
    #expect(tail.max()! > 0.75)
    #expect(tail.min()! < 0.4)
}

@Test func quietAndLoudTracksUseTheSameRange() {
    let quiet = play(loudness: 0.01, maxBrightness: 0.8).suffix(100).max()!
    let loud = play(loudness: 0.5, maxBrightness: 0.8).suffix(100).max()!
    #expect(abs(quiet - loud) < 0.05)
}

@Test func stillPulsesWithAPeakBelowTheFloor() {
    let peak = 0.1
    let tail = play(loudness: 0.3, maxBrightness: peak).suffix(100)
    #expect(tail.max()! - tail.min()! > 0.5 * (peak - LogoController.minBrightness))
}
