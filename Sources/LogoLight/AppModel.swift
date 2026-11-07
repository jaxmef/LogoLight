import AppKit
import IOKit
import IOKit.pwr_mgt
import Foundation
import os
import LogoCore

final class AppModel: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case system, custom, music, off
        var id: String { rawValue }
        var title: String { ["system": "Default", "custom": "Custom", "music": "Music", "off": "Off"][rawValue]! }
        /// LogoLight drives the light itself, so it must also turn it off for lid close and sleep.
        var drivesPWM: Bool { self == .custom || self == .music }
    }

    static let shared = AppModel()

    @Published var choice: Choice { didSet { if choice != oldValue { save(); apply() } } }
    @Published var brightness: Double {
        didSet {
            guard brightness != oldValue else { return }
            save()
            if choice == .custom { apply() }
            follower?.maxBrightness = brightness
        }
    }
    @Published private(set) var lastError: String?
    private(set) var isSupported = true

    static let minBrightness = LogoController.minBrightness

    var brightnessPercent: Int { Int(LogoController.percent(forBrightness: brightness).rounded()) }
    @Published private(set) var musicHint: String?

    private var logo: LogoController?
    private var follower: MusicFollower?
    private var timer: Timer?
    private var screensAsleep = false
    private let defaults = UserDefaults.standard
    /// LOGOLIGHT_TEST_BEAT=1: Music follows a synthetic beat, for testing without audio permission.
    private let testBeat = ProcessInfo.processInfo.environment["LOGOLIGHT_TEST_BEAT"] == "1"

    private init() {
        choice = Choice(rawValue: defaults.string(forKey: "choice") ?? "") ?? .system
        brightness = min(max(defaults.object(forKey: "brightness") as? Double ?? 0.5, Self.minBrightness), 1)
        do {
            logo = try LogoController()
        } catch {
            isSupported = false
            Self.log.error("logo control unavailable: \(String(describing: error), privacy: .public)")
            lastError = "This Mac doesn't have an Apple logo LogoLight can control. It needs a MacBook Pro with OLED display."
        }
        observeSystem()
        // macOS may take the logo back (e.g. on wake), so re-check regularly.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reassert() }
        if choice != .system { apply() }
        refreshStatus()
    }

    private func save() {
        defaults.set(choice.rawValue, forKey: "choice")
        defaults.set(brightness, forKey: "brightness")
    }

    func apply() {
        guard let logo else { return }
        if choice != .music { stopMusic() }
        do {
            switch choice {
            case .system: try logo.setDefault()
            case .off: try logo.setOff()
            case .custom:
                if !screensAsleep && LogoController.clamshellClosed() != true {
                    try logo.setCustom(brightness: brightness)
                }
            case .music:
                if !screensAsleep && LogoController.clamshellClosed() != true { try startMusic() }
            }
            lastError = nil
        } catch {
            report(error, choice == .music ? Self.musicFailed : Self.changeFailed)
        }
        refreshStatus()
    }

    private static let changeFailed = "Couldn't change the logo. Try Default, or quit and reopen LogoLight."
    private static let musicFailed = "Couldn't start Music. Try another mode, or quit and reopen LogoLight."

    private func report(_ error: Error, _ message: String) {
        Self.log.error("\(message, privacy: .public) (\(String(describing: error), privacy: .public))")
        if lastError != message { lastError = message }
    }

    private func startMusic() throws {
        guard follower == nil, let logo else { return }
        let source: AudioLevelSource = testBeat ? TestBeatSource() : SystemAudioTap()
        let f = MusicFollower(logo: logo, source: source, maxBrightness: brightness)
        f.onError = { [weak self] err in DispatchQueue.main.async { self?.report(err, Self.changeFailed) } }
        try f.start()
        follower = f
        Self.log.notice("music started (\(self.testBeat ? "test beat" : "system audio", privacy: .public))")
    }

    private func stopMusic() {
        guard let f = follower else { return }
        f.stop()
        follower = nil
        musicHint = nil
        Self.log.notice("music stopped")
    }

    private func reassert() {
        defer { refreshStatus() }
        guard let logo, !screensAsleep, !outputPaused, LogoController.clamshellClosed() != true else { return }
        switch choice {
        case .custom where !logo.isApplied(brightness: brightness): apply()
        case .off where logo.cb.mode != 0: apply()
        case .music:
            if follower == nil { apply() }
            // macOS took the logo back, or an earlier resume failed.
            else if follower?.isPaused == true || logo.cb.mode != 0 || logo.pwm.state()?.enabled != true {
                follower?.setPaused(false)
            }
        default: break
        }
    }

    func restoreOnQuit() {
        stopMusic()
        guard choice != .system, let logo else { return }
        do { try logo.setDefault() } catch {
            Self.log.error("restoring Default on quit failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: lid / sleep / display sleep
    //
    // In mode 0 macOS doesn't turn the logo off on lid close or sleep, so the app does it and re-applies on wake/open.

    private static let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
    private static let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
    private static let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
    private static let kIOPMMessageClamshellStateChange: UInt32 = 0xE003_4100   // iokit_family_msg(sub_iokit_powermanagement, 0x100)

    private var rootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var clamshellNotifyPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = 0
    private var outputPaused = false
    private static let log = Logger(subsystem: "io.github.jaxmef.LogoLight", category: "control")

    private func pauseOutput(_ why: String) {
        guard choice.drivesPWM, let logo, !outputPaused else { return }
        outputPaused = true
        follower?.setPaused(true)
        do { try logo.setOff() } catch {
            Self.log.error("turning the logo off (\(why, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
        Self.log.notice("paused (\(why, privacy: .public))")
    }

    private func resumeOutput(_ why: String, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !self.screensAsleep, LogoController.clamshellClosed() != true else { return }
            self.outputPaused = false
            Self.log.notice("resume (\(why, privacy: .public))")
            if self.choice == .music, let f = self.follower { f.setPaused(false) } else { self.reassert() }
        }
    }

    private func observePower() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &powerNotifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let model = Unmanaged<AppModel>.fromOpaque(refcon).takeUnretainedValue()
            switch messageType {
            case AppModel.kIOMessageCanSystemSleep:
                IOAllowPowerChange(model.rootPort, Int(bitPattern: messageArgument))
            case AppModel.kIOMessageSystemWillSleep:
                model.pauseOutput("system will sleep")
                IOAllowPowerChange(model.rootPort, Int(bitPattern: messageArgument))
            case AppModel.kIOMessageSystemHasPoweredOn:
                model.resumeOutput("system powered on", after: 1.0)
            default: break
            }
        }, &powerNotifier)
        if let p = powerNotifyPort { IONotificationPortSetDispatchQueue(p, .main) }

        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        clamshellNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let cp = clamshellNotifyPort else { return }
        IONotificationPortSetDispatchQueue(cp, .main)
        IOServiceAddInterestNotification(cp, root, kIOGeneralInterest, { refcon, _, messageType, messageArgument in
            guard let refcon, messageType == AppModel.kIOPMMessageClamshellStateChange else { return }
            let model = Unmanaged<AppModel>.fromOpaque(refcon).takeUnretainedValue()
            let closed = (UInt(bitPattern: messageArgument) & 1) != 0          // kClamshellStateBit
            if closed { model.pauseOutput("lid closed") } else { model.resumeOutput("lid opened", after: 0.5) }
        }, refcon, &clamshellNotifier)
    }

    private func observeSystem() {
        observePower()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.pauseOutput("display sleep")
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.resumeOutput("display wake", after: 0.8)
        }
    }

    /// Runs every 2 s. Assigns only on change: @Published fires even for identical values, which re-renders the popover.
    func refreshStatus() {
        var newHint: String?
        if choice == .music, let f = follower, !testBeat, f.secondsSinceAudio > 5 {
            newHint = "No audio heard. If something is playing, allow LogoLight in System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only)."
        }
        if musicHint != newHint { musicHint = newHint }
    }
}
