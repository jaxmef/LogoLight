import CoreGraphics
import Foundation
import LogoCore
import LogoMusic

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
    LogoController.isLidClosed() == true || CGDisplayIsAsleep(CGMainDisplayID()) != 0
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
    let follower = MusicFollower(logo: logo, source: source, peakPercent: opts.maxPercent)
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
            print(String(format: "  level %.4f  brightness %.0f %%", follower.currentLevel, follower.currentPercent))
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
        print(logo.diagnostics)
    case "default":
        try logo.setDefault()
        print("default: macOS controls the logo again")
    case "off":
        try logo.setOff()
        print("off. Run 'logoctl default' to give the logo back to macOS.")
    case "custom":
        guard args.count == 2, let pct = Double(args[1]), pct >= 0, pct <= 100 else { fail("custom needs a percent 0-100") }
        try logo.setBrightness(percent: pct)
        print(String(format: "custom %g %%. Run 'logoctl default' to give the logo back to macOS.", pct))
    case "music":
        try runMusic(logo, parseMusic(args))
    default:
        FileHandle.standardError.write(usage.data(using: .utf8)!); exit(1)
    }
} catch {
    FileHandle.standardError.write("logoctl: \(error)\n".data(using: .utf8)!)
    exit(2)
}
