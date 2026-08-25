import XCTest
@testable import ClaudeUsageBarCore

final class ChatGPTAuthStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTAuthStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        unsetenv("CODEX_HOME")
        try super.tearDownWithError()
    }

    private func write(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("auth.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // The real file's shape, with the secrets replaced.
    private let signedIn = """
    {
      "auth_mode": "chatgpt",
      "OPENAI_API_KEY": null,
      "tokens": {
        "id_token": "eyJhbGciOi.fake.token",
        "access_token": "access-token-value",
        "refresh_token": "refresh-token-value",
        "account_id": "acct-123"
      },
      "last_refresh": "2026-08-24T05:08:00.000Z"
    }
    """

    // MARK: Parsing

    func testParsesAccessTokenAndAccountId() {
        let credentials = ChatGPTAuthStore.parseCredentials(from: signedIn)
        XCTAssertEqual(credentials?.accessToken, "access-token-value")
        XCTAssertEqual(credentials?.accountId, "acct-123")
    }

    func testMissingAccountIdIsNilNotAFailure() {
        let raw = #"{"auth_mode":"chatgpt","tokens":{"access_token":"tok"}}"#
        let credentials = ChatGPTAuthStore.parseCredentials(from: raw)
        XCTAssertEqual(credentials?.accessToken, "tok")
        XCTAssertNil(credentials?.accountId)
    }

    func testEmptyAccountIdIsTreatedAsMissing() {
        let raw = #"{"tokens":{"access_token":"tok","account_id":""}}"#
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: raw)?.accountId)
    }

    /// An unfamiliar `auth_mode` must not hide the provider: the access token is the whole test.
    func testUnknownAuthModeStillParsesWhenATokenIsPresent() {
        let raw = #"{"auth_mode":"something_new","tokens":{"access_token":"tok","account_id":"a"}}"#
        XCTAssertEqual(ChatGPTAuthStore.parseCredentials(from: raw)?.accessToken, "tok")
    }

    /// Codex signed in with an API key instead of a ChatGPT account has no subscription to report.
    func testApiKeyModeHasNoCredentials() {
        let raw = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":null}"#
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: raw))
    }

    func testRejectsEmptyOrMissingAccessToken() {
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: #"{"tokens":{"access_token":""}}"#))
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: #"{"tokens":{"refresh_token":"r"}}"#))
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: #"{"tokens":{"access_token":123}}"#))
    }

    func testRejectsNonJSONAndEmptyInput() {
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: ""))
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: "not json at all"))
        XCTAssertNil(ChatGPTAuthStore.parseCredentials(from: "[]"))
    }

    // MARK: File lookup

    func testReadsCredentialsFromFile() throws {
        let store = ChatGPTAuthStore(authFileURL: try write(signedIn))
        let credentials = try store.credentials()
        XCTAssertEqual(credentials.accessToken, "access-token-value")
        XCTAssertEqual(credentials.accountId, "acct-123")
    }

    func testMissingFileThrowsNotSignedIn() {
        let store = ChatGPTAuthStore(authFileURL: directory.appendingPathComponent("nope.json"))
        XCTAssertThrowsError(try store.credentials()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    func testUnusableFileThrowsNotSignedIn() throws {
        let store = ChatGPTAuthStore(authFileURL: try write(#"{"auth_mode":"apikey","tokens":null}"#))
        XCTAssertThrowsError(try store.credentials()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    // MARK: Default location

    func testDefaultAuthFileIsCodexHome() {
        unsetenv("CODEX_HOME")
        let path = ChatGPTAuthStore.defaultAuthFile.path
        XCTAssertTrue(path.hasSuffix("/.codex/auth.json"), path)
    }

    func testCodexHomeEnvironmentOverridesTheDefault() {
        setenv("CODEX_HOME", "/tmp/custom-codex", 1)
        XCTAssertEqual(ChatGPTAuthStore.defaultAuthFile.path, "/tmp/custom-codex/auth.json")
    }
}
