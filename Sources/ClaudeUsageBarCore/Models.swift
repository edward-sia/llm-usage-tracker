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

/// What every provider's snapshot has in common: when it was fetched. The poller uses this
/// to decide whether numbers are fresh enough to skip an opportunistic refresh.
public protocol TimestampedSnapshot: Equatable, Sendable {
    var fetchedAt: Date { get }
}

/// A successful read of the usage API, with buckets already in display order.
public struct UsageSnapshot: TimestampedSnapshot {
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

/// The only thing the UI reads. Generic so Claude usage and OpenRouter credits share it.
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
