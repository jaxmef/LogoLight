import CoreGraphics
import Foundation
import LogoCore

let usage = """
usage: logoctl status                 show mode, PWM state and CoreBrightness's light-emitter state (read-only)
       logoctl default                give the logo back to macOS (follows the display)
       logoctl off                    turn the logo off (stays off, also at startup, until 'default')
       logoctl custom <0-100>         fixed brightness in percent (0 = dimmest glow, 100 = the OS maximum)
       logoctl music <seconds> [--test] [--max <0-100>]
                                      follow system audio for 1-3600 s, then restore Default
                                      --test: synthetic 120 BPM beat instead of audio; --max: peak brightness (default 70)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("logoctl: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func fmt(_ v: Any?) -> String {
    if let n = v as? NSNumber { return String(format: "%.1f", n.doubleValue) }
    if let s = v as? String, let d = Double(s) { return String(format: "%.1f", d) }
    return "-"
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

func installStopSignals(_ flag: StopFlag) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)   // otherwise the default handler kills the process before cleanup
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { flag.set() }
        src.resume()
        return src
    }
}

/// In mode 0 macOS doesn't turn the logo off for lid close or display sleep, so we do.
func shouldBeDark() -> Bool {
    LogoController.clamshellClosed() == true || CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

struct MusicOptions {
    var seconds: Double
    var test = false
    var maxPercent = 70.0
}

func parseMusic(_ args: [String]) -> MusicOptions {
    let musicUsage = "music <seconds 1-3600> [--test] [--max <0-100>]"
    guard args.count >= 2, let secs = Double(args[1]), secs >= 1, secs <= 3600 else { fail(musicUsage) }
    var opts = MusicOptions(seconds: secs)
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--test":
            opts.test = true
        case "--max":
            guard i + 1 < args.count, let m = Double(args[i + 1]), m >= 0, m <= 100 else { fail("--max needs a number 0-100") }
            opts.maxPercent = m
            i += 1
        default:
            fail("unknown option '\(args[i])'. Usage: \(musicUsage)")
        }
        i += 1
    }
    return opts
}

/// However it ends (time up, Ctrl-C, SIGTERM, error), Music stops before Default is restored, so no write lands after.
func runMusic(_ logo: LogoController, _ opts: MusicOptions) throws {
    let stop = StopFlag()
    let signalSources = installStopSignals(stop)
    defer { signalSources.forEach { $0.cancel() } }

    let source: AudioLevelSource = opts.test ? TestBeatSource() : SystemAudioTap()
    let follower = MusicFollower(logo: logo, source: source, maxBrightness: LogoController.brightness(forPercent: opts.maxPercent))
    follower.onError = { FileHandle.standardError.write("logoctl: write error \($0)\n".data(using: .utf8)!) }
    defer {
        follower.stop()
        do { try logo.setDefault(); print("music: restored Default") } catch {
            FileHandle.standardError.write("logoctl: restoring Default failed: \(error). Run 'logoctl default'.\n".data(using: .utf8)!)
        }
    }

    var dark = shouldBeDark()
    if dark { print("music: lid closed or display asleep, waiting") } else { try follower.start() }
    print("music: following \(opts.test ? "a synthetic 120 BPM beat" : "system audio") for \(Int(opts.seconds)) s, peak \(Int(opts.maxPercent)) %")

    let end = Date().addingTimeInterval(opts.seconds)
    var nextPrint = Date().addingTimeInterval(1)
    while Date() < end && !stop.isSet {
        Thread.sleep(forTimeInterval: 0.05)
        let nowDark = shouldBeDark()
        if nowDark != dark {
            dark = nowDark
            if dark {
                follower.setPaused(true)
                try logo.setOff()
                print("music: paused (lid closed or display asleep)")
            } else {
                if follower.isRunning { follower.setPaused(false) } else { try follower.start() }
                print("music: resumed")
            }
        }
        if !dark && Date() >= nextPrint {
            let b = follower.currentBrightness
            print(String(format: "  level %.4f  brightness %.0f %%  duty %.1f %%", follower.currentLevel,
                         LogoController.percent(forBrightness: b), LogoController.dutyPercent(forBrightness: b)))
            nextPrint = Date().addingTimeInterval(1)
        }
    }
    if stop.isSet { print("music: interrupted") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { FileHandle.standardError.write(usage.data(using: .utf8)!); exit(1) }

do {
    let logo = try LogoController()
    switch cmd {
    case "status":
        let s = logo.status()
        let modeName = [0: "off / app-controlled", 1: "on (not persisted)", 2: "default (follows display)"][s.mode ?? -1] ?? "unknown"
        print("mode        \(s.mode.map(String.init) ?? "-")  (\(modeName))")
        if let p = s.pwm {
            if p.enabled {
                print(String(format: "pwm         on   %d/%d  duty %.1f %%  (≈ brightness %.0f %%)",
                             p.highPeriod, p.lowPeriod, p.dutyPercent,
                             LogoController.percent(forBrightness: LogoController.brightness(forDutyPercent: p.dutyPercent))))
            } else {
                print("pwm         off")
            }
        }
        if let le = s.leState {
            print("macOS LE    display \(fmt(le["DisplayNits"])) nits → logo \(fmt(le["FinalNits"])) nits, lux \(fmt(le["Lux"])), boost ×\(fmt(le["NitsMultiplier"]))")
        }
        print("lid         \(s.clamshellClosed.map { $0 ? "closed" : "open" } ?? "-")")
    case "default":
        try logo.setDefault()
        print("default: macOS controls the logo again")
    case "off":
        try logo.setOff()
        print("off. Run 'logoctl default' to give the logo back to macOS.")
    case "custom":
        guard args.count == 2, let pct = Double(args[1]), pct >= 0, pct <= 100 else { fail("custom needs a percent 0-100") }
        let b = LogoController.brightness(forPercent: pct)
        try logo.setCustom(brightness: b)
        print(String(format: "custom %.0f %% (duty %.1f %%). Run 'logoctl default' to give the logo back to macOS.",
                     pct, LogoController.dutyPercent(forBrightness: b)))
    case "music":
        try runMusic(logo, parseMusic(args))
    default:
        FileHandle.standardError.write(usage.data(using: .utf8)!); exit(1)
    }
} catch {
    FileHandle.standardError.write("logoctl: \(error)\n".data(using: .utf8)!)
    exit(2)
}
