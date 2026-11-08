import Foundation
import IOKit

/// The logo's PWM channel (IOService `bklb-backlight`), written with the same property dictionaries CoreBrightness uses.
package final class LogoPWM {
    /// The most macOS itself uses (~1000 nits).
    static let maxDutyPercent = 77.0
    static let minDutyPercent = 0.5
    static let frequencyHz: Int64 = 25_000
    /// 24 MHz ticks per 25 kHz period.
    static let periodTicks = 960.0

    private let service: io_service_t

    init() throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPWMDevice"), &iterator) == KERN_SUCCESS else {
            throw LogoError.nodeNotFound
        }
        defer { IOObjectRelease(iterator) }
        var found: io_service_t = 0
        while case let s = IOIteratorNext(iterator), s != 0 {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(s, &name)
            if found == 0 && String(cString: name) == "bklb-backlight" { found = s } else { IOObjectRelease(s) }
        }
        guard found != 0 else { throw LogoError.nodeNotFound }
        service = found
    }

    deinit { IOObjectRelease(service) }

    // MARK: read

    struct State: Equatable {
        var enabled: Bool
        var highPeriod: Int
        var lowPeriod: Int
        var dutyPercent: Double {
            let total = Double(highPeriod + lowPeriod)
            return total > 0 ? 100.0 * Double(highPeriod) / total : 0
        }
    }

    func state() -> State? {
        func prop(_ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let en = prop("enabled") as? Bool,
              let hi = (prop("high-period") as? NSNumber)?.intValue,
              let lo = (prop("low-period") as? NSNumber)?.intValue else { return nil }
        return State(enabled: en, highPeriod: hi, lowPeriod: lo)
    }

    // MARK: write

    private func set(_ dict: [String: Any]) throws {
        let kr = IORegistryEntrySetCFProperties(service, dict as CFDictionary)
        guard kr == KERN_SUCCESS else { throw LogoError.ioKit(kr) }
    }

    /// The LED driver needs this pulse after the channel was off. Values copied from CoreBrightness:
    /// one 80 µs period at 12.5 kHz / 65 %, then 1 % at 25 kHz.
    func wake() throws {
        func step(_ duty: Int64, _ hz: Int64, _ interval: Int64) -> [String: Any] {
            ["duty cycle": NSNumber(value: duty), "frequency": NSNumber(value: hz), "interval": NSNumber(value: interval)]
        }
        let steps: [Any] = [step(2_791_728_742, 12_500, 79_999), NSNumber(value: 0),
                            step(42_949_672, 25_000, 3_600_000_000_000), NSNumber(value: 0)]
        try set(["hertz_millisecs": steps, "repeat": kCFBooleanFalse as Any])
    }

    package func setDuty(percent: Double) throws {
        let p = min(max(percent, Self.minDutyPercent), Self.maxDutyPercent)
        let duty = UInt64((p / 100.0 * 4_294_967_296.0).rounded())
        try set(["set-enabled": kCFBooleanTrue as Any,
                 "set-hz": NSNumber(value: Self.frequencyHz),
                 "set-duty-cycle": NSNumber(value: duty)])
    }

    package static func expectedHighPeriod(percent: Double) -> Int {
        let p = min(max(percent, minDutyPercent), maxDutyPercent)
        return Int((p / 100.0 * periodTicks).rounded())
    }
}
