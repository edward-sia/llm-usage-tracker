import Foundation

/// One usage limit as reported by Anthropic's usage API.
public struct ClaudeUsageBucket: Equatable, Sendable {
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

/// A successful read of Anthropic's usage API, with buckets already in display order.
public struct ClaudeUsageSnapshot: TimestampedSnapshot {
    public let buckets: [ClaudeUsageBucket]
    public let fetchedAt: Date

    public init(buckets: [ClaudeUsageBucket], fetchedAt: Date) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }
}
