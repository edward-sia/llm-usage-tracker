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

    // MARK: Labels

    /// Short labels for the menu bar, in bucket order. Scoped models that share a first
    /// letter get two letters instead.
    public static func shortLabels(for buckets: [UsageBucket]) -> [String] {
        var labels = buckets.map { baseShortLabel(for: $0.kind) }
        let scopedIndices = buckets.indices.filter {
            if case .weeklyScoped = buckets[$0].kind { return true }
            return false
        }
        var counts: [String: Int] = [:]
        for index in scopedIndices { counts[labels[index], default: 0] += 1 }
        for index in scopedIndices where counts[labels[index], default: 0] > 1 {
            if case .weeklyScoped(let model?) = buckets[index].kind {
                let trimmed = model.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 2 {
                    labels[index] = trimmed.prefix(1).uppercased() + trimmed.dropFirst().prefix(1).lowercased()
                }
            }
        }
        return labels
    }

    private static func baseShortLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session:
            return "5h"
        case .weeklyAll:
            return "W"
        case .weeklyScoped(let model):
            guard let first = model?.trimmingCharacters(in: .whitespaces).first else { return "M" }
            return String(first).uppercased()
        case .other(let kind):
            guard let first = kind.trimmingCharacters(in: .whitespaces).first else { return "?" }
            return String(first).uppercased()
        }
    }

    /// Full label for menus and tooltips.
    public static func longLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session: return "Session (5h)"
        case .weeklyAll: return "Weekly · all"
        case .weeklyScoped(let model):
            let name = model?.trimmingCharacters(in: .whitespaces) ?? ""
            return "Weekly · \(name.isEmpty ? "model" : name)"
        case .other(let kind):
            let words = kind.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            guard let first = words.first else { return "Unknown limit" }
            return String(first).uppercased() + words.dropFirst()
        }
    }

    // MARK: Title

    public static func titleSegments(for state: FetchState<UsageSnapshot>) -> [TitleSegment] {
        switch state {
        case .idle:
            return [TitleSegment(text: "…", severity: .normal)]
        case .loaded(let snapshot):
            return segments(for: snapshot)
        case .failed(let error, let last):
            if let last {
                return segments(for: last) + [TitleSegment(text: warningGlyph, severity: .warning)]
            }
            switch error {
            case .notSignedIn: return [TitleSegment(text: "\(warningGlyph) not signed in", severity: .warning)]
            default: return [TitleSegment(text: warningGlyph, severity: .warning)]
            }
        }
    }

    private static func segments(for snapshot: UsageSnapshot) -> [TitleSegment] {
        let labels = shortLabels(for: snapshot.buckets)
        return zip(labels, snapshot.buckets).map { label, bucket in
            TitleSegment(text: "\(label) \(bucket.percent)%", severity: severity(forPercent: bucket.percent))
        }
    }

    public static func joinedTitle(_ segments: [TitleSegment]) -> String {
        segments.map(\.text).joined(separator: separator)
    }
}

// MARK: - Time, bars, menu, tooltip, errors

