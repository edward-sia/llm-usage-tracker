import Foundation

/// Calls the ChatGPT usage endpoint with the access token Codex stored.
///
/// This endpoint is shared: the ChatGPT desktop app and `codex` itself read it for their own
/// status displays, and it is rate limited per account the same way Anthropic's is. Everything
/// that keeps this app off it lives in `UsagePoller` (429 backoff honoring `Retry-After`,
/// skipping opportunistic fetches while backing off or while numbers are fresh, jitter after
/// wake) plus the polling floor `main.swift` gives this provider.
public struct ChatGPTAPIClient {
    /// Codex ships this path and the newer alias `/backend-api/api/codex/usage` side by side.
    /// This one is what was verified to answer; if it ever starts returning 404, the menu says
    /// "ChatGPT usage API error (HTTP 404)" and the alias is the first thing to try.
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let timeout: TimeInterval = 10

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and decodes usage. Throws `UsageError` only.
    public func fetchUsage(credentials: ChatGPTCredentials, now: Date = Date()) async throws -> ChatGPTUsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        // Codex identifies itself this way; the endpoint is part of its API surface.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

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
        case 429: throw UsageError.rateLimited(retryAfter: RetryAfter.seconds(from: http))
        default: throw UsageError.http(http.statusCode)
        }
        return try Self.decode(data, fetchedAt: now)
    }

    struct Response: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_after_seconds: Double?
            /// Unix epoch seconds.
            let reset_at: Double?
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        let rate_limit: RateLimit?
        let plan_type: String?
    }

    /// Turns the usage JSON into a snapshot.
    ///
    /// Only the two named windows are read. `additional_rate_limits` and `code_review_rate_limit`
    /// are left alone: both were null on every response seen so far, so their shape is unverified
    /// and guessing at it would risk showing wrong numbers. Unknown fields are ignored, and every
    /// field is optional, so additions to the response cannot break this.
    public static func decode(_ data: Data, fetchedAt: Date) throws -> ChatGPTUsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageError.decoding
        }

        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window]
            .compactMap { $0 }
            .compactMap { window -> ChatGPTUsageWindow? in
                guard let percent = window.used_percent else { return nil }
                return ChatGPTUsageWindow(
                    usedPercent: Int(percent.rounded()),
                    windowSeconds: window.limit_window_seconds.flatMap { $0 > 0 ? $0 : nil },
                    resetsAt: resetDate(window, fetchedAt: fetchedAt)
                )
            }

        guard !windows.isEmpty else { throw UsageError.decoding }
        return ChatGPTUsageSnapshot(windows: windows, planType: planType(response.plan_type), fetchedAt: fetchedAt)
    }

    /// `reset_at` is an absolute epoch and survives a stale snapshot, so it wins.
    /// `reset_after_seconds` is relative to when the response was produced, so it is only used
    /// as a fallback and is anchored to the fetch time.
    private static func resetDate(_ window: Response.Window, fetchedAt: Date) -> Date? {
        if let epoch = window.reset_at, epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let after = window.reset_after_seconds, after > 0 {
            return fetchedAt.addingTimeInterval(after)
        }
        return nil
    }

    private static func planType(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
