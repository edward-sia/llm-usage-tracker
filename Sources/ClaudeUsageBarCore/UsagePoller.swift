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
/// - One retry with a freshly read credential after a 401 (the CLI that owns it may have rotated it).
/// - After a 429 the next tick waits `RateLimitPolicy.backoff` instead of `interval`.
/// - The last good snapshot travels with every failure so the UI keeps showing numbers.
/// - Wake-from-sleep is handled by the app calling `wake()`; Core has no AppKit.
/// - A provider can raise its own polling floor with `minimumInterval` and widen the window in
///   which opportunistic fetches are skipped with `opportunisticStaleAfter`. Both exist to keep
///   this app off shared, rate-limited usage endpoints.
/// - Every fetch outcome goes to the unified log (subsystem dev.llm-usage-tracker.ClaudeUsageBar).
///
/// Generic over the credential type as well as the snapshot type: Claude and OpenRouter each
/// authenticate with a bare token string, while ChatGPT needs a token plus an account id.
@MainActor
public final class UsagePoller<Snapshot: TimestampedSnapshot, Credential: Sendable> {
    public typealias CredentialProvider = () throws -> Credential
    public typealias Fetcher = (_ credential: Credential) async throws -> Snapshot

    public static var logSubsystem: String { "dev.llm-usage-tracker.ClaudeUsageBar" }
    public static var rateLimitBackoff: TimeInterval { RateLimitPolicy.minBackoff }

    public private(set) var state: FetchState<Snapshot> = .idle {
        didSet { onChange?(state) }
    }
    public var onChange: ((FetchState<Snapshot>) -> Void)?

    public var interval: TimeInterval {
        didSet { if running { scheduleNext() } }
    }

    /// A floor this poller never polls faster than, whatever the user picked in the menu. Providers
    /// whose numbers move slowly set it above the shared interval so a faster global setting cannot
    /// drag them into rate-limit territory.
    public let minimumInterval: TimeInterval

    /// Default age at which `refreshIfStale` considers the numbers worth refetching. Raised to
    /// `minimumInterval` when that is higher: fetching sooner than the floor would beat it, since
    /// every fetch reschedules the timer from the moment it completes.
    public let opportunisticStaleAfter: TimeInterval

    /// What the next timer wait will be: the backoff after a 429, otherwise the chosen interval —
    /// and never below this provider's own floor, whichever of the two is in play.
    public var nextInterval: TimeInterval {
        max(backoff ?? interval, minimumInterval)
    }

    private let credentialProvider: CredentialProvider
    private let fetcher: Fetcher
    private let logger: Logger
    private var timer: Timer?
    private var running = false
    /// Seconds the next tick must wait because of a 429; nil when not rate limited.
    private var backoff: TimeInterval?
    private var consecutiveRateLimits = 0
    private var inFlight = false

    public init(
        interval: TimeInterval,
        name: String = "poller",
        minimumInterval: TimeInterval = 0,
        opportunisticStaleAfter: TimeInterval = 20,
        credentialProvider: @escaping CredentialProvider,
        fetcher: @escaping Fetcher
    ) {
        self.interval = interval
        self.minimumInterval = minimumInterval
        self.opportunisticStaleAfter = opportunisticStaleAfter
        self.logger = Logger(subsystem: Self.logSubsystem, category: name)
        self.credentialProvider = credentialProvider
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
    /// are younger than `staleAfter` (which defaults to this poller's `opportunisticStaleAfter`,
    /// and never drops below `minimumInterval`). Reopening the menu rapidly therefore reuses the
    /// numbers it just fetched instead of firing a request each time. The timer and the manual
    /// Refresh button still call `refresh()` directly, so periodic polling and explicit refreshes
    /// are never suppressed.
    public func refreshIfStale(trigger: FetchTrigger = .menuOpen, olderThan staleAfter: TimeInterval? = nil, now: Date = Date()) async {
        if backoff != nil {
            logger.log("skip(\(trigger.rawValue, privacy: .public)): backing off after 429")
            return
        }
        // Clamped to the floor: a fetch here restarts the timer from now, so allowing one sooner
        // than `minimumInterval` would raise this provider's real request rate above its floor.
        let threshold = max(staleAfter ?? opportunisticStaleAfter, minimumInterval)
        if let fetchedAt = state.snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < threshold {
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
        let credentialProvider = self.credentialProvider
        // Off the main actor: the real providers read files and shell out to `security`, neither
        // of which must block the UI.
        let credential = try await Task.detached(priority: .utility) { try credentialProvider() }.value
        do {
            return try await fetcher(credential)
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
