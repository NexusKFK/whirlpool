import Foundation

// 真实行情源,免 key 双链:
//   美股/指数/加密  Yahoo 公开 chart 端点(yfinance 同源,Swift 原生调用)
//   A股/港股        腾讯 qt.gtimg.cn 实时链(GBK)
// 任一腿失败不影响另一腿;全部失败回调空字典,显示层自会 15s 重试。

final class RealProvider: QuoteProvider {
    var name: String { "real" }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        return URLSession(configuration: cfg)
    }()

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        let cnSide   = entries.filter { $0.market == "cn" || $0.market == "hk" }
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
            completion(out)
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
        return (key, Quote(price: px, changePct: pct))
    }

    private func tencentCode(_ e: WatchEntry) -> String {
        if e.market == "hk" {
            return "hk" + e.symbol.padding(toLength: 5, withPad: "0", startingAt: 0)
        }
        let sh = e.symbol.hasPrefix("6") || e.symbol.hasPrefix("5") || e.symbol.hasPrefix("9")
        return (sh ? "sh" : "sz") + e.symbol
    }

    // ── Yahoo(美股/指数/加密) ─────────────────────────────────────────────────
    // v8 chart 端点,免 crumb。chartPreviousClose = 区间前收盘(1d 即昨收),
    // regularMarketPrice 与之相除得涨跌幅。yfinance 间歇被限流的坑在这腿上,
    // 失败回空交给上层重试。

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
                lock.lock()
                out[e.symbol] = Quote(price: px, changePct: (px - prev) / prev * 100)
                lock.unlock()
            }.resume()
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
