import Foundation

/// How urgent a number is. The app maps this to a color; Core stays AppKit-free.
public enum Severity: Equatable, Sendable {
    case normal, warning, critical
}

/// One piece of the menu bar title, e.g. "5h 25%".
public struct TitleSegment: Equatable, Sendable {
    public let text: String
    public let severity: Severity
    public init(text: String, severity: Severity) {
        self.text = text
        self.severity = severity
    }
}

/// Pure functions from state to display strings. Nothing here touches AppKit or the clock
/// (callers pass `now`), so all of it is unit-tested.
public enum Formatting {
    public static let warningThreshold = 50
    public static let criticalThreshold = 80
    public static let separator = " · "
    public static let warningGlyph = "⚠︎"

    public static func severity(forPercent percent: Int) -> Severity {
        if percent >= criticalThreshold { return .critical }
        if percent >= warningThreshold { return .warning }
        return .normal
    }

    public static func joinedTitle(_ segments: [TitleSegment]) -> String {
        segments.map(\.text).joined(separator: separator)
    }
}

// MARK: - Time, bars, menu rows, and the combined tooltip

extension Formatting {
    public static var rateLimitBackoffDescription: String { durationText(seconds: RateLimitPolicy.minBackoff) }

    /// "45 s", "5 min", "27 min", "1 h", "1 h 5 min". Rounded to the nearest minute above 60 s.
    public static func durationText(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The rate-limited menu line. Shows the wait the poller will actually take; when the
    /// server sent a `Retry-After`, that drove the wait and the message says so.
    static func rateLimitedMessage(prefix: String, retryAfter: TimeInterval?) -> String {
        guard let retryAfter else { return "\(prefix) Next refresh in \(rateLimitBackoffDescription)." }
        let wait = durationText(seconds: RateLimitPolicy.backoff(retryAfter: retryAfter))
        return "\(prefix) Next refresh in \(wait) (server's Retry-After)."
    }

    /// "4h 22m", "59m", "<1m", or "now" for past dates.
    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours == 0 ? "\(remainder)m" : "\(hours)h \(remainder)m"
    }

    /// nil → nil; past → "resets now"; within 24 h → "resets in 4h 22m"; else "resets Sun 11:59 PM"
    /// (weekday + localized short time, 12/24-hour follows the locale).
    public static func resetText(for date: Date?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "resets now" }
        if interval < 24 * 3600 { return "resets in \(countdown(to: date, from: now))" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return "resets \(formatter.string(from: date))"
    }

    /// "just now" (< 5 s), "30 s ago", "3 min ago", "2 h ago". Never negative.
    public static func agoText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    /// Ten-cell text bar, rounded to the nearest cell. Percent is clamped to 0…100.
    public static func bar(percent: Int, width: Int = 10) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((Double(clamped) / 100 * Double(width)).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    public struct MenuRow: Equatable, Sendable {
        public let label: String
        public let percent: Int
        public let bar: String
        public let reset: String?
        public init(label: String, percent: Int, bar: String, reset: String?) {
            self.label = label
            self.percent = percent
            self.bar = bar
            self.reset = reset
        }
    }

    // MARK: Credit balances

    /// Below these remaining-dollar amounts a credit balance turns amber / red. Shared rather
    /// than per-provider: any provider that reports a balance in dollars reads the same scale.
    public static let creditsWarningThreshold = 5.0
    public static let creditsCriticalThreshold = 1.0

    public static func severity(forRemainingCredits remaining: Double) -> Severity {
        if remaining < creditsCriticalThreshold { return .critical }
        if remaining < creditsWarningThreshold { return .warning }
        return .normal
    }

    /// "$12.34". Negative balances display as $0.00.
    public static func creditsText(_ amount: Double) -> String {
        String(format: "$%.2f", max(0, amount))
    }

    /// One monospaced menu line: label padded to `labelWidth`, percent right-aligned to 4 chars.
    public static func menuLine(_ row: MenuRow, labelWidth: Int) -> String {
        let padded = row.label.padding(toLength: max(labelWidth, row.label.count), withPad: " ", startingAt: 0)
        let percentText = "\(row.percent)%"
        let alignedPercent = String(repeating: " ", count: max(0, 4 - percentText.count)) + percentText
        var line = "\(padded)  \(alignedPercent)  \(row.bar)"
        if let reset = row.reset { line += "   \(reset)" }
        return line
    }

    /// The whole tooltip, in menu bar order: Claude, then ChatGPT, then OpenRouter.
    ///
    /// A provider the user has hidden is passed as `.idle` and contributes nothing, which is the
    /// same thing `.idle` means while a provider is still on its first fetch. The caller decides
    /// what to say when every provider is hidden — from in here the two are indistinguishable.
    public static func tooltip(claude: FetchState<ClaudeUsageSnapshot>,
                               chatGPT: FetchState<ChatGPTUsageSnapshot> = .idle,
                               openRouter: FetchState<OpenRouterCreditsSnapshot> = .idle,
                               now: Date,
                               timeZone: TimeZone = .current,
                               locale: Locale = .current) -> String {
        var lines: [String] = []
        lines.append(contentsOf: claudeTooltipLines(for: claude, now: now, timeZone: timeZone, locale: locale))
        lines.append(contentsOf: chatGPTTooltipLines(for: chatGPT, now: now, timeZone: timeZone, locale: locale))
        lines.append(contentsOf: openRouterTooltipLines(for: openRouter, now: now))

        // A provider with no credentials stays quiet while anything else has something to say.
        // When it would leave the tooltip blank, say which provider is not signed in instead of
        // claiming to still be loading.
        if lines.isEmpty {
            if case .failed(.notSignedIn, let last) = chatGPT, last == nil {
                lines.append(chatGPTErrorMessage(.notSignedIn, last: nil, now: now))
            }
            if case .failed(.notSignedIn, let last) = openRouter, last == nil {
                lines.append(openRouterErrorMessage(.notSignedIn, last: nil, now: now))
            }
        }

        // One age for the whole tooltip, taken from the first provider that has numbers — the
        // same fallback order the click menu uses for its "Updated" line.
        if let updatedAt = claude.snapshot?.fetchedAt ?? chatGPT.snapshot?.fetchedAt ?? openRouter.snapshot?.fetchedAt {
            lines.append("Updated \(agoText(since: updatedAt, now: now))")
        }
        if lines.isEmpty { lines.append("Loading usage…") }
        return lines.joined(separator: "\n")
    }
}
