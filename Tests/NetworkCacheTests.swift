import Foundation

// 行情网络层回归(全部走本地桩,不上网):分时缓存接尾、过期与跨日重拉、东财 secid 复用、
// Yahoo 缓存期只要报价小包、按主机限流冷却、刷新节拍从请求发出算起。

private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if !condition { fatalError("FAIL line \(line): \(message())") }
}

/// URLProtocol 桩:按请求返回 (状态码, 数据),并记下每个请求
private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _handler: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    private static var _log: [URL] = []
    static var handler: (URLRequest) -> (Int, Data) {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var log: [URL] { lock.lock(); defer { lock.unlock() }; return _log }
    static func reset() { lock.lock(); _log = []; lock.unlock() }
    static func count(_ path: String) -> Int { log.filter { $0.path.contains(path) }.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self._log.append(url); let handler = Self._handler; Self.lock.unlock()
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> QuoteHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return QuoteHTTPClient(configuration: configuration)
}

private func fetch(_ provider: RealProvider, _ entries: [WatchEntry]) -> [String: Quote] {
    let done = DispatchSemaphore(value: 0)
    var result: [String: Quote] = [:]
    provider.quotes(for: entries) { result = $0; done.signal() }
    check(done.wait(timeout: .now() + 10) == .success, "provider answered")
    return result
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

func runNetworkCacheTests() throws {
    let et = TimeZone(identifier: "America/New_York")!
    func etDate(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = et; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    // 1) 接尾规则:同一分钟改尾点、新的一分钟追加、收盘后不接、次日作废
    let open = etDate("2026-09-25 09:30:00").timeIntervalSince1970
    let entry = SeriesCache.Entry(series: [SeriesPt(t: open, v: 100), SeriesPt(t: open + 60, v: 101)],
                                  start: open, end: open + 6.5 * 3600, clock: .epoch, zone: et,
                                  day: "2026-09-25", fetchedAt: Date())
    let sameMinute = SeriesCache.splice(entry, price: 102, at: etDate("2026-09-25 09:31:40"))
    check(sameMinute?.count == 2 && sameMinute?.last?.v == 102, "same minute updates the tail")
    let nextMinutes = SeriesCache.splice(entry, price: 103, at: etDate("2026-09-25 09:34:05"))
    check(nextMinutes?.count == 3 && nextMinutes?.last?.t == open + 240 && nextMinutes?.last?.v == 103,
          "a later minute is appended at its minute")
    check(SeriesCache.splice(entry, price: 104, at: etDate("2026-09-25 17:30:00"))?.count == 2,
          "after-hours prints stay off the regular-session line")
    check(SeriesCache.splice(entry, price: 105, at: etDate("2026-09-28 09:31:00")) == nil,
          "the next trading day invalidates the cached line")
    check(SeriesCache.splice(entry, price: 99, at: nil)?.last?.v == 101, "a quote without trade time leaves the line")
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let aShare = SeriesCache.Entry(series: [SeriesPt(t: 34200, v: 10), SeriesPt(t: 34260, v: 10.1)],
                                   start: 34200, end: 54000, clock: .daySeconds, zone: shanghai,
                                   day: "2026-09-25", fetchedAt: Date())
    let cnFormatter = DateFormatter(); cnFormatter.timeZone = shanghai; cnFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    check(SeriesCache.splice(aShare, price: 10.2, at: cnFormatter.date(from: "2026-09-25 09:33:20")!)?.last?.t == 34380,
          "A-share lines use exchange-local seconds of day")
    print("PASS: cached intraday lines extend by trade minute and roll over with the trading day")

    // 2) 东财:首轮 1 快照 + 1 分时;缓存期内只要快照(且只问解析过的 secid);5 分钟后整条校准
    var cacheNow = Date(timeIntervalSince1970: 1_790_000_000)
    let cache = SeriesCache(now: { cacheNow })
    var price = 339.5
    var tradeTime = etDate("2026-09-25 09:33:10")
    StubProtocol.reset()
    StubProtocol.handler = { request in
        let url = request.url!.absoluteString
        if url.contains("ulist.np") {
            return (200, json(["data": ["diff": [["f2": price, "f3": 1.0, "f12": "AAPL", "f13": 105,
                                                  "f124": tradeTime.timeIntervalSince1970]]]]))
        }
        if url.contains("trends2") {
            return (200, json(["data": ["trends": ["2026-09-25 21:30,335.95", "2026-09-25 21:31,336.10"],
                                        "preClose": 336.04]]))
        }
        return (404, Data())
    }
    let provider = RealProvider(client: stubbedClient(), seriesCache: cache)
    provider.includeSeries = true
    let aapl = [WatchEntry(symbol: "AAPL", market: "us")]
    var q = fetch(provider, aapl)
    check(q["AAPL"]?.series?.count == 3 && q["AAPL"]?.series?.last?.v == 339.5,
          "first board fetch downloads the line and extends it with the snapshot")
    check(StubProtocol.count("ulist.np") == 1 && StubProtocol.count("trends2") == 1, "one snapshot + one trend request")
    let firstSnapshot = StubProtocol.log.first?.query ?? ""
    check(["105.AAPL", "106.AAPL", "107.AAPL"].allSatisfy(firstSnapshot.contains), "an unresolved symbol asks every listing group")

    price = 340.25; tradeTime = etDate("2026-09-25 09:34:05"); cacheNow += 30
    q = fetch(provider, aapl)
    check(StubProtocol.count("trends2") == 1, "a fresh cached line is not downloaded again")
    check(q["AAPL"]?.series?.last?.v == 340.25 && q["AAPL"]?.series?.count == 4, "the next minute is appended from the snapshot")
    let secondSnapshot = StubProtocol.log.last { $0.path.contains("ulist.np") }?.query ?? ""
    check(secondSnapshot.contains("secids=105.AAPL") && !secondSnapshot.contains("106.AAPL"),
          "a resolved symbol is requested by its known secid only: \(secondSnapshot)")

    cacheNow += SeriesCache.maxAge
    _ = fetch(provider, aapl)
    check(StubProtocol.count("trends2") == 2, "the cached line is re-synchronized after five minutes")

    tradeTime = etDate("2026-09-28 09:31:00"); cacheNow += 10
    _ = fetch(provider, aapl)
    check(StubProtocol.count("trends2") == 3, "a quote from the next trading day refetches the line in the same pass")

    provider.includeSeries = false
    let before = StubProtocol.log.count
    q = fetch(provider, aapl)
    check(StubProtocol.log.count == before + 1 && q["AAPL"]?.series == nil, "the ticker alone never asks for minute data")
    print("PASS: EastMoney minute lines are cached, extended live, re-synchronized and resolved once")

    // 3) Yahoo:缓存期内只要 1d 报价小包,不再拉 1m 分时
    StubProtocol.reset()
    let yahooStart = etDate("2026-09-25 09:30:00").timeIntervalSince1970
    StubProtocol.handler = { request in
        let minute = request.url!.query?.contains("interval=1m") == true
        let meta: [String: Any] = ["regularMarketPrice": 101.0, "chartPreviousClose": 100.0,
                                   "regularMarketTime": etDate("2026-09-25 09:32:30").timeIntervalSince1970,
                                   "exchangeTimezoneName": "America/New_York",
                                   "currentTradingPeriod": ["regular": ["start": yahooStart, "end": yahooStart + 23400]]]
        var result: [String: Any] = ["meta": meta]
        if minute {
            result["timestamp"] = [yahooStart, yahooStart + 60]
            result["indicators"] = ["quote": [["close": [100.2, 100.6]]]]
        }
        return (200, json(["chart": ["result": [result]]]))
    }
    let yahoo = RealProvider(client: stubbedClient(), seriesCache: SeriesCache(now: { cacheNow }))
    yahoo.includeSeries = true
    let index = [WatchEntry(symbol: "^GSPC", market: "us")]
    q = fetch(yahoo, index)
    check(q["^GSPC"]?.series?.count == 2 && StubProtocol.log.last?.query?.contains("interval=1m") == true, "first fetch includes minutes")
    cacheNow += 30
    q = fetch(yahoo, index)
    check(StubProtocol.log.count == 2 && StubProtocol.log.last?.query?.contains("interval=1d") == true,
          "a fresh cached line only needs Yahoo's small daily quote")
    check(q["^GSPC"]?.series?.count == 3 && q["^GSPC"]?.series?.last?.v == 101, "the Yahoo line is extended from the quote")
    print("PASS: Yahoo keeps full minute payloads to one per five minutes")

    // 4) 按主机限流:一个源 429 只冷却它自己,其它源照常;全冷了才算整个行情源限流
    StubProtocol.reset()
    StubProtocol.handler = { request in request.url!.host == "limited.example" ? (429, Data()) : (200, Data("ok".utf8)) }
    let client = stubbedClient()
    func get(_ host: String) -> Int {
        let done = DispatchSemaphore(value: 0)
        var status = -1
        client.fetch(URLRequest(url: URL(string: "https://\(host)/q")!)) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.signal()
        }
        check(done.wait(timeout: .now() + 5) == .success, "request finished")
        return status
    }
    check(get("limited.example") == 429 && get("healthy.example") == 200, "both hosts reached")
    let sent = StubProtocol.log.count
    check(get("limited.example") == 0 && StubProtocol.log.count == sent, "a cooling host fails fast without a request")
    check(get("healthy.example") == 200 && client.cooldownUntil == nil, "other hosts keep working and the provider is not rate limited")
    StubProtocol.handler = { _ in (429, Data()) }
    _ = get("healthy.example")
    check(client.cooldownUntil != nil, "the provider is rate limited once every host it uses is cooling")
    print("PASS: HTTP 429 cools only the host that sent it")

    // 5) 节拍从请求发出算起:请求耗时不叠进周期,定时器按 nextRefresh 醒来正好到期
    final class SlowProvider: QuoteProvider {
        var name = "real"
        var calls = 0
        var pending: (([String: Quote]) -> Void)?
        func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) { calls += 1; pending = completion }
    }
    var now = Date(timeIntervalSince1970: 5000)
    let slow = SlowProvider()
    let service = QuoteService(provider: slow, interval: 15, now: { now })
    let spy = [WatchEntry(symbol: "SPY", market: "us")]
    service.quotes(for: spy) { _ in }
    now += 3   // 8 个请求排队约 3 秒
    slow.pending?(["SPY": Quote(price: 1, changePct: 0, series: nil, sessionStart: nil, sessionEnd: nil)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    check(service.nextRefresh == Date(timeIntervalSince1970: 5015), "next request is due one interval after the last one started")
    now = service.nextRefresh
    service.quotes(for: spy) { _ in }
    check(slow.calls == 2, "a board woken at nextRefresh fetches instead of hitting the cache")
    print("PASS: refresh cadence counts from the request start, so 15 seconds stays 15 seconds")
}
