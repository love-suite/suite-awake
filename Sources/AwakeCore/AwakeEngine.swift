import AwakeSettings
import Foundation

/// How much a power assertion keeps awake.
public enum AssertionLevel: Equatable, Sendable {
    /// The Mac and its screen (`kIOPMAssertPreventUserIdleDisplaySleep`).
    case systemAndDisplay
    /// The Mac only: the screen may go off (`kIOPMAssertPreventUserIdleSystemSleep`).
    case systemOnly
}

/// The power assertions Awake holds: IOKit's in the app, a fake in tests (tests never hold real ones).
public protocol PowerAssertions: AnyObject {
    /// Holds one assertion of `level`, replacing any held; `timeout`: powerd releases it by itself then.
    func hold(_ level: AssertionLevel, reason: String, timeout: TimeInterval?)
    func release()
}

/// Lid sleep: `ClamshellSleepManager` (suite-guard) in the app, a fake in tests.
public protocol LidSleepControl: AnyObject {
    /// Turns lid sleep off; returns whether macOS took it.
    func disableLidSleep() -> Bool
    /// Lid sleep back as macOS has it.
    func restoreLidSleep()
}

/// Putting the screens to sleep now (`pmset displaysleepnow` in the app).
public protocol DisplaySleeper: AnyObject {
    func sleepDisplays()
}

/// What a session does besides keeping the Mac awake, read from the settings at every update.
public struct AwakeOptions: Equatable, Sendable {
    public var safety: SafetyPolicy
    /// Nil: the screen stays on.
    public var screenOff: ScreenOffRule?
    /// Nil: closing the lid sleeps the Mac, as always.
    public var closedLid: ClosedLidPolicy?
    /// With the lid closed (and the Mac kept awake), the screens are put to sleep.
    public var closedLidSleepsDisplay: Bool

    public init(safety: SafetyPolicy = SafetyPolicy(), screenOff: ScreenOffRule? = nil,
                closedLid: ClosedLidPolicy? = nil, closedLidSleepsDisplay: Bool = true) {
        self.safety = safety
        self.screenOff = screenOff
        self.closedLid = closedLid
        self.closedLidSleepsDisplay = closedLidSleepsDisplay
    }

    public init(_ settings: AwakeSettings) {
        self.init(
            safety: SafetyPolicy(stopsBelowBattery: settings.stopsBelowBattery,
                                 stopsInLowPowerMode: settings.stopsInLowPowerMode,
                                 stopsOnThermalPressure: settings.stopsOnThermalPressure),
            screenOff: settings.screenOffMinutes > 0 ? ScreenOffRule(delay: TimeInterval(settings.screenOffMinutes) * 60) : nil,
            closedLid: settings.allowsClosedLid
                ? ClosedLidPolicy(requiresPower: settings.closedLidRequiresPower,
                                  batteryFloor: settings.closedLidBatteryFloor,
                                  maxDuration: TimeInterval(settings.closedLidMaxHours) * 3600)
                : nil,
            closedLidSleepsDisplay: settings.closedLidSleepsDisplay)
    }
}

/// What Awake reads of the Mac at each update.
public struct Readings: Equatable, Sendable {
    public var power: PowerConditions
    /// Seconds since the last keyboard, mouse or trackpad input.
    public var idle: TimeInterval
    public var lidClosed: Bool

    public init(power: PowerConditions = PowerConditions(), idle: TimeInterval = 0, lidClosed: Bool = false) {
        self.power = power
        self.idle = idle
        self.lidClosed = lidClosed
    }
}

/// The closed-lid part of a session.
public enum ClosedLidState: Equatable, Sendable {
    /// Not asked for: closing the lid sleeps the Mac.
    case off
    /// Closing the lid doesn't sleep the Mac.
    case active
    /// Waiting (for power, for charge): lid sleep is back meanwhile.
    case waiting(EndReason)
    /// Over for this session.
    case ended(EndReason)
}

/// A session keeping the Mac awake.
public struct Session: Equatable, Sendable {
    public let start: Date
    public let length: SessionLength
    /// Nil: until stopped.
    public let ends: Date?
    public internal(set) var closedLid: ClosedLidState = .off
    /// When the closed-lid part was first applied (its maximum duration counts from then).
    public internal(set) var closedLidSince: Date?

