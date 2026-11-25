import AppKit
import SuiteCore

/// Awake: keeps the Mac awake, for a while or until stopped, from its menu bar icon.

// Reopened by the previous copy (an update): once it is gone, this copy carries on.
AppRelauncher.waitForPreviousCopy()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AwakeAppDelegate()
app.delegate = delegate
app.run()
