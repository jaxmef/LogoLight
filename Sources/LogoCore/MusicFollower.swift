import Foundation

/// Drives the logo from an audio source at ~60 Hz.
public final class MusicFollower {
    /// Same scale as `LogoController.dutyPercent(forBrightness:)`.
    public var maxBrightness: Double {
        get { outQueue.sync { _maxBrightness } }
        set { outQueue.async { self._maxBrightness = newValue } }
    }
    public var currentBrightness: Double { outQueue.sync { _currentBrightness } }
    public var currentLevel: Float { outQueue.sync { _currentLevel } }
    /// Also true after a failed resume, so the caller can retry.
    public var isPaused: Bool { outQueue.sync { paused } }
    public var isRunning: Bool { outQueue.sync { timer != nil } }
    public var onError: ((Error) -> Void)?

    private let logo: LogoController
    private let source: AudioLevelSource
    private let bassWeight: Float = 0.65

    // Written by the audio callback, read by ticks.
    private let lock = NSLock()
    private var latestLevel: Float = 0
    private var lastAudioAt = Date.distantPast

    // Only touched on outQueue.
    private let outQueue = DispatchQueue(label: "io.github.jaxmef.LogoLight.music", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var paused = false
    private var envelope = MusicEnvelope()
    private var lastHigh = -1
    private var _maxBrightness: Double
    private var _currentBrightness = 0.0
    private var _currentLevel: Float = 0

    public init(logo: LogoController, source: AudioLevelSource, maxBrightness: Double) {
        self.logo = logo
        self.source = source
        _maxBrightness = maxBrightness
    }

    public func start() throws {
        guard !isRunning else { return }
        try logo.setCustom(brightness: MusicEnvelope.floor)
        try source.start { [weak self] full, bass in
            guard let self else { return }
            let level = self.bassWeight * bass * 2.2 + (1 - self.bassWeight) * full   // bass RMS runs lower
            self.lock.lock()
            self.latestLevel = max(self.latestLevel, level)   // hold the peak until the next tick
            if full > 1e-4 { self.lastAudioAt = Date() }
            self.lock.unlock()
        }
        let tm = DispatchSource.makeTimerSource(queue: outQueue)
        tm.schedule(deadline: .now(), repeating: .milliseconds(16))
        tm.setEventHandler { [weak self] in self?.tick(dt: 0.016) }
        outQueue.sync { paused = false; timer = tm }
        tm.resume()
    }

    /// Returns once no tick can write anymore, so the caller can safely set Off or Default next.
    public func stop() {
        outQueue.sync {
            timer?.cancel()
            timer = nil
            paused = true
            lastHigh = -1
        }
        source.stop()
    }

    /// Pausing is synchronous (no writes after it returns). Resuming re-takes the logo asynchronously.
    public func setPaused(_ p: Bool) {
        if p {
            outQueue.sync { paused = true; lastHigh = -1 }
        } else {
            outQueue.async { [weak self] in
                guard let self else { return }
                self.lastHigh = -1
                do {
                    try self.logo.setCustom(brightness: MusicEnvelope.floor)
                    self.paused = false
                } catch {
                    self.onError?(error)
                }
            }
        }
    }

    public var secondsSinceAudio: Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastAudioAt)
    }

    private func tick(dt: Double) {
        guard !paused else { return }
        lock.lock()
        let level = latestLevel
        latestLevel = 0
        let silent = Date().timeIntervalSince(lastAudioAt) > 2
        lock.unlock()

        let b = envelope.next(level: level, silent: silent, dt: dt, maxBrightness: _maxBrightness)
        _currentLevel = level
        _currentBrightness = b
        let duty = LogoController.dutyPercent(forBrightness: b)
        let high = LogoPWM.expectedHighPeriod(percent: duty)
        guard high != lastHigh else { return }   // skip writes the hardware can't show
        do {
            try logo.pwm.setDuty(percent: duty)
            lastHigh = high
        } catch {
            onError?(error)
        }
    }
}
