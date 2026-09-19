import Foundation

// ── 交易时段与节假日(智能刷新)────────────────────────────────────────────────
//
// 自选里所有市场都休市时,行情不会变,没必要每 30 秒请求一次:
// 拉取间隔放宽到"距最近一个开盘"(上限 30 分钟),开盘时刻准时恢复。
// 日历:美股按 NYSE 规则推算(含复活节、周末顺延、半日市);港股/A 股按官方公布的
// 休市表(每年更新一次,见下方数据来源)。表里没有的年份按"工作日即开市"处理——
// 宁可多拉几次,不会误判休市。另有实时兜底:行情时间戳显示几分钟内仍有成交,就按开市算。
// 各时段两端留几分钟余量,确保收盘价与开盘第一笔都能拿到。

enum MarketClock {

    struct Session: Equatable { let start: Int; let end: Int }   // 当地分钟数 [start, end)

    enum Exchange { case nyse, sse, hkex }

    static func exchange(for entry: WatchEntry) -> Exchange? {
        switch entry.market {
        case "crypto": return nil                                         // 7×24
        case "cn": return .sse
        case "hk": return .hkex
        default:
            // 期货/外汇(ES=F、EURUSD=X)近乎 24×5,加密后缀同理:按全天候处理
            if entry.symbol.contains("=") || entry.symbol.hasSuffix("-USD") { return nil }
            return .nyse
        }
    }

    static func timeZone(_ ex: Exchange) -> TimeZone {
        switch ex {
        case .nyse: return TimeZone(identifier: "America/New_York")!
        case .sse: return TimeZone(identifier: "Asia/Shanghai")!
        case .hkex: return TimeZone(identifier: "Asia/Hong_Kong")!
        }
    }

