import AppKit
import AwakeCore
import AwakeSettings

/// Awake's menu bar icon. A Control Center control can't be built for Awake (see CLAUDE.md, "Control
/// Center"): instead the icon is always there while Awake runs, small and plain. A click starts a session
/// of the default length; while one runs (the icon is filled), a click opens the menu: what is left, Stop,
/// the lengths, the options. A right-click or an Option-click always opens it.
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let delegate: AwakeAppDelegate
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var headerItem: NSMenuItem?
    private var headerTimer: Timer?

    init(delegate: AwakeAppDelegate) {
        self.delegate = delegate
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    private var engine: AwakeEngine { delegate.engine }
    private var settings: AwakeSettings { delegate.settings }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        refresh()
    }

    /// Opens the menu under the icon.
    func open() {
        guard let item, let button = item.button else { return }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    func refresh() {
        guard let button = item?.button else { return }
        let active = engine.isActive
        let lidActive = engine.session?.closedLid == .active
        let name = active ? "cup.and.heat.waves.fill" : "cup.and.saucer"
        let fallback = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let description = !active ? String(localized: "Awake")
            : lidActive ? String(localized: "Awake, on, lid can stay closed")
            : String(localized: "Awake, on")
        button.image = (NSImage(systemSymbolName: name, accessibilityDescription: description)
                        ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description))
        button.image?.isTemplate = true
        button.toolTip = active ? headerText() : String(localized: "Awake: click to keep the Mac awake")
        if menu.numberOfItems > 0 { headerItem?.title = headerText() }
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu || engine.isActive {
            open()
        } else {
            delegate.toggle()
        }
    }

    // MARK: The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        build()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // What is left, counting down while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            headerItem?.title = headerText()
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        headerTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        headerTimer?.invalidate()
        headerTimer = nil
    }

    private func build() {
        menu.removeAllItems()
        let session = engine.session

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerItem = header
        if let lidLine = closedLidText(session) {
            let line = NSMenuItem(title: lidLine, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        if session != nil {
            menu.addItem(action(String(localized: "Stop"), #selector(stop)))
        } else {
            menu.addItem(action(String(localized: "Keep Awake"), #selector(startDefault)))
        }

        menu.addItem(.separator())
        menu.addItem(sectionTitle(String(localized: "Duration")))
        let until = action(String(localized: "Until Stopped"), #selector(startLength(_:)))
        until.representedObject = 0
        until.state = session?.length == .indefinite ? .on : .off
        menu.addItem(until)
        for minutes in settings.durations {
            let item = action(Self.lengthText(minutes: minutes), #selector(startLength(_:)))
            item.representedObject = minutes
            item.state = session?.length == .minutes(minutes) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(untilItem(session))

        menu.addItem(.separator())
        menu.addItem(sectionTitle(String(localized: "Options")))
        if settings.statusHasLid || MacReadings.power().hasLid {
            let lid = action(String(localized: "Lid Closed"), #selector(toggleClosedLid(_:)))
            lid.state = settings.allowsClosedLid ? .on : .off
            lid.toolTip = String(format: String(localized: "The Mac stays awake with its lid closed, without an external display: on power only, for %d hours at most, never when it is hot. A closed Mac cools less well: never put it in a bag while Awake is on."), settings.closedLidMaxHours)
            menu.addItem(lid)
        }
        menu.addItem(screenOffItem())
        let login = action(String(localized: "Open at Login"), #selector(toggleOpensAtLogin(_:)))
        login.state = settings.opensAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Quit Awake"), #selector(quit), key: "q"))
    }

    private func untilItem(_ session: Session?) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Until"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        for date in SessionLength.untilChoices(now: Date()) {
            let choice = action(formatter.string(from: date), #selector(startUntil(_:)))
            choice.representedObject = date
            submenu.addItem(choice)
        }
        if case .until(let date) = session?.length {
            item.state = .on
            item.title = String(format: String(localized: "Until %@"), formatter.string(from: date))
        }
        item.submenu = submenu
        return item
    }

    private func screenOffItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Screen Off, Mac On"), action: nil, keyEquivalent: "")
        item.toolTip = String(localized: "While Awake is on, the screen goes off after this long without use; the Mac stays awake.")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = settings.screenOffMinutes
        let off = action(String(localized: "Never"), #selector(setScreenOff(_:)))
        off.representedObject = 0
        off.state = current == 0 ? .on : .off
        submenu.addItem(off)
        for minutes in AwakeSettings.screenOffChoices {
            let choice = action(String(format: String(localized: "After %@"), Self.lengthText(minutes: minutes, capitalized: false)),
                                #selector(setScreenOff(_:)))
            choice.representedObject = minutes
            choice.state = current == minutes ? .on : .off
            submenu.addItem(choice)
        }
        item.state = current > 0 ? .on : .off
        item.submenu = submenu
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func sectionTitle(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Texts

    private func headerText() -> String {
        guard let session = engine.session else {
            if let reason = engine.lastEnd, let text = Self.endText(reason, settings: settings) { return text }
            return String(localized: "Awake is off")
        }
        guard let remaining = session.remaining(at: Date()) else { return String(localized: "Awake until stopped") }
        return String(format: String(localized: "Awake, %@ left"), Self.remainingText(remaining))
    }

    private func closedLidText(_ session: Session?) -> String? {
        guard let session else { return nil }
        switch session.closedLid {
        case .off: return nil
        case .active: return String(localized: "The lid can stay closed")
        case .waiting(.needsPower): return String(localized: "Lid closed: waiting for power")
        case .waiting(.lowBattery): return String(localized: "Lid closed: battery too low")
        case .waiting: return String(localized: "Lid closed: waiting")
        case .ended(let reason) where Self.closedLidEndText(reason) != nil: return Self.closedLidEndText(reason)
        case .ended(.refused): return String(localized: "Lid closed: refused by macOS")
        case .ended: return String(localized: "Lid closed: unavailable")
        }
    }

    /// Why the closed-lid part ended for safety, in the menu and the notification.
    static func closedLidEndText(_ reason: EndReason) -> String? {
        switch reason {
        case .maxDuration: return String(localized: "Lid closed: time limit reached")
        case .thermal: return String(localized: "Lid closed: the Mac is too hot")
        case .lowPowerMode: return String(localized: "Lid closed: Low Power Mode is on")
        default: return nil
        }
    }

    static func endText(_ reason: EndReason, settings: AwakeSettings) -> String? {
        switch reason {
        case .timer: return String(localized: "Stopped: time is up")
        case .lowBattery:
            return String(format: String(localized: "Stopped: battery below %d %%"), settings.stopsBelowBattery)
        case .lowPowerMode: return String(localized: "Stopped: Low Power Mode is on")
        case .thermal: return String(localized: "Stopped: the Mac is too hot")
        default: return nil
        }
    }

    /// "15 Minutes", "1 Hour" (as macOS says them in the user's language).
    static func lengthText(minutes: Int, capitalized: Bool = true) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = minutes % 60 == 0 ? [.hour] : [.hour, .minute]
        let text = formatter.string(from: TimeInterval(minutes) * 60) ?? "\(minutes)"
        // Menus are in title case in English only.
        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? true
        return capitalized && english ? text.capitalized : text
    }

    /// "1 h 12 min", "45 s".
    static func remainingText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.zeroFormattingBehavior = .dropAll
        let rounded = seconds >= 60 ? (seconds / 60).rounded(.up) * 60 : seconds.rounded(.up)
        return formatter.string(from: rounded) ?? ""
    }

    // MARK: Actions

    @objc private func startDefault() { delegate.toggle() }
    @objc private func stop() { delegate.stop() }

    @objc private func startLength(_ sender: NSMenuItem) {
        delegate.start(SessionLength(minutes: sender.representedObject as? Int ?? 0))
    }

    @objc private func startUntil(_ sender: NSMenuItem) {
        guard let date = sender.representedObject as? Date else { return }
        delegate.start(.until(date))
    }

    @objc private func toggleClosedLid(_ sender: NSMenuItem) {
        delegate.setClosedLid(sender.state != .on)
    }

    @objc private func setScreenOff(_ sender: NSMenuItem) {
        delegate.setScreenOff(minutes: sender.representedObject as? Int ?? 0)
    }

    @objc private func toggleOpensAtLogin(_ sender: NSMenuItem) {
        delegate.setOpensAtLogin(sender.state != .on)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
