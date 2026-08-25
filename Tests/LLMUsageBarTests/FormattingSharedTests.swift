import XCTest
@testable import LLMUsageBarCore

/// The formatting helpers every provider shares: severity thresholds, time text, and bars.
/// Per-provider output is covered by FormattingClaudeTests, FormattingChatGPTTests, and
/// FormattingOpenRouterTests.
final class FormattingSharedTests: XCTestCase {
    // Sydney, like the account this was designed against. Deterministic locale for weekday/time text.
    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_US_POSIX")
    // 2026-08-18T02:39:00Z == Tue 12:39 AEST (1767225600 = 2026-01-01Z, +229 days, +2h39m)
    private let now = Date(timeIntervalSince1970: 1_787_020_740)

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
    }

    func testSeverityThresholds() {
        XCTAssertEqual(Formatting.severity(forPercent: 0), .normal)
        XCTAssertEqual(Formatting.severity(forPercent: 49), .normal)
        XCTAssertEqual(Formatting.severity(forPercent: 50), .warning)
        XCTAssertEqual(Formatting.severity(forPercent: 79), .warning)
        XCTAssertEqual(Formatting.severity(forPercent: 80), .critical)
        XCTAssertEqual(Formatting.severity(forPercent: 100), .critical)
        XCTAssertEqual(Formatting.severity(forPercent: 120), .critical)
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

    // MARK: Empty title

    func testEmptyTitleWithNoVisibleProvidersIsAllHidden() {
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: []), .allHidden)
    }

    func testEmptyTitleWhileAnyVisibleProviderIsStillFetching() {
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: [true]), .loading)
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: [true, true, true]), .loading)
    }

    func testEmptyTitleIsNothingSignedInOnlyWhenNothingIsStillFetching() {
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: [false]), .nothingSignedIn)
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: [false, false, false]), .nothingSignedIn)
    }

    func testLoadingWinsOverNothingSignedIn() {
        // Claude has no login but ChatGPT's first fetch is still out. Saying "not signed in"
        // here would be wrong twice: now, and again when ChatGPT's numbers land a moment later.
        XCTAssertEqual(Formatting.emptyTitle(loadingByVisibleProvider: [false, true]), .loading)
    }

    func testDurationText() {
        XCTAssertEqual(Formatting.durationText(seconds: 45), "45 s")
        XCTAssertEqual(Formatting.durationText(seconds: 300), "5 min")
        XCTAssertEqual(Formatting.durationText(seconds: 1622), "27 min")
        XCTAssertEqual(Formatting.durationText(seconds: 3600), "1 h")
        XCTAssertEqual(Formatting.durationText(seconds: 3900), "1 h 5 min")
    }
}
