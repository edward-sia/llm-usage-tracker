import Foundation

/// Types every provider shares. Anything specific to one provider lives in that provider's
/// own file: `ClaudeModels.swift`, `ChatGPTModels.swift`, `OpenRouterModels.swift`.

/// What every provider's snapshot has in common: when it was fetched. The poller uses this
/// to decide whether numbers are fresh enough to skip an opportunistic refresh.
public protocol TimestampedSnapshot: Equatable, Sendable {
    var fetchedAt: Date { get }
}

public enum UsageError: Error, Equatable, Sendable {
    /// No credential was found for this provider, or the one found held no usable token.
    /// What that means depends on the provider: no Keychain item and no credentials file for
    /// Claude, no Codex auth file for ChatGPT, no `OPENROUTER_API_KEY` for OpenRouter.
    case notSignedIn
    /// HTTP 401.
    case unauthorized
    /// HTTP 429. Carries the server's `Retry-After` wait in seconds when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case http(Int)
    /// 200 but the body could not be turned into a usable snapshot.
    case decoding
    /// Transport failure or timeout.
    case offline
}

/// Reads the `Retry-After` header off a 429 response. The usage endpoints send delta-seconds;
/// HTTP-date values and garbage come back as nil, and the poller falls back to its default backoff.
public enum RetryAfter {
    public static func seconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let value = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              value > 0, value.isFinite else { return nil }
        return value
    }
}

/// The only thing the UI reads. Generic over the snapshot type so every provider shares it.
public enum FetchState<Snapshot: TimestampedSnapshot>: Equatable, Sendable {
    case idle
    case loaded(Snapshot)
    /// The last good snapshot (if any) travels with the error so the UI can keep showing numbers.
    case failed(UsageError, last: Snapshot?)

    public var snapshot: Snapshot? {
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
