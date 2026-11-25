import AwakeSettings
import Foundation
import Testing
@testable import AwakeCore

@Suite struct SessionLengthTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func lengths() {
        #expect(SessionLength.indefinite.endDate(from: start) == nil)
        #expect(SessionLength.minutes(15).endDate(from: start) == start + 900)
        #expect(SessionLength.until(start + 42).endDate(from: start) == start + 42)
        #expect(SessionLength(minutes: 0) == .indefinite)
        #expect(SessionLength(minutes: 60) == .minutes(60))
    }

    @Test func untilChoicesAreHalfHoursAtLeastTenMinutesAway() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10, minute: 7)))
        let choices = SessionLength.untilChoices(now: now, count: 3, calendar: calendar)
        let times = choices.map { calendar.dateComponents([.hour, .minute], from: $0) }
        #expect(times.map(\.hour) == [10, 11, 11])
        #expect(times.map(\.minute) == [30, 0, 30])

        // 10:25: 10:30 is too close, 11:00 comes first.
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10, minute: 25)))
        let first = try #require(SessionLength.untilChoices(now: late, count: 1, calendar: calendar).first)
        #expect(calendar.dateComponents([.hour, .minute], from: first) == DateComponents(hour: 11, minute: 0))
    }

    @Test func untilChoicesCrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23, minute: 40)))
        let first = try #require(SessionLength.untilChoices(now: now, count: 1, calendar: calendar).first)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: first) == DateComponents(day: 26, hour: 0, minute: 0))
    }
}

@Suite struct SafetyPolicyTests {
    let policy = SafetyPolicy(stopsBelowBattery: 20, stopsInLowPowerMode: true, stopsOnThermalPressure: true)

    @Test func batteryCountsOnlyOnBattery() {
        #expect(policy.endReason(PowerConditions(onPower: false, batteryPercent: 19)) == .lowBattery)
        #expect(policy.endReason(PowerConditions(onPower: false, batteryPercent: 20)) == nil)
        #expect(policy.endReason(PowerConditions(onPower: true, batteryPercent: 5)) == nil)
        #expect(SafetyPolicy(stopsBelowBattery: 0).endReason(PowerConditions(onPower: false, batteryPercent: 1)) == nil)
    }

    @Test func lowPowerModeAndHeat() {
        #expect(policy.endReason(PowerConditions(lowPowerMode: true)) == .lowPowerMode)
        #expect(policy.endReason(PowerConditions(thermal: .serious)) == .thermal)
        #expect(policy.endReason(PowerConditions(thermal: .critical)) == .thermal)
        #expect(policy.endReason(PowerConditions(thermal: .fair)) == nil)
        let lenient = SafetyPolicy(stopsBelowBattery: 0, stopsInLowPowerMode: false, stopsOnThermalPressure: false)
        #expect(lenient.endReason(PowerConditions(lowPowerMode: true, thermal: .critical)) == nil)
    }
}

@Suite struct ClosedLidPolicyTests {
    let policy = ClosedLidPolicy(requiresPower: true, batteryFloor: 30, maxDuration: 4 * 3600)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let laptop = PowerConditions(onPower: true, batteryPercent: 80, hasLid: true)

    @Test func onPowerItApplies() {
        #expect(policy.decide(laptop, since: nil, now: now) == .apply)
    }

    @Test func onBatteryItWaitsForPowerByDefault() {
        var unplugged = laptop
        unplugged.onPower = false
        #expect(policy.decide(unplugged, since: nil, now: now) == .suspend(.needsPower))
        var allowed = policy
        allowed.requiresPower = false
        #expect(allowed.decide(unplugged, since: nil, now: now) == .apply)
        unplugged.batteryPercent = 29
        #expect(allowed.decide(unplugged, since: nil, now: now) == .suspend(.lowBattery))
    }

    @Test func heatLowPowerModeAndTimeEndIt() {
        var hot = laptop
        hot.thermal = .serious
        #expect(policy.decide(hot, since: nil, now: now) == .end(.thermal))
        var saving = laptop
        saving.lowPowerMode = true
        #expect(policy.decide(saving, since: nil, now: now) == .end(.lowPowerMode))
        #expect(policy.decide(laptop, since: now - 4 * 3600 + 1, now: now) == .apply)
        #expect(policy.decide(laptop, since: now - 4 * 3600, now: now) == .end(.maxDuration))
    }

    @Test func noLidNoClosedLid() {
        #expect(policy.decide(PowerConditions(hasLid: false), since: nil, now: now) == .end(.noLid))
    }
}

@Suite struct ScreenOffRuleTests {
    @Test func onceAfterTheDelay() {
        let rule = ScreenOffRule(delay: 120)
        #expect(!rule.shouldTurnScreenOff(idle: 119, alreadyOff: false))
        #expect(rule.shouldTurnScreenOff(idle: 120, alreadyOff: false))
        #expect(!rule.shouldTurnScreenOff(idle: 500, alreadyOff: true))
        #expect(!ScreenOffRule(delay: 0).shouldTurnScreenOff(idle: 500, alreadyOff: false))
    }
}

@Suite struct AwakeSettingsTests {
    private func fresh() -> AwakeSettings {
        let name = "AwakeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AwakeSettings(defaults: defaults)
    }

    /// Progressive enhancement: installed, Awake changes nothing.
    @Test func everythingIsOffByDefault() {
        let settings = fresh()
        #expect(!settings.isEnabled)
        #expect(!settings.allowsClosedLid)
        #expect(settings.screenOffMinutes == 0)
        #expect(!settings.opensAtLogin)
        #expect(settings.defaultDuration == 0)
        let options = AwakeOptions(settings)
        #expect(options.closedLid == nil)
        #expect(options.screenOff == nil)
    }

    @Test func safeDefaults() {
        let settings = fresh()
        #expect(settings.durations == [15, 30, 60, 120, 300])
        #expect(settings.stopsBelowBattery == 20)
        #expect(settings.stopsInLowPowerMode)
        #expect(settings.stopsOnThermalPressure)
        #expect(settings.closedLidRequiresPower)
        #expect(settings.closedLidBatteryFloor == 30)
        #expect(settings.closedLidMaxHours == 4)
        #expect(settings.closedLidSleepsDisplay)
    }

    @Test func durationsAreCleanedUp() {
        let settings = fresh()
        settings.durations = [60, 0, 15, 60, -3, 20_000]
        #expect(settings.durations == [15, 60])
        settings.durations = []
        #expect(settings.durations == AwakeSettings.defaultDurations)
    }

    @Test func optionsFollowTheSettings() {
        let settings = fresh()
        settings.allowsClosedLid = true
        settings.closedLidMaxHours = 2
        settings.screenOffMinutes = 5
        let options = AwakeOptions(settings)
        #expect(options.closedLid?.maxDuration == 7200)
        #expect(options.screenOff?.delay == 300)
    }
}