    // ── 官方休市表 ──
    // A 股:国务院办公厅 2025-11 放假通知(gov.cn content_7047091),与深交所交易日历接口逐日核对;
    //       2027 年安排通常 11 月公布,公布后补进来。
    // 港股:港交所 Trading Calendar and Holiday Schedule(2026-07-31 更新),含半日市。
    static let sseClosed: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20",
        "2026-02-23", "2026-04-06", "2026-05-01", "2026-05-04", "2026-05-05", "2026-06-19", "2026-09-25",
        "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07",
    ]
    static let hkexClosed: Set<String> = [
        "2026-01-01", "2026-02-17", "2026-02-18", "2026-02-19", "2026-04-03", "2026-04-06", "2026-04-07",
        "2026-05-01", "2026-05-25", "2026-06-19", "2026-07-01", "2026-10-01", "2026-10-19", "2026-12-25",
        "2027-01-01", "2027-02-08", "2027-02-09", "2027-03-26", "2027-03-29", "2027-04-05", "2027-05-13",
        "2027-06-09", "2027-07-01", "2027-09-16", "2027-10-01", "2027-10-08", "2027-12-27",
    ]
    static let hkexHalfDay: Set<String> = [   // 农历除夕、平安夜、除夕夜:只有上午
        "2026-02-16", "2026-12-24", "2026-12-31", "2027-02-05", "2027-12-24", "2027-12-31",
    ]

    // ── NYSE 规则(Rule 7.2)──

    private static func nthWeekday(_ n: Int, _ weekday: Int, month: Int, year: Int, cal: Calendar) -> DateComponents {
        var c = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n)
        let d = cal.date(from: c)!
        c = cal.dateComponents([.year, .month, .day], from: d)
        return c
    }

    private static func lastMonday(of month: Int, year: Int, cal: Calendar) -> DateComponents {
        let c = DateComponents(year: year, month: month, weekday: 2, weekdayOrdinal: -1)
        return cal.dateComponents([.year, .month, .day], from: cal.date(from: c)!)
    }

    /// 复活节(格里历,匿名算法)
    static func easter(_ y: Int) -> (month: Int, day: Int) {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        return ((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
    }

    static func nyseHolidays(_ year: Int) -> Set<String> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(.nyse)
        func key(_ c: DateComponents) -> String { String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) }
        func key(_ d: Date) -> String { key(cal.dateComponents([.year, .month, .day], from: d)) }
        /// 固定日:周六提前到周五、周日顺延到周一;元旦逢周六不补(规则 7.2)
        func observed(_ month: Int, _ day: Int, saturdayRule: Bool = true) -> String? {
            let d = cal.date(from: DateComponents(year: year, month: month, day: day))!
            switch cal.component(.weekday, from: d) {
            case 7: return saturdayRule ? key(cal.date(byAdding: .day, value: -1, to: d)!) : nil
            case 1: return key(cal.date(byAdding: .day, value: 1, to: d)!)
            default: return key(d)
            }
        }
        var days = Set<String>()
        [observed(1, 1, saturdayRule: false), observed(6, 19), observed(7, 4), observed(12, 25)]
            .compactMap { $0 }.forEach { days.insert($0) }
        days.insert(key(nthWeekday(3, 2, month: 1, year: year, cal: cal)))    // MLK
        days.insert(key(nthWeekday(3, 2, month: 2, year: year, cal: cal)))    // Washington's Birthday
        days.insert(key(lastMonday(of: 5, year: year, cal: cal)))             // Memorial Day
        days.insert(key(nthWeekday(1, 2, month: 9, year: year, cal: cal)))   // Labor Day
        days.insert(key(nthWeekday(4, 5, month: 11, year: year, cal: cal)))   // Thanksgiving
        let e = easter(year)
        let goodFriday = cal.date(byAdding: .day, value: -2, to: cal.date(from: DateComponents(year: year, month: e.month, day: e.day))!)!
        days.insert(key(goodFriday))
        // 次年元旦逢周六:NYSE 不在本年 12/31 补休(规则如此),无需处理
        return days
    }

    /// NYSE 13:00 提前收盘:感恩节次日、平安夜、7/3(均须为工作日且非假日)
    static func nyseEarlyClose(_ year: Int) -> Set<String> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(.nyse)
        let holidays = nyseHolidays(year)
        func key(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        var days = Set<String>()
        let thanksgiving = cal.date(from: nthWeekday(4, 5, month: 11, year: year, cal: cal))!
        days.insert(key(cal.date(byAdding: .day, value: 1, to: thanksgiving)!))
        for (m, d) in [(12, 24), (7, 3)] {
            let date = cal.date(from: DateComponents(year: year, month: m, day: d))!
            let wd = cal.component(.weekday, from: date)
            if (2...6).contains(wd), !holidays.contains(key(date)) { days.insert(key(date)) }
        }
        return days
    }

    private static var nyseCache: [Int: (closed: Set<String>, early: Set<String>)] = [:]

    /// 某交易所某个当地日期的交易时段;空 = 休市
    static func sessions(_ ex: Exchange, year: Int, month: Int, day: Int, weekday: Int) -> [Session] {
        guard (2...6).contains(weekday) else { return [] }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        switch ex {
        case .nyse:
            let table = nyseCache[year] ?? (nyseHolidays(year), nyseEarlyClose(year))
            nyseCache[year] = table
            if table.closed.contains(key) { return [] }
            return [Session(start: 9 * 60 + 25, end: (table.early.contains(key) ? 13 : 16) * 60 + 5)]
        case .sse:
            if sseClosed.contains(key) { return [] }
            return [Session(start: 9 * 60 + 10, end: 11 * 60 + 35), Session(start: 12 * 60 + 55, end: 15 * 60 + 5)]
        case .hkex:
            if hkexClosed.contains(key) { return [] }
            // 港交所全日市含延长早市(12:00-13:00),9:30-16:00 连续;半日市只到 12:00
            return [Session(start: 9 * 60 + 15, end: hkexHalfDay.contains(key) ? 12 * 60 + 15 : 16 * 60 + 15)]
        }
    }

    private static func local(_ date: Date, _ ex: Exchange) -> (y: Int, m: Int, d: Int, wd: Int, minute: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(ex)
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        return (c.year!, c.month!, c.day!, c.weekday!, c.hour! * 60 + c.minute!)
    }

    static func isOpen(_ entry: WatchEntry, at date: Date) -> Bool {
        guard let ex = exchange(for: entry) else { return true }
        let t = local(date, ex)
        return sessions(ex, year: t.y, month: t.m, day: t.d, weekday: t.wd)
            .contains { t.minute >= $0.start && t.minute < $0.end }
    }

    /// 下一次任一时段开始的时刻(最长往后看 20 天,够跨过国庆长假)
    static func nextOpen(_ entry: WatchEntry, after date: Date) -> Date? {
        guard let ex = exchange(for: entry) else { return date }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(ex)
        let today = cal.startOfDay(for: date)
        for offset in 0...20 {
            guard let base = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: base)
            for s in sessions(ex, year: c.year!, month: c.month!, day: c.day!, weekday: c.weekday!) {
                if let t = cal.date(byAdding: .minute, value: s.start, to: base), t > date { return t }
            }
        }
        return nil
    }

    /// 智能刷新间隔:任一市场开市(或刚有成交)→ 原间隔;全休市 → 等到最近开盘(上限 30 分钟)
    static func refreshInterval(_ entries: [WatchEntry], base: TimeInterval, now: Date,
                                lastTrade: [String: Date] = [:]) -> TimeInterval {
        guard !entries.isEmpty, !entries.contains(where: { isOpen($0, at: now) }) else { return base }
        // 实时兜底:日历说休市,但行情时间戳 5 分钟内还在走 → 日历可能漏了特殊交易日,按开市算
        if entries.contains(where: { e in lastTrade[e.symbol].map { now.timeIntervalSince($0) < 300 } ?? false }) {
            return base
        }
        let opens = entries.compactMap { nextOpen($0, after: now) }
        let untilOpen = opens.map { $0.timeIntervalSince(now) }.min() ?? 1800
        return min(1800, max(base, untilOpen + 5))
    }

    static func anyOpen(_ entries: [WatchEntry], at date: Date) -> Bool {
        entries.contains { isOpen($0, at: date) }
    }
}

/// 图表链接:美股/A 股/港股走 TradingView,指数/期货/外汇/加密走 Yahoo
func chartURL(for entry: WatchEntry) -> URL? {
    let s = entry.symbol
    let tvIndex: [String: String] = ["^GSPC": "SP:SPX", "^SPX": "SP:SPX", "^IXIC": "NASDAQ:IXIC",
                                      "^NDX": "NASDAQ:NDX", "^DJI": "DJ:DJI", "^VIX": "CBOE:VIX",
                                      "^RUT": "TVC:RUT", "^HSI": "HSI:HSI"]
    var tv: String?
    switch entry.market {
    case "cn":
        let sh = s.hasPrefix("6") || s.hasPrefix("5") || s.hasPrefix("9")
        tv = (sh ? "SSE:" : "SZSE:") + s
    case "hk":
        tv = "HKEX:" + String(Int(s) ?? 0)
    case "crypto":
        tv = nil
    default:
        if let mapped = tvIndex[s] { tv = mapped }
        else if !s.contains("^"), !s.contains("="), !s.hasSuffix("-USD") { tv = s }
    }
    if let tv, let q = tv.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ":.-"))) {
        return URL(string: "https://www.tradingview.com/chart/?symbol=\(q)")
    }
    let y = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    return URL(string: "https://finance.yahoo.com/quote/\(y)")
}
