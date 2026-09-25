import Foundation

// ── 分时缓存 ───────────────────────────────────────────────────────────────────
//
// 当日分钟线一分钟才多一个点,报价卡开着时却每次刷新都整条重拉——7 个美股标的就是
// 1 个报价请求 + 7 个分时请求(实测压缩后分时占流量 98%)。这里把整条线留 5 分钟:其间每次拿到
// 报价,就按成交时间把它接到线尾(同一分钟改尾点,新的一分钟追加一个点),缩略图照样
// 实时;过期整条重拉校准,报价已进入下一个交易日则立即重拉。
// 64pt 宽的缩略图里一个像素约 6 分钟,接尾与交易所分钟收盘价的细微差别看不出来。

final class SeriesCache {

    /// 点的时间单位:epoch 秒(东财、Yahoo)/ 交易所当地当日秒数(腾讯 A 股、港股)
    enum Clock: Equatable { case epoch, daySeconds }

    struct Entry {
        var series: [SeriesPt]
        var start: Double?
        var end: Double?
        var clock: Clock
        var zone: TimeZone
        var day: String          // 这条线所属交易日(交易所当地 yyyy-MM-dd)
        var fetchedAt: Date
    }

    static let maxAge: TimeInterval = 300

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// 还在有效期内(调用方据此决定只要报价还是连整条线一起拉)
    func isFresh(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key].map { now().timeIntervalSince($0.fetchedAt) < Self.maxAge } ?? false
    }

    /// 存一条刚拉到的整线。day 缺省时:epoch 线取末点所在交易日,当日秒数线取当前日期。
    func store(_ key: String, series: [SeriesPt], start: Double?, end: Double?,
               clock: Clock, zone: TimeZone, day: String? = nil) {
        guard let last = series.last, series.count > 1 else { return }
        let lineDay = day ?? Self.day(clock == .epoch ? Date(timeIntervalSince1970: last.t) : now(), zone)
        let entry = Entry(series: series, start: start, end: end, clock: clock, zone: zone,
                          day: lineDay, fetchedAt: now())
        lock.lock(); entries[key] = entry; lock.unlock()
    }

    /// 缓存新鲜时把这笔报价接到线尾,返回带线的报价;没缓存、过期或报价已是下一个交易日 → nil,调用方整条重拉
    func extended(_ key: String, with quote: Quote) -> Quote? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key], now().timeIntervalSince(entry.fetchedAt) < Self.maxAge else { return nil }
        guard let series = Self.splice(entry, price: quote.price, at: quote.marketTime) else {
            entries[key] = nil
            return nil
        }
        entry.series = series
        entries[key] = entry
        return Quote(price: quote.price, changePct: quote.changePct, series: series,
                     sessionStart: entry.start, sessionEnd: entry.end,
                     decimals: quote.decimals, marketTime: quote.marketTime)
    }

    /// 接尾规则。nil = 这条线已过期(报价属于更晚的交易日)。
    static func splice(_ entry: Entry, price: Double, at time: Date?) -> [SeriesPt]? {
        guard let last = entry.series.last else { return nil }
        guard let time, price.isFinite, price > 0 else { return entry.series }   // 没有成交时间:原样沿用
        let quoteDay = day(time, entry.zone)
        if quoteDay > entry.day { return nil }             // 已是下一个交易日:整条重拉
        if quoteDay < entry.day { return entry.series }    // 更早的报价(各源时间戳不一):不动
        let t: Double
        switch entry.clock {
        case .epoch:
            t = (time.timeIntervalSince1970 / 60).rounded(.down) * 60
        case .daySeconds:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = entry.zone
            let c = calendar.dateComponents([.hour, .minute], from: time)
            t = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)
        }
        if let end = entry.end, t > end { return entry.series }   // 收盘后(盘后成交、收市竞价尾巴)不接
        var out = entry.series
        if t > last.t {
            out.append(SeriesPt(t: t, v: price))
        } else {
            // 同一分钟,或成交稀疏的标的最后一笔早于线尾:更新尾点
            out[out.count - 1] = SeriesPt(t: last.t, v: price)
        }
        return out
    }

    static func day(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
