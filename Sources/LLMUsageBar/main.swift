import AppKit
import LLMUsageBarCore

/// Holds the object graph for the life of the process and wires system events to the pollers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller<ClaudeUsageSnapshot, String>?
    private var creditsPoller: UsagePoller<OpenRouterCreditsSnapshot, String>?
    private var chatGPTPoller: UsagePoller<ChatGPTUsageSnapshot, ChatGPTCredentials>?
    private var statusItem: StatusItemController?
    private var wakeObserver: NSObjectProtocol?

    /// ChatGPT's shortest rate-limit window is five hours, and the endpoint is shared with the
    /// ChatGPT app and `codex` on the same account. Polling it on the same 60–90 s cadence as the
    /// other two would spend requests on numbers that cannot have moved, so this provider keeps
    /// its own floor whatever interval the user picks. The floor governs opportunistic fetches
    /// too — a menu-open or wake refresh reuses numbers younger than this rather than restarting
    /// the timer early — so there is no separate staleness window to set here.
    private static let chatGPTMinimumInterval: TimeInterval = 180

    func applicationDidFinishLaunching(_ notification: Notification) {
        let credentials = ClaudeCredentialStore()
        let client = ClaudeAPIClient()
        let openRouterKeys = OpenRouterKeyStore()
        let openRouterClient = OpenRouterAPIClient()
        let chatGPTAuth = ChatGPTAuthStore()
        let chatGPTClient = ChatGPTAPIClient()
        let preferences = Preferences()

        let poller = UsagePoller(
            interval: preferences.refreshInterval,
            name: "claude",
            credentialProvider: { try credentials.accessToken() },
            fetcher: { token in try await client.fetchUsage(token: token) }
        )
        let creditsPoller = UsagePoller(
            interval: preferences.refreshInterval,
            name: "openrouter",
            credentialProvider: { try openRouterKeys.apiKey() },
            fetcher: { key in try await openRouterClient.fetchCredits(key: key) }
        )
        let chatGPTPoller = UsagePoller(
            interval: preferences.refreshInterval,
            name: "chatgpt",
            minimumInterval: Self.chatGPTMinimumInterval,
            credentialProvider: { try chatGPTAuth.credentials() },
            fetcher: { credentials in try await chatGPTClient.fetchUsage(credentials: credentials) }
        )
        self.poller = poller
        self.creditsPoller = creditsPoller
        self.chatGPTPoller = chatGPTPoller
        self.statusItem = StatusItemController(
            poller: poller,
            creditsPoller: creditsPoller,
            chatGPTPoller: chatGPTPoller,
            preferences: preferences
        )

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Every AI client on this machine refreshes at the moment of wake, against the same
            // account-level limits. wake() drops the timer fire that was missed during sleep and
            // fetches once after a random delay, so this app polls after that burst. Each poller
            // draws its own delay, which also spreads the three apart. Providers the user toggled
            // off are not fetched.
            Task { @MainActor in if preferences.showClaudeUsage { poller.wake() } }
            Task { @MainActor in if preferences.showOpenRouterCredits { creditsPoller.wake() } }
            Task { @MainActor in if preferences.showChatGPTUsage { chatGPTPoller.wake() } }
        }

        if preferences.showClaudeUsage { poller.start() }
        if preferences.showOpenRouterCredits { creditsPoller.start() }
        if preferences.showChatGPTUsage { chatGPTPoller.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        creditsPoller?.stop()
        chatGPTPoller?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

// Process startup genuinely runs on the main thread; `assumeIsolated` tells the compiler
// what the toolchain doesn't infer automatically for top-level main.swift code.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
