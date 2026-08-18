import Foundation

/// How urgent a number is. The app maps this to a color; Core stays AppKit-free.
public enum Severity: Equatable, Sendable {
    case normal, warning, critical
}

/// One piece of the menu bar title, e.g. "5h 25%".
public struct TitleSegment: Equatable, Sendable {
    public let text: String
    public let severity: Severity
    public init(text: String, severity: Severity) {
        self.text = text
        self.severity = severity
    }
}

/// Pure functions from state to display strings. Nothing here touches AppKit or the clock
/// (callers pass `now`), so all of it is unit-tested.
public enum Formatting {
    public static let warningThreshold = 50
    public static let criticalThreshold = 80
    public static let separator = " · "
    public static let warningGlyph = "⚠︎"

    public static func severity(forPercent percent: Int) -> Severity {
        if percent >= criticalThreshold { return .critical }
        if percent >= warningThreshold { return .warning }
        return .normal
    }

    // MARK: Labels

    /// Short labels for the menu bar, in bucket order. Scoped models that share a first
    /// letter get two letters instead.
    public static func shortLabels(for buckets: [UsageBucket]) -> [String] {
        var labels = buckets.map { baseShortLabel(for: $0.kind) }
        let scopedIndices = buckets.indices.filter {
            if case .weeklyScoped = buckets[$0].kind { return true }
            return false
        }
        var counts: [String: Int] = [:]
        for index in scopedIndices { counts[labels[index], default: 0] += 1 }
        for index in scopedIndices where counts[labels[index], default: 0] > 1 {
            if case .weeklyScoped(let model?) = buckets[index].kind {
                let trimmed = model.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 2 {
                    labels[index] = trimmed.prefix(1).uppercased() + trimmed.dropFirst().prefix(1).lowercased()
                }
            }
        }
        return labels
    }

    private static func baseShortLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session:
            return "5h"
        case .weeklyAll:
            return "W"
        case .weeklyScoped(let model):
            guard let first = model?.trimmingCharacters(in: .whitespaces).first else { return "M" }
            return String(first).uppercased()
        case .other(let kind):
            guard let first = kind.trimmingCharacters(in: .whitespaces).first else { return "?" }
            return String(first).uppercased()
        }
    }

    /// Full label for menus and tooltips.
    public static func longLabel(for kind: UsageBucket.Kind) -> String {
        switch kind {
        case .session: return "Session (5h)"
        case .weeklyAll: return "Weekly · all"
        case .weeklyScoped(let model):
            let name = model?.trimmingCharacters(in: .whitespaces) ?? ""
            return "Weekly · \(name.isEmpty ? "model" : name)"
        case .other(let kind):
            let words = kind.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            guard let first = words.first else { return "Unknown limit" }
            return String(first).uppercased() + words.dropFirst()
        }
    }

    // MARK: Title

    public static func titleSegments(for state: FetchState) -> [TitleSegment] {
        switch state {
        case .idle:
            return [TitleSegment(text: "…", severity: .normal)]
        case .loaded(let snapshot):
            return segments(for: snapshot)
        case .failed(let error, let last):
            if let last {
                return segments(for: last) + [TitleSegment(text: warningGlyph, severity: .warning)]
            }
            switch error {
            case .notSignedIn: return [TitleSegment(text: "\(warningGlyph) not signed in", severity: .warning)]
            default: return [TitleSegment(text: warningGlyph, severity: .warning)]
            }
        }
    }

    private static func segments(for snapshot: UsageSnapshot) -> [TitleSegment] {
        let labels = shortLabels(for: snapshot.buckets)
        return zip(labels, snapshot.buckets).map { label, bucket in
            TitleSegment(text: "\(label) \(bucket.percent)%", severity: severity(forPercent: bucket.percent))
        }
    }

    public static func joinedTitle(_ segments: [TitleSegment]) -> String {
        segments.map(\.text).joined(separator: separator)
    }
}
