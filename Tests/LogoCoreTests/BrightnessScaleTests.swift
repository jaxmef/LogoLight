import Testing
import LogoCore

@Test(arguments: [-1.0, 0, 0.3, 1, 5])
func dutyStaysWithinWhatMacOSUses(brightness: Double) {
    let duty = LogoController.dutyPercent(forBrightness: brightness)
    #expect(duty >= LogoPWM.minDutyPercent && duty <= LogoPWM.maxDutyPercent)
}

@Test func percentScaleSpansTheWholeDutyRange() {
    #expect(LogoController.dutyPercent(forBrightness: LogoController.brightness(forPercent: 0)) == LogoPWM.minDutyPercent)
    #expect(LogoController.dutyPercent(forBrightness: LogoController.brightness(forPercent: 100)) == LogoPWM.maxDutyPercent)
}

@Test(arguments: [0.0, 1, 46, 100])
func percentRoundTrips(percent: Double) {
    let b = LogoController.brightness(forPercent: percent)
    #expect(abs(LogoController.percent(forBrightness: b) - percent) < 1e-9)
}
