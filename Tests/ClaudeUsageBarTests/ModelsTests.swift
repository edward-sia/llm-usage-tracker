import XCTest
@testable import ClaudeUsageBarCore

final class ModelsTests: XCTestCase {
    private let snapshot = UsageSnapshot(
        buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )

    func testIdleHasNoSnapshotOrError() {
        let state = FetchState<UsageSnapshot>.idle
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.error)
    }

    func testLoadedExposesSnapshot() {
        let state = FetchState.loaded(snapshot)
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertNil(state.error)
    }

    func testFailedExposesErrorAndLastSnapshot() {
        let state = FetchState.failed(.offline, last: snapshot)
        XCTAssertEqual(state.error, .offline)
        XCTAssertEqual(state.snapshot, snapshot)
    }

    func testFailedWithoutLastSnapshot() {
        let state = FetchState<UsageSnapshot>.failed(.notSignedIn, last: nil)
        XCTAssertEqual(state.error, .notSignedIn)
        XCTAssertNil(state.snapshot)
    }
}
