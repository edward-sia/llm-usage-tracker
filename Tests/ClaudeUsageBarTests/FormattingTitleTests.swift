import XCTest
@testable import ClaudeUsageBarCore

final class FormattingTitleTests: XCTestCase {
    private func bucket(_ kind: UsageBucket.Kind, _ percent: Int) -> UsageBucket {
        UsageBucket(kind: kind, percent: percent, resetsAt: nil)
    }
    private func snapshot(_ buckets: [UsageBucket]) -> UsageSnapshot {
        UsageSnapshot(buckets: buckets, fetchedAt: Date(timeIntervalSince1970: 0))
    }
    private var standard: UsageSnapshot {
        snapshot([bucket(.session, 25), bucket(.weeklyAll, 26), bucket(.weeklyScoped(model: "Fable"), 17)])
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

    func testShortLabelsForStandardKinds() {
        XCTAssertEqual(Formatting.shortLabels(for: standard.buckets), ["5h", "W", "F"])
    }

    func testShortLabelForScopedModelWithoutNameIsM() {
        XCTAssertEqual(Formatting.shortLabels(for: [bucket(.weeklyScoped(model: nil), 1)]), ["M"])
        XCTAssertEqual(Formatting.shortLabels(for: [bucket(.weeklyScoped(model: "  "), 1)]), ["M"])
    }

    func testShortLabelForUnknownKindIsFirstLetter() {
        XCTAssertEqual(Formatting.shortLabels(for: [bucket(.other("mystery_limit"), 1)]), ["M"])
        XCTAssertEqual(Formatting.shortLabels(for: [bucket(.other(""), 1)]), ["?"])
    }

    func testScopedLabelCollisionUsesTwoLetters() {
        let buckets = [bucket(.weeklyScoped(model: "Fable"), 1), bucket(.weeklyScoped(model: "Falcon"), 2), bucket(.weeklyScoped(model: "Opus"), 3)]
        XCTAssertEqual(Formatting.shortLabels(for: buckets), ["Fa", "Fa", "O"])
        // Two letters still collide here; that is accepted (spec: "use the first two letters").
    }

    func testLongLabels() {
        XCTAssertEqual(Formatting.longLabel(for: .session), "Session (5h)")
        XCTAssertEqual(Formatting.longLabel(for: .weeklyAll), "Weekly · all")
        XCTAssertEqual(Formatting.longLabel(for: .weeklyScoped(model: "Fable")), "Weekly · Fable")
        XCTAssertEqual(Formatting.longLabel(for: .weeklyScoped(model: nil)), "Weekly · model")
        XCTAssertEqual(Formatting.longLabel(for: .other("mystery_limit")), "Mystery limit")
    }

    func testTitleSegmentsForLoadedState() {
        let segments = Formatting.titleSegments(for: .loaded(snapshot([bucket(.session, 25), bucket(.weeklyAll, 55), bucket(.weeklyScoped(model: "Fable"), 90)])))
        XCTAssertEqual(segments, [
            TitleSegment(text: "5h 25%", severity: .normal),
            TitleSegment(text: "W 55%", severity: .warning),
            TitleSegment(text: "F 90%", severity: .critical),
        ])
        XCTAssertEqual(Formatting.joinedTitle(segments), "5h 25% · W 55% · F 90%")
    }

    func testTitleForIdleIsEllipsis() {
        XCTAssertEqual(Formatting.joinedTitle(Formatting.titleSegments(for: .idle)), "…")
    }

    func testTitleForFailureKeepsLastNumbersAndAppendsWarning() {
        let segments = Formatting.titleSegments(for: .failed(.offline, last: standard))
        XCTAssertEqual(Formatting.joinedTitle(segments), "5h 25% · W 26% · F 17% · ⚠︎")
        XCTAssertEqual(segments.last, TitleSegment(text: "⚠︎", severity: .warning))
    }

    func testTitleForFailureWithoutNumbers() {
        XCTAssertEqual(Formatting.joinedTitle(Formatting.titleSegments(for: .failed(.notSignedIn, last: nil))), "⚠︎ not signed in")
        XCTAssertEqual(Formatting.joinedTitle(Formatting.titleSegments(for: .failed(.offline, last: nil))), "⚠︎")
        XCTAssertEqual(Formatting.joinedTitle(Formatting.titleSegments(for: .failed(.unauthorized, last: nil))), "⚠︎")
    }
}
