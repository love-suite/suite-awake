import AwakeSettings
import Foundation
import ServiceManagement

/// Awake's own login item: only the app itself can register it, so Suite Settings asks it to.
enum LoginItem {
    static var status: AwakeSettings.LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func set(_ on: Bool) {
        do {
            on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            NSLog("Awake: could not change the login item: \(error)")
        }
    }
}
