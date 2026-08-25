import Foundation

/// Reads the ChatGPT access token that Codex stores after a "Sign in with ChatGPT" login.
/// Read-only: never refreshes, never writes. Codex and the ChatGPT desktop app keep the token
/// fresh; this app only ever reads whatever is on disk at fetch time.
public struct ChatGPTAuthStore {
    /// `$CODEX_HOME/auth.json`, falling back to `~/.codex/auth.json`.
    public static var defaultAuthFile: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    private let authFileURL: URL

    public init(authFileURL: URL = ChatGPTAuthStore.defaultAuthFile) {
        self.authFileURL = authFileURL
    }

    /// Returns the current credentials or throws `UsageError.notSignedIn`.
    public func credentials() throws -> ChatGPTCredentials {
        guard let data = try? Data(contentsOf: authFileURL),
              let raw = String(data: data, encoding: .utf8),
              let credentials = Self.parseCredentials(from: raw) else {
            throw UsageError.notSignedIn
        }
        return credentials
    }

    /// Extracts `tokens.access_token` and `tokens.account_id` from Codex's auth JSON.
    ///
    /// Presence of an access token is the whole test. `auth_mode` is deliberately not checked:
    /// a Codex signed in with an API key instead of a ChatGPT account has no `access_token`, so
    /// it falls out on its own, and keying off the mode string would hide the segment for anyone
    /// whose Codex reports a mode name this app has never heard of.
    public static func parseCredentials(from raw: String) -> ChatGPTCredentials? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else { return nil }
        let accountId = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ChatGPTCredentials(accessToken: token, accountId: accountId)
    }
}
