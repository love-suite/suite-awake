import Foundation
import Testing
@testable import AwakeCore

/// Power assertions in memory: tests never hold real ones.
final class FakeAssertions: PowerAssertions {
    var held: AssertionLevel?
    var timeout: TimeInterval?
    var holds = 0
    func hold(_ level: AssertionLevel, reason: String, timeout: TimeInterval?) {
        held = level
        self.timeout = timeout
        holds += 1
    }
    func release() { held = nil }
}

/// Lid sleep in memory: tests never touch the real Mac's.
final class FakeLid: LidSleepControl {
    var sleepOff = false
    var accepts = true
    var disables = 0
    func disableLidSleep() -> Bool {
        disables += 1
        sleepOff = accepts
        return accepts
    }
    func restoreLidSleep() { sleepOff = false }
}

final class FakeDisplay: DisplaySleeper {
    var sleeps = 0
    func sleepDisplays() { sleeps += 1 }
}

struct Harness {
    let assertions = FakeAssertions()
    let lid = FakeLid()
    let display = FakeDisplay()
    let box = OptionsBox()
    let engine: AwakeEngine
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    final class OptionsBox { var options = AwakeOptions() }

    init(_ options: AwakeOptions = AwakeOptions()) {
        box.options = options
        let box = box
        engine = AwakeEngine(assertions: assertions, lid: lid, display: display, options: { box.options })
    }
}

let laptopOnPower = Readings(power: PowerConditions(onPower: true, batteryPercent: 90, hasLid: true))

@Suite struct AwakeEngineTests {
    @Test func aSessionHoldsTheScreenAwakeUntilStopped() {
        let h = Harness()
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        #expect(h.engine.isActive)
        #expect(h.assertions.held == .systemAndDisplay)
        #expect(h.assertions.timeout == nil)
        h.engine.update(now: h.t0 + 86_400, readings: Readings())
        #expect(h.engine.isActive)
        h.engine.stop(.user)
        #expect(!h.engine.isActive)
        #expect(h.assertions.held == nil)
        #expect(h.engine.lastEnd == .user)
    }

    @Test func aTimedSessionEndsOnTimeAndTellsPowerdToo() {
        let h = Harness()
        h.engine.start(.minutes(15), now: h.t0, readings: Readings())
        #expect(h.assertions.timeout == 960)
        #expect(h.engine.session?.remaining(at: h.t0 + 60) == 840)
        h.engine.update(now: h.t0 + 899, readings: Readings())
        #expect(h.engine.isActive)
        h.engine.update(now: h.t0 + 900, readings: Readings())
        #expect(!h.engine.isActive)
        #expect(h.engine.lastEnd == .timer)
        #expect(h.assertions.held == nil)
    }

    @Test func safetyEndsTheSession() {
        let h = Harness()
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        h.engine.update(now: h.t0 + 5, readings: Readings(power: PowerConditions(onPower: false, batteryPercent: 10)))
        #expect(!h.engine.isActive)
        #expect(h.engine.lastEnd == .lowBattery)
    }

    @Test func screenOffMacOnHoldsOnlyTheMacAndTurnsTheScreenOffOnce() {
        let h = Harness(AwakeOptions(screenOff: ScreenOffRule(delay: 60)))
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        #expect(h.assertions.held == .systemOnly)
        h.engine.update(now: h.t0 + 30, readings: Readings(idle: 30))
        #expect(h.display.sleeps == 0)
        h.engine.update(now: h.t0 + 60, readings: Readings(idle: 60))
        h.engine.update(now: h.t0 + 65, readings: Readings(idle: 65))
        #expect(h.display.sleeps == 1)
        // Input, then idle again: off again.
        h.engine.update(now: h.t0 + 70, readings: Readings(idle: 1))
        h.engine.update(now: h.t0 + 131, readings: Readings(idle: 61))
        #expect(h.display.sleeps == 2)
    }

    @Test func changingTheOptionChangesTheAssertion() {
        let h = Harness()
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        #expect(h.assertions.held == .systemAndDisplay)
        h.box.options.screenOff = ScreenOffRule(delay: 120)
        h.engine.update(now: h.t0 + 5, readings: Readings())
        #expect(h.assertions.held == .systemOnly)
        let holds = h.assertions.holds
        h.engine.update(now: h.t0 + 10, readings: Readings())
        #expect(h.assertions.holds == holds)
    }
}

@Suite struct ClosedLidEngineTests {
    let lidOption = AwakeOptions(closedLid: ClosedLidPolicy(requiresPower: true, batteryFloor: 30, maxDuration: 3600))

    @Test func withoutTheOptionLidSleepIsNeverTouched() {
        let h = Harness()
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        #expect(h.lid.disables == 0)
        #expect(h.engine.session?.closedLid == .off)
    }

