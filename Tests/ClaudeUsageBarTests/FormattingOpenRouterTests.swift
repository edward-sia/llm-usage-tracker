import XCTest
@testable import ClaudeUsageBarCore

final class FormattingOpenRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    private func credits(_ remaining: Double, of total: Double = 500) -> CreditsSnapshot {
        CreditsSnapshot(totalCredits: total, totalUsage: total - remaining, fetchedAt: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: Severity thresholds ($5 amber, $1 red)

    func testSeverityForRemainingCredits() {
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 12.34), .normal)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 5.0), .normal)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 4.99), .warning)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 1.0), .warning)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 0.99), .critical)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: 0), .critical)
        XCTAssertEqual(Formatting.severity(forRemainingCredits: -0.5), .critical)
    }

    // MARK: Dollar formatting

    func testCreditsTextFormatsDollarsWithTwoDecimals() {
        XCTAssertEqual(Formatting.creditsText(12.34), "$12.34")
        XCTAssertEqual(Formatting.creditsText(500), "$500.00")
        XCTAssertEqual(Formatting.creditsText(0.5), "$0.50")
    }

    func testCreditsTextClampsNegativeToZero() {
        XCTAssertEqual(Formatting.creditsText(-0.12), "$0.00")
    }

    // MARK: Title segments

    func testTitleSegmentsWhileIdleAreEmpty() {
        XCTAssertEqual(Formatting.openRouterTitleSegments(for: .idle), [])
    }

    func testTitleSegmentsWhenLoaded() {
        let segments = Formatting.openRouterTitleSegments(for: .loaded(credits(12.34)))
        XCTAssertEqual(segments, [TitleSegment(text: "OR $12.34", severity: .normal)])
    }

    func testTitleSegmentsCarrySeverityOfBalance() {
        XCTAssertEqual(Formatting.openRouterTitleSegments(for: .loaded(credits(2))).first?.severity, .warning)
        XCTAssertEqual(Formatting.openRouterTitleSegments(for: .loaded(credits(0.2))).first?.severity, .critical)
    }

    func testTitleSegmentsHiddenWhenNoKeyFound() {
        XCTAssertEqual(Formatting.openRouterTitleSegments(for: .failed(.notSignedIn, last: nil)), [])
    }

    func testTitleSegmentsShowWarningGlyphOnErrorWithoutNumbers() {
        let segments = Formatting.openRouterTitleSegments(for: .failed(.offline, last: nil))
        XCTAssertEqual(segments, [TitleSegment(text: "OR \(Formatting.warningGlyph)", severity: .warning)])
    }

    func testTitleSegmentsKeepLastBalanceAndAppendGlyphOnError() {
        let segments = Formatting.openRouterTitleSegments(for: .failed(.offline, last: credits(12.34)))
        XCTAssertEqual(segments, [
            TitleSegment(text: "OR $12.34", severity: .normal),
            TitleSegment(text: Formatting.warningGlyph, severity: .warning),
        ])
    }

    // MARK: Menu line

    func testMenuLineShowsRemainingAndTotals() {
        XCTAssertEqual(Formatting.openRouterMenuLine(for: credits(12.34, of: 500)),
                       "OpenRouter  $12.34 remaining · used $487.66 of $500.00")
    }

    // MARK: Error messages

    func testErrorMessages() {
        XCTAssertEqual(Formatting.openRouterErrorMessage(.notSignedIn, last: nil, now: now),
                       "No OpenRouter API key found in your shell config.")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.unauthorized, last: nil, now: now),
                       "OpenRouter API key was rejected. Check OPENROUTER_API_KEY in your shell config.")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.rateLimited(retryAfter: nil), last: nil, now: now),
                       "OpenRouter rate limited. Next refresh in 5 min.")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.rateLimited(retryAfter: 600), last: nil, now: now),
                       "OpenRouter rate limited. Next refresh in 10 min (server's Retry-After).")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.http(500), last: nil, now: now),
                       "OpenRouter API error (HTTP 500).")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.decoding, last: nil, now: now),
                       "Unexpected response from the OpenRouter credits API.")
        XCTAssertEqual(Formatting.openRouterErrorMessage(.offline, last: nil, now: now),
                       "OpenRouter unreachable.")
    }

    func testErrorMessageAppendsAgeOfLastNumbers() {
        XCTAssertEqual(Formatting.openRouterErrorMessage(.offline, last: credits(12.34), now: now),
                       "OpenRouter unreachable. Last updated 16 min ago.")
    }

    // MARK: Tooltip lines

    func testTooltipLinesWhenLoaded() {
        XCTAssertEqual(Formatting.openRouterTooltipLines(for: .loaded(credits(12.34)), now: now),
                       ["OpenRouter credits: $12.34 remaining"])
    }

    func testTooltipLinesOnErrorKeepBalanceAfterMessage() {
        XCTAssertEqual(Formatting.openRouterTooltipLines(for: .failed(.offline, last: credits(12.34)), now: now),
                       ["OpenRouter unreachable. Last updated 16 min ago.",
                        "OpenRouter credits: $12.34 remaining"])
    }

    func testTooltipLinesHiddenWhenIdleOrNoKey() {
        XCTAssertEqual(Formatting.openRouterTooltipLines(for: .idle, now: now), [])
        XCTAssertEqual(Formatting.openRouterTooltipLines(for: .failed(.notSignedIn, last: nil), now: now), [])
    }

    // MARK: Combined tooltip

    private let usage = UsageSnapshot(
        buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )

    func testCombinedTooltipPutsCreditLinesBeforeUpdated() {
        let text = Formatting.tooltip(for: .loaded(usage), credits: .loaded(credits(12.34)), now: now)
        XCTAssertEqual(text, "Session (5h): 25%\nOpenRouter credits: $12.34 remaining\nUpdated 16 min ago")
    }

    func testCombinedTooltipShowsCreditsAloneWhileClaudeIsIdle() {
        let text = Formatting.tooltip(for: .idle, credits: .loaded(credits(12.34)), now: now)
        XCTAssertEqual(text, "OpenRouter credits: $12.34 remaining")
    }

    func testCombinedTooltipWithoutCreditsMatchesClaudeOnlyTooltip() {
        XCTAssertEqual(Formatting.tooltip(for: .loaded(usage), credits: .idle, now: now),
                       Formatting.tooltip(for: .loaded(usage), now: now))
    }
}
