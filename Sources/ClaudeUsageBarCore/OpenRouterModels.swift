import Foundation

/// A successful read of the OpenRouter credits API.
public struct CreditsSnapshot: TimestampedSnapshot {
    /// Total credits ever purchased, in USD.
    public let totalCredits: Double
    /// Total credits ever spent, in USD.
    public let totalUsage: Double
    public let fetchedAt: Date

    /// What is left to spend. Can go slightly negative if usage overshoots.
    public var remaining: Double { totalCredits - totalUsage }

    public init(totalCredits: Double, totalUsage: Double, fetchedAt: Date) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.fetchedAt = fetchedAt
    }
}
