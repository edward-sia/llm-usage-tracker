import Foundation

/// Calls OpenRouter's credits endpoint with an API key.
public struct OpenRouterAPIClient {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/credits")!
    public static let timeout: TimeInterval = 10

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and decodes the credit balance. Throws `UsageError` only.
    public func fetchCredits(key: String, now: Date = Date()) async throws -> CreditsSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
        struct Body: Decodable {
            let total_credits: Double?
            let total_usage: Double?
        }
        let data: Body?
    }

    /// Turns the credits JSON (`{"data":{"total_credits":…,"total_usage":…}}`) into a snapshot.
    public static func decode(_ data: Data, fetchedAt: Date) throws -> CreditsSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let credits = response.data?.total_credits,
              let usage = response.data?.total_usage else {
            throw UsageError.decoding
        }
        return CreditsSnapshot(totalCredits: credits, totalUsage: usage, fetchedAt: fetchedAt)
    }
}
