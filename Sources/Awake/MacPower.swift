import AppKit
import AwakeCore
import ClamshellGuard
import IOKit.ps
import IOKit.pwr_mgt

/// Power assertions through IOKit (`IOPMAssertionCreateWithProperties`), named "Awake": they show in
/// `pmset -g assertions` and in Activity Monitor › Energy. powerd releases them when Awake quits or
/// crashes, and by itself at the timeout of a timed session.
final class IOKitAssertions: PowerAssertions {
    private var assertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func hold(_ level: AssertionLevel, reason: String, timeout: TimeInterval?) {
        let type = level == .systemAndDisplay ? kIOPMAssertPreventUserIdleDisplaySleep
                                              : kIOPMAssertPreventUserIdleSystemSleep
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: type,
            kIOPMAssertionNameKey: "Awake",
            kIOPMAssertionDetailsKey: reason,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
        ]
        if let timeout {
            properties[kIOPMAssertionTimeoutKey] = max(1, Int(timeout))
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }
        var created = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &created)
        // The new one first, then the old one: the Mac is never left without either.
        release()
        if result == kIOReturnSuccess {
            assertion = created
        } else {
            NSLog("Awake: could not create the power assertion (\(result))")
        }
    }

    func release() {
        guard assertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
    }
}

/// Lid sleep through suite-guard's `ClamshellSleepManager`, which notes it in Awake's defaults so Suite
/// Guard turns it back on should Awake vanish; Suite Guard is loaded while it is off.
final class ClamshellLid: LidSleepControl {
    private let manager = ClamshellSleepManager()

    func disableLidSleep() -> Bool {
        let wasOff = manager.isHiding
        let took = manager.turnOff()
        if !wasOff { GuardAgent.update() }
        if took && RootDomainClamshellSwitch.lidClosingSleeps {
            // Read back: `AppleClamshellCausesSleep` may only be refreshed at the next lid event.
            NSLog("Awake: lid sleep turned off, yet IOPMrootDomain still reports AppleClamshellCausesSleep")
        }
        return took
    }

    func restoreLidSleep() {
        guard manager.isHiding else { return }
        manager.restore()
        GuardAgent.update()
    }

    /// At launch: lid sleep back, should a previous Awake have been stopped without putting it back.
    func restoreAtLaunch() {
        if manager.isHiding { restoreLidSleep() } else { GuardAgent.update() }
    }
}

/// `pmset displaysleepnow` (documented in pmset(1), needs no root): every screen goes to sleep now; the
/// Mac doesn't.
final class PmsetDisplaySleeper: DisplaySleeper {
    func sleepDisplays() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("Awake: could not put the screens to sleep: \(error)") }
    }
}

/// What the Mac looks like now: power source, battery, Low Power Mode, heat, lid, idle time.
enum MacReadings {
    static func now() -> Readings {
        Readings(power: power(), idle: idleSeconds(), lidClosed: RootDomainClamshellSwitch.isLidClosed)
    }

    static func power() -> PowerConditions {
        var onPower = true
        var battery: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                onPower = type != kIOPMBatteryPowerKey
            }
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                        as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                battery = current * 100 / max
            }
        }
        let thermal: PowerConditions.Thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        return PowerConditions(onPower: onPower, batteryPercent: battery,
                               lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                               thermal: thermal, hasLid: RootDomainClamshellSwitch.hasLid)
    }

    /// Seconds since the last input of any kind (no permission needed).
    static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Calls back when the power source or the battery changes (`IOPSNotificationCreateRunLoopSource`).
final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
