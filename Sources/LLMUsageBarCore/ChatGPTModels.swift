import Foundation

/// What the ChatGPT usage endpoint needs to authenticate: the Codex access token plus, for
/// accounts that belong to more than one workspace, which account the numbers are for.
public struct ChatGPTCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String?

    public init(accessToken: String, accountId: String?) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

/// One ChatGPT rate-limit window.
///
/// Unlike Claude's limits, which the API names (`session`, `weekly_all`), ChatGPT's are described
/// only by how long they last. `windowSeconds` is therefore what the labels are derived from, so a
/// plan whose windows change — or a plan this app has never seen — still renders correctly.
public struct ChatGPTUsageWindow: Equatable, Sendable {
    /// 0–100 (may exceed 100 in theory; formatting clamps for the bar only).
    public let usedPercent: Int
    /// How long the window lasts, from `limit_window_seconds`. Nil when the API omits it.
    public let windowSeconds: TimeInterval?
    public let resetsAt: Date?

    public init(usedPercent: Int, windowSeconds: TimeInterval?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
    }
}

/// A successful read of the ChatGPT usage endpoint, windows already in display order
/// (primary first, then secondary).
public struct ChatGPTUsageSnapshot: TimestampedSnapshot {
    public let windows: [ChatGPTUsageWindow]
    /// `plan_type` from the response, e.g. "free", "plus", "pro". Nil when absent.
    public let planType: String?
    public let fetchedAt: Date

    public init(windows: [ChatGPTUsageWindow], planType: String?, fetchedAt: Date) {
        self.windows = windows
        self.planType = planType
        self.fetchedAt = fetchedAt
    }
}
