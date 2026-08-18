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
