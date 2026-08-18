import Foundation

/// Drives periodic fetches and owns the current `FetchState`.
///
/// - One retry with a freshly read token after a 401 (Claude Code may have rotated it).
/// - After a 429 the next tick waits `rateLimitBackoff` instead of `interval`, once.
/// - The last good snapshot travels with every failure so the UI keeps showing numbers.
/// - Wake-from-sleep is handled by the app calling `refresh()`; Core has no AppKit.
@MainActor
public final class UsagePoller {
    public typealias TokenProvider = () throws -> String
    public typealias Fetcher = (_ token: String) async throws -> UsageSnapshot

    public static let rateLimitBackoff: TimeInterval = 300

    public private(set) var state: FetchState = .idle {
        didSet { onChange?(state) }
    }
    public var onChange: ((FetchState) -> Void)?

    public var interval: TimeInterval {
        didSet { if running { scheduleNext() } }
    }

    /// What the next timer wait will be: the normal interval, or the backoff after a 429.
    public var nextInterval: TimeInterval {
        backingOff ? Self.rateLimitBackoff : interval
    }

    private let tokenProvider: TokenProvider
    private let fetcher: Fetcher
    private var timer: Timer?
    private var running = false
    private var backingOff = false
    private var inFlight = false

    public init(interval: TimeInterval, tokenProvider: @escaping TokenProvider, fetcher: @escaping Fetcher) {
        self.interval = interval
        self.tokenProvider = tokenProvider
        self.fetcher = fetcher
    }

    /// Fetch immediately, then keep fetching on the timer.
    public func start() {
        running = true
        Task { await refresh() }
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
    public func refreshIfStale(olderThan staleAfter: TimeInterval = 20, now: Date = Date()) async {
        if backingOff { return }
        if let fetchedAt = state.snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < staleAfter { return }
        await refresh()
    }

    /// One fetch cycle. Calls made while a fetch is in flight are ignored.
    public func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let previous = state.snapshot
        do {
            let snapshot = try await fetchOnce(retryOnUnauthorized: true)
            backingOff = false
            state = .loaded(snapshot)
        } catch let error as UsageError {
            backingOff = (error == .rateLimited)
            state = .failed(error, last: previous)
        } catch {
            backingOff = false
            state = .failed(.offline, last: previous)
        }
        if running { scheduleNext() }
    }

    private func fetchOnce(retryOnUnauthorized: Bool) async throws -> UsageSnapshot {
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
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        timer.tolerance = min(5, nextInterval / 10)
        // .common so the timer still fires while a menu is open (menu tracking uses its own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
