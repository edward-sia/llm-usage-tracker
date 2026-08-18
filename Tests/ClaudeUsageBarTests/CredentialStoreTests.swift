import XCTest
@testable import ClaudeUsageBarCore

final class CredentialStoreTests: XCTestCase {
    private let blob = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-TEST","refreshToken":"sk-ant-ort01-X","expiresAt":1755509769617,"scopes":["user:inference"],"subscriptionType":"max"}}"#

    private func missingFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
    }

    func testParsesAccessTokenFromJSON() {
        XCTAssertEqual(CredentialStore.parseAccessToken(from: blob), "sk-ant-oat01-TEST")
    }

    func testParsesHexEncodedJSON() {
        // `security -w` prints hex when the secret is stored as binary data.
        let hex = blob.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(CredentialStore.parseAccessToken(from: hex), "sk-ant-oat01-TEST")
    }

    func testRejectsMissingOrEmptyToken() {
        XCTAssertNil(CredentialStore.parseAccessToken(from: #"{"claudeAiOauth":{"accessToken":""}}"#))
        XCTAssertNil(CredentialStore.parseAccessToken(from: #"{"claudeAiOauth":{}}"#))
        XCTAssertNil(CredentialStore.parseAccessToken(from: #"{"other":1}"#))
        XCTAssertNil(CredentialStore.parseAccessToken(from: "not json"))
        XCTAssertNil(CredentialStore.parseAccessToken(from: ""))
    }

    func testUsesKeychainCommandFirst() throws {
        var calls: [(String, [String])] = []
        let store = CredentialStore(runCommand: { exe, args in calls.append((exe, args)); return self.blob },
                                    credentialsFileURL: missingFile())
        XCTAssertEqual(try store.accessToken(), "sk-ant-oat01-TEST")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "/usr/bin/security")
        XCTAssertEqual(calls[0].1, ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    }

    func testFallsBackToCredentialsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        try blob.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CredentialStore(runCommand: { _, _ in nil }, credentialsFileURL: file)
        XCTAssertEqual(try store.accessToken(), "sk-ant-oat01-TEST")
    }

    func testThrowsNotSignedInWhenNothingAvailable() {
        let store = CredentialStore(runCommand: { _, _ in nil }, credentialsFileURL: missingFile())
        XCTAssertThrowsError(try store.accessToken()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    func testThrowsNotSignedInWhenKeychainBlobHasNoToken() {
        let store = CredentialStore(runCommand: { _, _ in #"{"claudeAiOauth":{}}"# }, credentialsFileURL: missingFile())
        XCTAssertThrowsError(try store.accessToken()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    func testRunProcessTimesOutAndReturnsNil() {
        let start = Date()
        let result = CredentialStore.runProcess("/bin/sleep", ["5"], timeout: 0.3)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a timed-out process must not block the caller")
    }

    func testRunProcessReturnsTrimmedStdout() {
        XCTAssertEqual(CredentialStore.runProcess("/bin/echo", ["  hi  "]), "hi")
    }

    func testRunProcessReturnsNilOnNonZeroExit() {
        XCTAssertNil(CredentialStore.runProcess("/bin/sh", ["-c", "exit 3"]))
    }
}
