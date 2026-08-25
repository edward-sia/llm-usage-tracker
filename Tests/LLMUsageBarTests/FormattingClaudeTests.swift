import XCTest
@testable import LLMUsageBarCore

/// Everything Formatting produces for the Claude provider: labels, menu bar title, menu rows,
/// error lines, and the Claude part of the tooltip.
final class FormattingClaudeTests: XCTestCase {
    // Sydney, like the account this was designed against. Deterministic locale for weekday/time text.
    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_US_POSIX")
    // 2026-08-18T02:39:00Z == Tue 12:39 AEST (1767225600 = 2026-01-01Z, +229 days, +2h39m)
    private let now = Date(timeIntervalSince1970: 1_787_020_740)

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
    }

    private func bucket(_ kind: ClaudeUsageBucket.Kind, _ percent: Int) -> ClaudeUsageBucket {
        ClaudeUsageBucket(kind: kind, percent: percent, resetsAt: nil)
    }
    private func claudeSnapshot(_ buckets: [ClaudeUsageBucket]) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(buckets: buckets, fetchedAt: Date(timeIntervalSince1970: 0))
    }
    private var standard: ClaudeUsageSnapshot {
        claudeSnapshot([bucket(.session, 25), bucket(.weeklyAll, 26), bucket(.weeklyScoped(model: "Fable"), 17)])
    }

    func testShortLabelsForStandardKinds() {
        XCTAssertEqual(Formatting.claudeShortLabels(for: standard.buckets), ["5h", "W", "F"])
    }

    func testShortLabelForScopedModelWithoutNameIsM() {
        XCTAssertEqual(Formatting.claudeShortLabels(for: [bucket(.weeklyScoped(model: nil), 1)]), ["M"])
        XCTAssertEqual(Formatting.claudeShortLabels(for: [bucket(.weeklyScoped(model: "  "), 1)]), ["M"])
    }

    func testShortLabelForUnknownKindIsFirstLetter() {
        XCTAssertEqual(Formatting.claudeShortLabels(for: [bucket(.other("mystery_limit"), 1)]), ["M"])
        XCTAssertEqual(Formatting.claudeShortLabels(for: [bucket(.other(""), 1)]), ["?"])
    }

    func testScopedLabelCollisionUsesTwoLetters() {
        let buckets = [bucket(.weeklyScoped(model: "Fable"), 1), bucket(.weeklyScoped(model: "Falcon"), 2), bucket(.weeklyScoped(model: "Opus"), 3)]
        XCTAssertEqual(Formatting.claudeShortLabels(for: buckets), ["Fa", "Fa", "O"])
        // Two letters still collide here; that is accepted (spec: "use the first two letters").
    }

    func testLongLabels() {
        XCTAssertEqual(Formatting.claudeLongLabel(for: .session), "Session (5h)")
        XCTAssertEqual(Formatting.claudeLongLabel(for: .weeklyAll), "Weekly · all")
        XCTAssertEqual(Formatting.claudeLongLabel(for: .weeklyScoped(model: "Fable")), "Weekly · Fable")
        XCTAssertEqual(Formatting.claudeLongLabel(for: .weeklyScoped(model: nil)), "Weekly · model")
        XCTAssertEqual(Formatting.claudeLongLabel(for: .other("mystery_limit")), "Mystery limit")
    }

    func testTitleSegmentsForLoadedState() {
        let segments = Formatting.claudeTitleSegments(for: .loaded(claudeSnapshot([bucket(.session, 25), bucket(.weeklyAll, 55), bucket(.weeklyScoped(model: "Fable"), 90)])))
        XCTAssertEqual(segments, [
            TitleSegment(text: "5h 25%", severity: .normal),
            TitleSegment(text: "W 55%", severity: .warning),
            TitleSegment(text: "F 90%", severity: .critical),
        ])
        XCTAssertEqual(Formatting.joinedTitle(segments), "5h 25% · W 55% · F 90%")
    }

    func testTitleIsEmptyWhileLoading() {
        // Not "…". The app decides what an empty title across every provider means; Claude
        // saying it alone put a loading indicator in the menu bar for one provider out of three.
        XCTAssertEqual(Formatting.claudeTitleSegments(for: .idle), [])
    }

    func testTitleForFailureKeepsLastNumbersAndAppendsWarning() {
        let segments = Formatting.claudeTitleSegments(for: .failed(.offline, last: standard))
        XCTAssertEqual(Formatting.joinedTitle(segments), "5h 25% · W 26% · F 17% · ⚠︎")
        XCTAssertEqual(segments.last, TitleSegment(text: "⚠︎", severity: .warning))
    }

    func testTitleIsEmptyWhenClaudeCodeHasNoLogin() {
        // The contract every provider follows: no credential means no segment, so a Mac that
        // only uses ChatGPT and OpenRouter never sees a Claude warning it cannot act on.
        XCTAssertEqual(Formatting.claudeTitleSegments(for: .failed(.notSignedIn, last: nil)), [])
    }

    func testTitleForOtherFailuresWithoutNumbersIsTheWarningGlyph() {
        // A real failure still shows: unlike a missing login, it says something went wrong.
        XCTAssertEqual(Formatting.joinedTitle(Formatting.claudeTitleSegments(for: .failed(.offline, last: nil))), "⚠︎")
        XCTAssertEqual(Formatting.joinedTitle(Formatting.claudeTitleSegments(for: .failed(.unauthorized, last: nil))), "⚠︎")
    }

    func testTitleSegmentsMatchTheContractTheOtherProvidersFollow() {
        // The parity this file exists to pin down. If a future change makes Claude special
        // again, this is the test that should fail.
        for state: FetchState<ClaudeUsageSnapshot> in [.idle, .failed(.notSignedIn, last: nil)] {
            XCTAssertEqual(Formatting.claudeTitleSegments(for: state), [],
                           "Claude should contribute nothing for \(state)")
            XCTAssertEqual(Formatting.chatGPTTitleSegments(for: .idle), [])
            XCTAssertEqual(Formatting.openRouterTitleSegments(for: .idle), [])
        }
        XCTAssertEqual(Formatting.chatGPTTitleSegments(for: .failed(.notSignedIn, last: nil)), [])
        XCTAssertEqual(Formatting.openRouterTitleSegments(for: .failed(.notSignedIn, last: nil)), [])
    }

    func testMenuRowsAndLines() {
        let snapshot = ClaudeUsageSnapshot(buckets: [
            ClaudeUsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            ClaudeUsageBucket(kind: .weeklyAll, percent: 26, resetsAt: iso("2026-08-23T13:59:59Z")),
            ClaudeUsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 5, resetsAt: nil),
        ], fetchedAt: now)
        let rows = Formatting.claudeMenuRows(for: snapshot, now: now, timeZone: tz, locale: locale)
        XCTAssertEqual(rows, [
            Formatting.MenuRow(label: "Session (5h)", percent: 25, bar: "▓▓▓░░░░░░░", reset: "resets in 4h 20m"),
            Formatting.MenuRow(label: "Weekly · all", percent: 26, bar: "▓▓▓░░░░░░░", reset: "resets Sun 11:59\u{202F}PM"),
            Formatting.MenuRow(label: "Weekly · Fable", percent: 5, bar: "▓░░░░░░░░░", reset: nil),
        ])
        let width = rows.map(\.label.count).max()!
        XCTAssertEqual(Formatting.menuLine(rows[0], labelWidth: width), "Session (5h)     25%  ▓▓▓░░░░░░░   resets in 4h 20m")
        XCTAssertEqual(Formatting.menuLine(rows[2], labelWidth: width), "Weekly · Fable    5%  ▓░░░░░░░░░")
    }

    func testErrorMessages() {
        let last = ClaudeUsageSnapshot(buckets: [], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.claudeErrorMessage(.notSignedIn, last: nil, now: now), "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.unauthorized, last: last, now: now), "Claude token expired. Open Claude Code to refresh it.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.rateLimited(retryAfter: nil), last: last, now: now), "Claude rate limited. Next refresh in 5 min.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.rateLimited(retryAfter: 1622), last: last, now: now),
                       "Claude rate limited. Next refresh in 27 min (server's Retry-After).")
        XCTAssertEqual(Formatting.claudeErrorMessage(.rateLimited(retryAfter: 10), last: last, now: now),
                       "Claude rate limited. Next refresh in 5 min (server's Retry-After).",
                       "the message shows the wait the poller will actually take, floor applied")
        XCTAssertEqual(Formatting.claudeErrorMessage(.http(500), last: last, now: now), "Claude usage API error (HTTP 500). Last updated 3 min ago.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.http(500), last: nil, now: now), "Claude usage API error (HTTP 500).")
        XCTAssertEqual(Formatting.claudeErrorMessage(.decoding, last: last, now: now), "Unexpected response from the Claude usage API. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.offline, last: last, now: now), "Claude unreachable. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.claudeErrorMessage(.offline, last: nil, now: now), "Claude unreachable.")
    }

    func testEveryErrorMessageNamesTheProvider() {
        // In a three-provider menu a bare "Offline." does not say whose. Claude's messages used
        // to be the unqualified ones, because it was the only provider when they were written.
        let errors: [UsageError] = [.notSignedIn, .unauthorized, .rateLimited(retryAfter: nil), .http(500), .decoding, .offline]
        for error in errors {
            let message = Formatting.claudeErrorMessage(error, last: nil, now: now)
            XCTAssertTrue(message.contains("Claude"), "\(error) produced \"\(message)\", which does not name the provider")
        }
    }

    func testTooltipLoaded() {
        let snapshot = ClaudeUsageSnapshot(buckets: [
            ClaudeUsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            ClaudeUsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 17, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(Formatting.tooltip(claude: .loaded(snapshot), now: now, timeZone: tz, locale: locale), """
        Session (5h): 25% — resets in 4h 20m
        Weekly · Fable: 17%
        Updated 30 s ago
        """)
    }

    func testTooltipFailedWithLastSnapshotStartsWithError() {
        let snapshot = ClaudeUsageSnapshot(buckets: [ClaudeUsageBucket(kind: .session, percent: 25, resetsAt: nil)], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.tooltip(claude: .failed(.offline, last: snapshot), now: now, timeZone: tz, locale: locale), """
        Claude unreachable. Last updated 3 min ago.
        Session (5h): 25%
        Updated 3 min ago
        """)
    }

    func testTooltipIdleAndFailedWithoutSnapshot() {
        // Not "Loading Claude usage…": with three providers the tooltip cannot say whose numbers
        // are still on the way.
        XCTAssertEqual(Formatting.tooltip(claude: .idle, now: now, timeZone: tz, locale: locale), "Loading usage…")
        // Nothing else has anything to say, so the missing login comes back rather than leaving
        // the tooltip blank.
        XCTAssertEqual(Formatting.tooltip(claude: .failed(.notSignedIn, last: nil), now: now, timeZone: tz, locale: locale),
                       "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
    }

    func testTooltipStaysQuietAboutAMissingClaudeLoginWhenAnotherProviderHasNumbers() {
        // The gate ChatGPT and OpenRouter already had. On a Mac that never signed in to Claude
        // Code, the line was previously repeated on every hover next to working numbers.
        let credits = OpenRouterCreditsSnapshot(totalCredits: 20, totalUsage: 7.66, fetchedAt: now)
        let text = Formatting.tooltip(claude: .failed(.notSignedIn, last: nil), openRouter: .loaded(credits), now: now)
        XCTAssertFalse(text.contains("Not signed in to Claude Code"), text)
        XCTAssertTrue(text.contains("OpenRouter credits:"), text)
    }

    func testClaudeUsagePageURL() {
        XCTAssertEqual(Formatting.claudeUsagePageURL.absoluteString, "https://claude.ai/settings/usage")
    }
}
