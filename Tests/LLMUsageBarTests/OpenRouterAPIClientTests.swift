import XCTest
@testable import LLMUsageBarCore

final class OpenRouterAPIClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_520_000)
    private var client: OpenRouterAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        client = OpenRouterAPIClient(session: StubURLProtocol.session())
    }

    private let body = #"{"data":{"total_credits":500.0,"total_usage":487.66}}"#

    func testSendsCorrectRequest() async throws {
        StubURLProtocol.respond(status: 200, body: body)
        _ = try await client.fetchCredits(key: "sk-or-v1-TEST", now: now)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-TEST")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testDecodesSuccessfulResponse() async throws {
        StubURLProtocol.respond(status: 200, body: body)
        let snapshot = try await client.fetchCredits(key: "k", now: now)
        XCTAssertEqual(snapshot.totalCredits, 500.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalUsage, 487.66, accuracy: 0.001)
        XCTAssertEqual(snapshot.remaining, 12.34, accuracy: 0.001)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testMapsStatusCodesToErrors() async {
        let cases: [(Int, UsageError)] = [(401, .unauthorized), (429, .rateLimited(retryAfter: nil)), (500, .http(500)), (403, .http(403))]
        for (status, expected) in cases {
            StubURLProtocol.respond(status: status, body: "{}")
            do {
                _ = try await client.fetchCredits(key: "k", now: now)
                XCTFail("expected error for \(status)")
            } catch {
                XCTAssertEqual(error as? UsageError, expected, "status \(status)")
            }
        }
    }

    func testRateLimitCarriesRetryAfterHeader() async {
        StubURLProtocol.respond(status: 429, body: "{}", headers: ["Retry-After": "600"])
        do {
            _ = try await client.fetchCredits(key: "k", now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .rateLimited(retryAfter: 600))
        }
    }

    func testMalformedBodyIsDecodingError() async {
        for bad in ["<html>nope</html>", "{}", #"{"data":{}}"#] {
            StubURLProtocol.respond(status: 200, body: bad)
            do {
                _ = try await client.fetchCredits(key: "k", now: now)
                XCTFail("expected error for body \(bad)")
            } catch {
                XCTAssertEqual(error as? UsageError, .decoding, "body \(bad)")
            }
        }
    }

    func testTransportFailureIsOffline() async {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        do {
            _ = try await client.fetchCredits(key: "k", now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .offline)
        }
    }
}
