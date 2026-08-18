import Foundation
import ServiceManagement

/// User settings. Interval lives in UserDefaults; launch-at-login is asked of the system each time.
final class Preferences {
    struct IntervalOption: Equatable {
        let title: String
        let seconds: TimeInterval
    }

    static let intervalOptions: [IntervalOption] = [
        IntervalOption(title: "30 s", seconds: 30),
        IntervalOption(title: "60 s", seconds: 60),
        IntervalOption(title: "3 min", seconds: 180),
        IntervalOption(title: "5 min", seconds: 300),
    ]
    static let defaultInterval: TimeInterval = 60
    private static let intervalKey = "refreshInterval"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Self.intervalKey)
            return stored > 0 ? stored : Self.defaultInterval
        }
        set { defaults.set(newValue, forKey: Self.intervalKey) }
    }

    /// True when the system reports the app registered as a login item.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when not running from an installed .app bundle (e.g. `swift run`).
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