    public func remaining(at now: Date) -> TimeInterval? {
        ends.map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Keeps the Mac awake: starts and stops sessions, holds the matching power assertion, and at each update
/// (a timer, a power change) ends the session when its time is up or safety requires, turns lid sleep off
/// and on as the closed-lid policy says (again after every power change: powerd turns it back on), and
/// turns the screen off as "Screen off, Mac on" says. UI-free: the app gives it the real Mac, tests fakes.
public final class AwakeEngine {
    public private(set) var session: Session?
    /// Why the last session ended (shown in the menu until the next one).
    public private(set) var lastEnd: EndReason?
    /// Called after every change of `session` or of its closed-lid state.
    public var onChange: (() -> Void)?
    /// Called when safety ends the session or its closed-lid part (`EndReason.isSafetyStop`).
    public var onSafetyStop: ((SafetyStop) -> Void)?

    private let assertions: PowerAssertions
    private let lid: LidSleepControl
    private let display: DisplaySleeper
    private let options: () -> AwakeOptions
    private var heldLevel: AssertionLevel?
    private var lidSleepOff = false
    private var screenTurnedOff = false
    private var lidWasClosed = false

    /// The reason shown in `pmset -g assertions` and Activity Monitor.
    public static let assertionReason = "Awake: keeping the Mac awake as asked"

    public init(assertions: PowerAssertions, lid: LidSleepControl, display: DisplaySleeper,
                options: @escaping () -> AwakeOptions) {
        self.assertions = assertions
        self.lid = lid
        self.display = display
        self.options = options
    }

    public var isActive: Bool { session != nil }

    /// Starts a session (replacing the current one, whose closed-lid time still counts).
    public func start(_ length: SessionLength, now: Date = Date(), readings: Readings) {
        let since = session?.closedLidSince
        session = Session(start: now, length: length, ends: length.endDate(from: now), closedLidSince: since)
        lastEnd = nil
        heldLevel = nil
        screenTurnedOff = false
        lidWasClosed = readings.lidClosed
        update(now: now, readings: readings)
        if session != nil { onChange?() }
    }

    /// Ends the session: the assertion is released and lid sleep is back.
    public func stop(_ reason: EndReason) {
        guard session != nil else { return }
        assertions.release()
        heldLevel = nil
        if lidSleepOff {
            lid.restoreLidSleep()
            lidSleepOff = false
        }
        session = nil
        lastEnd = reason
        onChange?()
        if reason.isSafetyStop { onSafetyStop?(.session(reason)) }
    }

    /// Applies the rules to what the Mac looks like now.
    public func update(now: Date = Date(), readings: Readings) {
        guard var current = session else { return }
        let options = options()
        if let ends = current.ends, now >= ends { return stop(.timer) }
        if let reason = options.safety.endReason(readings.power) { return stop(reason) }

        let before = current.closedLid
        updateClosedLid(&current, options: options, power: readings.power, now: now)
        session = current

        // With the screen allowed off, or the lid closed, only the Mac is kept awake.
        let level: AssertionLevel = options.screenOff != nil || (readings.lidClosed && lidSleepOff)
            ? .systemOnly : .systemAndDisplay
        if level != heldLevel {
            assertions.hold(level, reason: Self.assertionReason,
                            timeout: current.remaining(at: now).map { $0 + 60 })
            heldLevel = level
        }

        if let rule = options.screenOff {
            if readings.idle < rule.delay { screenTurnedOff = false }
            if rule.shouldTurnScreenOff(idle: readings.idle, alreadyOff: screenTurnedOff) {
                display.sleepDisplays()
                screenTurnedOff = true
            }
        }
        if readings.lidClosed && !lidWasClosed && lidSleepOff && options.closedLidSleepsDisplay {
            display.sleepDisplays()
        }
        lidWasClosed = readings.lidClosed

        if current.closedLid != before {
            onChange?()
            if case .ended(let reason) = current.closedLid, reason.isSafetyStop { onSafetyStop?(.closedLid(reason)) }
        }
    }

    private func updateClosedLid(_ session: inout Session, options: AwakeOptions, power: PowerConditions, now: Date) {
        guard let policy = options.closedLid else {
            setLidSleepOff(false)
            session.closedLid = .off
            return
        }
        if case .ended = session.closedLid { return setLidSleepOff(false) }
        switch policy.decide(power, since: session.closedLidSince, now: now) {
        case .apply:
            // Every update, not only the first: powerd turns lid sleep back on after a power change.
            if lid.disableLidSleep() {
                lidSleepOff = true
                session.closedLid = .active
                if session.closedLidSince == nil { session.closedLidSince = now }
            } else {
                setLidSleepOff(false, force: true)
                session.closedLid = .ended(.refused)
            }
        case .suspend(let reason):
            setLidSleepOff(false)
            session.closedLid = .waiting(reason)
        case .end(let reason):
            setLidSleepOff(false)
            session.closedLid = .ended(reason)
        }
    }

    private func setLidSleepOff(_ off: Bool, force: Bool = false) {
        guard !off, lidSleepOff || force else { return }
        lid.restoreLidSleep()
        lidSleepOff = false
    }
}
