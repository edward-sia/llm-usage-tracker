# Claude Usage Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that always shows Claude subscription usage (`5h 25% · W 26% · F 17%`) by reading Claude Code's Keychain token and polling Anthropic's usage endpoint.

**Architecture:** A Swift Package with three targets. `ClaudeUsageBarCore` (library, no AppKit) holds models, credential reading, HTTP client + JSON decoding, pure formatting functions, and the poller. `ClaudeUsageBar` (executable, AppKit) owns the `NSStatusItem`, menu, and preferences and wires Core together. `ClaudeUsageBarTests` depends only on Core. A shell script assembles the release binary into a `.app` bundle.

**Tech Stack:** Swift 5.9 tools-version (Swift 5 language mode) on the Swift 6.3 toolchain, macOS 14+ deployment target, AppKit (`NSStatusItem`, `NSMenu`), Foundation `URLSession`, `ServiceManagement` (`SMAppService`), XCTest, `security` CLI for Keychain reads, Make + bash for build/install.

**Spec:** `docs/superpowers/specs/2026-08-18-claude-usage-bar-design.md`

## Global Constraints

- Package: `// swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`. Do not switch to tools-version 6 (strict concurrency would add noise for no benefit).
- Core target must not `import AppKit` or `import ServiceManagement`. Only `Foundation`.
- Credentials are read-only. Never write to the Keychain, never call any token-refresh endpoint.
- Keychain read is exactly: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. File fallback is `~/.claude/.credentials.json`.
- Endpoint is exactly `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`, 10 s timeout.
- Menu bar labels: `session` → `5h`, `weekly_all` → `W`, `weekly_scoped` → first letter of model display name uppercased (`M` if missing), unknown kind → first letter of kind uppercased. Segments joined by ` · `.
- Severity thresholds: `< 50` normal, `50–79` warning (amber), `>= 80` critical (red).
- Refresh interval default 60 s; options 30 s / 60 s / 3 min / 5 min. 429 → one 5-minute backoff.
- Timeout for HTTP requests: 10 seconds.
- Commit after every task with the message shown. Every commit message ends with the line `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Never print or commit a real access token. Fixtures contain no tokens.
- Run commands from the repo root `/Users/esia/repos/llm-usage-tracker`.

---

## File map

| Path | Responsibility |
|---|---|
| `Package.swift` | Three targets, macOS 14, test resources |
| `Sources/ClaudeUsageBarCore/Models.swift` | `UsageBucket`, `UsageSnapshot`, `UsageError`, `FetchState` |
| `Sources/ClaudeUsageBarCore/CredentialStore.swift` | Read token from Keychain (via `security`) or credentials file; parse JSON (and hex-encoded JSON) |
| `Sources/ClaudeUsageBarCore/UsageResponseDecoder.swift` | Response JSON → `UsageSnapshot`; `limits[]` first, `five_hour`/`seven_day` fallback; display ordering; date parsing |
| `Sources/ClaudeUsageBarCore/UsageAPIClient.swift` | Build request, call `URLSession`, map status codes to `UsageError` |
| `Sources/ClaudeUsageBarCore/Formatting.swift` | Pure functions: short/long labels, severity, title segments, countdown/reset/ago text, bar, menu rows, tooltip, error messages |
| `Sources/ClaudeUsageBarCore/UsagePoller.swift` | `@MainActor` class: timer, `refresh()`, 401 retry, 429 backoff, `onChange` |
| `Sources/ClaudeUsageBar/main.swift` | Top-level: `NSApplication` accessory, object graph, wake observer, start |
| `Sources/ClaudeUsageBar/StatusItemController.swift` | `NSStatusItem` title/tooltip/menu rendering and actions |
| `Sources/ClaudeUsageBar/Preferences.swift` | Interval in `UserDefaults`; launch-at-login via `SMAppService` |
| `Tests/ClaudeUsageBarTests/Fixtures/usage-response.json` | Real (token-free) API response |
| `Tests/ClaudeUsageBarTests/*.swift` | One test file per Core file |
| `scripts/bundle-app.sh` | Release build → `build/ClaudeUsageBar.app`, ad-hoc codesign |
| `Makefile` | `build`, `test`, `bundle`, `run`, `install`, `clean` |
| `README.md`, `LICENSE` | Docs and MIT license |

---

### Task 1: Package scaffold and models

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeUsageBarCore/Models.swift`
- Create: `Sources/ClaudeUsageBar/main.swift` (placeholder, replaced in Task 8)
- Create: `Tests/ClaudeUsageBarTests/ModelsTests.swift`

**Interfaces:**
- Produces (used by every later task):
  ```swift
  public struct UsageBucket: Equatable, Sendable {
      public enum Kind: Equatable, Sendable { case session, weeklyAll, weeklyScoped(model: String?), other(String) }
      public let kind: Kind; public let percent: Int; public let resetsAt: Date?
      public init(kind: Kind, percent: Int, resetsAt: Date?)
  }
  public struct UsageSnapshot: Equatable, Sendable { public let buckets: [UsageBucket]; public let fetchedAt: Date; public init(buckets:fetchedAt:) }
  public enum UsageError: Error, Equatable, Sendable { case notSignedIn, unauthorized, rateLimited, http(Int), decoding, offline }
  public enum FetchState: Equatable, Sendable { case idle, loaded(UsageSnapshot), failed(UsageError, last: UsageSnapshot?); var snapshot: UsageSnapshot?; var error: UsageError? }
  ```

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
        .library(name: "ClaudeUsageBarCore", targets: ["ClaudeUsageBarCore"]),
    ],
    targets: [
        .target(name: "ClaudeUsageBarCore"),
        .executableTarget(name: "ClaudeUsageBar", dependencies: ["ClaudeUsageBarCore"]),
        .testTarget(
            name: "ClaudeUsageBarTests",
            dependencies: ["ClaudeUsageBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Create the fixtures directory with a placeholder so the resource declaration resolves**

Create `Tests/ClaudeUsageBarTests/Fixtures/.gitkeep` (empty file). Task 3 adds the real fixture.

- [ ] **Step 3: Write the failing test `Tests/ClaudeUsageBarTests/ModelsTests.swift`**

```swift
import XCTest
@testable import ClaudeUsageBarCore

final class ModelsTests: XCTestCase {
    private let snapshot = UsageSnapshot(
        buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )

    func testIdleHasNoSnapshotOrError() {
        XCTAssertNil(FetchState.idle.snapshot)
        XCTAssertNil(FetchState.idle.error)
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
        let state = FetchState.failed(.notSignedIn, last: nil)
        XCTAssertEqual(state.error, .notSignedIn)
        XCTAssertNil(state.snapshot)
    }
}
```

- [ ] **Step 4: Create placeholder `Sources/ClaudeUsageBar/main.swift`**

```swift
import Foundation
import ClaudeUsageBarCore

// Replaced in Task 8 with the real AppKit entry point.
print("ClaudeUsageBar placeholder")
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: build error — `cannot find 'UsageSnapshot' in scope` (or similar).

- [ ] **Step 6: Create `Sources/ClaudeUsageBarCore/Models.swift`**

```swift
import Foundation

/// One usage limit as reported by the usage API.
public struct UsageBucket: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The rolling 5-hour session limit (`kind: "session"`).
        case session
        /// The weekly limit across all models (`kind: "weekly_all"`).
        case weeklyAll
        /// A weekly limit scoped to one model (`kind: "weekly_scoped"`), e.g. "Fable".
        case weeklyScoped(model: String?)
        /// Any kind we do not know yet. Shown anyway so new limits appear without an update.
        case other(String)
    }

    public let kind: Kind
    /// 0–100 (may exceed 100 in theory; formatting clamps for the bar only).
    public let percent: Int
    public let resetsAt: Date?

    public init(kind: Kind, percent: Int, resetsAt: Date?) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// A successful read of the usage API, with buckets already in display order.
public struct UsageSnapshot: Equatable, Sendable {
    public let buckets: [UsageBucket]
    public let fetchedAt: Date

    public init(buckets: [UsageBucket], fetchedAt: Date) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }
}

public enum UsageError: Error, Equatable, Sendable {
    /// No Keychain item and no credentials file, or neither contained a token.
    case notSignedIn
    /// HTTP 401.
    case unauthorized
    /// HTTP 429.
    case rateLimited
    /// Any other non-2xx status.
    case http(Int)
    /// 200 but the body could not be turned into at least one bucket.
    case decoding
    /// Transport failure or timeout.
    case offline
}

/// The only thing the UI reads.
public enum FetchState: Equatable, Sendable {
    case idle
    case loaded(UsageSnapshot)
    /// The last good snapshot (if any) travels with the error so the UI can keep showing numbers.
    case failed(UsageError, last: UsageSnapshot?)

    public var snapshot: UsageSnapshot? {
        switch self {
        case .idle: return nil
        case .loaded(let snapshot): return snapshot
        case .failed(_, let last): return last
        }
    }

    public var error: UsageError? {
        if case .failed(let error, _) = self { return error }
        return nil
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test 2>&1 | tail -20`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Scaffold Swift package with Core models and test target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: CredentialStore

**Files:**
- Create: `Sources/ClaudeUsageBarCore/CredentialStore.swift`
- Create: `Tests/ClaudeUsageBarTests/CredentialStoreTests.swift`

**Interfaces:**
- Consumes: `UsageError.notSignedIn` (Task 1)
- Produces:
  ```swift
  public struct CredentialStore {
      public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> String?
      public init(runCommand: @escaping CommandRunner = CredentialStore.runProcess, credentialsFileURL: URL = <~/.claude/.credentials.json>)
      public func accessToken() throws -> String        // throws UsageError.notSignedIn
      public static func parseAccessToken(from raw: String) -> String?
      public static func runProcess(_ executable: String, _ arguments: [String]) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarTests/CredentialStoreTests.swift`**

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CredentialStoreTests 2>&1 | tail -20`
Expected: build error `cannot find 'CredentialStore' in scope`.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/CredentialStore.swift`**

```swift
import Foundation

/// Reads the Claude Code OAuth access token. Read-only: never refreshes, never writes.
///
/// Order: macOS Keychain (via the `security` CLI, same as Claude Code itself, so no
/// permission prompt), then `~/.claude/.credentials.json` for file-based installs.
public struct CredentialStore {
    public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> String?

    public static let keychainService = "Claude Code-credentials"

    private let runCommand: CommandRunner
    private let credentialsFileURL: URL

    public init(
        runCommand: @escaping CommandRunner = CredentialStore.runProcess,
        credentialsFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.runCommand = runCommand
        self.credentialsFileURL = credentialsFileURL
    }

    /// Returns the current access token or throws `UsageError.notSignedIn`.
    public func accessToken() throws -> String {
        if let raw = runCommand("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]),
           let token = Self.parseAccessToken(from: raw) {
            return token
        }
        if let data = try? Data(contentsOf: credentialsFileURL),
           let raw = String(data: data, encoding: .utf8),
           let token = Self.parseAccessToken(from: raw) {
            return token
        }
        throw UsageError.notSignedIn
    }

    /// Extracts `claudeAiOauth.accessToken` from the credential JSON.
    /// Accepts the JSON directly or hex-encoded (what `security -w` prints for binary secrets).
    public static func parseAccessToken(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates: [String] = [trimmed] + (decodeHex(trimmed).map { [$0] } ?? [])
        for text in candidates {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else { continue }
            return token
        }
        return nil
    }

    private static func decodeHex(_ text: String) -> String? {
        guard text.count % 2 == 0, text.count >= 2,
              text.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Runs a process and returns trimmed stdout, or nil on non-zero exit / launch failure.
    public static func runProcess(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CredentialStoreTests 2>&1 | tail -20`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/CredentialStore.swift Tests/ClaudeUsageBarTests/CredentialStoreTests.swift
git commit -m "Add CredentialStore: read Claude Code token from Keychain or credentials file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: UsageResponseDecoder and fixture

**Files:**
- Create: `Tests/ClaudeUsageBarTests/Fixtures/usage-response.json`
- Delete: `Tests/ClaudeUsageBarTests/Fixtures/.gitkeep`
- Create: `Sources/ClaudeUsageBarCore/UsageResponseDecoder.swift`
- Create: `Tests/ClaudeUsageBarTests/UsageResponseDecoderTests.swift`

**Interfaces:**
- Consumes: `UsageBucket`, `UsageSnapshot`, `UsageError.decoding` (Task 1)
- Produces:
  ```swift
  public enum UsageResponseDecoder {
      public static func decode(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot   // throws UsageError.decoding
      public static func sortedForDisplay(_ buckets: [UsageBucket]) -> [UsageBucket]
      public static func parseDate(_ string: String?) -> Date?
  }
  ```

- [ ] **Step 1: Create the fixture `Tests/ClaudeUsageBarTests/Fixtures/usage-response.json`** (real response shape from 2026-08-18; no secrets) and delete `.gitkeep`

```json
{
  "five_hour": {
    "utilization": 25,
    "resets_at": "2026-08-18T06:59:59.531450+00:00",
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null
  },
  "seven_day": {
    "utilization": 26,
    "resets_at": "2026-08-23T13:59:59.531474+00:00",
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null
  },
  "seven_day_oauth_apps": null,
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "seven_day_cowork": null,
  "nimbus_quill": {
    "utilization": 0,
    "resets_at": null,
    "limit_dollars": null,
    "used_dollars": null,
    "remaining_dollars": null
  },
  "extra_usage": {
    "is_enabled": false,
    "monthly_limit": null,
    "used_credits": null,
    "utilization": null,
    "currency": null,
    "decimal_places": null,
    "disabled_reason": null,
    "user_disabled": true,
    "spend_limit_reached": false,
    "credits_ever_enabled": true,
    "daily": null,
    "weekly": null
  },
  "limits": [
    {
      "kind": "session",
      "group": "session",
      "percent": 25,
      "severity": "normal",
      "resets_at": "2026-08-18T06:59:59.531450+00:00",
      "scope": null,
      "is_active": false
    },
    {
      "kind": "weekly_all",
      "group": "weekly",
      "percent": 26,
      "severity": "normal",
      "resets_at": "2026-08-23T13:59:59.531474+00:00",
      "scope": null,
      "is_active": true
    },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "percent": 17,
      "severity": "normal",
      "resets_at": "2026-08-23T13:59:59.531690+00:00",
      "scope": {
        "model": { "id": null, "display_name": "Fable" },
        "surface": null
      },
      "is_active": false
    }
  ],
  "spend": {
    "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
    "limit": null,
    "percent": 0,
    "severity": "normal",
    "enabled": false,
    "disabled_reason": null,
    "cap": null,
    "balance": null,
    "auto_reload": null,
    "disclaimer": "Usage credits cover you when you hit your plan limits.",
    "can_purchase_credits": false,
    "can_toggle": false
  },
  "member_dashboard_available": false
}
```

- [ ] **Step 2: Write the failing tests `Tests/ClaudeUsageBarTests/UsageResponseDecoderTests.swift`**

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter UsageResponseDecoderTests 2>&1 | tail -20`
Expected: build error `cannot find 'UsageResponseDecoder' in scope`.

- [ ] **Step 4: Create `Sources/ClaudeUsageBarCore/UsageResponseDecoder.swift`**

```swift
import Foundation

/// Turns the usage API JSON into a `UsageSnapshot`.
///
/// The `limits` array is the primary source (it carries per-model limits such as Fable).
/// If it is missing or empty, the top-level `five_hour` / `seven_day` objects are used.
/// Every field is optional and unknown fields are ignored so API additions do not break us.
public enum UsageResponseDecoder {
    struct Response: Decodable {
        struct Bucket: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Bucket?
        let seven_day: Bucket?
        let limits: [Limit]?
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageError.decoding
        }

        var buckets: [UsageBucket] = []
        for limit in response.limits ?? [] {
            guard let kind = limit.kind, let percent = limit.percent else { continue }
            let bucketKind: UsageBucket.Kind
            switch kind {
            case "session": bucketKind = .session
            case "weekly_all": bucketKind = .weeklyAll
            case "weekly_scoped": bucketKind = .weeklyScoped(model: limit.scope?.model?.display_name)
            default: bucketKind = .other(kind)
            }
            buckets.append(UsageBucket(kind: bucketKind, percent: Int(percent.rounded()), resetsAt: parseDate(limit.resets_at)))
        }

        if buckets.isEmpty {
            if let bucket = response.five_hour, let utilization = bucket.utilization {
                buckets.append(UsageBucket(kind: .session, percent: Int(utilization.rounded()), resetsAt: parseDate(bucket.resets_at)))
            }
            if let bucket = response.seven_day, let utilization = bucket.utilization {
                buckets.append(UsageBucket(kind: .weeklyAll, percent: Int(utilization.rounded()), resetsAt: parseDate(bucket.resets_at)))
            }
        }

        guard !buckets.isEmpty else { throw UsageError.decoding }
        return UsageSnapshot(buckets: sortedForDisplay(buckets), fetchedAt: fetchedAt)
    }

    /// session, weekly_all, scoped models (API order), then unknown kinds (API order).
    public static func sortedForDisplay(_ buckets: [UsageBucket]) -> [UsageBucket] {
        func rank(_ kind: UsageBucket.Kind) -> Int {
            switch kind {
            case .session: return 0
            case .weeklyAll: return 1
            case .weeklyScoped: return 2
            case .other: return 3
            }
        }
        // enumerated + stable tie-break keeps API order within a rank.
        return buckets.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)
    }

    /// Parses ISO-8601 timestamps like `2026-08-18T06:59:59.531450+00:00`.
    /// Fractional seconds are dropped before parsing (Foundation's parser is picky about their length).
    public static func parseDate(_ string: String?) -> Date? {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zoneStart = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text = String(text[..<dot]) + String(text[zoneStart...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter UsageResponseDecoderTests 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`. If `Bundle.module` fails to find the fixture, check that `Package.swift` has `resources: [.copy("Fixtures")]` on the test target and the file is at `Tests/ClaudeUsageBarTests/Fixtures/usage-response.json`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageBarCore/UsageResponseDecoder.swift Tests/ClaudeUsageBarTests
git commit -m "Add UsageResponseDecoder with real-response fixture

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: UsageAPIClient

**Files:**
- Create: `Sources/ClaudeUsageBarCore/UsageAPIClient.swift`
- Create: `Tests/ClaudeUsageBarTests/StubURLProtocol.swift`
- Create: `Tests/ClaudeUsageBarTests/UsageAPIClientTests.swift`

**Interfaces:**
- Consumes: `UsageResponseDecoder.decode(_:fetchedAt:)` (Task 3), `UsageError` (Task 1)
- Produces:
  ```swift
  public struct UsageAPIClient {
      public static let endpoint: URL   // https://api.anthropic.com/api/oauth/usage
      public init(session: URLSession = .shared)
      public func fetchUsage(token: String, now: Date = Date()) async throws -> UsageSnapshot   // throws UsageError
  }
  ```

- [ ] **Step 1: Create the test helper `Tests/ClaudeUsageBarTests/StubURLProtocol.swift`**

```swift
import Foundation

/// Intercepts every request on a session built with `StubURLProtocol.session()`.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    static var handler: Handler?
    static var lastRequest: URLRequest?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func respond(status: Int, body: String = "") {
        handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    static func fail(with error: Error) {
        handler = { _ in throw error }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing tests `Tests/ClaudeUsageBarTests/UsageAPIClientTests.swift`**

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter UsageAPIClientTests 2>&1 | tail -20`
Expected: build error `cannot find 'UsageAPIClient' in scope`.

- [ ] **Step 4: Create `Sources/ClaudeUsageBarCore/UsageAPIClient.swift`**

```swift
import Foundation

/// Calls Anthropic's OAuth usage endpoint with a Claude Code access token.
public struct UsageAPIClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let timeout: TimeInterval = 10

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and decodes usage. Throws `UsageError` only.
    public func fetchUsage(token: String, now: Date = Date()) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.offline }

        switch http.statusCode {
        case 200..<300: break
        case 401: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
        return try UsageResponseDecoder.decode(data, fetchedAt: now)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter UsageAPIClientTests 2>&1 | tail -20`
Expected: `Executed 5 tests, with 0 failures`.

If only the `timeoutInterval` assertion fails because `URLProtocol` hands the request over with a default timeout, keep the implementation and instead assert the timeout on the client constant: `XCTAssertEqual(UsageAPIClient.timeout, 10)`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageBarCore/UsageAPIClient.swift Tests/ClaudeUsageBarTests/StubURLProtocol.swift Tests/ClaudeUsageBarTests/UsageAPIClientTests.swift
git commit -m "Add UsageAPIClient with status-code to UsageError mapping

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Formatting — labels, severity, title segments

**Files:**
- Create: `Sources/ClaudeUsageBarCore/Formatting.swift`
- Create: `Tests/ClaudeUsageBarTests/FormattingTitleTests.swift`

**Interfaces:**
- Consumes: `UsageBucket`, `UsageSnapshot`, `FetchState`, `UsageError` (Task 1)
- Produces (Task 6 extends the same enum; Task 8 renders these):
  ```swift
  public enum Severity: Equatable, Sendable { case normal, warning, critical }
  public struct TitleSegment: Equatable, Sendable { public let text: String; public let severity: Severity }
  public enum Formatting {
      public static let warningThreshold = 50
      public static let criticalThreshold = 80
      public static let separator = " · "
      public static func severity(forPercent: Int) -> Severity
      public static func shortLabels(for buckets: [UsageBucket]) -> [String]
      public static func longLabel(for kind: UsageBucket.Kind) -> String
      public static func titleSegments(for state: FetchState) -> [TitleSegment]
      public static func joinedTitle(_ segments: [TitleSegment]) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarTests/FormattingTitleTests.swift`**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FormattingTitleTests 2>&1 | tail -20`
Expected: build error `cannot find 'Formatting' in scope`.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/Formatting.swift`**

```swift
import Foundation

/// How urgent a number is. The app maps this to a color; Core stays AppKit-free.
public enum Severity: Equatable, Sendable {
    case normal, warning, critical
}

/// One piece of the menu bar title, e.g. "5h 25%".
public struct TitleSegment: Equatable, Sendable {
    public let text: String
    public let severity: Severity
    public init(text: String, severity: Severity) {
        self.text = text
        self.severity = severity
    }
}

/// Pure functions from state to display strings. Nothing here touches AppKit or the clock
/// (callers pass `now`), so all of it is unit-tested.
public enum Formatting {
    public static let warningThreshold = 50
    public static let criticalThreshold = 80
    public static let separator = " · "
    public static let warningGlyph = "⚠︎"

    public static func severity(forPercent percent: Int) -> Severity {
        if percent >= criticalThreshold { return .critical }
        if percent >= warningThreshold { return .warning }
        return .normal
    }

    // MARK: Labels

    /// Short labels for the menu bar, in bucket order. Scoped models that share a first
    /// letter get two letters instead.
    public static func shortLabels(for buckets: [UsageBucket]) -> [String] {
        var labels = buckets.map { baseShortLabel(for: $0.kind) }
        let scopedIndices = buckets.indices.filter {
            if case .weeklyScoped = buckets[$0].kind { return true }
            return false
        }
        var counts: [String: Int] = [:]
        for index in scopedIndices { counts[labels[index], default: 0] += 1 }
        for index in scopedIndices where counts[labels[index], default: 0] > 1 {
            if case .weeklyScoped(let model?) = buckets[index].kind {
                let trimmed = model.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 2 {
                    labels[index] = trimmed.prefix(1).uppercased() + trimmed.dropFirst().prefix(1).lowercased()
                }
            }
        }
        return labels
    }

    private static func baseShortLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session:
            return "5h"
        case .weeklyAll:
            return "W"
        case .weeklyScoped(let model):
            guard let first = model?.trimmingCharacters(in: .whitespaces).first else { return "M" }
            return String(first).uppercased()
        case .other(let kind):
            guard let first = kind.trimmingCharacters(in: .whitespaces).first else { return "?" }
            return String(first).uppercased()
        }
    }

    /// Full label for menus and tooltips.
    public static func longLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session: return "Session (5h)"
        case .weeklyAll: return "Weekly · all"
        case .weeklyScoped(let model):
            let name = model?.trimmingCharacters(in: .whitespaces) ?? ""
            return "Weekly · \(name.isEmpty ? "model" : name)"
        case .other(let kind):
            let words = kind.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            guard let first = words.first else { return "Unknown limit" }
            return String(first).uppercased() + words.dropFirst()
        }
    }

    // MARK: Title

    public static func titleSegments(for state: FetchState) -> [TitleSegment] {
        switch state {
        case .idle:
            return [TitleSegment(text: "…", severity: .normal)]
        case .loaded(let snapshot):
            return segments(for: snapshot)
        case .failed(let error, let last):
            if let last {
                return segments(for: last) + [TitleSegment(text: warningGlyph, severity: .warning)]
            }
            switch error {
            case .notSignedIn: return [TitleSegment(text: "\(warningGlyph) not signed in", severity: .warning)]
            default: return [TitleSegment(text: warningGlyph, severity: .warning)]
            }
        }
    }

    private static func segments(for snapshot: UsageSnapshot) -> [TitleSegment] {
        let labels = shortLabels(for: snapshot.buckets)
        return zip(labels, snapshot.buckets).map { label, bucket in
            TitleSegment(text: "\(label) \(bucket.percent)%", severity: severity(forPercent: bucket.percent))
        }
    }

    public static func joinedTitle(_ segments: [TitleSegment]) -> String {
        segments.map(\.text).joined(separator: separator)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FormattingTitleTests 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageBarCore/Formatting.swift Tests/ClaudeUsageBarTests/FormattingTitleTests.swift
git commit -m "Add Formatting: labels, severity thresholds, menu bar title segments

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Formatting — time text, bar, menu rows, tooltip, error messages

**Files:**
- Modify: `Sources/ClaudeUsageBarCore/Formatting.swift` (append inside `enum Formatting`)
- Create: `Tests/ClaudeUsageBarTests/FormattingDetailTests.swift`

**Interfaces:**
- Consumes: everything from Task 5
- Produces (Task 8 renders these):
  ```swift
  extension Formatting {
      public static func countdown(to date: Date, from now: Date) -> String
      public static func resetText(for date: Date?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String?
      public static func agoText(since date: Date, now: Date) -> String
      public static func bar(percent: Int, width: Int = 10) -> String
      public struct MenuRow: Equatable, Sendable { public let label: String; public let percent: Int; public let bar: String; public let reset: String? }
      public static func menuRows(for snapshot: UsageSnapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [MenuRow]
      public static func menuLine(_ row: MenuRow, labelWidth: Int) -> String
      public static func errorMessage(_ error: UsageError, last: UsageSnapshot?, now: Date) -> String
      public static func tooltip(for state: FetchState, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String
      public static let usagePageURL: URL   // https://claude.ai/settings/usage
  }
  ```

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarTests/FormattingDetailTests.swift`**

```swift
import XCTest
@testable import ClaudeUsageBarCore

final class FormattingDetailTests: XCTestCase {
    // Sydney, like the account this was designed against. Deterministic locale for weekday/time text.
    private let tz = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_US_POSIX")
    // 2026-08-18T02:39:00Z == Tue 12:39 AEST (1767225600 = 2026-01-01Z, +229 days, +2h39m)
    private let now = Date(timeIntervalSince1970: 1_787_020_740)

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
    }

    func testCountdown() {
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(4 * 3600 + 22 * 60 + 10), from: now), "4h 22m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(59 * 60), from: now), "59m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(3600), from: now), "1h 0m")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(30), from: now), "<1m")
        XCTAssertEqual(Formatting.countdown(to: now, from: now), "now")
        XCTAssertEqual(Formatting.countdown(to: now.addingTimeInterval(-5), from: now), "now")
    }

    func testResetTextWithin24HoursIsCountdown() {
        let reset = iso("2026-08-18T06:59:59Z") // 16:59:59 AEST, 4h 20m 59s away
        XCTAssertEqual(Formatting.resetText(for: reset, now: now, timeZone: tz, locale: locale), "resets in 4h 20m")
    }

    func testResetTextBeyond24HoursIsWeekdayAndTime() {
        // 2026-08-23T13:59:59Z == Sun 23:59 AEST
        XCTAssertEqual(Formatting.resetText(for: iso("2026-08-23T13:59:59Z"), now: now, timeZone: tz, locale: locale), "resets Sun 11:59 PM")
        // 2026-08-23T14:00:00Z == Mon 00:00 AEST
        XCTAssertEqual(Formatting.resetText(for: iso("2026-08-23T14:00:00Z"), now: now, timeZone: tz, locale: locale), "resets Mon 12:00 AM")
    }

    func testResetTextForPastOrNil() {
        XCTAssertEqual(Formatting.resetText(for: now.addingTimeInterval(-60), now: now, timeZone: tz, locale: locale), "resets now")
        XCTAssertNil(Formatting.resetText(for: nil, now: now, timeZone: tz, locale: locale))
    }

    func testAgoText() {
        XCTAssertEqual(Formatting.agoText(since: now, now: now), "just now")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-4), now: now), "just now")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-30), now: now), "30 s ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(Formatting.agoText(since: now.addingTimeInterval(60), now: now), "just now") // clock skew
    }

    func testBar() {
        XCTAssertEqual(Formatting.bar(percent: 0), "░░░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 17), "▓▓░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 26), "▓▓▓░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 100), "▓▓▓▓▓▓▓▓▓▓")
        XCTAssertEqual(Formatting.bar(percent: 140), "▓▓▓▓▓▓▓▓▓▓")
        XCTAssertEqual(Formatting.bar(percent: -5), "░░░░░░░░░░")
        XCTAssertEqual(Formatting.bar(percent: 50, width: 4), "▓▓░░")
    }

    func testMenuRowsAndLines() {
        let snapshot = UsageSnapshot(buckets: [
            UsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyAll, percent: 26, resetsAt: iso("2026-08-23T13:59:59Z")),
            UsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 5, resetsAt: nil),
        ], fetchedAt: now)
        let rows = Formatting.menuRows(for: snapshot, now: now, timeZone: tz, locale: locale)
        XCTAssertEqual(rows, [
            Formatting.MenuRow(label: "Session (5h)", percent: 25, bar: "▓▓▓░░░░░░░", reset: "resets in 4h 20m"),
            Formatting.MenuRow(label: "Weekly · all", percent: 26, bar: "▓▓▓░░░░░░░", reset: "resets Sun 11:59 PM"),
            Formatting.MenuRow(label: "Weekly · Fable", percent: 5, bar: "▓░░░░░░░░░", reset: nil),
        ])
        let width = rows.map(\.label.count).max()!
        XCTAssertEqual(Formatting.menuLine(rows[0], labelWidth: width), "Session (5h)     25%  ▓▓▓░░░░░░░   resets in 4h 20m")
        XCTAssertEqual(Formatting.menuLine(rows[2], labelWidth: width), "Weekly · Fable    5%  ▓░░░░░░░░░")
    }

    func testErrorMessages() {
        let last = UsageSnapshot(buckets: [], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.errorMessage(.notSignedIn, last: nil, now: now), "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
        XCTAssertEqual(Formatting.errorMessage(.unauthorized, last: last, now: now), "Token expired. Open Claude Code to refresh it.")
        XCTAssertEqual(Formatting.errorMessage(.rateLimited, last: last, now: now), "Rate limited. Next refresh in 5 min.")
        XCTAssertEqual(Formatting.errorMessage(.http(500), last: last, now: now), "Usage API error (HTTP 500). Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.http(500), last: nil, now: now), "Usage API error (HTTP 500).")
        XCTAssertEqual(Formatting.errorMessage(.decoding, last: last, now: now), "Unexpected response from the usage API. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.offline, last: last, now: now), "Offline. Last updated 3 min ago.")
        XCTAssertEqual(Formatting.errorMessage(.offline, last: nil, now: now), "Offline.")
    }

    func testTooltipLoaded() {
        let snapshot = UsageSnapshot(buckets: [
            UsageBucket(kind: .session, percent: 25, resetsAt: iso("2026-08-18T06:59:59Z")),
            UsageBucket(kind: .weeklyScoped(model: "Fable"), percent: 17, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(Formatting.tooltip(for: .loaded(snapshot), now: now, timeZone: tz, locale: locale), """
        Session (5h): 25% — resets in 4h 20m
        Weekly · Fable: 17%
        Updated 30 s ago
        """)
    }

    func testTooltipFailedWithLastSnapshotStartsWithError() {
        let snapshot = UsageSnapshot(buckets: [UsageBucket(kind: .session, percent: 25, resetsAt: nil)], fetchedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(Formatting.tooltip(for: .failed(.offline, last: snapshot), now: now, timeZone: tz, locale: locale), """
        Offline. Last updated 3 min ago.
        Session (5h): 25%
        Updated 3 min ago
        """)
    }

    func testTooltipIdleAndFailedWithoutSnapshot() {
        XCTAssertEqual(Formatting.tooltip(for: .idle, now: now, timeZone: tz, locale: locale), "Loading Claude usage…")
        XCTAssertEqual(Formatting.tooltip(for: .failed(.notSignedIn, last: nil), now: now, timeZone: tz, locale: locale),
                       "Not signed in to Claude Code. Run `claude` in a terminal and log in.")
    }

    func testUsagePageURL() {
        XCTAssertEqual(Formatting.usagePageURL.absoluteString, "https://claude.ai/settings/usage")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FormattingDetailTests 2>&1 | tail -20`
Expected: build errors like `type 'Formatting' has no member 'countdown'`.

- [ ] **Step 3: Append to `Sources/ClaudeUsageBarCore/Formatting.swift`** (a new `extension Formatting` at the end of the file)

```swift
// MARK: - Time, bars, menu, tooltip, errors

extension Formatting {
    public static let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
    public static let rateLimitBackoffDescription = "5 min"

    /// "4h 22m", "59m", "<1m", or "now" for past dates.
    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours == 0 ? "\(remainder)m" : "\(hours)h \(remainder)m"
    }

    /// nil → nil; past → "resets now"; within 24 h → "resets in 4h 22m"; else "resets Sun 11:59 PM"
    /// (weekday + localized short time, 12/24-hour follows the locale).
    public static func resetText(for date: Date?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "resets now" }
        if interval < 24 * 3600 { return "resets in \(countdown(to: date, from: now))" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return "resets \(formatter.string(from: date))"
    }

    /// "just now" (< 5 s), "30 s ago", "3 min ago", "2 h ago". Never negative.
    public static func agoText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    /// Ten-cell text bar, rounded to the nearest cell. Percent is clamped to 0…100.
    public static func bar(percent: Int, width: Int = 10) -> String {
        let clamped = min(max(percent, 0), 100)
        let filled = Int((Double(clamped) / 100 * Double(width)).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    public struct MenuRow: Equatable, Sendable {
        public let label: String
        public let percent: Int
        public let bar: String
        public let reset: String?
        public init(label: String, percent: Int, bar: String, reset: String?) {
            self.label = label
            self.percent = percent
            self.bar = bar
            self.reset = reset
        }
    }

    public static func menuRows(for snapshot: UsageSnapshot, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [MenuRow] {
        snapshot.buckets.map { bucket in
            MenuRow(label: longLabel(for: bucket.kind),
                    percent: bucket.percent,
                    bar: bar(percent: bucket.percent),
                    reset: resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale))
        }
    }

    /// One monospaced menu line: label padded to `labelWidth`, percent right-aligned to 3 chars.
    public static func menuLine(_ row: MenuRow, labelWidth: Int) -> String {
        let padded = row.label.padding(toLength: max(labelWidth, row.label.count), withPad: " ", startingAt: 0)
        let percentText = "\(row.percent)%"
        let alignedPercent = String(repeating: " ", count: max(0, 4 - percentText.count)) + percentText
        var line = "\(padded)  \(alignedPercent)  \(row.bar)"
        if let reset = row.reset { line += "   \(reset)" }
        return line
    }

    public static func errorMessage(_ error: UsageError, last: UsageSnapshot?, now: Date) -> String {
        let suffix = last.map { " Last updated \(agoText(since: $0.fetchedAt, now: now))." } ?? ""
        switch error {
        case .notSignedIn: return "Not signed in to Claude Code. Run `claude` in a terminal and log in."
        case .unauthorized: return "Token expired. Open Claude Code to refresh it."
        case .rateLimited: return "Rate limited. Next refresh in \(rateLimitBackoffDescription)."
        case .http(let code): return "Usage API error (HTTP \(code)).\(suffix)"
        case .decoding: return "Unexpected response from the usage API.\(suffix)"
        case .offline: return "Offline.\(suffix)"
        }
    }

    public static func tooltip(for state: FetchState, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var lines: [String] = []
        if let error = state.error {
            lines.append(errorMessage(error, last: state.snapshot, now: now))
        }
        if let snapshot = state.snapshot {
            for bucket in snapshot.buckets {
                var line = "\(longLabel(for: bucket.kind)): \(bucket.percent)%"
                if let reset = resetText(for: bucket.resetsAt, now: now, timeZone: timeZone, locale: locale) {
                    line += " — \(reset)"
                }
                lines.append(line)
            }
            lines.append("Updated \(agoText(since: snapshot.fetchedAt, now: now))")
        }
        if lines.isEmpty { lines.append("Loading Claude usage…") }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FormattingDetailTests 2>&1 | tail -30`
Expected: `Executed 12 tests, with 0 failures`.

If `testMenuRowsAndLines` fails on spacing, check the exact expected strings: label padded to 14 (`"Weekly · Fable"` is 14 chars), then two spaces, then percent right-aligned in 4 chars (`" 25%"`), two spaces, bar, three spaces, reset. `"Session (5h)"` (12) + 2 pad + `"  "` + `" 25%"` → `"Session (5h)     25%"` (5 spaces between `)` and `25%`); `"Weekly · Fable"` (14) + `"  "` + `"  5%"` → 4 spaces between `Fable` and `5%`.

If `testResetTextBeyond24HoursIsWeekdayAndTime` yields e.g. `"resets Sun 11:59 PM"` with a narrow no-break space before `PM` (U+202F), that is what `en_US_POSIX` produces on recent macOS. Adjust the two expected strings in that test to use `\u{202F}` before `PM`/`AM` and keep the implementation as is.

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageBarCore/Formatting.swift Tests/ClaudeUsageBarTests/FormattingDetailTests.swift
git commit -m "Add Formatting: countdowns, bars, menu rows, tooltip, error messages

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: UsagePoller

**Files:**
- Create: `Sources/ClaudeUsageBarCore/UsagePoller.swift`
- Create: `Tests/ClaudeUsageBarTests/UsagePollerTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageError`, `FetchState` (Task 1)
- Produces (Task 8 wires this):
  ```swift
  @MainActor public final class UsagePoller {
      public typealias TokenProvider = () throws -> String
      public typealias Fetcher = (_ token: String) async throws -> UsageSnapshot
      public static let rateLimitBackoff: TimeInterval = 300
      public private(set) var state: FetchState
      public var onChange: ((FetchState) -> Void)?
      public var interval: TimeInterval          // setting it reschedules the timer
      public var nextInterval: TimeInterval      // interval, or 300 after a 429
      public init(interval: TimeInterval, tokenProvider: @escaping TokenProvider, fetcher: @escaping Fetcher)
      public func start()                        // refresh now + schedule timer
      public func stop()
      public func refresh() async                // one fetch cycle; ignored if one is already running
  }
  ```

- [ ] **Step 1: Write the failing tests `Tests/ClaudeUsageBarTests/UsagePollerTests.swift`**

```swift
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
        var published: [FetchState] = []
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
        let fetcher = ScriptedFetcher([.failure(.rateLimited), .success(snapshot(25))])
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: fetcher.fetch)
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.rateLimited, last: nil))
        XCTAssertEqual(poller.nextInterval, UsagePoller.rateLimitBackoff)
        await poller.refresh()
        XCTAssertEqual(poller.state, .loaded(snapshot(25)))
        XCTAssertEqual(poller.nextInterval, 60)
    }

    func testChangingIntervalIsReflectedInNextInterval() async {
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: ScriptedFetcher([.success(snapshot(1))]).fetch)
        poller.interval = 180
        XCTAssertEqual(poller.nextInterval, 180)
    }

    func testUnknownErrorIsReportedAsOffline() async {
        struct Boom: Error {}
        let poller = UsagePoller(interval: 60, tokenProvider: { "tok" }, fetcher: { _ in throw Boom() })
        await poller.refresh()
        XCTAssertEqual(poller.state, .failed(.offline, last: nil))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UsagePollerTests 2>&1 | tail -20`
Expected: build error `cannot find 'UsagePoller' in scope`.

- [ ] **Step 3: Create `Sources/ClaudeUsageBarCore/UsagePoller.swift`**

```swift
import Foundation

/// Drives periodic fetches and owns the current `FetchState`.
///
/// - One retry with a freshly read token after a 401 (Claude Code may have rotated it).
/// - After a 429 the next tick waits `rateLimitBackoff` instead of `interval`, once.
/// - The last good snapshot travels with every failure so the UI keeps showing numbers.
/// - Wake-from-sleep is handled by the app calling `refresh()`; Core has no AppKit.
@MainActor
public final class UsagePoller {
    public typealias TokenProvider = () throws -> String
    public typealias Fetcher = (_ token: String) async throws -> UsageSnapshot

    public static let rateLimitBackoff: TimeInterval = 300

    public private(set) var state: FetchState = .idle {
        didSet { onChange?(state) }
    }
    public var onChange: ((FetchState) -> Void)?

    public var interval: TimeInterval {
        didSet { if running { scheduleNext() } }
    }

    /// What the next timer wait will be: the normal interval, or the backoff after a 429.
    public var nextInterval: TimeInterval {
        backingOff ? Self.rateLimitBackoff : interval
    }

    private let tokenProvider: TokenProvider
    private let fetcher: Fetcher
    private var timer: Timer?
    private var running = false
    private var backingOff = false
    private var inFlight = false

    public init(interval: TimeInterval, tokenProvider: @escaping TokenProvider, fetcher: @escaping Fetcher) {
        self.interval = interval
        self.tokenProvider = tokenProvider
        self.fetcher = fetcher
    }

    /// Fetch immediately, then keep fetching on the timer.
    public func start() {
        running = true
        Task { await refresh() }
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// One fetch cycle. Calls made while a fetch is in flight are ignored.
    public func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let previous = state.snapshot
        do {
            let snapshot = try await fetchOnce(retryOnUnauthorized: true)
            backingOff = false
            state = .loaded(snapshot)
        } catch let error as UsageError {
            backingOff = (error == .rateLimited)
            state = .failed(error, last: previous)
        } catch {
            backingOff = false
            state = .failed(.offline, last: previous)
        }
        if running { scheduleNext() }
    }

    private func fetchOnce(retryOnUnauthorized: Bool) async throws -> UsageSnapshot {
        let token = try tokenProvider()
        do {
            return try await fetcher(token)
        } catch UsageError.unauthorized where retryOnUnauthorized {
            return try await fetchOnce(retryOnUnauthorized: false)
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let timer = Timer(timeInterval: nextInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        timer.tolerance = min(5, nextInterval / 10)
        // .common so the timer still fires while a menu is open (menu tracking uses its own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UsagePollerTests 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`.

If the compiler complains that `fetcher.fetch` (an instance method of a non-Sendable class) cannot be passed, keep Swift 5 mode (tools-version 5.9) — it is a warning at most. If it is an error, wrap: `fetcher: { try await fetcher.fetch($0) }`.

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageBarCore/UsagePoller.swift Tests/ClaudeUsageBarTests/UsagePollerTests.swift
git commit -m "Add UsagePoller with 401 retry and 429 backoff

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Menu bar app (Preferences, StatusItemController, main.swift)

**Files:**
- Create: `Sources/ClaudeUsageBar/Preferences.swift`
- Create: `Sources/ClaudeUsageBar/StatusItemController.swift`
- Replace: `Sources/ClaudeUsageBar/main.swift`

**Interfaces:**
- Consumes: `CredentialStore`, `UsageAPIClient`, `UsagePoller`, `Formatting`, `TitleSegment`, `Severity`, `FetchState` from Core.
- Produces: the running app. No later task consumes Swift symbols from this one; Task 9 bundles the binary named `ClaudeUsageBar`.

There are no unit tests for this task (it is AppKit glue over tested Core). Verification is `swift build` plus a manual run.

- [ ] **Step 1: Create `Sources/ClaudeUsageBar/Preferences.swift`**

```swift
import Foundation
import ServiceManagement

/// User settings. Interval lives in UserDefaults; launch-at-login is asked of the system each time.
final class Preferences {
    struct IntervalOption: Equatable {
        let title: String
        let seconds: TimeInterval
    }

    static let intervalOptions: [IntervalOption] = [
        IntervalOption(title: "30 s", seconds: 30),
        IntervalOption(title: "60 s", seconds: 60),
        IntervalOption(title: "3 min", seconds: 180),
        IntervalOption(title: "5 min", seconds: 300),
    ]
    static let defaultInterval: TimeInterval = 60
    private static let intervalKey = "refreshInterval"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Self.intervalKey)
            return stored > 0 ? stored : Self.defaultInterval
        }
        set { defaults.set(newValue, forKey: Self.intervalKey) }
    }

    /// True when the system reports the app registered as a login item.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when not running from an installed .app bundle (e.g. `swift run`).
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Create `Sources/ClaudeUsageBar/StatusItemController.swift`**

```swift
import AppKit
import ClaudeUsageBarCore

/// Owns the NSStatusItem: renders the title/tooltip from FetchState and builds the click menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let poller: UsagePoller
    private let preferences: Preferences
    private let menu = NSMenu()
    private var state: FetchState = .idle

    init(poller: UsagePoller, preferences: Preferences) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.poller = poller
        self.preferences = preferences
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = []
        poller.onChange = { [weak self] state in self?.render(state) }
        render(.idle)
    }

    // MARK: Rendering

    private func render(_ state: FetchState) {
        self.state = state
        guard let button = statusItem.button else { return }
        button.attributedTitle = Self.attributedTitle(Formatting.titleSegments(for: state))
        button.toolTip = Formatting.tooltip(for: state, now: Date())
    }

    static func attributedTitle(_ segments: [TitleSegment]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: Formatting.separator,
                                                 attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            result.append(NSAttributedString(string: segment.text,
                                             attributes: [.font: font, .foregroundColor: color(for: segment.severity)]))
        }
        return result
    }

    static func color(for severity: Severity) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        if let error = state.error {
            addDisabled(Formatting.errorMessage(error, last: state.snapshot, now: now))
            menu.addItem(.separator())
        }

        if let snapshot = state.snapshot {
            let rows = Formatting.menuRows(for: snapshot, now: now)
            let width = rows.map(\.label.count).max() ?? 0
            for row in rows {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: Formatting.menuLine(row, labelWidth: width), attributes: [.font: mono])
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
            addDisabled("Updated \(Formatting.agoText(since: snapshot.fetchedAt, now: now))")
        } else if state.error == nil {
            addDisabled("Loading…")
            menu.addItem(.separator())
        }

        addAction("Refresh", #selector(refreshNow), key: "r")
        addAction("Open usage page (claude.ai)", #selector(openUsagePage))
        menu.addItem(.separator())

        let login = addAction("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = preferences.launchAtLogin ? .on : .off

        let intervalItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        intervalItem.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for option in Preferences.intervalOptions {
            let item = NSMenuItem(title: option.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            item.state = option.seconds == preferences.refreshInterval ? .on : .off
            submenu.addItem(item)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claude Usage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func refreshNow() {
        Task { await poller.refresh() }
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(Formatting.usagePageURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try preferences.setLaunchAtLogin(!preferences.launchAtLogin)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at login"
            alert.informativeText = "This only works when the app runs from an installed bundle (run `make install` and start /Applications/ClaudeUsageBar.app).\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        preferences.refreshInterval = seconds
        poller.interval = seconds
    }
}
```

- [ ] **Step 3: Replace `Sources/ClaudeUsageBar/main.swift`**

Top-level code in `main.swift` runs on the main actor, which is what the `@MainActor` types need.

```swift
import AppKit
import ClaudeUsageBarCore

/// Holds the object graph for the life of the process and wires system events to the poller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var statusItem: StatusItemController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let credentials = CredentialStore()
        let client = UsageAPIClient()
        let preferences = Preferences()

        let poller = UsagePoller(
            interval: preferences.refreshInterval,
            tokenProvider: { try credentials.accessToken() },
            fetcher: { token in try await client.fetchUsage(token: token) }
        )
        self.poller = poller
        self.statusItem = StatusItemController(poller: poller, preferences: preferences)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await poller.refresh() }
        }

        poller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!` with no errors. Warnings about Sendable closures are acceptable; errors are not.

Common fixes if it does not compile:
- "call to main actor-isolated initializer in a synchronous nonisolated context": make sure `AppDelegate` is marked `@MainActor` and the graph is built inside `applicationDidFinishLaunching`, as above.
- If `#selector(NSApplication.terminate(_:))` complains, use `#selector(NSApplication.shared.terminate(_:))`.

- [ ] **Step 5: Run the whole test suite still passes**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 6: Manual smoke run (bare binary)**

Run in the background: `swift run ClaudeUsageBar > /tmp/claude-usage-bar.log 2>&1 &` then `sleep 8`.

Check:
1. A new item appears at the right side of the menu bar reading like `5h 25% · W 26% · F 17%` (numbers will differ). Take a screenshot with `screencapture -x /tmp/menubar.png` and view it (Read tool) — the item should be visible top-right. If the screenshot is black/empty because Screen Recording permission is missing, fall back to `osascript -e 'tell application "System Events" to get name of every menu bar item of menu bar 2 of process "ClaudeUsageBar"'`, which lists the status item's title.
2. `cat /tmp/claude-usage-bar.log` shows no crash.
3. Quit it: `pkill -x ClaudeUsageBar`.

Record what you saw in the task report (the exact title text you observed).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeUsageBar
git commit -m "Add menu bar app: status item, click menu, preferences, wake refresh

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: App bundle script and Makefile

**Files:**
- Create: `scripts/bundle-app.sh` (executable)
- Create: `Makefile`

**Interfaces:**
- Consumes: the `ClaudeUsageBar` executable product (Task 8)
- Produces: `build/ClaudeUsageBar.app`; `make build|test|bundle|run|install|clean`

- [ ] **Step 1: Create `scripts/bundle-app.sh`**

```bash
#!/usr/bin/env bash
# Builds the release binary and wraps it in a minimal .app bundle at build/ClaudeUsageBar.app.
# The bundle is what makes "Launch at login" work and keeps the app out of the Dock (LSUIElement).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ClaudeUsageBar"
DISPLAY_NAME="Claude Usage Bar"
BUNDLE_ID="${BUNDLE_ID:-dev.llm-usage-tracker.ClaudeUsageBar}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/${APP_NAME}.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for a locally built app and for SMAppService login items.
codesign --force --sign - "$APP"

echo "Built $APP"
```

Then: `chmod +x scripts/bundle-app.sh`.

- [ ] **Step 2: Create `Makefile`** (recipes must be indented with a real tab)

```make
APP := ClaudeUsageBar
BUNDLE := build/$(APP).app
INSTALL_DIR := /Applications

.PHONY: build test bundle run install clean

build:
	swift build -c release

test:
	swift test

bundle:
	scripts/bundle-app.sh

# Rebuild the bundle and launch it from build/ (kills a running copy first).
run: bundle
	-pkill -x $(APP)
	open $(BUNDLE)

# Rebuild the bundle, copy to /Applications, and launch it.
install: bundle
	-pkill -x $(APP)
	rm -rf $(INSTALL_DIR)/$(APP).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP).app

clean:
	rm -rf .build build
```

- [ ] **Step 3: Build the bundle and check its shape**

Run: `make bundle 2>&1 | tail -5 && ls -R build/ClaudeUsageBar.app && plutil -lint build/ClaudeUsageBar.app/Contents/Info.plist && codesign -dv build/ClaudeUsageBar.app 2>&1 | head -5`
Expected: `Built build/ClaudeUsageBar.app`; the tree has `Contents/MacOS/ClaudeUsageBar`, `Contents/Info.plist`, `Contents/PkgInfo`; plist lints OK; codesign reports `Signature=adhoc`.

- [ ] **Step 4: Run the bundle and confirm the menu bar item**

Run: `make run` then `sleep 8`.
Check the item is visible (screenshot via `screencapture -x /tmp/menubar.png` and view, or the `osascript` fallback from Task 8 Step 6). Confirm no Dock icon appeared (`osascript -e 'tell application "System Events" to get name of every process whose background only is false' | tr ',' '\n' | grep -c ClaudeUsageBar` should print `0`).
Then quit: `pkill -x ClaudeUsageBar`.

- [ ] **Step 5: Add `build/` to `.gitignore` if not already there and commit**

`.gitignore` already lists `build/`. Verify with `grep -q '^build/$' .gitignore && echo ok`.

```bash
git add scripts/bundle-app.sh Makefile
git commit -m "Add app bundle script and Makefile (build, test, run, install)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: README, LICENSE, install and end-to-end verification

**Files:**
- Create: `README.md`
- Create: `LICENSE`

**Interfaces:** none (docs) — plus the final verification of the whole thing.

- [ ] **Step 1: Create `LICENSE`** (MIT, copyright holder from `git config user.name`, which is `Edward Sia`)

```
MIT License

Copyright (c) 2026 Edward Sia

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Create `README.md`**

````markdown
# Claude Usage Bar

A tiny macOS menu bar app that always shows your Claude subscription usage:

```
5h 25% · W 26% · F 17%
```

- **5h** — the rolling 5-hour session limit
- **W** — the weekly limit across all models
- **F** (or another letter) — a weekly limit scoped to one model, e.g. Fable

Numbers turn amber at 50 % and red at 80 %. Hover for reset countdowns. Click for
bars, exact reset times, a refresh button, a link to the usage page, and settings.

It shows the same numbers as the claude.ai usage page and the Claude Code status
line, without keeping a browser tab open or clicking anything.

## Requirements

- macOS 14 or newer
- [Claude Code](https://claude.com/claude-code) installed and signed in (`claude` → log in). The app reuses that login.
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install from source

```bash
git clone <this repo>
cd llm-usage-tracker
make install
```

`make install` builds a release binary, wraps it in `ClaudeUsageBar.app`, ad-hoc
signs it, copies it to `/Applications`, and launches it. Turn on **Launch at
login** from the click menu if you want it always there.

Other targets: `make test` (unit tests), `make run` (build and launch from
`build/`), `make clean`.

If you download a pre-built zip instead of building, macOS will quarantine it.
Remove the flag before launching:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

## How it works

1. Reads the OAuth access token that Claude Code stores in the macOS Keychain
   (item `Claude Code-credentials`), the same way Claude Code's own status line
   integrations do. Falls back to `~/.claude/.credentials.json`.
2. Calls `GET https://api.anthropic.com/api/oauth/usage` every 60 seconds (or
   30 s / 3 min / 5 min from the menu), on wake from sleep, and when you click
   Refresh.
3. Renders the `limits` from the response in the menu bar.

The app is read-only: it never writes to the Keychain and never refreshes the
token itself (Claude Code does that). If the token expires, the app shows a
warning and picks up the new token on the next refresh after you use Claude
Code again.

## Privacy

Nothing leaves your Mac except the request to Anthropic's usage endpoint,
authenticated with your existing Claude Code token. There is no telemetry, no
third-party server, and no storage beyond the refresh-interval preference.

## Troubleshooting

| Menu bar shows | Meaning | Fix |
|---|---|---|
| `⚠︎ not signed in` | No Claude Code credentials found | Run `claude` in a terminal and log in |
| numbers followed by `⚠︎` | Last refresh failed; numbers are stale | Hover or click for the reason (offline, token expired, rate limited, API error) |
| `…` | First fetch has not finished | Wait a second; hover shows "Loading…" |

"Launch at login" only works when the app runs from `/Applications` (i.e. after
`make install`), because macOS registers login items by bundle.

## Development

```bash
swift test          # unit tests for everything except the AppKit glue
swift build         # debug build
make run            # build the .app and launch it
```

Structure: `Sources/ClaudeUsageBarCore` (models, credential reading, API client,
formatting, poller — all unit-tested, no AppKit) and `Sources/ClaudeUsageBar`
(the menu bar UI). Design notes live in `docs/superpowers/specs/`.

## Roadmap

- Floating always-on-top overlay as an alternative to the menu bar
- Notifications when a limit crosses a threshold
- Signed/notarized releases and a Homebrew cask

## License

MIT — see `LICENSE`.
````

- [ ] **Step 3: Install and verify end to end**

Run: `make install 2>&1 | tail -3` then `sleep 8`.

Verify each of these and record the result:
1. Menu bar shows live numbers (screenshot `screencapture -x /tmp/menubar.png` and view it, or `osascript -e 'tell application "System Events" to get name of every menu bar item of menu bar 2 of process "ClaudeUsageBar"'`). Compare against a direct API call so the numbers are known to be right:
   ```bash
   security find-generic-password -s "Claude Code-credentials" -w | node -e '
   const c=JSON.parse(require("fs").readFileSync(0,"utf8")).claudeAiOauth.accessToken;
   fetch("https://api.anthropic.com/api/oauth/usage",{headers:{Authorization:"Bearer "+c,"anthropic-beta":"oauth-2025-04-20"}}).then(r=>r.json()).then(j=>console.log(j.limits.map(l=>`${l.kind}${l.scope?.model?.display_name?"("+l.scope.model.display_name+")":""}=${l.percent}%`).join(" ")))'
   ```
   The menu bar percentages must match this output.
2. `/Applications/ClaudeUsageBar.app` exists and `codesign -dv` says adhoc.
3. No Dock icon (see Task 9 Step 4 command).
4. `ps -o rss= -p $(pgrep -x ClaudeUsageBar)` shows a modest footprint (tens of MB).
5. Leave it running — it is the user's installed app.

- [ ] **Step 4: Run the full test suite one last time**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add README.md LICENSE
git commit -m "Add README and MIT license

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Manual verification checklist (after all tasks)

Done by the coordinating agent with the installed app running:

- [ ] Menu bar text matches the API (Task 10 Step 3).
- [ ] Hover tooltip shows one line per limit with reset text and "Updated … ago".
- [ ] Click menu: rows with bars; "Refresh" works (Updated resets to "just now"); "Open usage page" opens the browser; "Refresh interval" submenu shows a check on the current value and changing it persists across relaunch; "Launch at login" toggles and reflects the real state; "Quit" quits.
- [ ] Interval preference survives relaunch (`defaults read dev.llm-usage-tracker.ClaudeUsageBar refreshInterval`).
- [ ] Log shows no crash across a few minutes of polling.
