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
        runCommand: @escaping CommandRunner = { CredentialStore.runProcess($0, $1) },
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

    /// Runs a process and returns trimmed stdout, or nil on non-zero exit / launch failure / timeout.
    ///
    /// Reading stdout and waiting for exit happen on a background queue so a wedged process
    /// (e.g. `security` blocked on a locked keychain or an unanswered ACL prompt) cannot hang
    /// the caller forever. If `timeout` elapses first, the process is terminated so it does not
    /// linger, and this returns nil.
    public static func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
