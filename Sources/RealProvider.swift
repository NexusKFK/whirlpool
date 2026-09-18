import Foundation

// 真实行情源,免 key 双链:
//   美股/指数/加密  Yahoo 公开 chart 端点(yfinance 同源,Swift 原生调用)
//   A股/港股        腾讯 qt.gtimg.cn 实时链(GBK)+ ifzq 分钟线端点
// 任一腿失败不影响另一腿;全部失败回调空字典,显示层自会 15s 重试。
// 分钟线从同一响应/附加端点取,降采样到 60 点喂 board 缩略图。

final class RealProvider: QuoteProvider {
    var name: String { "real" }

    private let client = QuoteHTTPClient()
    var cooldownUntil: Date? { client.cooldownUntil }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let cnSide    = entries.filter { $0.market == "cn" || $0.market == "hk" }
        let yahooSide = entries.filter { $0.market != "cn" && $0.market != "hk" }

        var results: [String: Quote] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        if !cnSide.isEmpty {
            group.enter()
            fetchTencent(cnSide) { qs in
                lock.lock(); results.merge(qs) { a, _ in a }; lock.unlock()
                group.leave()
            }
        }
        if !yahooSide.isEmpty {
            group.enter()
            fetchYahoo(yahooSide) { qs in
                lock.lock(); results.merge(qs) { a, _ in a }; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global()) { completion(results) }
    }

    // ── 腾讯(A股/港股) ────────────────────────────────────────────────────────
    // https://qt.gtimg.cn/q=sh600519,sz510300  响应 GBK;
    // 字段:~3 现价,~32 涨跌幅%(港股同族布局,若有出入只影响港股行)。
    // 分钟线走 ifzq 端点,每标的一个附加请求。

    private func fetchTencent(_ entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
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

            // 分钟线:每标的单独取,取不到就让该行没有缩略图
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
                                                sessionStart: session.0, sessionEnd: session.1)
                        }
                        outLock.unlock()
                    }
                    seriesGroup.leave()
                }
            }
            seriesGroup.notify(queue: .global()) { completion(out) }
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
        return (key, Quote(price: px, changePct: pct, series: nil,
                           sessionStart: nil, sessionEnd: nil))
    }

    func tencentCode(_ e: WatchEntry) -> String {
        if e.market == "hk" {
            return "hk" + String(repeating: "0", count: max(0, 5 - e.symbol.count)) + e.symbol
        }
        let sh = e.symbol.hasPrefix("6") || e.symbol.hasPrefix("5") || e.symbol.hasPrefix("9")
        return (sh ? "sh" : "sz") + e.symbol
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

    // ── Yahoo(美股/指数/加密) ─────────────────────────────────────────────────
    // v8 chart 端点,免 crumb。chartPreviousClose = 区间前收盘(1d 即昨收),
    // regularMarketPrice 与之相除得涨跌幅;同一响应的 indicators 即分钟线。

    private func fetchYahoo(_ entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        var out: [String: Quote] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for e in entries {
            group.enter()
            let sym = e.symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e.symbol
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(sym)?interval=1m&range=1d")
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
                if let ts = result["timestamp"] as? [Double],
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
                        let day = pts.filter { $0.t >= st }
                        if day.count > 2 { pts = day }
                    }
                    if pts.count > 2 { series = pts }
                }

                lock.lock()
                out[e.symbol] = Quote(price: px, changePct: (px - prev) / prev * 100,
                                      series: series, sessionStart: sStart, sessionEnd: sEnd)
                lock.unlock()
            }
        }

        group.notify(queue: .global()) { completion(out) }
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
