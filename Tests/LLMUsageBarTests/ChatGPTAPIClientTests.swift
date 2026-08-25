import XCTest
@testable import LLMUsageBarCore

final class ChatGPTAPIClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_520_000)
    private var client: ChatGPTAPIClient!
    private let credentials = ChatGPTCredentials(accessToken: "access-token-value", accountId: "acct-123")

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        client = ChatGPTAPIClient(session: StubURLProtocol.session())
    }

    /// The response this was built against, captured from a real account.
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chatgpt-usage", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Two windows, the shape a paid plan reports. Synthesized from the same field names as the
    /// fixture — no paid account was available to capture one.
    private let twoWindowBody = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_after_seconds": 3600, "reset_at": 1755523600},
        "secondary_window": {"used_percent": 8, "limit_window_seconds": 604800, "reset_after_seconds": 200000, "reset_at": 1755720000}
      }
    }
    """

    // MARK: Request

    func testSendsCorrectRequest() async throws {
        StubURLProtocol.respond(status: 200, body: twoWindowBody)
        _ = try await client.fetchUsage(credentials: credentials, now: now)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testOmitsAccountHeaderWhenThereIsNoAccountId() async throws {
        StubURLProtocol.respond(status: 200, body: twoWindowBody)
        _ = try await client.fetchUsage(credentials: ChatGPTCredentials(accessToken: "tok", accountId: nil), now: now)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    // MARK: Decoding

    func testDecodesTheRealFreePlanResponse() throws {
        let snapshot = try ChatGPTAPIClient.decode(try fixture(), fetchedAt: now)
        XCTAssertEqual(snapshot.planType, "free")
        XCTAssertEqual(snapshot.windows.count, 1, "secondary_window is null on this plan")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 7)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 2_592_000)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_789_132_044))
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testDecodesBothWindowsInPrimaryThenSecondaryOrder() throws {
        let snapshot = try ChatGPTAPIClient.decode(Data(twoWindowBody.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [42, 8])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800])
    }

    func testRoundsFractionalPercentages() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":6.6,"limit_window_seconds":18000}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 7)
    }

    /// `reset_at` is absolute and survives a stale snapshot, so it beats the relative countdown.
    func testAbsoluteResetWinsOverRelative() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":1,"reset_after_seconds":60,"reset_at":1755530000}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_755_530_000))
    }

    func testFallsBackToRelativeResetAnchoredAtFetchTime() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":1,"reset_after_seconds":600}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.windows[0].resetsAt, now.addingTimeInterval(600))
    }

    func testMissingResetInformationIsNil() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":1}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertNil(snapshot.windows[0].windowSeconds)
    }

    func testZeroWindowAndResetValuesAreTreatedAsAbsent() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":0,"reset_after_seconds":0,"reset_at":0}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertNil(snapshot.windows[0].windowSeconds)
        XCTAssertNil(snapshot.windows[0].resetsAt)
    }

    func testMissingPlanTypeIsNil() throws {
        let snapshot = try ChatGPTAPIClient.decode(Data(#"{"rate_limit":{"primary_window":{"used_percent":1}}}"#.utf8), fetchedAt: now)
        XCTAssertNil(snapshot.planType)
    }

    func testBodiesWithNoUsableWindowAreDecodingErrors() {
        let bodies = [
            "<html>nope</html>",
            "{}",
            #"{"rate_limit":null}"#,
            #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#,
            // A window with no percentage says nothing worth rendering.
            #"{"rate_limit":{"primary_window":{"limit_window_seconds":18000}}}"#,
        ]
        for body in bodies {
            XCTAssertThrowsError(try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now), "body \(body)") { error in
                XCTAssertEqual(error as? UsageError, .decoding, "body \(body)")
            }
        }
    }

    /// A null primary with a usable secondary still renders, rather than dropping the provider.
    func testSecondaryWindowAloneIsEnough() throws {
        let body = #"{"rate_limit":{"primary_window":null,"secondary_window":{"used_percent":3,"limit_window_seconds":604800}}}"#
        let snapshot = try ChatGPTAPIClient.decode(Data(body.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [3])
    }

    // MARK: Status codes

    func testMapsStatusCodesToErrors() async {
        let cases: [(Int, UsageError)] = [(401, .unauthorized), (429, .rateLimited(retryAfter: nil)), (500, .http(500)), (403, .http(403))]
        for (status, expected) in cases {
            StubURLProtocol.respond(status: status, body: "{}")
            do {
                _ = try await client.fetchUsage(credentials: credentials, now: now)
                XCTFail("expected error for \(status)")
            } catch {
                XCTAssertEqual(error as? UsageError, expected, "status \(status)")
            }
        }
    }

    func testRateLimitCarriesRetryAfterHeader() async {
        StubURLProtocol.respond(status: 429, body: "{}", headers: ["Retry-After": "900"])
        do {
            _ = try await client.fetchUsage(credentials: credentials, now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .rateLimited(retryAfter: 900))
        }
    }

    func testTransportFailureIsOffline() async {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        do {
            _ = try await client.fetchUsage(credentials: credentials, now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .offline)
        }
    }
}
