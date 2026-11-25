import AppKit
import UserNotifications
import AwakeCore
import AwakeSettings
import SuiteCore

/// Ties the pieces together: the menu bar icon starts and stops sessions, the engine keeps the Mac awake
/// (IOKit assertions, lid sleep through suite-guard's ClamshellGuard), and power changes, a timer and the
/// other apps' messages (`AwakeMessage`) keep it up to date.
final class AwakeAppDelegate: NSObject, NSApplicationDelegate {
    let settings = AwakeSettings()
    private let lid = ClamshellLid()
    private(set) lazy var engine = AwakeEngine(
        assertions: IOKitAssertions(), lid: lid, display: PmsetDisplaySleeper(),
        options: { [settings] in AwakeOptions(settings) })
    private lazy var statusMenu = StatusMenu(delegate: self)
    private var tick: Timer?
    private var endTimer: Timer?
    private var powerObserver: PowerSourceObserver?
    private var observers: [NSObjectProtocol] = []
    /// False when Awake quit at launch (`--if-enabled` while off): then it leaves its status alone.
    private var running = false

    /// Awake keeps itself up to date from its own releases, never during a session (relaunching ends it).
    private(set) lazy var updater = SuiteUpdater(appName: "Awake", isBusy: { [weak self] in
        self?.engine.isActive ?? false
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never resumes anything: lid sleep back, should a previous Awake have been stopped without it.
        lid.restoreAtLaunch()
        // Started by another app only to run if it is on (`--if-enabled`): off, nothing to do. Opened by the
        // user, opening it is turning it on.
        if CommandLine.arguments.contains("--if-enabled") && !settings.isEnabled {
            NSApp.terminate(nil)
            return
        }
        running = true
        settings.isEnabled = true
        // "Lid closed" never outlives the Awake that had it: off again at each launch.
        settings.allowsClosedLid = false
        settings.statusHasLid = MacReadings.power().hasLid
        settings.loginStatus = LoginItem.status
        writeStatus()

        engine.onChange = { [weak self] in self?.sessionDidChange() }
        engine.onSafetyStop = { [weak self] stop in self?.notify(stop) }
        statusMenu.show()
        updater.start()

        powerObserver = PowerSourceObserver { [weak self] in self?.update() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.update() })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                            queue: .main) { [weak self] _ in self?.update() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.update() })
        // Another user takes the screen: this user's session ends, as it would at logout.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.engine.stop(.quit)
            })
        listen()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Assertions die with the process; lid sleep doesn't, so it comes back now.
        lid.restoreLidSleep()
        guard running else { return }
        engine.stop(.quit)
        settings.statusActive = false
        settings.statusSessionEnds = nil
        AwakeMessage.stateDidChange.post()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusMenu.open()
        return false
    }

    // MARK: Sessions

    func start(_ length: SessionLength) {
        engine.start(length, readings: MacReadings.now())
        // Asked at the first session, while the user is here, not when a stop happens.
        if settings.notifiesSafetyStops {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Tells the user safety ended the session, or its closed-lid part: they may be away from the Mac.
    private func notify(_ stop: SafetyStop) {
        guard settings.notifiesSafetyStops else { return }
        let content = UNMutableNotificationContent()
        switch stop {
        case .session(let reason):
            content.title = String(localized: "Awake stopped")
            content.body = StatusMenu.endText(reason, settings: settings) ?? ""
        case .closedLid(let reason):
            content.title = String(localized: "Lid closed turned off")
            content.body = StatusMenu.closedLidEndText(reason) ?? ""
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "safety-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// What the icon's click (and `AwakeMessage.toggle`) does: the default length, or stop.
    func toggle() {
        engine.isActive ? engine.stop(.user) : start(SessionLength(minutes: settings.defaultDuration))
    }

    func stop() {
        engine.stop(.user)
    }

    private func update() {
        engine.update(readings: MacReadings.now())
        statusMenu.refresh()
    }

    private func sessionDidChange() {
        tick?.invalidate()
        endTimer?.invalidate()
        tick = nil
        endTimer = nil
        if let session = engine.session {
            // Every 5 seconds: the lid, idle time for "Screen off, Mac on", lid sleep turned off again.
            tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.update() }
            tick?.tolerance = 1
            if let ends = session.ends {
                endTimer = Timer(fire: ends, interval: 0, repeats: false) { [weak self] _ in self?.update() }
                endTimer.map { RunLoop.main.add($0, forMode: .common) }
            }
        }
        writeStatus()
        statusMenu.refresh()
    }

    private func writeStatus() {
        settings.statusActive = engine.isActive
        settings.statusSessionEnds = engine.session?.ends
        AwakeMessage.stateDidChange.post()
    }

    // MARK: Options (the menu's; Suite Settings writes the same settings)

    func setClosedLid(_ on: Bool) {
        settings.allowsClosedLid = on
        update()
    }

    func setScreenOff(minutes: Int) {
        settings.screenOffMinutes = minutes
        update()
    }

    func setOpensAtLogin(_ on: Bool) {
        settings.opensAtLogin = on
        LoginItem.set(on)
        settings.loginStatus = LoginItem.status
        AwakeMessage.stateDidChange.post()
    }

    // MARK: Messages

    private func listen() {
        AwakeMessage.toggle.observe { [weak self] _ in self?.toggle() }
        AwakeMessage.start.observe { [weak self] note in
            guard let self else { return }
            let minutes = note.userInfo?["minutes"] as? Int ?? settings.defaultDuration
            start(SessionLength(minutes: minutes))
        }
        AwakeMessage.stop.observe { [weak self] _ in self?.stop() }
        AwakeMessage.setOpensAtLogin.observe { [weak self] note in
            self?.setOpensAtLogin(note.userInfo?["on"] as? Bool ?? false)
        }
        AwakeMessage.settingsDidChange.observe { [weak self] _ in
            guard let self else { return }
            settings.reload()
            guard settings.isEnabled else { return NSApp.terminate(nil) }
            update()
        }
    }
}