extension Formatting {
    public static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
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
    private static func rateLimitedMessage(prefix: String, retryAfter: TimeInterval?) -> String {
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

    public static func menuRows(for snapshot: UsageSnapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [MenuRow] {
        snapshot.buckets.map { bucket in
            MenuRow(label: longLabel(for: bucket.kind),
                    percent: bucket.percent,
                    bar: bar(percent: bucket.percent),
                    reset: resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale))
        }
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

    // MARK: OpenRouter credits

    /// Below these remaining-dollar amounts the balance turns amber / red.
    public static let creditsWarningThreshold = 5.0
    public static let creditsCriticalThreshold = 1.0
    public static let openRouterShortLabel = "OR"
    public static let openRouterCreditsPageURL = URL(string: "https://openrouter.ai/settings/credits")!

    public static func severity(forRemainingCredits remaining: Double) -> Severity {
        if remaining < creditsCriticalThreshold { return .critical }
        if remaining < creditsWarningThreshold { return .warning }
        return .normal
    }

    /// "$12.34". Negative balances display as $0.00.
    public static func creditsText(_ amount: Double) -> String {
        String(format: "$%.2f", max(0, amount))
    }

    /// The menu bar segments for the credits state. Empty while loading and when no key is
    /// configured, so Macs without OpenRouter never see the segment. Pass
    /// `includeShortLabel: false` when something else already identifies the provider
    /// (the app renders the OpenRouter logo in front of the segment).
    public static func openRouterTitleSegments(for state: FetchState<CreditsSnapshot>, includeShortLabel: Bool = true) -> [TitleSegment] {
        let prefix = includeShortLabel ? "\(openRouterShortLabel) " : ""
        func segment(_ snapshot: CreditsSnapshot) -> TitleSegment {
            TitleSegment(text: "\(prefix)\(creditsText(snapshot.remaining))",
                         severity: severity(forRemainingCredits: snapshot.remaining))
        }
        switch state {
        case .idle:
            return []
        case .loaded(let snapshot):
            return [segment(snapshot)]
        case .failed(let error, let last):
            if let last { return [segment(last), TitleSegment(text: warningGlyph, severity: .warning)] }
            if error == .notSignedIn { return [] }
            return [TitleSegment(text: "\(prefix)\(warningGlyph)", severity: .warning)]
        }
    }

    public static func openRouterMenuLine(for snapshot: CreditsSnapshot) -> String {
        "OpenRouter  \(creditsText(snapshot.remaining)) remaining"
            + " · used \(creditsText(snapshot.totalUsage)) of \(creditsText(snapshot.totalCredits))"
    }

    public static func openRouterErrorMessage(_ error: UsageError, last: CreditsSnapshot?, now: Date) -> String {
        let suffix = last.map { " Last updated \(agoText(since: $0.fetchedAt, now: now))." } ?? ""
        switch error {
        case .notSignedIn: return "No OpenRouter API key found in your shell config."
        case .unauthorized: return "OpenRouter API key was rejected. Check OPENROUTER_API_KEY in your shell config."
        case .rateLimited(let retryAfter): return rateLimitedMessage(prefix: "OpenRouter rate limited.", retryAfter: retryAfter)
        case .http(let code): return "OpenRouter API error (HTTP \(code)).\(suffix)"
        case .decoding: return "Unexpected response from the OpenRouter credits API.\(suffix)"
        case .offline: return "OpenRouter unreachable.\(suffix)"
        }
    }

    public static func openRouterTooltipLines(for state: FetchState<CreditsSnapshot>, now: Date) -> [String] {
        var lines: [String] = []
        if let error = state.error, !(error == .notSignedIn && state.snapshot == nil) {
            lines.append(openRouterErrorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            lines.append("OpenRouter credits: \(creditsText(snapshot.remaining)) remaining")
        }
        return lines
    }

    public static func errorMessage(_ error: UsageError, last: UsageSnapshot?, now: Date) -> String {
        let suffix = last.map { " Last updated \(agoText(since: $0.fetchedAt, now: now))." } ?? ""
        switch error {
        case .notSignedIn: return "Not signed in to Claude Code. Run `claude` in a terminal and log in."
        case .unauthorized: return "Token expired. Open Claude Code to refresh it."
        case .rateLimited(let retryAfter): return rateLimitedMessage(prefix: "Rate limited.", retryAfter: retryAfter)
        case .http(let code): return "Usage API error (HTTP \(code)).\(suffix)"
        case .decoding: return "Unexpected response from the usage API.\(suffix)"
        case .offline: return "Offline.\(suffix)"
        }
    }

    public static func tooltip(for state: FetchState<UsageSnapshot>, credits: FetchState<CreditsSnapshot> = .idle, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var lines: [String] = []
        if let error = state.error {
            lines.append(errorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            for bucket in snapshot.buckets {
                var line = "\(longLabel(for: bucket.kind)): \(bucket.percent)%"
                if let reset = resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale) {
                    line += " — \(reset)"
                }
                lines.append(line)
            }
        }
        lines.append(contentsOf: openRouterTooltipLines(for: credits, now: now))
        if let snapshot = state.snapshot {
            lines.append("Updated \(agoText(since: snapshot.fetchedAt, now: now))")
        }
        if lines.isEmpty { lines.append("Loading Claude usage…") }
        return lines.joined(separator: "\n")
    }
}
