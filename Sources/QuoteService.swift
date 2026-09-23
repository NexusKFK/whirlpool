import Foundation

/// One cache and in-flight request shared by every display. Called on the main thread.
final class QuoteService {
    private let provider: QuoteProvider
    private let now: () -> Date
    private var key = ""
    private var generation = 0
    private var cached: [String: Quote] = [:]
    private var waiters: [([String: Quote]) -> Void] = []
    private var inFlight = false
    private var invalidatedDuringFlight = false
    private var nextFetch = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var failures = 0
    private var retries: [String: (count: Int, until: Date)] = [:]
    private(set) var lastUpdated: Date?
    private(set) var status = "Waiting for quotes"
    var interval: TimeInterval {
        didSet { if interval != oldValue { requestRefresh() } }
    }
    var onUpdate: (() -> Void)?
    /// 智能刷新:按交易时段放宽成功后的下次拉取间隔(nil = 恒用 interval)
    var cadence: (([WatchEntry], TimeInterval, Date, [String: Date]) -> TimeInterval)? {
        didSet { requestRefresh() }
    }

    init(provider: QuoteProvider, interval: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.provider = provider; self.interval = interval; self.now = now
    }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let newKey = entries.map { "\($0.market):\($0.symbol)" }.sorted().joined(separator: "|")
        if newKey != key {
            generation += 1; key = newKey; cached = [:]; lastUpdated = nil; nextFetch = .distantPast
            failures = 0; retries = [:]; status = "Waiting for quotes"; invalidatedDuringFlight = false
            let oldWaiters = waiters; waiters = []; inFlight = false
            oldWaiters.forEach { $0([:]) }
        }
        guard !entries.isEmpty else { completion([:]); return }
        if inFlight { waiters.append(completion); return }
        if now() < nextFetch { completion(cached); return }
        if let until = provider.cooldownUntil, until > now() {
            status = "Rate limited · retrying later"; nextFetch = until; completion(cached); onUpdate?(); return
        }
        let requested = entries.filter { retries[$0.symbol].map { $0.until <= now() } ?? true }
        guard !requested.isEmpty else {
            nextFetch = retries.values.map { $0.until }.min() ?? now().addingTimeInterval(max(5, interval))
            completion(cached); return
        }
        let symbols = Set(requested.map { $0.symbol })
        inFlight = true; lastAttempt = now(); waiters.append(completion)
        let requestGeneration = generation
        status = cached.isEmpty ? "Loading quotes…" : status
        provider.quotes(for: requested) { [weak self] fresh in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.inFlight = false
                let valid = fresh.filter { symbols.contains($0.key) && $0.value.price.isFinite && $0.value.price > 0 && $0.value.changePct.isFinite }
                for symbol in symbols {
                    if valid[symbol] != nil { self.retries.removeValue(forKey: symbol) }
                    else {
                        let count = min(6, (self.retries[symbol]?.count ?? 0) + 1)
                        self.retries[symbol] = (count, self.now().addingTimeInterval(Self.retryDelay(count)))
                    }
                }
                self.cached.merge(valid) { _, new in new }
                if !valid.isEmpty { self.lastUpdated = self.now() }
                if let until = self.provider.cooldownUntil, until > self.now() {
                    self.status = "Rate limited · retrying later"; self.nextFetch = until
                } else if valid.isEmpty {
                    self.failures = min(6, self.failures + 1)
                    self.status = "Offline · showing last prices"
                    self.nextFetch = self.now().addingTimeInterval(max(self.interval, Self.retryDelay(self.failures)))
                } else {
                    self.failures = 0
                    let next = self.provider.name == "demo" ? self.interval :
                        (self.cadence?(entries, self.interval, self.now(),
                                      self.cached.compactMapValues { $0.marketTime }) ?? self.interval)
                    self.status = self.provider.name == "demo" ? "Demo · simulated prices"
                        : (next > self.interval ? "Markets closed · refreshing slowly" : "Updated")
                    self.nextFetch = self.now().addingTimeInterval(max(5, next))
                    if self.invalidatedDuringFlight {
                        self.nextFetch = max(self.now(), self.lastAttempt.addingTimeInterval(5))
                    }
                    if let retry = self.retries.values.map({ $0.until }).min() {
                        self.status = "Some quotes unavailable · showing last prices"
                        self.nextFetch = max(self.now().addingTimeInterval(5), min(self.nextFetch, retry))
                    }
                }
                self.invalidatedDuringFlight = false
                let callbacks = self.waiters; self.waiters = []
                callbacks.forEach { $0(self.cached) }
                self.onUpdate?()
            }
        }
    }

    /// 数据需求变了(比如报价卡打开要分时线):下次调用直接重拉,仍受退避约束
    func invalidate() {
        if failures == 0 && provider.cooldownUntil.map({ $0 > now() }) != true {
            nextFetch = max(now(), lastAttempt.addingTimeInterval(5))
            if inFlight { invalidatedDuringFlight = true }
        }
    }

    // A manual refresh can skip the normal cache, but never provider backoff.
    func requestRefresh() {
        if failures == 0 && provider.cooldownUntil.map({ $0 > now() }) != true {
            nextFetch = min(nextFetch, max(now(), lastAttempt.addingTimeInterval(5)))
        }
    }
    static func retryDelay(_ failures: Int) -> TimeInterval { min(900, 30 * pow(2, Double(min(5, max(0, failures - 1))))) }
}

/// Bounded concurrency and a provider-wide cooldown. No retry loops on HTTP 429.
final class QuoteHTTPClient {
    typealias Callback = (Data?, URLResponse?, Error?) -> Void
    private let queue = DispatchQueue(label: "whirlpool.http")
    private let session: URLSession
    private var pending: [(URLRequest, Callback)] = []
    private var active = 0
    private var nextStart = Date.distantPast
    private var until = Date.distantPast
    private var rateLimitCount = 0
    var cooldownUntil: Date? { queue.sync { until > Date() ? until : nil } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }
    func fetch(_ request: URLRequest, completion: @escaping Callback) {
        queue.async { self.pending.append((request, completion)); self.drain() }
    }
    private func drain() {
        if until > Date() {
            let blocked = pending; pending = []
            blocked.forEach { $0.1(nil, nil, URLError(.resourceUnavailable)) }
            return
        }
        guard active < 2, !pending.isEmpty else { return }
        let delay = nextStart.timeIntervalSinceNow
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { self.drain() }; return }
        let (request, completion) = pending.removeFirst()
        active += 1; nextStart = Date().addingTimeInterval(0.35)
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                self.active -= 1
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self.rateLimitCount = 0
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    self.rateLimitCount += 1
                    let wait = max(QuoteService.retryDelay(self.rateLimitCount), Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 0)
                    self.until = max(self.until, Date().addingTimeInterval(wait))
                }
                completion(data, response, error)
                self.drain()
            }
        }.resume()
        queue.asyncAfter(deadline: .now() + 0.35) { self.drain() }
    }
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}
