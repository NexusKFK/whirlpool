import Foundation

// 真实行情源,免 key 双链:
//   美股/指数/加密  Yahoo 公开 chart 端点(yfinance 同源,Swift 原生调用)
//   A股/港股        腾讯 qt.gtimg.cn 实时链(GBK)+ ifzq 分钟线端点
// 任一腿失败不影响另一腿;全部失败回调空字典,显示层自会 15s 重试。
// 分钟线从同一响应/附加端点取,降采样到 60 点喂 board 缩略图。

final class RealProvider: QuoteProvider {
    var name: String { "real" }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        return URLSession(configuration: cfg)
    }()

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
        let codeToSymbol = Dictionary(uniqueKeysWithValues: entries.map { (tencentCode($0), $0.symbol) })
        let codes = codeToSymbol.keys.joined(separator: ",")
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(codes)") else {
            completion([:]); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, resp, _ in
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
                seriesGroup.enter()
                self.fetchTencentSeries(code: code) { series in
                    if let series {
                        outLock.lock()
                        if let q = out[symbol] {
                            out[symbol] = Quote(price: q.price, changePct: q.changePct, series: series)
                        }
                        outLock.unlock()
                    }
                    seriesGroup.leave()
                }
            }
            seriesGroup.notify(queue: .global()) { completion(out) }
        }.resume()
    }

    /// 返回 (腾讯代码 如 "sh600519", 报价)
    private func parseTencentLine(_ line: String) -> (String, Quote)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).replacingOccurrences(of: "v_", with: "")
        let inner = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        let parts = inner.components(separatedBy: "~")
        guard parts.count > 32,
              let px = Double(parts[3]),
              let pct = Double(parts[32])
        else { return nil }
        return (key, Quote(price: px, changePct: pct, series: nil))
    }

    private func tencentCode(_ e: WatchEntry) -> String {
        if e.market == "hk" {
            return "hk" + e.symbol.padding(toLength: 5, withPad: "0", startingAt: 0)
        }
        let sh = e.symbol.hasPrefix("6") || e.symbol.hasPrefix("5") || e.symbol.hasPrefix("9")
        return (sh ? "sh" : "sz") + e.symbol
    }

    /// https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519
    /// data.<code>.data.data = ["0930 1250.00 1249.00 123", …](时间 价格 均价 量)
    private func fetchTencentSeries(code: String, completion: @escaping ([Double]?) -> Void) {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(code)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, resp, _ in
            guard let data, self.httpOK(resp),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataNode = obj["data"] as? [String: Any],
                  let codeNode = dataNode[code] as? [String: Any],
                  let inner = codeNode["data"] as? [String: Any],
                  let lines = inner["data"] as? [String]
            else { completion(nil); return }
            let pts = lines.compactMap { l -> Double? in
                let f = l.components(separatedBy: " ")
                return f.count > 1 ? Double(f[1]) : nil
            }
            completion(pts.count > 2 ? Self.downsample(Array(pts.suffix(240)), to: 60) : nil)
        }.resume()
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
            session.dataTask(with: req) { data, resp, _ in
                defer { group.leave() }
                guard let data, self.httpOK(resp),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chart = obj["chart"] as? [String: Any],
                      let result = (chart["result"] as? [[String: Any]])?.first,
                      let meta = result["meta"] as? [String: Any],
                      let px = meta["regularMarketPrice"] as? Double,
                      let prev = meta["chartPreviousClose"] as? Double,
                      prev != 0
                else { return }

                var series: [Double]? = nil
                if let indicators = result["indicators"] as? [String: Any],
                   let quoteArr = (indicators["quote"] as? [[String: Any]])?.first,
                   let raw = quoteArr["close"] as? [Any] {
                    var closes = raw.compactMap { $0 as? Double }
                    // 只保留当天:盘前/隔夜时 range=1d 会整段返回上一交易日,
                    // 用当日常规时段开盘时间戳截掉更早的 bar
                    if let ts = result["timestamp"] as? [Double],
                       ts.count == closes.count,
                       let period = meta["currentTradingPeriod"] as? [String: Any],
                       let regular = period["regular"] as? [String: Any],
                       let dayStart = regular["start"] as? Double {
                        let dayCloses = zip(ts, closes).filter { $0.0 >= dayStart }.map(\.1)
                        if dayCloses.count > 2 { closes = dayCloses }
                    }
                    if closes.count > 2 {
                        series = Self.downsample(Array(closes.suffix(240)), to: 60)
                    }
                }

                lock.lock()
                out[e.symbol] = Quote(price: px, changePct: (px - prev) / prev * 100, series: series)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global()) { completion(out) }
    }

    /// 等距抽点,保留首尾形状
    static func downsample(_ a: [Double], to n: Int) -> [Double] {
        guard a.count > n, n > 1 else { return a }
        let step = Double(a.count - 1) / Double(n - 1)
        return (0..<n).map { a[Int((Double($0) * step).rounded())] }
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
