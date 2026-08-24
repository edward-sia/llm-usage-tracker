import XCTest
@testable import ClaudeUsageBarCore

final class FormattingDetailTests: XCTestCase {
    // Sydney, like the account this was designed against. Deterministic locale for weekday/time text.
    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_US_POSIX")
    // 2026-08-18T02:39:00Z == Tue 12:39 AEST (1767225600 = 2026-01-01Z, +229 days, +2h39m)
    private let now = Date(timeIntervalSince1970: 1_787_020_740)

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
    }

    func testCountdown() {
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(4 * 3600 + 22 * 60 + 10), from: now), "4h 22m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(59 * 60), from: now), "59m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(3600), from: now), "1h 0m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(30), from: now), "<1m")
        XCTAssertEqual(Formatting.countdown(to: now, from: now), "now")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(-5), from: now), "now")
    }

    func testResetTextWithin24HoursIsCountdown() {
        let reset = iso("2026-08-18T06:59:59Z") // 16:59:59 AEST, 4h 20m 59s away
        XCTAssertEqual(Formatting.resetText(for: reset, now: now, timeZone: tz, locale: locale), "resets in 4h 20m")
    }

    func testResetTextBeyond24HoursIsWeekdayAndTime() {
        // 2026-08-23T13:59:59Z == Sun 23:59 AEST
        XCTAssertEqual(Formatting.resetText(for: iso("2026-08-23T13:59:59Z"), now: now, timeZone: tz, locale: locale), "resets Sun 11:59\u{202F}PM")
        // 2026-08-23T14:00:00Z == Mon 00:00 AEST
        XCTAssertEqual(Formatting.resetText(for: iso("2026-08-23T14:00:00Z"), now: now, timeZone: tz, locale: locale), "resets Mon 12:00\u{202F}AM")
    }

    func testResetTextForPastOrNil() {
        XCTAssertEqual(Formatting.resetText(for: now.addingTimeInterval(-60), now: now, timeZone: tz, locale: locale), "resets now")
        XCTAssertNil(Formatting.resetText(for: nil, now: now, timeZone: tz, locale: locale))
    }

    func testAgoText() {
        XCTAssertEqual(Formatting.agoText(since: now, now: now), "just now")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-4), now: now), "just now")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-30), now: now), "30 s ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(60), now: now), "just now") // clock skew
    }

    func testBar() {
        XCTAssertEqual(Formatting.bar(percent: 0), "░░░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 17), "▓▓░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 26), "▓▓▓░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 100), "▓▓▓▓▓▓▓▓▓▓")
        XCTAssertEqual(Formatting.bar(percent: 140), "▓▓▓▓▓▓▓▓▓▓")
        XCTAssertEqual(Formatting.bar(percent: -5), "░░░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 50, width: 4), "▓▓░░")
    }

    func testMenuRowsAndLines() {
        let snapshot = UsageSnapshot(buckets: [
            UsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyAll, percent: 26, resetsAt: iso("2026-08-23T13:59:59Z")),
            UsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 5, resetsAt: nil),
        ], fetchedAt: now)
        let rows = Formatting.menuRows(for: snapshot, now: now, timeZone: tz, locale: locale)
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
        let last = UsageSnapshot(buckets: [], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.errorMessage(.notSignedIn, last: nil, now: now), "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
        XCTAssertEqual(Formatting.errorMessage(.unauthorized, last: last, now: now), "Token expired. Open Claude Code to refresh it.")
        XCTAssertEqual(Formatting.errorMessage(.rateLimited(retryAfter: nil), last: last, now: now), "Rate limited. Next refresh in 5 min.")
        XCTAssertEqual(Formatting.errorMessage(.rateLimited(retryAfter: 1622), last: last, now: now),
                       "Rate limited. Next refresh in 27 min (server's Retry-After).")
        XCTAssertEqual(Formatting.errorMessage(.rateLimited(retryAfter: 10), last: last, now: now),
                       "Rate limited. Next refresh in 5 min (server's Retry-After).",
                       "the message shows the wait the poller will actually take, floor applied")
        XCTAssertEqual(Formatting.errorMessage(.http(500), last: last, now: now), "Usage API error (HTTP 500). Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.http(500), last: nil, now: now), "Usage API error (HTTP 500).")
        XCTAssertEqual(Formatting.errorMessage(.decoding, last: last, now: now), "Unexpected response from the usage API. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.offline, last: last, now: now), "Offline. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.offline, last: nil, now: now), "Offline.")
    }

    func testDurationText() {
        XCTAssertEqual(Formatting.durationText(seconds: 45), "45 s")
        XCTAssertEqual(Formatting.durationText(seconds: 300), "5 min")
        XCTAssertEqual(Formatting.durationText(seconds: 1622), "27 min")
        XCTAssertEqual(Formatting.durationText(seconds: 3600), "1 h")
        XCTAssertEqual(Formatting.durationText(seconds: 3900), "1 h 5 min")
    }

    func testTooltipLoaded() {
        let snapshot = UsageSnapshot(buckets: [
            UsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 17, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(Formatting.tooltip(for: .loaded(snapshot), now: now, timeZone: tz, locale: locale), """
        Session (5h): 25% — resets in 4h 20m
        Weekly · Fable: 17%
        Updated 30 s ago
        """)
    }

    func testTooltipFailedWithLastSnapshotStartsWithError() {
        let snapshot = UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.tooltip(for: .failed(.offline, last: snapshot), now: now, timeZone: tz, locale: locale), """
        Offline. Last updated 3 min ago.
        Session (5h): 25%
        Updated 3 min ago
        """)
    }

    func testTooltipIdleAndFailedWithoutSnapshot() {
        XCTAssertEqual(Formatting.tooltip(for: .idle, now: now, timeZone: tz, locale: locale), "Loading Claude usage…")
        XCTAssertEqual(Formatting.tooltip(for: .failed(.notSignedIn, last: nil), now: now, timeZone: tz, locale: locale),
                       "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
    }

    func testUsagePageURL() {
        XCTAssertEqual(Formatting.usagePageURL.absoluteString, "https://claude.ai/settings/usage")
    }
}
