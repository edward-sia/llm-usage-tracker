import AppKit
import ClaudeUsageBarCore

/// Owns the NSStatusItem: renders the title/tooltip from FetchState and builds the click menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let poller: UsagePoller
    private let preferences: Preferences
    private let menu = NSMenu()
    private var state: FetchState = .idle

    init(poller: UsagePoller, preferences: Preferences) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.poller = poller
        self.preferences = preferences
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = []
        poller.onChange = { [weak self] state in self?.render(state) }
        render(.idle)
    }

    // MARK: Rendering

    private func render(_ state: FetchState) {
        self.state = state
        guard let button = statusItem.button else { return }
        button.attributedTitle = Self.attributedTitle(Formatting.titleSegments(for: state))
        button.toolTip = Formatting.tooltip(for: state, now: Date())
    }

    static func attributedTitle(_ segments: [TitleSegment]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: Formatting.separator,
                                                 attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            result.append(NSAttributedString(string: segment.text,
                                             attributes: [.font: font, .foregroundColor: color(for: segment.severity)]))
        }
        return result
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

    private func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        if let error = state.error {
            addDisabled(Formatting.errorMessage(error, last: state.snapshot, now: now))
            menu.addItem(.separator())
        }

        if let snapshot = state.snapshot {
            let rows = Formatting.menuRows(for: snapshot, now: now)
            let width = rows.map(\.label.count).max() ?? 0
            for row in rows {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: Formatting.menuLine(row, labelWidth: width), attributes: [.font: mono])
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
            addDisabled("Updated \(Formatting.agoText(since: snapshot.fetchedAt, now: now))")
        } else if state.error == nil {
            addDisabled("Loading…")
            menu.addItem(.separator())
        }

        addAction("Refresh", #selector(refreshNow), key: "r")
        addAction("Open usage page (claude.ai)", #selector(openUsagePage))
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

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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
        Task { await poller.refresh() }
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(Formatting.usagePageURL)
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
    }
}