    @Test func lidSleepIsOffDuringTheSessionAndBackAfter() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        #expect(h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .active)
        h.engine.stop(.user)
        #expect(!h.lid.sleepOff)
    }

    /// powerd turns lid sleep back on after a power change: every update turns it off again.
    @Test func itIsReappliedAtEveryUpdate() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        h.lid.sleepOff = false
        h.engine.update(now: h.t0 + 5, readings: laptopOnPower)
        #expect(h.lid.sleepOff)
        #expect(h.lid.disables == 2)
    }

    @Test func unpluggedItWaitsThenComesBack() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        var unplugged = laptopOnPower
        unplugged.power.onPower = false
        h.engine.update(now: h.t0 + 5, readings: unplugged)
        #expect(!h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .waiting(.needsPower))
        #expect(h.engine.isActive)
        h.engine.update(now: h.t0 + 10, readings: laptopOnPower)
        #expect(h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .active)
    }

    @Test func itEndsAfterItsMaximumDurationTheSessionGoesOn() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        h.engine.update(now: h.t0 + 3600, readings: laptopOnPower)
        #expect(!h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .ended(.maxDuration))
        #expect(h.engine.isActive)
        h.engine.update(now: h.t0 + 3700, readings: laptopOnPower)
        #expect(!h.lid.sleepOff)
    }

    /// Choosing another length doesn't give the lid a new maximum duration.
    @Test func restartingKeepsTheClosedLidClock() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        h.engine.start(.minutes(120), now: h.t0 + 3000, readings: laptopOnPower)
        h.engine.update(now: h.t0 + 3600, readings: laptopOnPower)
        #expect(h.engine.session?.closedLid == .ended(.maxDuration))
    }

    @Test func heatEndsItEvenWhenTheSessionMayGoOn() {
        var options = lidOption
        options.safety.stopsOnThermalPressure = false
        let h = Harness(options)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        var hot = laptopOnPower
        hot.power.thermal = .serious
        h.engine.update(now: h.t0 + 5, readings: hot)
        #expect(!h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .ended(.thermal))
        #expect(h.engine.isActive)
    }

    @Test func aRefusalIsReportedAndLidSleepRestored() {
        let h = Harness(lidOption)
        h.lid.accepts = false
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        #expect(h.engine.session?.closedLid == .ended(.refused))
        #expect(!h.lid.sleepOff)
    }

    @Test func turningTheOptionOffBringsLidSleepBack() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        h.box.options.closedLid = nil
        h.engine.update(now: h.t0 + 5, readings: laptopOnPower)
        #expect(!h.lid.sleepOff)
        #expect(h.engine.session?.closedLid == .off)
    }

    @Test func closingTheLidTurnsTheScreenOffAndLeavesOnlyTheMacAwake() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        #expect(h.assertions.held == .systemAndDisplay)
        var closed = laptopOnPower
        closed.lidClosed = true
        h.engine.update(now: h.t0 + 5, readings: closed)
        #expect(h.display.sleeps == 1)
        #expect(h.assertions.held == .systemOnly)
        h.engine.update(now: h.t0 + 10, readings: closed)
        #expect(h.display.sleeps == 1)
        h.engine.update(now: h.t0 + 15, readings: laptopOnPower)
        #expect(h.assertions.held == .systemAndDisplay)
    }

    @Test func endingTheSessionForSafetyRestoresLidSleep() {
        let h = Harness(lidOption)
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        var saving = laptopOnPower
        saving.power.lowPowerMode = true
        h.engine.update(now: h.t0 + 5, readings: saving)
        #expect(!h.engine.isActive)
        #expect(!h.lid.sleepOff)
        #expect(h.engine.lastEnd == .lowPowerMode)
    }
}

@Suite struct SafetyStopTests {
    @Test func heatEndingASessionIsToldButTheUserStoppingItIsNot() {
        let h = Harness()
        var told: [SafetyStop] = []
        h.engine.onSafetyStop = { told.append($0) }
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        h.engine.stop(.user)
        #expect(told.isEmpty)
        h.engine.start(.minutes(15), now: h.t0, readings: Readings())
        h.engine.update(now: h.t0 + 900, readings: Readings())
        #expect(told.isEmpty)
        h.engine.start(.indefinite, now: h.t0, readings: Readings())
        h.engine.update(now: h.t0 + 60, readings: Readings(power: PowerConditions(thermal: .critical)))
        #expect(told == [.session(.thermal)])
    }

    @Test func theClosedLidTimeLimitIsToldOnce() {
        let h = Harness(AwakeOptions(closedLid: ClosedLidPolicy(requiresPower: true, batteryFloor: 30, maxDuration: 3600)))
        var told: [SafetyStop] = []
        h.engine.onSafetyStop = { told.append($0) }
        h.engine.start(.indefinite, now: h.t0, readings: laptopOnPower)
        h.engine.update(now: h.t0 + 3600, readings: laptopOnPower)
        h.engine.update(now: h.t0 + 3700, readings: laptopOnPower)
        #expect(told == [.closedLid(.maxDuration)])
        #expect(h.engine.isActive)
    }
}
