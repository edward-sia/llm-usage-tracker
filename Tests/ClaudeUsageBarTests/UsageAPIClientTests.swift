import XCTest
@testable import ClaudeUsageBarCore

final class UsageAPIClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_520_000)
    private var client: UsageAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        client = UsageAPIClient(session: StubURLProtocol.session())
    }

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "usage-response", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSendsCorrectRequest() async throws {
        StubURLProtocol.respond(status: 200, body: try fixture())
        _ = try await client.fetchUsage(token: "sk-ant-oat01-TEST", now: now)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-TEST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testDecodesSuccessfulResponse() async throws {
        StubURLProtocol.respond(status: 200, body: try fixture())
        let snapshot = try await client.fetchUsage(token: "t", now: now)
        XCTAssertEqual(snapshot.buckets.count, 3)
        XCTAssertEqual(snapshot.buckets[0].percent, 25)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testMapsStatusCodesToErrors() async {
        let cases: [(Int, UsageError)] = [(401, .unauthorized), (429, .rateLimited), (500, .http(500)), (403, .http(403)), (404, .http(404))]
        for (status, expected) in cases {
            StubURLProtocol.respond(status: status, body: "{}")
            do {
                _ = try await client.fetchUsage(token: "t", now: now)
                XCTFail("expected error for \(status)")
            } catch {
                XCTAssertEqual(error as? UsageError, expected, "status \(status)")
            }
        }
    }

    func testMalformedBodyIsDecodingError() async {
        StubURLProtocol.respond(status: 200, body: "<html>nope</html>")
        do {
            _ = try await client.fetchUsage(token: "t", now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .decoding)
        }
    }

    func testTransportFailureIsOffline() async {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        do {
            _ = try await client.fetchUsage(token: "t", now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? UsageError, .offline)
        }
    }
}
