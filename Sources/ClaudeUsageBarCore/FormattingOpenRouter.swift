import Foundation

/// Display strings for the OpenRouter provider. Kept in its own file so `Formatting.swift` stays
/// about the pieces every provider shares — the same split `FormattingChatGPT.swift` and
/// `FormattingClaude.swift` follow.
extension Formatting {
    public static let openRouterShortLabel = "OR"
    public static let openRouterCreditsPageURL = URL(string: "https://openrouter.ai/settings/credits")!

    /// The menu bar segments for the credits state. Empty while loading and when no key is
    /// configured, so Macs without OpenRouter never see the segment. Pass
    /// `includeShortLabel: false` when something else already identifies the provider
    /// (the app renders the OpenRouter logo in front of the segment).
    public static func openRouterTitleSegments(for state: FetchState<OpenRouterCreditsSnapshot>, includeShortLabel: Bool = true) -> [TitleSegment] {
        let prefix = includeShortLabel ? "\(openRouterShortLabel) " : ""
        func segment(_ snapshot: OpenRouterCreditsSnapshot) -> TitleSegment {
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

    public static func openRouterMenuLine(for snapshot: OpenRouterCreditsSnapshot) -> String {
        "OpenRouter  \(creditsText(snapshot.remaining)) remaining"
            + " · used \(creditsText(snapshot.totalUsage)) of \(creditsText(snapshot.totalCredits))"
    }

    public static func openRouterErrorMessage(_ error: UsageError, last: OpenRouterCreditsSnapshot?, now: Date) -> String {
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

    public static func openRouterTooltipLines(for state: FetchState<OpenRouterCreditsSnapshot>, now: Date) -> [String] {
        var lines: [String] = []
        if let error = state.error, !(error == .notSignedIn && state.snapshot == nil) {
            lines.append(openRouterErrorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            lines.append("OpenRouter credits: \(creditsText(snapshot.remaining)) remaining")
        }
        return lines
    }
}
