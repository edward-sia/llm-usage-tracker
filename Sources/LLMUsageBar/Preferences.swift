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

    // No sub-60s option: the usage endpoints are shared and rate-limited (Anthropic's also backs
    // the claude.ai usage page and the Claude Code status line; ChatGPT's also backs the ChatGPT
    // app and `codex`), so polling faster than once a minute risks HTTP 429. 90 s is the default;
    // 60 s is the floor for anyone who wants it. Individual providers can raise that floor further
    // for themselves — see the pollers built in main.swift.
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
        migrateLegacyDefaultsIfNeeded()
    }

    // MARK: Migration from the ClaudeUsageBar bundle id

    /// UserDefaults is keyed by bundle id, so renaming the app to LLMUsageBar left the settings
    /// behind in the old domain. Copy them across once, then never look again.
    ///
    /// Reading another domain works because the app is not sandboxed. If it ever is, this
    /// quietly finds nothing and every setting falls back to its default — which is also what
    /// happens for anyone who never ran the old build.
    private static let legacyDomain = "dev.llm-usage-tracker.ClaudeUsageBar"
    private static let migratedKey = "migratedFromClaudeUsageBar"

    private func migrateLegacyDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)

        guard let legacy = UserDefaults(suiteName: Self.legacyDomain) else { return }
        for key in [Self.intervalKey, Self.showClaudeKey, Self.showOpenRouterKey, Self.showChatGPTKey] {
            // Anything already set in the new domain wins: a value there was chosen after the
            // rename, so it is newer than whatever the old domain still holds.
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
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
    private static let showChatGPTKey = "showChatGPTUsage"

    /// Every provider is on until the user turns one off. A provider that is off is dropped
    /// from the menu bar title and its poller stays stopped, so nothing is fetched for it.
    var showClaudeUsage: Bool {
        get { defaults.object(forKey: Self.showClaudeKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showClaudeKey) }
    }

    var showOpenRouterCredits: Bool {
        get { defaults.object(forKey: Self.showOpenRouterKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showOpenRouterKey) }
    }

    var showChatGPTUsage: Bool {
        get { defaults.object(forKey: Self.showChatGPTKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showChatGPTKey) }
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
