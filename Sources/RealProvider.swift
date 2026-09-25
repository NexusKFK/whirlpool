import Foundation

// 真实行情源,免 key,美股数据链顺序随设置(usQuoteSource):
//   A股/港股        腾讯 qt.gtimg.cn 实时链(GBK)+ ifzq 分钟线端点
//   美股             东财 push2 批量快照与逐分钟分时(直连实时);链上依次回落
//                   腾讯裸代码 us<symbol> 批量快照、Yahoo v8 chart;Yahoo 也可单独选中。
//   加密货币等       只有 Yahoo 覆盖,直接走 Yahoo。
// 报价与分时分开凑:链上先凑齐报价,再由供分时的源(东财,其次 Yahoo)补曲线;
// 腾讯没有美股分钟数据。Yahoo 不可达只是没缩略图,行情不受影响。
// 任一环失败不影响其他环;全部失败回调空字典,由 QuoteService 统一退避重试。

final class RealProvider: QuoteProvider {
    var name: String { "real" }

    /// 美股数据链优先源(设置 General 页)
    enum USSource: String { case eastmoney, tencent, yahoo }
    var usSource: USSource = .eastmoney

    private let client = QuoteHTTPClient()
    var cooldownUntil: Date? { client.cooldownUntil }
    /// 只有报价卡需要当日分时线;纯跑马灯时不拉分钟端点
    var includeSeries = true

