import Foundation

/// Display strings for the Claude provider. Kept in its own file so `Formatting.swift` stays
/// about the pieces every provider shares — the same split `FormattingChatGPT.swift` and
/// `FormattingOpenRouter.swift` follow.
extension Formatting {
    public static let claudeUsagePageURL = URL(string: "https://claude.ai/settings/usage")!

    // MARK: Labels

    /// Short labels for the menu bar, in bucket order. Scoped models that share a first
    /// letter get two letters instead.
    public static func claudeShortLabels(for buckets: [ClaudeUsageBucket]) -> [String] {
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

    private static func baseShortLabel(for kind: ClaudeUsageBucket.Kind) -> String {
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
    public static func claudeLongLabel(for kind: ClaudeUsageBucket.Kind) -> String {
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

    /// Menu bar segments for the Claude state. Empty while loading and when Claude Code has no
    /// login, so a Mac that only uses the other providers never sees a Claude segment — the same
    /// contract `chatGPTTitleSegments` and `openRouterTitleSegments` follow.
    ///
    /// An empty title across every provider is the app's problem to explain, not this function's:
    /// the caller knows whether that means loading, nothing signed in, or everything hidden.
    public static func claudeTitleSegments(for state: FetchState<ClaudeUsageSnapshot>) -> [TitleSegment] {
        switch state {
        case .idle:
            return []
        case .loaded(let snapshot):
            return claudeSegments(for: snapshot)
        case .failed(let error, let last):
            if let last {
                return claudeSegments(for: last) + [TitleSegment(text: warningGlyph, severity: .warning)]
            }
            if error == .notSignedIn { return [] }
            return [TitleSegment(text: warningGlyph, severity: .warning)]
        }
    }

    private static func claudeSegments(for snapshot: ClaudeUsageSnapshot) -> [TitleSegment] {
        let labels = claudeShortLabels(for: snapshot.buckets)
        return zip(labels, snapshot.buckets).map { label, bucket in
            TitleSegment(text: "\(label) \(bucket.percent)%", severity: severity(forPercent: bucket.percent))
        }
    }

    // MARK: Menu

    public static func claudeMenuRows(for snapshot: ClaudeUsageSnapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [MenuRow] {
        snapshot.buckets.map { bucket in
            MenuRow(label: claudeLongLabel(for: bucket.kind),
                    percent: bucket.percent,
                    bar: bar(percent: bucket.percent),
                    reset: resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale))
        }
    }

    // MARK: Errors and tooltip

    public static func claudeErrorMessage(_ error: UsageError, last: ClaudeUsageSnapshot?, now: Date) -> String {
        let suffix = last.map { " Last updated \(agoText(since: $0.fetchedAt, now: now))." } ?? ""
        switch error {
        case .notSignedIn: return "Not signed in to Claude Code. Run `claude` in a terminal and log in."
        case .unauthorized: return "Claude token expired. Open Claude Code to refresh it."
        case .rateLimited(let retryAfter): return rateLimitedMessage(prefix: "Claude rate limited.", retryAfter: retryAfter)
        case .http(let code): return "Claude usage API error (HTTP \(code)).\(suffix)"
        case .decoding: return "Unexpected response from the Claude usage API.\(suffix)"
        case .offline: return "Claude unreachable.\(suffix)"
        }
    }

    /// The Claude section of the tooltip: the error line, when there is one, then one line per
    /// limit. A missing Claude Code login stays quiet while another provider has something to
    /// say, the same way ChatGPT's and OpenRouter's do — `tooltip` brings it back when it would
    /// otherwise leave the tooltip blank.
    public static func claudeTooltipLines(for state: FetchState<ClaudeUsageSnapshot>, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [String] {
        var lines: [String] = []
        if let error = state.error, !(error == .notSignedIn && state.snapshot == nil) {
            lines.append(claudeErrorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            for bucket in snapshot.buckets {
                var line = "\(claudeLongLabel(for: bucket.kind)): \(bucket.percent)%"
                if let reset = resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale) {
                    line += " — \(reset)"
                }
                lines.append(line)
            }
        }
        return lines
    }
}
