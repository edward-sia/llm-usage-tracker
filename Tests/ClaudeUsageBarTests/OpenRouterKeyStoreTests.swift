import XCTest
@testable import ClaudeUsageBarCore

final class OpenRouterKeyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRouterKeyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Line parsing

    func testParsesPlainExportLine() {
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=sk-or-v1-abc123"),
                       "sk-or-v1-abc123")
    }

    func testParsesAssignmentWithoutExport() {
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: "OPENROUTER_API_KEY=sk-or-v1-abc123"),
                       "sk-or-v1-abc123")
    }

    func testParsesDoubleAndSingleQuotedValues() {
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=\"sk-or-v1-abc\""),
                       "sk-or-v1-abc")
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY='sk-or-v1-abc'"),
                       "sk-or-v1-abc")
    }

    func testIgnoresTrailingComment() {
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=sk-or-v1-abc # my key"),
                       "sk-or-v1-abc")
    }

    func testSkipsCommentedOutLines() {
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "# export OPENROUTER_API_KEY=sk-or-v1-abc"))
    }

    func testSkipsVariableReferencesItCannotResolve() {
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=$SECRET_FROM_ELSEWHERE"))
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=\"$SECRET\""))
    }

    func testSkipsEmptyValues() {
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY="))
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY=\"\""))
    }

    func testDoesNotMatchOtherVariables() {
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OPENROUTER_API_KEY_BACKUP=sk-or-v1-abc"))
        XCTAssertNil(OpenRouterKeyStore.parseKey(fromFileContents: "export OTHER_KEY=sk-or-v1-abc"))
    }

    func testLastAssignmentInAFileWins() {
        let contents = """
        export OPENROUTER_API_KEY=sk-or-v1-old
        alias ll='ls -l'
        export OPENROUTER_API_KEY=sk-or-v1-new
        """
        XCTAssertEqual(OpenRouterKeyStore.parseKey(fromFileContents: contents), "sk-or-v1-new")
    }

    // MARK: File lookup

    func testReadsKeyFromFirstFileThatHasOne() throws {
        let zshrc = try write(".zshrc", "export OPENROUTER_API_KEY=sk-or-v1-from-zshrc")
        let bashrc = try write(".bashrc", "export OPENROUTER_API_KEY=sk-or-v1-from-bashrc")
        let store = OpenRouterKeyStore(files: [zshrc, bashrc])
        XCTAssertEqual(try store.apiKey(), "sk-or-v1-from-zshrc")
    }

    func testFallsThroughFilesWithoutAKey() throws {
        let zshrc = try write(".zshrc", "alias ll='ls -l'\n# export OPENROUTER_API_KEY=sk-or-v1-commented")
        let bashrc = try write(".bashrc", "export OPENROUTER_API_KEY=sk-or-v1-from-bashrc")
        let store = OpenRouterKeyStore(files: [zshrc, bashrc])
        XCTAssertEqual(try store.apiKey(), "sk-or-v1-from-bashrc")
    }

    func testMissingFilesAreSkippedNotFatal() throws {
        let missing = directory.appendingPathComponent(".zshenv")
        let bashrc = try write(".bashrc", "OPENROUTER_API_KEY=sk-or-v1-abc")
        let store = OpenRouterKeyStore(files: [missing, bashrc])
        XCTAssertEqual(try store.apiKey(), "sk-or-v1-abc")
    }

    func testThrowsNotSignedInWhenNoFileHasAKey() throws {
        let zshrc = try write(".zshrc", "alias ll='ls -l'")
        let store = OpenRouterKeyStore(files: [zshrc, directory.appendingPathComponent(".bashrc")])
        XCTAssertThrowsError(try store.apiKey()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    func testDefaultFileListCoversCommonShellConfigs() {
        let names = OpenRouterKeyStore.defaultFiles.map(\.lastPathComponent)
        XCTAssertEqual(names, [".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile", ".profile"])
    }
}
