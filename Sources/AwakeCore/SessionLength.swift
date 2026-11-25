import Foundation

/// How long a session keeps the Mac awake: until stopped, for a number of minutes, or until a time.
public enum SessionLength: Equatable, Sendable {
    case indefinite
    case minutes(Int)
    case until(Date)

    /// From a length in minutes, as the settings keep it: 0 is until stopped.
    public init(minutes: Int) {
        self = minutes > 0 ? .minutes(minutes) : .indefinite
    }

    /// When a session of this length started at `start` ends; nil when it runs until stopped.
    public func endDate(from start: Date) -> Date? {
        switch self {
        case .indefinite: return nil
        case .minutes(let minutes): return start.addingTimeInterval(TimeInterval(max(0, minutes)) * 60)
        case .until(let date): return date
        }
    }

    /// The times offered for "Until": the next `count` steps of `step` minutes (every half hour by default),
    /// the first at least `margin` minutes away, so "until 10:30" is never chosen at 10:29.
    public static func untilChoices(now: Date, count: Int = 12, step: Int = 30, margin: Int = 10,
                                    calendar: Calendar = .current) -> [Date] {
        guard count > 0, step > 0 else { return [] }
        let earliest = now.addingTimeInterval(TimeInterval(margin) * 60)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: earliest)
        let minute = parts.minute ?? 0
        let rounded = (minute + step - 1) / step * step
        parts.minute = 0
        guard let hour = calendar.date(from: parts),
              var first = calendar.date(byAdding: .minute, value: rounded, to: hour) else { return [] }
        if first < earliest { first = first.addingTimeInterval(TimeInterval(step) * 60) }
        return (0..<count).compactMap { calendar.date(byAdding: .minute, value: $0 * step, to: first) }
    }
}

/// Why a session, or its closed-lid part, ended or waits.
public enum EndReason: String, Equatable, Sendable {
    /// The user stopped it.
    case user
    /// Its time was up.
    case timer
    /// On battery, the charge went below the setting.
    case lowBattery
    /// Low Power Mode turned on.
    case lowPowerMode
    /// The Mac got too hot.
    case thermal
    /// The lid stayed closed as long as allowed (closed-lid part only).
    case maxDuration
    /// The closed-lid part needs power (it comes back when the Mac is plugged in again).
    case needsPower
    /// This Mac has no lid (closed-lid part only).
    case noLid
    /// macOS refused to keep the Mac awake with its lid closed (closed-lid part only).
    case refused
    /// Awake was turned off or quit.
    case quit

    /// The reasons the user is told about (a notification): safety ended the session, or its closed-lid
    /// part, while they may be away.
    public var isSafetyStop: Bool {
        switch self {
        case .lowBattery, .lowPowerMode, .thermal, .maxDuration: true
        default: false
        }
    }
}

/// What safety ended, for the notification: the whole session, or only its closed-lid part.
public enum SafetyStop: Equatable, Sendable {
    case session(EndReason)
    case closedLid(EndReason)
}
