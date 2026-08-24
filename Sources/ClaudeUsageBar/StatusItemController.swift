import AppKit
import ClaudeUsageBarCore

/// Owns the NSStatusItem: renders the title/tooltip from FetchState and builds the click menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSViewToolTipOwner {
    private let statusItem: NSStatusItem
    private let poller: UsagePoller<UsageSnapshot, String>
    private let creditsPoller: UsagePoller<CreditsSnapshot, String>
    private let chatGPTPoller: UsagePoller<ChatGPTUsageSnapshot, ChatGPTCredentials>
    private let preferences: Preferences
    private let menu = NSMenu()
    private var state: FetchState<UsageSnapshot> = .idle
    private var creditsState: FetchState<CreditsSnapshot> = .idle
    private var chatGPTState: FetchState<ChatGPTUsageSnapshot> = .idle
    private var isMenuOpen = false
    private var appearanceObservation: NSKeyValueObservation?

    init(poller: UsagePoller<UsageSnapshot, String>,
         creditsPoller: UsagePoller<CreditsSnapshot, String>,
         chatGPTPoller: UsagePoller<ChatGPTUsageSnapshot, ChatGPTCredentials>,
         preferences: Preferences) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.poller = poller
        self.creditsPoller = creditsPoller
        self.chatGPTPoller = chatGPTPoller
        self.preferences = preferences
        super.init()

        statusItem.autosaveName = "ClaudeUsageBar"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = []
        poller.onChange = { [weak self] state in self?.render(state) }
        creditsPoller.onChange = { [weak self] creditsState in
            guard let self else { return }
            self.creditsState = creditsState
            self.render(self.state)
        }
        chatGPTPoller.onChange = { [weak self] chatGPTState in
            guard let self else { return }
            self.chatGPTState = chatGPTState
            self.render(self.state)
        }
        // The provider icons are tinted when first drawn; re-render on appearance flips so a
        // rasterization from the old appearance never lingers in the title.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render(self.state)
            }
        }
        render(.idle)
    }

    // MARK: Rendering

    /// One title group: a provider's logo followed by its segments.
    struct TitleGroup {
        let icon: NSImage
        let segments: [TitleSegment]
    }

    private func titleGroups() -> [TitleGroup] {
        var groups: [TitleGroup] = []
        if preferences.showClaudeUsage {
            groups.append(TitleGroup(icon: ProviderIcons.claude(), segments: Formatting.titleSegments(for: state)))
        }
        if preferences.showChatGPTUsage {
            // The logo identifies the provider, so the window labels ("5h", "W") are the only text.
            let segments = Formatting.chatGPTTitleSegments(for: chatGPTState)
            if !segments.isEmpty {
                groups.append(TitleGroup(icon: ProviderIcons.openAI(), segments: segments))
            }
        }
        if preferences.showOpenRouterCredits {
            // The logo stands in for the old "OR" text label.
            let segments = Formatting.openRouterTitleSegments(for: creditsState, includeShortLabel: false)
            if !segments.isEmpty {
                groups.append(TitleGroup(icon: ProviderIcons.openRouter(), segments: segments))
            }
        }
        return groups
    }

    private func render(_ state: FetchState<UsageSnapshot>) {
        self.state = state
        guard let button = statusItem.button else { return }
        button.attributedTitle = Self.attributedTitle(groups: titleGroups())
        // Re-added on every render so the tracking rect follows the title's width. The tooltip
        // text itself is computed lazily in `view(_:stringForToolTip:point:userData:)` at hover
        // time, so the "Updated N s ago" text is never stale between polls.
        button.removeAllToolTips()
        button.addToolTip(button.bounds, owner: self, userData: nil)
        // If the menu is open, the fetch triggered by menuWillOpen just returned — rebuild the
        // open menu so its rows and "Updated N ago" line show the fresh numbers immediately.
        if isMenuOpen { rebuildMenu() }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard preferences.showClaudeUsage || preferences.showChatGPTUsage || preferences.showOpenRouterCredits else {
            return "Claude, ChatGPT, and OpenRouter are all hidden. Show one again from this menu."
        }
        // A hidden provider goes in as .idle, which Formatting treats as nothing to say.
        return Formatting.tooltip(
            for: preferences.showClaudeUsage ? state : .idle,
            credits: preferences.showOpenRouterCredits ? creditsState : .idle,
            chatGPT: preferences.showChatGPTUsage ? chatGPTState : .idle,
            now: Date()
        )
    }

    /// Gap between provider groups. Wider than the in-group separator: each group already
    /// starts with its logo, so a dot between groups would read as part of the numbers.
    static let groupGap = "  "

    static func attributedTitle(groups: [TitleGroup]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for group in groups {
            if result.length > 0 {
                result.append(NSAttributedString(string: groupGap, attributes: [.font: font]))
            }
            result.append(attachmentString(for: group.icon, font: font))
            result.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            for (index, segment) in group.segments.enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: Formatting.separator,
                                                     attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                }
                result.append(NSAttributedString(string: segment.text,
                                                 attributes: [.font: font, .foregroundColor: color(for: segment.severity)]))
            }
        }
        if result.length == 0 {
            // Every provider hidden: keep a small clickable glyph so the menu stays reachable.
            if let gauge = ProviderIcons.hiddenPlaceholder() {
                result.append(attachmentString(for: gauge, font: font))
            } else {
                result.append(NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
        }
        return result
    }

    /// The icon as an inline attachment, vertically centered on the text's cap height.
    private static func attachmentString(for icon: NSImage, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = icon
        let side = ProviderIcons.pointSize
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }

    static func color(for severity: Severity) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Fetch the moment the user looks, so the panel shows current numbers instead of
        // whatever the last background tick left (which App Nap can delay by minutes). This is
        // opportunistic: it does nothing during a 429 backoff, and nothing if the numbers are
        // already fresh, so reopening the menu repeatedly does not hammer the rate-limited
        // endpoints. Each poller applies its own freshness window. The open menu updates itself
        // when a fetch returns (see `render`). Providers the user turned off are not fetched.
        if preferences.showClaudeUsage { Task { await poller.refreshIfStale(trigger: .menuOpen) } }
        if preferences.showChatGPTUsage { Task { await chatGPTPoller.refreshIfStale(trigger: .menuOpen) } }
        if preferences.showOpenRouterCredits { Task { await creditsPoller.refreshIfStale(trigger: .menuOpen) } }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// True when some visible provider already has numbers on screen. A provider with no
    /// credentials stays quiet in that case — "no key found" is noise next to real rows, and the
    /// explanation only earns a line when the menu would otherwise not explain itself.
    private var anyVisibleSnapshot: Bool {
        (preferences.showClaudeUsage && state.snapshot != nil)
            || (preferences.showChatGPTUsage && chatGPTState.snapshot != nil)
            || (preferences.showOpenRouterCredits && creditsState.snapshot != nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let showClaude = preferences.showClaudeUsage
        let showChatGPT = preferences.showChatGPTUsage
        let showOpenRouter = preferences.showOpenRouterCredits

        if showClaude, let error = state.error {
            addDisabled(Formatting.errorMessage(error, last: state.snapshot, now: now))
            menu.addItem(.separator())
        }
        if showChatGPT, let chatGPTError = chatGPTState.error,
           chatGPTError != .notSignedIn || !anyVisibleSnapshot {
            addDisabled(Formatting.chatGPTErrorMessage(chatGPTError, last: chatGPTState.snapshot, now: now))
            menu.addItem(.separator())
        }
        if showOpenRouter, let creditsError = creditsState.error,
           creditsError != .notSignedIn || !anyVisibleSnapshot {
            addDisabled(Formatting.openRouterErrorMessage(creditsError, last: creditsState.snapshot, now: now))
            menu.addItem(.separator())
        }

        // Claude and ChatGPT rows share one label column so their percentages line up.
        let claudeRows = showClaude ? state.snapshot.map { Formatting.menuRows(for: $0, now: now) } ?? [] : []
        let chatGPTRows = showChatGPT ? chatGPTState.snapshot.map { Formatting.chatGPTMenuRows(for: $0, now: now) } ?? [] : []
        let labelWidth = (claudeRows + chatGPTRows).map(\.label.count).max() ?? 0

        for row in claudeRows {
            addMonospaced(Formatting.menuLine(row, labelWidth: labelWidth), font: mono)
        }
        if showChatGPT, let chatGPTSnapshot = chatGPTState.snapshot {
            if !claudeRows.isEmpty { menu.addItem(.separator()) }
            if let planLine = Formatting.chatGPTPlanLine(for: chatGPTSnapshot) {
                addMonospaced(planLine, font: mono)
            }
            for row in chatGPTRows {
                addMonospaced(Formatting.menuLine(row, labelWidth: labelWidth), font: mono)
            }
        }
        if showOpenRouter, let creditsSnapshot = creditsState.snapshot {
            if !claudeRows.isEmpty || !chatGPTRows.isEmpty { menu.addItem(.separator()) }
            addMonospaced(Formatting.openRouterMenuLine(for: creditsSnapshot), font: mono)
        }

        let visibleSnapshotDate = (showClaude ? state.snapshot?.fetchedAt : nil)
            ?? (showChatGPT ? chatGPTState.snapshot?.fetchedAt : nil)
            ?? (showOpenRouter ? creditsState.snapshot?.fetchedAt : nil)
        if let updatedAt = visibleSnapshotDate {
            menu.addItem(.separator())
            addDisabled("Updated \(Formatting.agoText(since: updatedAt, now: now))")
        } else if !showClaude && !showChatGPT && !showOpenRouter {
            addDisabled("Claude, ChatGPT, and OpenRouter credits are hidden")
            menu.addItem(.separator())
        } else if !anyVisibleError {
            // Every visible provider is still on its first fetch.
            addDisabled("Loading…")
            menu.addItem(.separator())
        }

        if showClaude || showChatGPT || showOpenRouter {
            addAction("Refresh", #selector(refreshNow), key: "r")
        }
        if showClaude {
            addAction("Open usage page (claude.ai)", #selector(openUsagePage))
        }
        if showChatGPT, chatGPTState.snapshot != nil || chatGPTState.error.map({ $0 != .notSignedIn }) == true {
            addAction("Open usage page (chatgpt.com)", #selector(openChatGPTUsagePage))
        }
        if showOpenRouter, creditsState.snapshot != nil || creditsState.error.map({ $0 != .notSignedIn }) == true {
            addAction("Open credits page (openrouter.ai)", #selector(openCreditsPage))
        }
        menu.addItem(.separator())

        let claudeToggle = addAction("Show Claude subscription", #selector(toggleClaudeUsage))
        claudeToggle.state = showClaude ? .on : .off
        let chatGPTToggle = addAction("Show ChatGPT subscription", #selector(toggleChatGPTUsage))
        chatGPTToggle.state = showChatGPT ? .on : .off
        let openRouterToggle = addAction("Show OpenRouter credits", #selector(toggleOpenRouterCredits))
        openRouterToggle.state = showOpenRouter ? .on : .off
        menu.addItem(.separator())

        let login = addAction("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = preferences.launchAtLogin ? .on : .off

        let intervalItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        intervalItem.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for option in Preferences.intervalOptions {
            let item = NSMenuItem(title: option.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            item.state = option.seconds == preferences.refreshInterval ? .on : .off
            submenu.addItem(item)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claude Usage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// True when a visible provider already put an error line in the menu, so "Loading…" would
    /// contradict it.
    private var anyVisibleError: Bool {
        (preferences.showClaudeUsage && state.error != nil)
            || (preferences.showChatGPTUsage && chatGPTState.error != nil)
            || (preferences.showOpenRouterCredits && creditsState.error != nil)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addMonospaced(_ title: String, font: NSFont) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func refreshNow() {
        if preferences.showClaudeUsage { Task { await poller.refresh(trigger: .manual) } }
        if preferences.showChatGPTUsage { Task { await chatGPTPoller.refresh(trigger: .manual) } }
        if preferences.showOpenRouterCredits { Task { await creditsPoller.refresh(trigger: .manual) } }
    }

    /// Turning a provider off stops its poller (no more requests) and re-renders the title
    /// without its segments. Turning it back on starts the poller, which fetches immediately.
    @objc private func toggleClaudeUsage() {
        preferences.showClaudeUsage.toggle()
        if preferences.showClaudeUsage { poller.start() } else { poller.stop() }
        render(state)
    }

    @objc private func toggleChatGPTUsage() {
        preferences.showChatGPTUsage.toggle()
        if preferences.showChatGPTUsage { chatGPTPoller.start() } else { chatGPTPoller.stop() }
        render(state)
    }

    @objc private func toggleOpenRouterCredits() {
        preferences.showOpenRouterCredits.toggle()
        if preferences.showOpenRouterCredits { creditsPoller.start() } else { creditsPoller.stop() }
        render(state)
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(Formatting.usagePageURL)
    }

    @objc private func openChatGPTUsagePage() {
        NSWorkspace.shared.open(Formatting.chatGPTUsagePageURL)
    }

    @objc private func openCreditsPage() {
        NSWorkspace.shared.open(Formatting.openRouterCreditsPageURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try preferences.setLaunchAtLogin(!preferences.launchAtLogin)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at login"
            alert.informativeText = "This only works when the app runs from an installed bundle (run `make install` and start /Applications/ClaudeUsageBar.app).\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        preferences.refreshInterval = seconds
        poller.interval = seconds
        creditsPoller.interval = seconds
        // The ChatGPT poller clamps this to its own floor; see UsagePoller.minimumInterval.
        chatGPTPoller.interval = seconds
    }
}
