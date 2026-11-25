import Foundation

/// What the Mac's power looks like now: read by Awake from IOKit and ProcessInfo, made up by tests.
public struct PowerConditions: Equatable, Sendable {
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    /// On power (AC, or a UPS) rather than on battery.
    public var onPower: Bool
    /// The battery's charge in percent; nil without a battery.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var thermal: Thermal
    /// Whether the Mac has a lid (a laptop).
    public var hasLid: Bool

    public init(onPower: Bool = true, batteryPercent: Int? = nil, lowPowerMode: Bool = false,
                thermal: Thermal = .nominal, hasLid: Bool = false) {
        self.onPower = onPower
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.hasLid = hasLid
    }

    /// Hot enough that keeping the Mac working is unwise.
    public var isHot: Bool { thermal >= .serious }
}

/// When a session ends for safety: battery low (on battery only), Low Power Mode, heat.
public struct SafetyPolicy: Equatable, Sendable {
    /// Percent; 0 never.
    public var stopsBelowBattery: Int
    public var stopsInLowPowerMode: Bool
    public var stopsOnThermalPressure: Bool

    public init(stopsBelowBattery: Int = 20, stopsInLowPowerMode: Bool = true, stopsOnThermalPressure: Bool = true) {
        self.stopsBelowBattery = stopsBelowBattery
        self.stopsInLowPowerMode = stopsInLowPowerMode
        self.stopsOnThermalPressure = stopsOnThermalPressure
    }

    /// Why the session must end now, if it must.
    public func endReason(_ power: PowerConditions) -> EndReason? {
        if stopsOnThermalPressure && power.isHot { return .thermal }
        if stopsInLowPowerMode && power.lowPowerMode { return .lowPowerMode }
        if stopsBelowBattery > 0, !power.onPower, let battery = power.batteryPercent, battery < stopsBelowBattery {
            return .lowBattery
        }
        return nil
    }
}

/// What the closed-lid part of a session does now.
public enum ClosedLidDecision: Equatable, Sendable {
    /// Closing the lid doesn't sleep the Mac.
    case apply
    /// Lid sleep is back for now; it may come back (plugged in again, charged).
    case suspend(EndReason)
    /// Lid sleep is back for the rest of the session.
    case end(EndReason)
}

/// When a Mac may stay awake with its lid closed: always on power unless allowed, never hot nor in Low
/// Power Mode, for a few hours at most. A closed Mac cools worse, and may be in a bag.
public struct ClosedLidPolicy: Equatable, Sendable {
    public var requiresPower: Bool
    /// On battery (when allowed), down to this charge.
    public var batteryFloor: Int
    /// How long the lid may stay closed in a session, counted from when it was first allowed.
    public var maxDuration: TimeInterval

    public init(requiresPower: Bool = true, batteryFloor: Int = 30, maxDuration: TimeInterval = 4 * 3600) {
        self.requiresPower = requiresPower
        self.batteryFloor = batteryFloor
        self.maxDuration = maxDuration
    }

    /// `since`: when the closed-lid part was first applied in this session (nil: not yet).
    public func decide(_ power: PowerConditions, since: Date?, now: Date) -> ClosedLidDecision {
        guard power.hasLid else { return .end(.noLid) }
        if power.isHot { return .end(.thermal) }
        if power.lowPowerMode { return .end(.lowPowerMode) }
        if let since, now.timeIntervalSince(since) >= maxDuration { return .end(.maxDuration) }
        if !power.onPower {
            if requiresPower { return .suspend(.needsPower) }
            if let battery = power.batteryPercent, battery < batteryFloor { return .suspend(.lowBattery) }
        }
        return .apply
    }
}

/// "Screen off, Mac on": after `delay` without input the screen goes off, once; input brings it back and
/// the count starts again.
public struct ScreenOffRule: Equatable, Sendable {
    public var delay: TimeInterval

    public init(delay: TimeInterval) { self.delay = delay }

    /// `idle`: seconds since the last input; `alreadyOff`: the screen was put to sleep since that input.
    public func shouldTurnScreenOff(idle: TimeInterval, alreadyOff: Bool) -> Bool {
        delay > 0 && idle >= delay && !alreadyOff
    }
}
