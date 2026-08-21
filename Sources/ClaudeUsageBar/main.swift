import AppKit
import ClaudeUsageBarCore

/// Holds the object graph for the life of the process and wires system events to the poller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller<UsageSnapshot>?
    private var creditsPoller: UsagePoller<CreditsSnapshot>?
    private var statusItem: StatusItemController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let credentials = CredentialStore()
        let client = UsageAPIClient()
        let openRouterKeys = OpenRouterKeyStore()
        let openRouterClient = OpenRouterAPIClient()
        let preferences = Preferences()

        let poller = UsagePoller(
            interval: preferences.refreshInterval,
            tokenProvider: { try credentials.accessToken() },
            fetcher: { token in try await client.fetchUsage(token: token) }
        )
        let creditsPoller = UsagePoller(
            interval: preferences.refreshInterval,
            tokenProvider: { try openRouterKeys.apiKey() },
            fetcher: { key in try await openRouterClient.fetchCredits(key: key) }
        )
        self.poller = poller
        self.creditsPoller = creditsPoller
        self.statusItem = StatusItemController(poller: poller, creditsPoller: creditsPoller, preferences: preferences)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Opportunistic: skips if a fetch just happened before sleep or a backoff is active.
            Task { @MainActor in await poller.refreshIfStale() }
            Task { @MainActor in await creditsPoller.refreshIfStale() }
        }

        poller.start()
        creditsPoller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        creditsPoller?.stop()
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
