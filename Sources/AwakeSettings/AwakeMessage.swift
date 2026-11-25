import Foundation

/// What Awake and the other apps of the suite say to each other, as distributed notifications: Suite
/// Settings changes Awake's settings, Bindings (or any app) turns it on and off, and Awake says when its
/// state changes. Nobody imports Awake for this.
public enum AwakeMessage: String, CaseIterable, Sendable {
    /// To Awake: settings were changed by another app; read them again.
    case settingsDidChange
    /// To Awake: start a session if none runs, else stop it.
    case toggle
    /// To Awake: start a session (`"minutes"`: its length, 0 until stopped; absent: the default length).
    case start
    /// To Awake: stop the session.
    case stop
    /// To Awake: register (`"on": true`) or remove its login item.
    case setOpensAtLogin
    /// From Awake: a session started or ended, or its status changed (see `AwakeSettings`' status keys).
    case stateDidChange

    public var name: Notification.Name {
        Notification.Name("local.suite.awake." + rawValue)
    }

    /// Delivered at once, even to an app in the background.
    public func post(_ userInfo: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: userInfo,
                                                                     deliverImmediately: true)
    }

    @discardableResult
    public func observe(_ handler: @escaping (Notification) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main, using: handler)
    }
}