    /// 东财 secid 解析缓存(symbol → "105.AAPL"),报价环节解析完分时环节直接复用
    private final class SecidCache {
        private let lock = NSLock()
        private var map: [String: String] = [:]
        func get(_ symbol: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[symbol] }
        func set(_ secid: String, for symbol: String) { lock.lock(); defer { lock.unlock() }; map[symbol] = secid }
        func unresolved(_ entries: [WatchEntry]) -> [WatchEntry] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { map[$0.symbol] == nil }
        }
    }
    private let secidCache = SecidCache()

    /// 东财分时的产出:曲线 + 时段轴 + 足以拼出整条报价的尾价/昨收
    struct EMSeries {
        var series: [SeriesPt]
        var start: Double
        var end: Double
        var lastPrice: Double
        var preClose: Double
        var lastTime: Date?
    }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let cnSide    = entries.filter { $0.market == "cn" || $0.market == "hk" }
        let usSide    = entries.filter { $0.market == "us" }
        let yahooSide = entries.filter { !["cn", "hk", "us"].contains($0.market) }   // 加密货币等只有 Yahoo 有
        let wantsSeries = includeSeries

        var results: [String: Quote] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        if !cnSide.isEmpty {
            group.enter()
            fetchTencent(cnSide, includeSeries: wantsSeries) { qs in
                lock.lock(); results.merge(qs) { a, _ in a }; lock.unlock()
                group.leave()
            }
        }
        if !usSide.isEmpty {
            group.enter()
            fetchUS(usSide, includeSeries: wantsSeries) { qs in
                lock.lock(); results.merge(qs) { a, _ in a }; lock.unlock()
                group.leave()
            }
        }
        if !yahooSide.isEmpty {
            group.enter()
            fetchYahoo(yahooSide, includeSeries: wantsSeries) { qs in
                lock.lock(); results.merge(qs) { a, _ in a }; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global()) { completion(results) }
    }

    // ── 腾讯(A股/港股/美股兜底) ──────────────────────────────────────────────
    // https://qt.gtimg.cn/q=sh600519,sz510300,usAAPL  响应 GBK;
    // 字段:~3 现价,~32 涨跌幅%(港股/美股同族布局,若有出入只影响对应行)。
    // 分钟线走 ifzq 端点,每标的一个附加请求(仅 A股/港股;美股无分时)。

    private func fetchTencent(_ entries: [WatchEntry], includeSeries: Bool, completion: @escaping ([String: Quote]) -> Void) {
        fetchTencentQuotes(entries) { quotes in
            guard includeSeries else { completion(quotes); return }
            var out = quotes
            // 分钟线:每标的单独取,取不到就让该行没有缩略图
            let codeToSymbol = Dictionary(entries.map { (self.tencentCode($0), $0.symbol) }, uniquingKeysWith: { first, _ in first })
            let present = Set(out.keys)
            let outLock = NSLock()
            let seriesGroup = DispatchGroup()
            for (code, symbol) in codeToSymbol where present.contains(symbol) {
                let market = entries.first { $0.symbol == symbol }?.market ?? "cn"
                let session: (Double, Double) = market == "hk" ? (9.5 * 3600, 16 * 3600)
                                                                : (9.5 * 3600, 15 * 3600)
                seriesGroup.enter()
                self.fetchTencentSeries(code: code) { series in
                    if let series {
                        outLock.lock()
                        if let q = out[symbol] {
                            out[symbol] = Quote(price: q.price, changePct: q.changePct,
                                                series: series,
                                                sessionStart: session.0, sessionEnd: session.1,
                                                decimals: q.decimals, marketTime: q.marketTime)
                        }
                        outLock.unlock()
                    }
                    seriesGroup.leave()
                }
            }
            seriesGroup.notify(queue: .global()) { completion(out) }
        }
    }

    /// 腾讯 v_ 串批量快照,cn/hk 与美股兜底共用
    private func fetchTencentQuotes(_ entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let codeToSymbol = Dictionary(entries.map { (tencentCode($0), $0.symbol) }, uniquingKeysWith: { first, _ in first })
        let codes = codeToSymbol.keys.joined(separator: ",")
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(codes)") else {
            completion([:]); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        client.fetch(req) { data, resp, _ in
            guard let data, self.httpOK(resp),
                  let text = String(data: data, encoding: .gb18030)
                          ?? String(data: data, encoding: .utf8)
            else { completion([:]); return }

            var out: [String: Quote] = [:]
            for line in text.components(separatedBy: ";") {
                guard let (code, quote) = self.parseTencentLine(line),
                      let symbol = codeToSymbol[code]
                else { continue }
                out[symbol] = quote
            }
            completion(out)
        }
    }

    /// 返回 (腾讯代码 如 "sh600519", 报价)
    func parseTencentLine(_ line: String) -> (String, Quote)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v_", with: "")
        let inner = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        let parts = inner.components(separatedBy: "~")
        guard parts.count > 32,
              let px = Double(parts[3]),
              let pct = Double(parts[32]), px.isFinite, px > 0, pct.isFinite
        else { return nil }
        var quote = Quote(price: px, changePct: pct, series: nil, sessionStart: nil, sessionEnd: nil)
        // A 股报价串自带精度(股票 2 位、ETF/基金 3 位);港股一律写 3 位,不作数,交给价位表
        if !key.hasPrefix("hk"), let dot = parts[3].firstIndex(of: ".") {
            quote.decimals = parts[3].distance(from: dot, to: parts[3].endIndex) - 1
        }
        quote.marketTime = Self.tencentTime(parts[30], zone: key.hasPrefix("hk") ? "Asia/Hong_Kong"
                                              : key.hasPrefix("us") ? "America/New_York"
                                              : "Asia/Shanghai")
        return (key, quote)
    }

    /// 腾讯时间戳:A 股 "20260918150003"(北京时间),港股 "2026/09/18 16:08:32"(香港时间),
    /// 美股 "2026-09-25 11:41:20"(美东,随冬令时切换)
    static func tencentTime(_ raw: String, zone: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = raw.contains("/") ? "yyyy/MM/dd HH:mm:ss"
                     : raw.contains("-") ? "yyyy-MM-dd HH:mm:ss"
                     : "yyyyMMddHHmmss"
        return f.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    func tencentCode(_ e: WatchEntry) -> String { Self.tencentCode(for: e) }

    /// 港股左补零到 5 位。A 股可带交易所前缀(SH000001 = 上证指数;只写 000001 是深市平安银行);
    /// 不带前缀按号段:92/4/8 北交所,6/5/9 沪市,其余深市。
    static func tencentCode(for e: WatchEntry) -> String {
        let s = e.symbol
        if e.market == "hk" {
            return "hk" + String(repeating: "0", count: max(0, 5 - s.count)) + s
        }
        if e.market == "us" { return "us" + s }
        let named = String(s.prefix(2))
        if s.count == 8, ["SH", "SZ", "BJ"].contains(named) {
            return named.lowercased() + String(s.dropFirst(2))
        }
        if s.hasPrefix("92") || s.hasPrefix("4") || s.hasPrefix("8") { return "bj" + s }
        if s.hasPrefix("6") || s.hasPrefix("5") || s.hasPrefix("9") { return "sh" + s }
        return "sz" + s
    }

    /// 腾讯/东财批量接口都吃裸代码,符号里出不了的字符(如 ^GSPC、带空格的写法)直接交给 Yahoo
    static func usCodeAllowed(_ symbol: String) -> Bool {
        !symbol.isEmpty && symbol.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "-"
        }
    }

    /// 美股上市代码:无点号,或分级股 BRK.B 这类 .A/.B/.C;7203.T、VOD.L、0700.HK 是 Yahoo 的
    /// 交易所后缀,东财/腾讯的美股口查不到,直接交给 Yahoo
    static func usListed(_ symbol: String) -> Bool {
        guard usCodeAllowed(symbol) else { return false }
        let parts = symbol.uppercased().split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 1 || (parts.count == 2 && !parts[0].isEmpty && ["A", "B", "C"].contains(parts[1]))
    }

    /// https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519
    /// data.<code>.data.data = ["0930 1250.00 1249.00 123", …](时间 价格 均价 量)
    private func fetchTencentSeries(code: String, completion: @escaping ([SeriesPt]?) -> Void) {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(code)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        client.fetch(req) { data, resp, _ in
            guard let data, self.httpOK(resp),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataNode = obj["data"] as? [String: Any],
                  let codeNode = dataNode[code] as? [String: Any],
                  let inner = codeNode["data"] as? [String: Any],
                  let lines = inner["data"] as? [String]
            else { completion(nil); return }
            let pts = lines.compactMap { l -> SeriesPt? in
                let f = l.components(separatedBy: " ")
                guard f.count > 1, let v = Double(f[1]), f[0].count == 4,
                      let hh = Int(f[0].prefix(2)), let mm = Int(f[0].suffix(2))
                else { return nil }
                return SeriesPt(t: Double(hh * 3600 + mm * 60), v: v)
            }
            completion(pts.count > 2 ? pts : nil)
        }
    }

    // ── 东财(美股,免 key 直连) ──────────────────────────────────────────────
    // 快照一次批量:三个上市组前缀(105 纳斯达克 / 106 纽交所 / 107 Arca·美交组)
    // 全部候选一起问,有效价回在哪个前缀,市场归属就解析到哪;无效代码自动缺席。
    // f124 是最近成交的 epoch 秒,给智能刷新当实时兜底。
    // 分时 trends2 是当日逐分钟(北京时间),换算成 epoch 后与 Yahoo 分时同一坐标系。

    private func fetchEastMoneyQuotes(_ entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let symbolBySecid = Dictionary(entries.flatMap { e in Self.eastMoneySecids(e.symbol).map { ($0, e.symbol) } },
                                       uniquingKeysWith: { first, _ in first })
        let secids = symbolBySecid.keys.joined(separator: ",")
        guard let url = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=f2,f3,f12,f13,f124&secids=\(secids)") else {
            completion([:]); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        client.fetch(req) { data, resp, _ in
            guard let data, self.httpOK(resp),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let node = obj["data"] as? [String: Any],
                  let rows = node["diff"] as? [[String: Any]]
            else { completion([:]); return }
            var out: [String: Quote] = [:]
            for row in rows {
                guard let parsed = Self.parseEastMoneyRow(row), let symbol = symbolBySecid[parsed.secid] else { continue }
                self.secidCache.set(parsed.secid, for: symbol)
                out[symbol] = Quote(price: parsed.price, changePct: parsed.changePct,
                                    series: nil, sessionStart: nil, sessionEnd: nil,
                                    decimals: Self.eastMoneyDecimals(parsed.price),
                                    marketTime: (row["f124"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            completion(out)
        }
    }

    /// 逐标的 trends2 分时;secid 没解析过的符号先用一次批量快照补解析(仅认代码/市场字段)
    private func fetchEastMoneySeries(_ entries: [WatchEntry], completion: @escaping ([String: EMSeries]) -> Void) {
        let usable = entries.filter { !Self.eastMoneySecids($0.symbol).isEmpty }
        let unresolved = secidCache.unresolved(usable)
        guard unresolved.isEmpty else {
            resolveEastMoneySecids(unresolved) { [weak self] in
                self?.trendsFor(usable, completion: completion)
            }
            return
        }
        trendsFor(usable, completion: completion)
    }

    private func resolveEastMoneySecids(_ entries: [WatchEntry], completion: @escaping () -> Void) {
        let symbolBySecid = Dictionary(entries.flatMap { e in Self.eastMoneySecids(e.symbol).map { ($0, e.symbol) } },
                                       uniquingKeysWith: { first, _ in first })
        let secids = symbolBySecid.keys.joined(separator: ",")
        guard let url = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=f12,f13&secids=\(secids)") else {
            completion(); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        client.fetch(req) { data, resp, _ in
            if let data, self.httpOK(resp),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let node = obj["data"] as? [String: Any],
               let rows = node["diff"] as? [[String: Any]] {
                for row in rows {
                    if let parsed = Self.parseEastMoneyRow(row), let symbol = symbolBySecid[parsed.secid] {
                        self.secidCache.set(parsed.secid, for: symbol)
                    }
                }
            }
            completion()
        }
    }

    private func trendsFor(_ entries: [WatchEntry], completion: @escaping ([String: EMSeries]) -> Void) {
        var out: [String: EMSeries] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for e in entries {
            guard let secid = secidCache.get(e.symbol) else { continue }
            group.enter()
            fetchEastMinuteTrend(secid: secid) { got in
                if let got { lock.lock(); out[e.symbol] = got; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .global()) { completion(out) }
    }

    private func fetchEastMinuteTrend(secid: String, completion: @escaping (EMSeries?) -> Void) {
        guard let url = URL(string: "https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f3&fields2=f51,f53&iscr=0&ndays=1") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        client.fetch(req) { data, resp, _ in
            guard let data, self.httpOK(resp),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let node = obj["data"] as? [String: Any],
                  let lines = node["trends"] as? [String]
            else { completion(nil); return }
            let preClose = (node["preClose"] as? Double) ?? (node["preSettlement"] as? Double) ?? 0
            completion(Self.parseEastMoneyTrends(lines, preClose: preClose))
        }
    }

    /// diff 行 → (secid, 价格, 涨跌%);无效代码与停牌的 "-" 一律拒绝
    static func parseEastMoneyRow(_ row: [String: Any]) -> (secid: String, price: Double, changePct: Double)? {
        guard let code = row["f12"] as? String, let market = row["f13"] as? Int,
              let price = row["f2"] as? Double, price.isFinite, price > 0,
              let pct = row["f3"] as? Double, pct.isFinite
        else { return nil }
        return ("\(market).\(code)", price, pct)
    }

    /// 上市组候选;^指数、加密货币这类不在组内的代码给空 → 链上直接落下一源
    static func eastMoneySecids(_ symbol: String) -> [String] {
        guard usListed(symbol) else { return [] }
        let code = symbol.uppercased().replacingOccurrences(of: ".", with: "_")   // 分级股 BRK.B → BRK_B
        return [105, 106, 107].map { "\($0).\(code)" }
    }

    /// 东财会带出亚美分成交价(如 339.345),按价位定精度免得列宽来回跳:$1 以上 2 位,以下 4 位
    static func eastMoneyDecimals(_ price: Double) -> Int {
        price < 1 ? 4 : 2
    }

    /// "2026-09-25 21:30,335.950,…" → 逐分钟点(北京时间换算 epoch);
    /// 时段轴取首点起 6.5 小时,提前收盘只是轴更宽,不影响画线
    static func parseEastMoneyTrends(_ lines: [String], preClose: Double) -> EMSeries? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var pts: [SeriesPt] = []
        var lastTime: Date?
        for line in lines {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 2, let v = Double(parts[1]), let t = f.date(from: String(parts[0])) else { continue }
            pts.append(SeriesPt(t: t.timeIntervalSince1970, v: v))
            lastTime = t
        }
        guard let first = pts.first, pts.count > 1 else { return nil }
        return EMSeries(series: pts, start: first.t, end: first.t + 6.5 * 3600,
                        lastPrice: pts[pts.count - 1].v, preClose: preClose, lastTime: lastTime)
    }

    // ── 美股(数据链:设置定首位,Yahoo 永远殿后) ────────────────────────────
    // 先凑报价(东财批量 ⇄ 腾讯批量按 usSource 排序,缺的落 Yahoo;^指数/期货、
    // 带交易所后缀的海外代码直接跳到 Yahoo),再补分时(东财 trends2,缺的落 Yahoo);
    // 分时自带尾价/昨收,极端情况下连报价都能凭分时拼出来。

    private func fetchUS(_ entries: [WatchEntry], includeSeries: Bool, completion: @escaping ([String: Quote]) -> Void) {
        let chain: [USSource] = {
            switch usSource {
            case .yahoo: return [.yahoo]
            case .tencent: return [.tencent, .eastmoney, .yahoo]
            case .eastmoney: return [.eastmoney, .tencent, .yahoo]
            }
        }()
        var merged: [String: Quote] = [:]
        var yahooTried: Set<String> = []   // 报价环节已问过 Yahoo 的,分时环节不再重复问

        func merge(_ fresh: [String: Quote]) {
            for (symbol, quote) in fresh where merged[symbol] == nil { merged[symbol] = quote }
        }
        func finish() { completion(merged) }

        func seriesPass() {
            guard includeSeries else { finish(); return }
            let need = entries.filter { merged[$0.symbol]?.series == nil }
            guard !need.isEmpty, usSource != .yahoo else { finish(); return }
            fetchEastMoneySeries(need) { got in
                for (symbol, em) in got {
                    if let q = merged[symbol] {
                        merged[symbol] = Quote(price: q.price, changePct: q.changePct,
                                               series: em.series, sessionStart: em.start, sessionEnd: em.end,
                                               decimals: q.decimals, marketTime: q.marketTime ?? em.lastTime)
                    } else if em.preClose > 0, em.lastPrice > 0 {
                        merged[symbol] = Quote(price: em.lastPrice,
                                               changePct: (em.lastPrice - em.preClose) / em.preClose * 100,
                                               series: em.series, sessionStart: em.start, sessionEnd: em.end,
                                               decimals: Self.eastMoneyDecimals(em.lastPrice), marketTime: em.lastTime)
                    }
                }
                let still = entries.filter { !yahooTried.contains($0.symbol) && merged[$0.symbol]?.series == nil }
                guard !still.isEmpty else { finish(); return }
                self.fetchYahoo(still, includeSeries: true) { fresh in
                    for (symbol, yq) in fresh {
                        if let q = merged[symbol] {
                            if let series = yq.series {
                                merged[symbol] = Quote(price: q.price, changePct: q.changePct,
                                                       series: series, sessionStart: yq.sessionStart, sessionEnd: yq.sessionEnd,
                                                       decimals: q.decimals, marketTime: q.marketTime)
                            }
                        } else {
                            merged[symbol] = yq
                        }
                    }
                    finish()
                }
            }
        }

        func step(_ rest: ArraySlice<USSource>) {
            guard let head = rest.first else { seriesPass(); return }
            let todo = entries.filter { merged[$0.symbol] == nil }
            guard !todo.isEmpty else { seriesPass(); return }
            switch head {
            case .yahoo:
                yahooTried.formUnion(todo.map(\.symbol))
                fetchYahoo(todo, includeSeries: includeSeries) { qs in merge(qs); seriesPass() }
            case .tencent:
                let plain = todo.filter { Self.usListed($0.symbol) }
                guard !plain.isEmpty else { step(rest.dropFirst()); return }
                fetchTencentQuotes(plain) { qs in merge(qs); step(rest.dropFirst()) }
            case .eastmoney:
                let plain = todo.filter { Self.usListed($0.symbol) }
                guard !plain.isEmpty else { step(rest.dropFirst()); return }
                fetchEastMoneyQuotes(plain) { qs in merge(qs); step(rest.dropFirst()) }
            }
        }
        step(chain[...])
    }

    // ── Yahoo(兜底 + 美股分时备胎) ───────────────────────────────────────────
    // v8 chart 端点,免 crumb。chartPreviousClose = 区间前收盘(1d 即昨收),
    // regularMarketPrice 与之相除得涨跌幅;同一响应的 indicators 即分钟线。

    private func fetchYahoo(_ entries: [WatchEntry], includeSeries: Bool, completion: @escaping ([String: Quote]) -> Void) {
        var out: [String: Quote] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for e in entries {
            group.enter()
            let raw = e.market == "us" ? Self.yahooUSSymbol(e.symbol) : e.symbol
            let sym = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
            let query = includeSeries ? "interval=1m&range=1d" : "interval=1d&range=1d"
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(sym)?\(query)")
            else { group.leave(); continue }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            client.fetch(req) { data, resp, _ in
                defer { group.leave() }
                guard let data, self.httpOK(resp),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chart = obj["chart"] as? [String: Any],
                      let result = (chart["result"] as? [[String: Any]])?.first,
                      let meta = result["meta"] as? [String: Any],
                      let px = meta["regularMarketPrice"] as? Double,
                      let prev = meta["chartPreviousClose"] as? Double,
                      prev > 0, prev.isFinite, px.isFinite, px > 0
                else { return }

                // 分钟线带时间戳,只留当天;x 轴按真实时段画,不降采样
                var series: [SeriesPt]? = nil
                var sStart: Double? = nil
                var sEnd: Double? = nil
                if includeSeries, let ts = result["timestamp"] as? [Double],
                   let indicators = result["indicators"] as? [String: Any],
                   let quoteArr = (indicators["quote"] as? [[String: Any]])?.first,
                   let raw = quoteArr["close"] as? [Any] {
                    var pts: [SeriesPt] = []
                    for (t, c) in zip(ts, raw) {
                        if let v = c as? Double { pts.append(SeriesPt(t: t, v: v)) }
                    }
                    if let period = meta["currentTradingPeriod"] as? [String: Any],
                       let regular = period["regular"] as? [String: Any],
                       let st = regular["start"] as? Double, let en = regular["end"] as? Double {
                        sStart = st; sEnd = en
                        let day = pts.filter { $0.t >= st && $0.t <= en }
                        if day.count > 1 { pts = day }
                        else { sStart = nil; sEnd = nil }
                    }
                    if pts.count > 1 { series = pts }
                }

                let hint = meta["priceHint"] as? Int
                let time = (meta["regularMarketTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
                lock.lock()
                out[e.symbol] = Quote(price: px, changePct: (px - prev) / prev * 100,
                                      series: series, sessionStart: sStart, sessionEnd: sEnd,
                                      decimals: hint, marketTime: time)
                lock.unlock()
            }
        }

        group.notify(queue: .global()) { completion(out) }
    }

    /// Yahoo 的分级股写法是 BRK-B;^指数、=F 期货、7203.T 这类交易所后缀原样
    static func yahooUSSymbol(_ symbol: String) -> String {
        usListed(symbol) ? symbol.replacingOccurrences(of: ".", with: "-") : symbol
    }

    private func httpOK(_ resp: URLResponse?) -> Bool {
        guard let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(code)
    }
}

private extension String.Encoding {
    // 腾讯响应是 GBK;CoreFoundation 桥一个 18030(GBK 超集)
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}