import Foundation
import os

/// 行情状态变化(在线/离线/限流/部分缺失)落系统日志:
/// `log show --last 1h --predicate 'subsystem == "local.whirlpool" && category == "quotes"'`
let quoteLog = Logger(subsystem: "local.whirlpool", category: "quotes")

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
    private(set) var status = "Waiting for quotes" {
        didSet { if status != oldValue { quoteLog.notice("status: \(self.status, privacy: .public)") } }
    }
    /// 下一次真正向行情源发请求的时刻;报价卡按它排下一次刷新,不用固定节拍去撞缓存
    var nextRefresh: Date { nextFetch }
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
                    // 节拍从请求发出算起:从返回算会把请求耗时叠进每个周期,
                    // 报价卡的定时器又略早于它醒来 → 撞缓存再等一整轮,15 秒实际变 30 秒
                    self.nextFetch = max(self.lastAttempt.addingTimeInterval(max(5, next)),
                                         self.now().addingTimeInterval(1))
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

/// Bounded concurrency and per-host cooldowns. No retry loops on HTTP 429.
/// 限流按主机记:Yahoo 回 429 只冷却 Yahoo,东财/腾讯照常,链上自然落到还能用的源。
final class QuoteHTTPClient {
    typealias Callback = (Data?, URLResponse?, Error?) -> Void
    private let queue = DispatchQueue(label: "whirlpool.http")
    private let session: URLSession
    private var pending: [(URLRequest, Callback)] = []
    private var active = 0
    private var nextStart = Date.distantPast
    private var cooling: [String: Date] = [:]     // host → 冷却到期
    private var rateLimits: [String: Int] = [:]   // host → 连续 429 次数
    private var hosts = Set<String>()             // 用过的主机
    /// 用过的主机全在冷却中才算整个行情源限流(返回最早解冻时刻);只冷了一部分时为 nil
    var cooldownUntil: Date? {
        queue.sync {
            let now = Date()
            let cold = hosts.compactMap { host in cooling[host].flatMap { $0 > now ? $0 : nil } }
            return !hosts.isEmpty && cold.count == hosts.count ? cold.min() : nil
        }
    }

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }
    func fetch(_ request: URLRequest, completion: @escaping Callback) {
        queue.async { self.pending.append((request, completion)); self.drain() }
    }
    private func isCooling(_ request: URLRequest, at now: Date) -> Bool {
        guard let host = request.url?.host, let until = cooling[host] else { return false }
        return until > now
    }
    private func drain() {
        let now = Date()
        // 冷却中的主机:请求当场失败(不上网),其余照常排队
        let blocked = pending.filter { isCooling($0.0, at: now) }
        if !blocked.isEmpty {
            pending.removeAll { isCooling($0.0, at: now) }
            blocked.forEach { $0.1(nil, nil, URLError(.resourceUnavailable)) }
        }
        guard active < 2, !pending.isEmpty else { return }
        let delay = nextStart.timeIntervalSinceNow
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { self.drain() }; return }
        let (request, completion) = pending.removeFirst()
        let host = request.url?.host ?? ""
        hosts.insert(host)
        active += 1; nextStart = Date().addingTimeInterval(0.35)
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                self.active -= 1
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self.rateLimits[host] = 0
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    let count = (self.rateLimits[host] ?? 0) + 1
                    self.rateLimits[host] = count
                    let wait = max(QuoteService.retryDelay(count), Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 0)
                    self.cooling[host] = max(self.cooling[host] ?? .distantPast, Date().addingTimeInterval(wait))
                    quoteLog.notice("HTTP 429 from \(host, privacy: .public), cooling \(Int(wait))s")
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
