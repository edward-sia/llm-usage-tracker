import XCTest
@testable import ClaudeUsageBarCore

@MainActor
final class UsagePollerTests: XCTestCase {
    private func snapshot(_ percent: Int) -> UsageSnapshot {
        UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: percent, resetsAt: nil)], fetchedAt: Date(timeIntervalSince1970: 0))
    }

    /// Scripted fetcher: each call pops the next result. Records tokens it was called with.
    private final class ScriptedFetcher {
        var results: [Result<UsageSnapshot, UsageError>]
        var tokens: [String] = []
        init(_ results: [Result<UsageSnapshot, UsageError>]) { self.results = results }
        func fetch(_ token: String) async throws -> UsageSnapshot {
            tokens.append(token)
            guard !results.isEmpty else { throw UsageError.offline }
            return try results.removeFirst().get()
        }
    }

    func testSuccessfulRefreshPublishesLoaded() async {
        let fetcher = ScriptedFetcher([.success(snapshot(25))])
        var published: [FetchState<UsageSnapshot>] = []
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        poller.onChange = { published.append($0) }
        await poller.refresh()
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
        XCTAssertEqual(published, [.loaded(snapshot(25))])
        XCTAssertEqual(fetcher.tokens, ["tok"])
        XCTAssertEqual(poller.nextInterval, 60)
    }

    func testMissingTokenPublishesNotSignedIn() async {
        let fetcher = ScriptedFetcher([])
        let poller = UsagePoller(interval: 60, tokenProvider: { throw UsageError.notSignedIn }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.notSignedIn, last: nil))
        XCTAssertEqual(fetcher.tokens, [])
    }

    func testUnauthorizedRereadsTokenAndRetriesOnce() async {
        var tokenReads = 0
        let fetcher = ScriptedFetcher([.failure(.unauthorized), .success(snapshot(30))])
        let poller = UsagePoller(interval: 60, tokenProvider: { tokenReads += 1; return "tok\(tokenReads)" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .loaded(snapshot(30)))
        XCTAssertEqual(fetcher.tokens, ["tok1", "tok2"])
        XCTAssertEqual(tokenReads, 2)
    }

    func testUnauthorizedTwiceFailsWithUnauthorized() async {
        let fetcher = ScriptedFetcher([.failure(.unauthorized), .failure(.unauthorized), .success(snapshot(1))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.unauthorized, last: nil))
        XCTAssertEqual(fetcher.tokens.count, 2, "exactly one retry")
    }

    func testFailureKeepsLastSnapshot() async {
        let fetcher = ScriptedFetcher([.success(snapshot(25)), .failure(.offline)])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.offline, last: snapshot(25)))
    }

    func testRateLimitBacksOffOnceThenReturnsToInterval() async {
        let fetcher = ScriptedFetcher([.failure(.rateLimited(retryAfter: nil)), .success(snapshot(25))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.rateLimited(retryAfter: nil), last: nil))
        XCTAssertEqual(poller.nextInterval, UsagePoller<UsageSnapshot>.rateLimitBackoff)
        await poller.refresh()
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
        XCTAssertEqual(poller.nextInterval, 60)
    }

    func testRateLimitHonorsServerRetryAfter() async {
        let fetcher = ScriptedFetcher([.failure(.rateLimited(retryAfter: 1622)), .success(snapshot(25))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.nextInterval, 1622, "wait what the server asked, not the fixed default")
        await poller.refresh()
        XCTAssertEqual(poller.nextInterval, 60)
    }

    func testRetryAfterIsClampedToFloorAndCeiling() {
        XCTAssertEqual(RateLimitPolicy.backoff(retryAfter: nil), 300)
        XCTAssertEqual(RateLimitPolicy.backoff(retryAfter: 1622), 1622)
        XCTAssertEqual(RateLimitPolicy.backoff(retryAfter: 10), 300, "never retry faster than the default backoff")
        XCTAssertEqual(RateLimitPolicy.backoff(retryAfter: 90_000), 3600, "cap absurd waits at an hour")
    }

    func testChangingIntervalIsReflectedInNextInterval() async {
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: ScriptedFetcher([.success(snapshot(1))]).fetch)
        poller.interval = 180
        XCTAssertEqual(poller.nextInterval, 180)
    }

    func testUnknownErrorIsReportedAsOffline() async {
        struct Boom: Error {}
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: { _ -> UsageSnapshot in throw Boom() })
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.offline, last: nil))
    }

    func testRateLimitBackoffDescriptionMatchesPoller() {
        XCTAssertEqual(Formatting.rateLimitBackoffDescription, "\(Int(UsagePoller<UsageSnapshot>.rateLimitBackoff) / 60) min")
    }

    func testStartPollsRepeatedlyAndStopHalts() async {
        let exp = XCTestExpectation(description: "polled at least 3 times")
        exp.expectedFulfillmentCount = 3
        var count = 0
        let poller = UsagePoller(interval: 0.05, tokenProvider: { "tok" }, fetcher: { [self] _ in
            count += 1
            exp.fulfill()
            return snapshot(1)
        })
        poller.start()
        await fulfillment(of: [exp], timeout: 3)
        poller.stop()
        let countAtStop = count
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(count, countAtStop, "no fetch should happen after stop()")
    }

    func testRefreshIgnoresCallsWhileInFlight() async {
        // Holds the continuation for the fetch currently in flight so the test can control
        // exactly when it completes.
        final class ContinuationBox: @unchecked Sendable {
            var continuation: CheckedContinuation<UsageSnapshot, Error>?
        }
        let box = ContinuationBox()
        var callCount = 0
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: { _ in
            callCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                box.continuation = continuation
            }
        })

        async let a: Void = poller.refresh()
        async let b: Void = poller.refresh()

        var attempts = 0
        while box.continuation == nil && attempts < 1000 {
            await Task.yield()
            attempts += 1
        }
        box.continuation?.resume(returning: snapshot(42))
        await a
        await b

        XCTAssertEqual(callCount, 1, "the second concurrent refresh() must be ignored while one is in flight")
        XCTAssertEqual(poller.state, .loaded(snapshot(42)))
        poller.stop()
    }

    func testPollerDrivesCreditsSnapshotsToo() async {
        // The poller is generic over the snapshot type so OpenRouter credits reuse the same
        // tested retry/backoff/staleness logic.
        let credits = CreditsSnapshot(totalCredits: 500, totalUsage: 487.66, fetchedAt: Date(timeIntervalSince1970: 0))
        let poller = UsagePoller(interval: 60, tokenProvider: { "sk-or-key" }, fetcher: { _ in credits })
        await poller.refresh()
        XCTAssertEqual(poller.state, .loaded(credits))
        await poller.refreshIfStale(olderThan: 20, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(poller.state, .loaded(credits), "fresh credits must not refetch")
    }

    // The snapshot(_) helper stamps fetchedAt = 1970-01-01, so `now` offsets below are the
    // age of the last good numbers in seconds.
    private let epoch = Date(timeIntervalSince1970: 0)

    func testRefreshIfStaleSkipsWhenNumbersAreFresh() async {
        let fetcher = ScriptedFetcher([.success(snapshot(25)), .success(snapshot(99))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()                                      // loaded, fetchedAt = epoch
        await poller.refreshIfStale(olderThan: 20, now: epoch.addingTimeInterval(10))
        XCTAssertEqual(fetcher.tokens.count, 1, "10s < 20s: must not fetch again")
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
    }

    func testRefreshIfStaleFetchesWhenNumbersAreStale() async {
        let fetcher = ScriptedFetcher([.success(snapshot(25)), .success(snapshot(99))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        await poller.refreshIfStale(olderThan: 20, now: epoch.addingTimeInterval(30))
        XCTAssertEqual(fetcher.tokens.count, 2, "30s >= 20s: must fetch")
        XCTAssertEqual(poller.state, .loaded(snapshot(99)))
    }

    func testRefreshIfStaleFetchesWhenNoSnapshotYet() async {
        let fetcher = ScriptedFetcher([.success(snapshot(25))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refreshIfStale(olderThan: 20, now: epoch.addingTimeInterval(5))
        XCTAssertEqual(fetcher.tokens.count, 1, "no numbers yet: must fetch")
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
    }

    func testRefreshIfStaleSkipsWhileBackingOff() async {
        // A 429 puts the poller in backoff; an opportunistic refresh must not poke the endpoint,
        // even though there are no fresh numbers to reuse.
        let fetcher = ScriptedFetcher([.failure(.rateLimited(retryAfter: nil)), .success(snapshot(50))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.rateLimited(retryAfter: nil), last: nil))
        await poller.refreshIfStale(olderThan: 0, now: epoch.addingTimeInterval(9_999))
        XCTAssertEqual(fetcher.tokens.count, 1, "backing off: must not fetch on an opportunistic trigger")
        XCTAssertEqual(poller.state, .failed(.rateLimited(retryAfter: nil), last: nil))
    }

    // MARK: Wake

    func testWakeFetchesAfterJitterWhenStale() async {
        let exp = XCTestExpectation(description: "wake fetch fired")
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: { [self] _ in
            exp.fulfill()
            return snapshot(25)
        })
        poller.wake(jitter: 0.05)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
    }

    func testWakeSkipsWhenNumbersAreFresh() async {
        // fetchedAt is stamped with the real clock here because wake() checks staleness
        // against the real clock after its jitter delay.
        let fresh = UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: 1, resetsAt: nil)], fetchedAt: Date())
        var calls = 0
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: { _ in
            calls += 1
            return fresh
        })
        await poller.refresh()
        XCTAssertEqual(calls, 1)
        poller.wake(jitter: 0.02)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1, "numbers seconds old: wake must not fetch again")
    }

    func testWakeSkipsWhileBackingOff() async {
        let fetcher = ScriptedFetcher([.failure(.rateLimited(retryAfter: nil)), .success(snapshot(50))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        poller.wake(jitter: 0.02)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fetcher.tokens.count, 1, "backing off: wake must not fetch")
    }
}
