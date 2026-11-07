import Foundation
import IOKit

public enum LogoError: Error, CustomStringConvertible {
    case coreBrightnessUnavailable(String)
    case nodeNotFound
    case unsupportedMac
    case invalidArgument(String)
    case rejected(String)
    case ioKit(kern_return_t)

    public var description: String {
        switch self {
        case .coreBrightnessUnavailable(let s): return "CoreBrightness unavailable: \(s)"
        case .nodeNotFound: return "logo PWM node bklb-backlight@0 not found (not an OLED MacBook Pro?)"
        case .unsupportedMac: return "logo light doesn't match the tested configuration (LEBacklightMode / PWM period); not an OLED MacBook Pro?"
        case .invalidArgument(let s): return "invalid argument: \(s)"
        case .rejected(let s): return "rejected: \(s)"
        case .ioKit(let kr): return String(format: "IOKit error 0x%08x", kr)
        }
    }
}

/// Controls the logo through CoreBrightness's mode and the logo's PWM channel.
public final class LogoController {
    public let cb: CoreBrightnessClient
    public let pwm: LogoPWM

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

    /// Brightness 0...1 → duty. Quadratic, so equal slider steps look roughly equal.
    public static func dutyPercent(forBrightness b: Double) -> Double {
        let x = min(max(b, 0), 1)
        return max(LogoPWM.minDutyPercent, LogoPWM.maxDutyPercent * x * x)
    }

    public static func brightness(forDutyPercent d: Double) -> Double {
        min(max((d / LogoPWM.maxDutyPercent).squareRoot(), 0), 1)
    }

    /// Anything lower maps to the minimum duty anyway.
    public static let minBrightness = brightness(forDutyPercent: LogoPWM.minDutyPercent)

    /// The 0–100 % scale of the app and logoctl. 0 % is the dimmest glow, not off.
    public static func brightness(forPercent p: Double) -> Double {
        minBrightness + (1 - minBrightness) * min(max(p, 0), 100) / 100
    }

    public static func percent(forBrightness b: Double) -> Double {
        min(max((b - minBrightness) / (1 - minBrightness), 0), 1) * 100
    }

    /// Hands the logo back to macOS. Passing through mode 0 makes CoreBrightness wake the LED again.
    public func setDefault() throws {
        try cb.setMode(0)
        Thread.sleep(forTimeInterval: 0.3)
        try cb.setMode(2)
    }

    public func setOff() throws {
        try cb.setMode(0)
    }

    public func setCustom(brightness: Double) throws {
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

    /// Whether the hardware still shows this custom brightness (macOS may have taken over).
    public func isApplied(brightness: Double) -> Bool {
        guard cb.mode == 0, let s = pwm.state(), s.enabled else { return false }
        return abs(s.highPeriod - LogoPWM.expectedHighPeriod(percent: Self.dutyPercent(forBrightness: brightness))) <= 2
    }

    public struct Status {
        public var mode: Int?
        public var pwm: LogoPWM.State?
        public var leState: [String: Any]?
        public var clamshellClosed: Bool?
    }

    public func status() -> Status {
        Status(mode: cb.mode, pwm: pwm.state(), leState: cb.leState, clamshellClosed: Self.clamshellClosed())
    }

    public static func clamshellClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}
