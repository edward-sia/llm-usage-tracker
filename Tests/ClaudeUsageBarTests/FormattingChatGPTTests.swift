import XCTest
@testable import ClaudeUsageBarCore

final class FormattingChatGPTTests: XCTestCase {
    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = Date(timeIntervalSince1970: 2_000)

    private func window(_ percent: Int, seconds: TimeInterval? = 18_000, resetsAt: Date? = nil) -> ChatGPTUsageWindow {
        ChatGPTUsageWindow(usedPercent: percent, windowSeconds: seconds, resetsAt: resetsAt)
    }

    private func snapshot(_ windows: [ChatGPTUsageWindow], plan: String? = "free", age: TimeInterval = 1_000) -> ChatGPTUsageSnapshot {
        ChatGPTUsageSnapshot(windows: windows, planType: plan, fetchedAt: now.addingTimeInterval(-age))
    }

    // MARK: Labels derived from the window duration

    func testShortLabels() {
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 18_000), "5h")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 3_600), "1h")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 1_800), "30m")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 86_400), "D")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 604_800), "W")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 2_592_000), "M")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 1_209_600), "14d")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: nil), "?")
        XCTAssertEqual(Formatting.chatGPTShortLabel(forWindowSeconds: 0), "?")
    }

    func testLongLabels() {
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: 18_000), "Rolling 5h")
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: 86_400), "Daily")
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: 604_800), "Weekly")
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: 2_592_000), "Monthly")
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: 1_209_600), "Rolling 14d")
        XCTAssertEqual(Formatting.chatGPTLongLabel(forWindowSeconds: nil), "Usage")
    }

    func testPlanLabels() {
        XCTAssertEqual(Formatting.chatGPTPlanLabel("free"), "Free plan")
        XCTAssertEqual(Formatting.chatGPTPlanLabel("plus"), "Plus plan")
        XCTAssertEqual(Formatting.chatGPTPlanLabel("pro"), "Pro plan")
        XCTAssertEqual(Formatting.chatGPTPlanLabel("enterprise_cbp_usage_based"), "Enterprise cbp usage based plan")
        XCTAssertNil(Formatting.chatGPTPlanLabel(nil))
        XCTAssertNil(Formatting.chatGPTPlanLabel("   "))
    }

    /// A value that already says "plan" must not become "… plan plan".
    func testPlanLabelDoesNotDoubleTheWordPlan() {
        XCTAssertEqual(Formatting.chatGPTPlanLabel("team_plan"), "Team plan")
    }

    // MARK: Title segments

    func testTitleSegmentsForLoadedSnapshot() {
        let segments = Formatting.chatGPTTitleSegments(for: .loaded(snapshot([window(7, seconds: 2_592_000)])))
        XCTAssertEqual(segments.map(\.text), ["M 7%"])
        XCTAssertEqual(segments.map(\.severity), [.normal])
    }

    func testTitleSegmentsUseTheSameThresholdsAsClaude() {
        let segments = Formatting.chatGPTTitleSegments(for: .loaded(snapshot([
            window(49), window(50, seconds: 604_800), window(80, seconds: 86_400),
        ])))
        XCTAssertEqual(segments.map(\.text), ["5h 49%", "W 50%", "D 80%"])
        XCTAssertEqual(segments.map(\.severity), [.normal, .warning, .critical])
    }

    /// A Mac with no Codex login shows no ChatGPT segment at all, the way a Mac with no
    /// OpenRouter key shows no credits segment.
    func testTitleSegmentsAreEmptyWhileIdleOrNotSignedIn() {
        XCTAssertEqual(Formatting.chatGPTTitleSegments(for: .idle), [])
        XCTAssertEqual(Formatting.chatGPTTitleSegments(for: .failed(.notSignedIn, last: nil)), [])
    }

    func testTitleKeepsLastNumbersAndAddsAWarningOnFailure() {
        let segments = Formatting.chatGPTTitleSegments(for: .failed(.offline, last: snapshot([window(42)])))
        XCTAssertEqual(segments.map(\.text), ["5h 42%", Formatting.warningGlyph])
    }

    func testTitleShowsOnlyAWarningWhenAFailureHasNoNumbers() {
        let segments = Formatting.chatGPTTitleSegments(for: .failed(.http(500), last: nil))
        XCTAssertEqual(segments.map(\.text), [Formatting.warningGlyph])
    }

    // MARK: Menu

    func testMenuRows() {
        let rows = Formatting.chatGPTMenuRows(
            for: snapshot([window(25, resetsAt: now.addingTimeInterval(3_600))]),
            now: now, timeZone: tz, locale: locale
        )
        XCTAssertEqual(rows.map(\.label), ["Rolling 5h"])
        XCTAssertEqual(rows.map(\.percent), [25])
        XCTAssertEqual(rows.map(\.reset), ["resets in 1h 0m"])
        XCTAssertEqual(rows[0].bar, Formatting.bar(percent: 25))
    }

    func testPlanLine() {
        XCTAssertEqual(Formatting.chatGPTPlanLine(for: snapshot([window(7)])), "ChatGPT  Free plan")
        XCTAssertNil(Formatting.chatGPTPlanLine(for: snapshot([window(7)], plan: nil)))
    }

    // MARK: Errors

    func testErrorMessages() {
        XCTAssertTrue(Formatting.chatGPTErrorMessage(.notSignedIn, last: nil, now: now).hasPrefix("Not signed in to ChatGPT."))
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.unauthorized, last: nil, now: now),
                       "ChatGPT token expired. Open Codex or the ChatGPT app to refresh it.")
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.http(503), last: nil, now: now),
                       "ChatGPT usage API error (HTTP 503).")
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.decoding, last: nil, now: now),
                       "Unexpected response from the ChatGPT usage API.")
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.offline, last: nil, now: now), "ChatGPT unreachable.")
    }

    func testErrorMessageMentionsHowStaleTheKeptNumbersAre() {
        let message = Formatting.chatGPTErrorMessage(.offline, last: snapshot([window(7)], age: 180), now: now)
        XCTAssertEqual(message, "ChatGPT unreachable. Last updated 3 min ago.")
    }

    /// The 429 wording comes from the shared helper, so it names the server's Retry-After too.
    func testRateLimitedMessageNamesTheServerWait() {
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.rateLimited(retryAfter: 1_622), last: nil, now: now),
                       "ChatGPT rate limited. Next refresh in 27 min (server's Retry-After).")
        XCTAssertEqual(Formatting.chatGPTErrorMessage(.rateLimited(retryAfter: nil), last: nil, now: now),
                       "ChatGPT rate limited. Next refresh in 5 min.")
    }

    // MARK: Tooltip

    func testTooltipLinesCarryPlanOnTheFirstWindowOnly() {
        let lines = Formatting.chatGPTTooltipLines(
            for: .loaded(snapshot([window(42), window(8, seconds: 604_800)])),
            now: now, timeZone: tz, locale: locale
        )
        XCTAssertEqual(lines, ["ChatGPT Rolling 5h: 42%  (Free plan)", "ChatGPT Weekly: 8%"])
    }

    func testTooltipLinesAreEmptyWhenIdleOrNotSignedIn() {
        XCTAssertEqual(Formatting.chatGPTTooltipLines(for: .idle, now: now), [])
        XCTAssertEqual(Formatting.chatGPTTooltipLines(for: .failed(.notSignedIn, last: nil), now: now), [])
    }

    func testTooltipLinesLeadWithTheError() {
        let lines = Formatting.chatGPTTooltipLines(for: .failed(.offline, last: snapshot([window(7)], age: 60)), now: now)
        XCTAssertEqual(lines.first, "ChatGPT unreachable. Last updated 1 min ago.")
    }

    // MARK: Combined tooltip ordering

    func testCombinedTooltipOrdersClaudeThenChatGPTThenOpenRouter() {
        let claude = UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)],
                                   fetchedAt: now.addingTimeInterval(-1_000))
        let credits = CreditsSnapshot(totalCredits: 500, totalUsage: 487.66, fetchedAt: now.addingTimeInterval(-1_000))
        let text = Formatting.tooltip(for: .loaded(claude),
                                      credits: .loaded(credits),
                                      chatGPT: .loaded(snapshot([window(7, seconds: 2_592_000)])),
                                      now: now, timeZone: tz, locale: locale)
        XCTAssertEqual(text, """
        Session (5h): 25%
        ChatGPT Monthly: 7%  (Free plan)
        OpenRouter credits: $12.34 remaining
        Updated 16 min ago
        """)
    }

    /// With every other provider quiet, "not signed in" is the only thing that explains the
    /// empty tooltip, so it gets said.
    func testCombinedTooltipExplainsAMissingChatGPTLoginWhenNothingElseSpeaks() {
        let text = Formatting.tooltip(for: .idle, credits: .idle, chatGPT: .failed(.notSignedIn, last: nil), now: now)
        XCTAssertTrue(text.hasPrefix("Not signed in to ChatGPT."), text)
    }

    func testCombinedTooltipStaysQuietAboutAMissingLoginWhenOtherProvidersHaveNumbers() {
        let claude = UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)],
                                   fetchedAt: now.addingTimeInterval(-1_000))
        let text = Formatting.tooltip(for: .loaded(claude), chatGPT: .failed(.notSignedIn, last: nil), now: now)
        XCTAssertFalse(text.contains("ChatGPT"), text)
    }

    func testUsagePageURL() {
        XCTAssertEqual(Formatting.chatGPTUsagePageURL.absoluteString, "https://chatgpt.com/codex/settings/usage")
    }
}
