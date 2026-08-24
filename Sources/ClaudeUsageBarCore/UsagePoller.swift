import Foundation
import os

/// What caused a fetch. Only used for the log lines, so a morning of 429s can be
/// reconstructed afterwards with `log show`.
public enum FetchTrigger: String, Sendable {
    case start, timer, manual, wake
    case menuOpen = "menu-open"
}

/// How long to wait after a 429. The server's `Retry-After` wins when it sent one,
/// clamped: never sooner than the default backoff, never longer than an hour.
public enum RateLimitPolicy {
    public static let minBackoff: TimeInterval = 300
    public static let maxBackoff: TimeInterval = 3600

    public static func backoff(retryAfter: TimeInterval?) -> TimeInterval {
        min(max(retryAfter ?? minBackoff, minBackoff), maxBackoff)
    }
}

/// Drives periodic fetches and owns the current `FetchState`.
///
/// - One retry with a freshly read token after a 401 (Claude Code may have rotated it).
/// - After a 429 the next tick waits `RateLimitPolicy.backoff` instead of `interval`.
/// - The last good snapshot travels with every failure so the UI keeps showing numbers.
/// - Wake-from-sleep is handled by the app calling `wake()`; Core has no AppKit.
/// - Every fetch outcome goes to the unified log (subsystem dev.llm-usage-tracker.ClaudeUsageBar).
@MainActor
public final class UsagePoller<Snapshot: TimestampedSnapshot> {
    public typealias TokenProvider = () throws -> String
    public typealias Fetcher = (_ token: String) async throws -> Snapshot

    public static var logSubsystem: String { "dev.llm-usage-tracker.ClaudeUsageBar" }
    public static var rateLimitBackoff: TimeInterval { RateLimitPolicy.minBackoff }

    public private(set) var state: FetchState<Snapshot> = .idle {
        didSet { onChange?(state) }
    }
    public var onChange: ((FetchState<Snapshot>) -> Void)?

    public var interval: TimeInterval {
        didSet { if running { scheduleNext() } }
    }

    /// What the next timer wait will be: the normal interval, or the backoff after a 429.
    public var nextInterval: TimeInterval {
        backoff ?? interval
    }

    private let tokenProvider: TokenProvider
    private let fetcher: Fetcher
    private let logger: Logger
    private var timer: Timer?
    private var running = false
    /// Seconds the next tick must wait because of a 429; nil when not rate limited.
    private var backoff: TimeInterval?
    private var consecutiveRateLimits = 0
    private var inFlight = false

    public init(interval: TimeInterval, name: String = "poller", tokenProvider: @escaping TokenProvider, fetcher: @escaping Fetcher) {
        self.interval = interval
        self.logger = Logger(subsystem: Self.logSubsystem, category: name)
        self.tokenProvider = tokenProvider
        self.fetcher = fetcher
    }

    /// Fetch immediately, then keep fetching on the timer.
    public func start() {
        running = true
        Task { await refresh(trigger: .start) }
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// An opportunistic refresh — triggered by the user glancing at the menu or by wake from
    /// sleep, not by the timer. It protects the shared, rate-limited usage endpoint:
    /// it does nothing while a 429 backoff is in effect, and nothing if the last good numbers
    /// are younger than `staleAfter`. Reopening the menu rapidly therefore reuses the numbers
    /// it just fetched instead of firing a request each time. The timer and the manual Refresh
    /// button still call `refresh()` directly, so periodic polling and explicit refreshes are
    /// never suppressed.
    public func refreshIfStale(trigger: FetchTrigger = .menuOpen, olderThan staleAfter: TimeInterval = 20, now: Date = Date()) async {
        if backoff != nil {
            logger.log("skip(\(trigger.rawValue, privacy: .public)): backing off after 429")
            return
        }
        if let fetchedAt = state.snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < staleAfter {
            logger.debug("skip(\(trigger.rawValue, privacy: .public)): numbers are fresh")
            return
        }
        await refresh(trigger: trigger)
    }

    /// Called on wake from sleep. The timer that was due during sleep would otherwise fire
    /// right away — at the same moment every other client on this machine refreshes against
    /// the same account limit — so push it a full interval out, and instead make one
    /// opportunistic fetch after a random delay, once the wake burst has passed.
    public func wake(jitter: TimeInterval = .random(in: 30...90)) {
        if running { scheduleNext() }
        logger.log("wake: opportunistic fetch in \(Int(jitter), privacy: .public)s")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
            await self?.refreshIfStale(trigger: .wake)
        }
    }

    /// One fetch cycle. Calls made while a fetch is in flight are ignored.
    public func refresh(trigger: FetchTrigger = .manual) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let previous = state.snapshot
        let started = Date()
        do {
            let snapshot = try await fetchOnce(retryOnUnauthorized: true)
            backoff = nil
            consecutiveRateLimits = 0
            state = .loaded(snapshot)
            log(trigger, "ok", since: started)
        } catch let error as UsageError {
            if case .rateLimited(let retryAfter) = error {
                consecutiveRateLimits += 1
                let wait = RateLimitPolicy.backoff(retryAfter: retryAfter)
                backoff = wait
                let header = retryAfter.map { "\(Int($0))s" } ?? "no header"
                log(trigger, "HTTP 429 (retry-after \(header), \(consecutiveRateLimits) in a row) — next attempt in \(Int(wait))s", since: started)
            } else {
                backoff = nil
                consecutiveRateLimits = 0
                log(trigger, String(describing: error), since: started)
            }
            state = .failed(error, last: previous)
        } catch {
            backoff = nil
            consecutiveRateLimits = 0
            state = .failed(.offline, last: previous)
            log(trigger, "offline (\(String(describing: error)))", since: started)
        }
        if running { scheduleNext() }
    }

    private func log(_ trigger: FetchTrigger, _ outcome: String, since started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        logger.log("fetch(\(trigger.rawValue, privacy: .public)): \(outcome, privacy: .public) (\(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
    }

    private func fetchOnce(retryOnUnauthorized: Bool) async throws -> Snapshot {
        let tokenProvider = self.tokenProvider
        // Off the main actor: the real provider shells out to `security`, which must not block the UI.
        let token = try await Task.detached(priority: .utility) { try tokenProvider() }.value
        do {
            return try await fetcher(token)
        } catch UsageError.unauthorized where retryOnUnauthorized {
            return try await fetchOnce(retryOnUnauthorized: false)
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let timer = Timer(timeInterval: nextInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(trigger: .timer) }
        }
        timer.tolerance = min(5, nextInterval / 10)
        // .common so the timer still fires while a menu is open (menu tracking uses its own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
