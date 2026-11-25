import Foundation

/// Awake's settings, kept in its user defaults (`local.suite.awake`). Awake reads them as its own; Suite
/// Settings, for its Awake tab, reads and writes them through `forSuiteSettings()` and tells Awake with
/// `AwakeMessage.settingsDidChange`. Everything is off by default: installed, Awake changes nothing until
/// the user turns it on.
public final class AwakeSettings {
    public static let bundleID = "local.suite.awake"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Awake's settings as another app (Suite Settings) sees them.
    public static func forSuiteSettings() -> AwakeSettings {
        AwakeSettings(defaults: UserDefaults(suiteName: bundleID) ?? .standard)
    }

    /// Picks up what the other app just wrote.
    public func reload() {
        defaults.synchronize()
    }

    // MARK: Awake

    /// Whether Awake runs at all (and shows its menu bar icon). Off by default; opening Awake.app turns it on.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: "isEnabled") }
        set { defaults.set(newValue, forKey: "isEnabled") }
    }

    /// The lengths offered in the menu, in minutes.
    public static let defaultDurations = [15, 30, 60, 120, 300]

    /// The lengths offered in the menu, in minutes, shortest first; positive, at most a week.
    public var durations: [Int] {
        get {
            let saved = (defaults.array(forKey: "durations") as? [Int])?.filter { $0 > 0 && $0 <= 10_080 }
            guard let saved, !saved.isEmpty else { return Self.defaultDurations }
            return Array(Set(saved)).sorted()
        }
        set { defaults.set(Array(Set(newValue.filter { $0 > 0 && $0 <= 10_080 })).sorted(), forKey: "durations") }
    }

    /// What turning Awake on starts, in minutes: 0, the default, until stopped.
    public var defaultDuration: Int {
        get { max(0, defaults.integer(forKey: "defaultDuration")) }
        set { defaults.set(max(0, newValue), forKey: "defaultDuration") }
    }

    // MARK: Screen off, Mac on

    /// The delays offered for "Screen Off, Mac On", in minutes.
    public static let screenOffChoices = [1, 2, 5, 10]

    /// While Awake is on, the screen goes off after this many minutes without input, the Mac staying awake;
    /// 0, the default, keeps the screen on.
    public var screenOffMinutes: Int {
        get { max(0, defaults.integer(forKey: "screenOffMinutes")) }
        set { defaults.set(max(0, newValue), forKey: "screenOffMinutes") }
    }

    // MARK: Safety

    /// On battery, Awake stops below this charge (percent); 0 never.
    public var stopsBelowBattery: Int {
        get { defaults.object(forKey: "stopsBelowBattery") as? Int ?? 20 }
        set { defaults.set(min(max(0, newValue), 100), forKey: "stopsBelowBattery") }
    }

    /// Awake stops when Low Power Mode turns on.
    public var stopsInLowPowerMode: Bool {
        get { defaults.object(forKey: "stopsInLowPowerMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stopsInLowPowerMode") }
    }

    /// Awake stops when the Mac gets too hot (thermal state serious or critical).
    /// A notification when safety (battery, Low Power Mode, heat, the closed-lid time limit) ends a session
    /// or its closed-lid part. On by default; macOS asks once, at the first session.
    public var notifiesSafetyStops: Bool {
        get { defaults.object(forKey: "notifiesSafetyStops") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifiesSafetyStops") }
    }

    public var stopsOnThermalPressure: Bool {
        get { defaults.object(forKey: "stopsOnThermalPressure") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stopsOnThermalPressure") }
    }

    // MARK: Lid closed

    /// While Awake is on, closing the lid doesn't sleep the Mac, without an external display. Off by default,
    /// and off again at each launch of Awake (asked by the user): it never lasts beyond the Awake that had it.
    /// Uses an undocumented behaviour of a public IOKit call (see ClamshellGuard in suite-guard).
    public var allowsClosedLid: Bool {
        get { defaults.bool(forKey: "allowsClosedLid") }
        set { defaults.set(newValue, forKey: "allowsClosedLid") }
    }

    /// The lid may stay closed only on power (the default).
    public var closedLidRequiresPower: Bool {
        get { defaults.object(forKey: "closedLidRequiresPower") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "closedLidRequiresPower") }
    }

    /// On battery (when allowed), the lid may stay closed down to this charge (percent).
    public var closedLidBatteryFloor: Int {
        get { defaults.object(forKey: "closedLidBatteryFloor") as? Int ?? 30 }
        set { defaults.set(min(max(0, newValue), 100), forKey: "closedLidBatteryFloor") }
    }

    /// The lid may stay closed this many hours at most in a session; then lid sleep comes back.
    public var closedLidMaxHours: Int {
        get { max(1, defaults.object(forKey: "closedLidMaxHours") as? Int ?? 4) }
        set { defaults.set(max(1, newValue), forKey: "closedLidMaxHours") }
    }

    /// The built-in screen goes off when the lid closes.
    public var closedLidSleepsDisplay: Bool {
        get { defaults.object(forKey: "closedLidSleepsDisplay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "closedLidSleepsDisplay") }
    }

    // MARK: Login

    /// Whether Awake starts at login (its own login item, which only it can register).
    public var opensAtLogin: Bool {
        get { defaults.bool(forKey: "opensAtLogin") }
        set { defaults.set(newValue, forKey: "opensAtLogin") }
    }

    public enum LoginStatus: String, Sendable {
        case off, on, needsApproval
    }

    // MARK: Reported by Awake, shown by Suite Settings (kept out of profiles)

    /// Awake's login item as macOS has it.
    public var loginStatus: LoginStatus {
        get { defaults.string(forKey: "StatusLoginItem").flatMap(LoginStatus.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "StatusLoginItem") }
    }

    /// Whether a session keeps the Mac awake now.
    public var statusActive: Bool {
        get { defaults.bool(forKey: "StatusActive") }
        set { defaults.set(newValue, forKey: "StatusActive") }
    }

    /// When the current session ends; nil until stopped, or when none runs.
    public var statusSessionEnds: Date? {
        get { defaults.object(forKey: "StatusSessionEnds") as? Date }
        set { defaults.set(newValue, forKey: "StatusSessionEnds") }
    }

    /// Whether this Mac has a lid (the lid-closed option is shown only then).
    public var statusHasLid: Bool {
        get { defaults.bool(forKey: "StatusHasLid") }
        set { defaults.set(newValue, forKey: "StatusHasLid") }
    }

    /// The keys Awake writes for others to read, not settings (left out of settings profiles).
    public static let statusKeys = ["StatusLoginItem", "StatusActive", "StatusSessionEnds", "StatusHasLid"]
}
