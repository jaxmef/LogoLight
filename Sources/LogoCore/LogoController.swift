import Foundation
import IOKit

public enum LogoError: Error, CustomStringConvertible {
    case coreBrightnessUnavailable(String)
    case nodeNotFound
    case unsupportedMac
    case rejected(String)
    case ioKit(kern_return_t)

    public var description: String {
        switch self {
        case .coreBrightnessUnavailable(let s): return "CoreBrightness unavailable: \(s)"
        case .nodeNotFound: return "logo PWM node bklb-backlight not found (not an OLED MacBook Pro?)"
        case .unsupportedMac: return "logo light doesn't match the tested configuration (not an OLED MacBook Pro?)"
        case .rejected(let s): return "rejected: \(s)"
        case .ioKit(let kr): return String(format: "IOKit error 0x%08x", kr)
        }
    }
}

/// Controls the glowing Apple logo.
public final class LogoController {
    public enum Mode: Equatable {
        /// macOS controls the logo (it follows the display brightness).
        case system
        /// Taken over and dark.
        case off
        /// Taken over and lit at a fixed brightness.
        case custom
    }

    let cb: CoreBrightnessClient
    package let pwm: LogoPWM

    /// Throws on hardware that doesn't match the tested Mac.
    public init() throws {
        pwm = try LogoPWM()
        cb = try CoreBrightnessClient()
        // Fail closed unless the hardware looks exactly like the tested configuration.
        guard let mode = cb.mode, [0, 1, 2].contains(mode), pwm.state() != nil else { throw LogoError.unsupportedMac }
        // The period swings for ~0.7 s while macOS fades the logo in, so keep sampling for a while.
        let periodOK = (0..<25).contains { attempt in
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            guard let s = pwm.state() else { return false }
            return !s.enabled || abs(s.highPeriod + s.lowPeriod - Int(LogoPWM.periodTicks)) <= 2
        }
        guard periodOK else { throw LogoError.unsupportedMac }
    }

    public var mode: Mode {
        guard cb.mode == 0 else { return .system }
        return pwm.state()?.enabled == true ? .custom : .off
    }

    /// Hands the logo back to macOS. Passing through mode 0 makes CoreBrightness wake the LED again.
    public func setDefault() throws {
        try cb.setMode(0)
        Thread.sleep(forTimeInterval: 0.3)
        try cb.setMode(2)
    }

    /// Stays dark, also across restarts, until `setDefault()`.
    public func setOff() throws {
        try cb.setMode(0)
    }

    /// 0–100 %. 0 % is the dimmest glow, 100 % the most macOS itself uses. Stays until `setDefault()` or `setOff()`.
    public func setBrightness(percent: Double) throws {
        try setBrightness(Self.brightness(forPercent: percent))
    }

    /// Whether the logo still shows this brightness (macOS may have taken it back, e.g. after sleep).
    public func isShowing(percent: Double) -> Bool {
        guard cb.mode == 0, let s = pwm.state(), s.enabled else { return false }
        let duty = Self.dutyPercent(forBrightness: Self.brightness(forPercent: percent))
        return abs(s.highPeriod - LogoPWM.expectedHighPeriod(percent: duty)) <= 2
    }

    /// In `.off` and `.custom`, macOS doesn't turn the logo off when the lid closes; callers have to.
    public static func isLidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// Raw hardware state, for debugging.
    public var diagnostics: String {
        func num(_ v: Any?) -> String { (v as? NSNumber).map { String(format: "%.1f", $0.doubleValue) } ?? "-" }
        let rawMode = cb.mode
        let modeName = [0: "taken over", 1: "on, not persisted", 2: "macOS, follows the display"][rawMode ?? -1] ?? "unknown"
        var lines = ["mode   \(rawMode.map(String.init) ?? "-") (\(modeName))"]
        if let s = pwm.state() {
            lines.append(s.enabled
                ? String(format: "pwm    on, %d/%d ticks, duty %.1f %% (≈ %.0f %%)", s.highPeriod, s.lowPeriod, s.dutyPercent,
                         Self.percent(forBrightness: Self.brightness(forDutyPercent: s.dutyPercent)))
                : "pwm    off")
        }
        if let le = cb.leState {
            lines.append("macOS  display \(num(le["DisplayNits"])) nits → logo \(num(le["FinalNits"])) nits, lux \(num(le["Lux"]))")
        }
        lines.append("lid    \(Self.isLidClosed().map { $0 ? "closed" : "open" } ?? "-")")
        return lines.joined(separator: "\n")
    }

    // MARK: for LogoLight's own modules (`package`), not the public API

    /// Brightness 0...1 → duty. Quadratic, so equal slider steps look roughly equal.
    package static func dutyPercent(forBrightness b: Double) -> Double {
        let x = min(max(b, 0), 1)
        return max(LogoPWM.minDutyPercent, LogoPWM.maxDutyPercent * x * x)
    }

    static func brightness(forDutyPercent d: Double) -> Double {
        min(max((d / LogoPWM.maxDutyPercent).squareRoot(), 0), 1)
    }

    /// Anything lower maps to the minimum duty anyway.
    package static let minBrightness = brightness(forDutyPercent: LogoPWM.minDutyPercent)

    package static func brightness(forPercent p: Double) -> Double {
        minBrightness + (1 - minBrightness) * min(max(p, 0), 100) / 100
    }

    package static func percent(forBrightness b: Double) -> Double {
        min(max((b - minBrightness) / (1 - minBrightness), 0), 1) * 100
    }

    package func setBrightness(_ brightness: Double) throws {
        if cb.mode != 0 {
            try cb.setMode(0)
            // CoreBrightness turns the channel off asynchronously; wait, so our write lands last.
            for _ in 0..<20 where pwm.state()?.enabled == true { Thread.sleep(forTimeInterval: 0.05) }
        }
        if pwm.state()?.enabled != true {
            try pwm.wake()
            Thread.sleep(forTimeInterval: 0.01)
        }
        try pwm.setDuty(percent: Self.dutyPercent(forBrightness: brightness))
    }
}
