import Foundation
import ServiceManagement

/// User settings. Interval and provider toggles live in UserDefaults; launch-at-login is
/// asked of the system each time. `@unchecked Sendable` is sound because the class itself is
/// stateless: every property reads through UserDefaults or SMAppService, both thread-safe.
final class Preferences: @unchecked Sendable {
    struct IntervalOption: Equatable {
        let title: String
        let seconds: TimeInterval
    }

    // No sub-60s option: the usage endpoint is shared and rate-limited (it also backs the
    // claude.ai usage page and the Claude Code status line), so polling faster than once a
    // minute risks HTTP 429. 90 s is the default; 60 s is the floor for anyone who wants it.
    static let intervalOptions: [IntervalOption] = [
        IntervalOption(title: "60 s", seconds: 60),
        IntervalOption(title: "90 s", seconds: 90),
        IntervalOption(title: "3 min", seconds: 180),
        IntervalOption(title: "5 min", seconds: 300),
    ]
    static let defaultInterval: TimeInterval = 90
    private static let intervalKey = "refreshInterval"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The floor also migrates anyone who had picked the old 30 s option (removed because it
    /// invites HTTP 429) up to the default on next launch, instead of silently keeping them
    /// below the floor.
    static let minInterval: TimeInterval = 60

    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Self.intervalKey)
            return stored >= Self.minInterval ? stored : Self.defaultInterval
        }
        set { defaults.set(newValue, forKey: Self.intervalKey) }
    }

    // MARK: Provider toggles

    private static let showClaudeKey = "showClaudeUsage"
    private static let showOpenRouterKey = "showOpenRouterCredits"

    /// Both providers are on until the user turns one off. A provider that is off is dropped
    /// from the menu bar title and its poller stays stopped, so nothing is fetched for it.
    var showClaudeUsage: Bool {
        get { defaults.object(forKey: Self.showClaudeKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showClaudeKey) }
    }

    var showOpenRouterCredits: Bool {
        get { defaults.object(forKey: Self.showOpenRouterKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showOpenRouterKey) }
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
