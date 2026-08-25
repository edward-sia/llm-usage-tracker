import Foundation

/// Display strings for the ChatGPT provider. Kept in its own file so `Formatting.swift` stays
/// about the shared pieces and the Claude limits.
extension Formatting {
    public static let chatGPTUsagePageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    private static let day: TimeInterval = 86_400
    private static let week: TimeInterval = 604_800
    private static let month: TimeInterval = 2_592_000

    // MARK: Labels

    /// Short menu bar label for a window, derived from how long the window lasts: "5h", "D",
    /// "W", "M", "14d". The API describes ChatGPT's limits only by duration, so nothing here
    /// hardcodes a plan's particular windows.
    public static func chatGPTShortLabel(forWindowSeconds seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "?" }
        switch seconds {
        case day: return "D"
        case week: return "W"
        case month: return "M"
        default: break
        }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < day { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / day).rounded()))d"
    }

    /// Full label for menus and tooltips.
    public static func chatGPTLongLabel(forWindowSeconds seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        switch seconds {
        case day: return "Daily"
        case week: return "Weekly"
        case month: return "Monthly"
        default: return "Rolling \(chatGPTShortLabel(forWindowSeconds: seconds))"
        }
    }

    /// "Free plan", "Plus plan". Underscored API values are spaced out rather than reworded, so
    /// a plan name this app has never seen still reads as itself.
    public static func chatGPTPlanLabel(_ planType: String?) -> String? {
        guard let raw = planType?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let words = raw.replacingOccurrences(of: "_", with: " ")
        let capitalized = words.prefix(1).uppercased() + words.dropFirst()
        return words.lowercased().contains("plan") ? capitalized : "\(capitalized) plan"
    }

    // MARK: Title

    /// Menu bar segments for the ChatGPT state. Empty while loading and when Codex has no
    /// ChatGPT login, so Macs without Codex never see the segment — the same contract the
    /// OpenRouter segment follows for a missing key.
    public static func chatGPTTitleSegments(for state: FetchState<ChatGPTUsageSnapshot>) -> [TitleSegment] {
        switch state {
        case .idle:
            return []
        case .loaded(let snapshot):
            return chatGPTSegments(for: snapshot)
        case .failed(let error, let last):
            if let last {
                return chatGPTSegments(for: last) + [TitleSegment(text: warningGlyph, severity: .warning)]
            }
            if error == .notSignedIn { return [] }
            return [TitleSegment(text: warningGlyph, severity: .warning)]
        }
    }

    private static func chatGPTSegments(for snapshot: ChatGPTUsageSnapshot) -> [TitleSegment] {
        snapshot.windows.map { window in
            TitleSegment(text: "\(chatGPTShortLabel(forWindowSeconds: window.windowSeconds)) \(window.usedPercent)%",
                         severity: severity(forPercent: window.usedPercent))
        }
    }

    // MARK: Menu

    public static func chatGPTMenuRows(for snapshot: ChatGPTUsageSnapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [MenuRow] {
        snapshot.windows.map { window in
            MenuRow(label: chatGPTLongLabel(forWindowSeconds: window.windowSeconds),
                    percent: window.usedPercent,
                    bar: bar(percent: window.usedPercent),
                    reset: resetText(for: window.resetsAt, now: now, timeZone: timeZone, locale: locale))
        }
    }

    /// The header line above the rows, e.g. "ChatGPT  Free plan". Nil when the API did not say
    /// which plan this is, in which case the logo and rows carry the menu on their own.
    public static func chatGPTPlanLine(for snapshot: ChatGPTUsageSnapshot) -> String? {
        chatGPTPlanLabel(snapshot.planType).map { "ChatGPT  \($0)" }
    }

    // MARK: Errors and tooltip

    public static func chatGPTErrorMessage(_ error: UsageError, last: ChatGPTUsageSnapshot?, now: Date) -> String {
        let suffix = last.map { " Last updated \(agoText(since: $0.fetchedAt, now: now))." } ?? ""
        switch error {
        case .notSignedIn: return "Not signed in to ChatGPT. Sign in from the ChatGPT app or run `codex` and choose Sign in with ChatGPT."
        case .unauthorized: return "ChatGPT token expired. Open Codex or the ChatGPT app to refresh it."
        case .rateLimited(let retryAfter): return rateLimitedMessage(prefix: "ChatGPT rate limited.", retryAfter: retryAfter)
        case .http(let code): return "ChatGPT usage API error (HTTP \(code)).\(suffix)"
        case .decoding: return "Unexpected response from the ChatGPT usage API.\(suffix)"
        case .offline: return "ChatGPT unreachable.\(suffix)"
        }
    }

    public static func chatGPTTooltipLines(for state: FetchState<ChatGPTUsageSnapshot>, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [String] {
        var lines: [String] = []
        if let error = state.error, !(error == .notSignedIn && state.snapshot == nil) {
            lines.append(chatGPTErrorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            let plan = chatGPTPlanLabel(snapshot.planType)
            for (index, window) in snapshot.windows.enumerated() {
                var line = "ChatGPT \(chatGPTLongLabel(forWindowSeconds: window.windowSeconds)): \(window.usedPercent)%"
                if let reset = resetText(for: window.resetsAt, now: now, timeZone: timeZone, locale: locale) {
                    line += " — \(reset)"
                }
                // The plan rides on the first window line rather than a line of its own, so a
                // two-window plan does not push the tooltip to four lines.
                if index == 0, let plan { line += "  (\(plan))" }
                lines.append(line)
            }
        }
        return lines
    }
}
