import XCTest
@testable import ClaudeUsageBarCore

final class UsageResponseDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_020_740) // arbitrary fixed instant used as fetchedAt

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "usage-response", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testDecodesRealResponseIntoThreeBucketsInDisplayOrder() throws {
        let snapshot = try UsageResponseDecoder.decode(try fixture(), fetchedAt: now)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.buckets, [
            UsageBucket(kind: .session, percent: 25, resetsAt: date("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyAll, percent: 26, resetsAt: date("2026-08-23T13:59:59Z")),
            UsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 17, resetsAt: date("2026-08-23T13:59:59Z")),
        ])
    }

    func testFallsBackToTopLevelBucketsWhenLimitsMissing() throws {
        let json = #"{"five_hour":{"utilization":40,"resets_at":"2026-08-18T06:59:59+00:00"},"seven_day":{"utilization":70,"resets_at":null}}"#
        let snapshot = try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.buckets, [
            UsageBucket(kind: .session, percent: 40, resetsAt: date("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyAll, percent: 70, resetsAt: nil),
        ])
    }

    func testFallsBackWhenLimitsIsEmptyArray() throws {
        let json = #"{"five_hour":{"utilization":5},"seven_day":{"utilization":6},"limits":[]}"#
        let snapshot = try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.buckets.map(\.percent), [5, 6])
    }

    func testUnknownKindIsKeptAsOtherAndSortedLast() throws {
        let json = #"""
        {"limits":[
          {"kind":"mystery_limit","percent":3},
          {"kind":"weekly_scoped","percent":17,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_all","percent":26},
          {"kind":"session","percent":25}
        ]}
        """#
        let snapshot = try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.buckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped(model: "Fable"), .other("mystery_limit")])
    }

    func testScopedLimitWithoutModelNameHasNilModel() throws {
        let json = #"{"limits":[{"kind":"weekly_scoped","percent":9,"scope":{"model":null}}]}"#
        let snapshot = try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.buckets, [UsageBucket(kind: .weeklyScoped(model: nil), percent: 9, resetsAt: nil)])
    }

    func testLimitsWithoutKindOrPercentAreSkipped() throws {
        let json = #"{"limits":[{"kind":"session"},{"percent":50},{"kind":"weekly_all","percent":12.6}]}"#
        let snapshot = try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.buckets, [UsageBucket(kind: .weeklyAll, percent: 13, resetsAt: nil)])
    }

    func testThrowsDecodingWhenNothingUsable() {
        for json in ["{}", #"{"limits":null,"five_hour":null}"#, "not json", #"{"limits":[{"kind":"session"}]}"#] {
            XCTAssertThrowsError(try UsageResponseDecoder.decode(Data(json.utf8), fetchedAt: now), json) { error in
                XCTAssertEqual(error as? UsageError, .decoding)
            }
        }
    }

    func testParseDateHandlesFractionalSecondsAndOffsets() {
        XCTAssertEqual(UsageResponseDecoder.parseDate("2026-08-18T06:59:59.531450+00:00"), date("2026-08-18T06:59:59Z"))
        XCTAssertEqual(UsageResponseDecoder.parseDate("2026-08-18T06:59:59Z"), date("2026-08-18T06:59:59Z"))
        XCTAssertEqual(UsageResponseDecoder.parseDate("2026-08-18T16:59:59+10:00"), date("2026-08-18T06:59:59Z"))
        XCTAssertNil(UsageResponseDecoder.parseDate(nil))
        XCTAssertNil(UsageResponseDecoder.parseDate("tomorrow"))
    }
}
