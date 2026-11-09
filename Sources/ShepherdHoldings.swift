import Foundation

/// 跟随 Shepherd 持仓的自选池。
/// Shepherd(github.com/NexusKFK/shepherd)把持仓快照写在 ~/tools/holdings_local/state.json,
/// 每条持仓带 sym:正股是自己的代码,期权是正股代码。这里只读代码,不读数量和成本以外的任何东西,
/// 也不把它们写进配置——配置里只落代码、市场和用户隐藏的代码。
enum ShepherdHoldings {
    static let sourceKey = "shepherd"

    /// 快照位置:WHIRLPOOL_SHEPHERD_STATE > $TRADING_SOURCE_HOME/tools/holdings_local/state.json(与 Shepherd 同一规则)> ~
    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["WHIRLPOOL_SHEPHERD_STATE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let home = env["TRADING_SOURCE_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent("tools/holdings_local/state.json")
    }

    /// 一只标的:多条持仓(正股 + 期权、两个券商)按正股合并,weight 是合计市值绝对值,用来排序
    struct Holding: Equatable {
        var symbol: String
        var market: String
        var weight: Double
    }

    struct Snapshot: Equatable {
        var holdings: [Holding]
        var modified: Date?
    }

    enum ReadError: Error, Equatable {
        case missing(String)      // 文件不存在
        case unreadable(String)   // 读不了或不是 Shepherd 快照
    }

    // ── 解析 ────────────────────────────────────────────────────────────────

    /// 解析 Shepherd 快照;不是 {"positions": [...]} 结构时返回 nil
    static func parse(_ data: Data) -> [Holding]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let positions = root["positions"] as? [Any] else { return nil }
        var order: [String] = []
        var merged: [String: Holding] = [:]
        for case let p as [String: Any] in positions {
            guard let raw = p["sym"] as? String,
                  let (symbol, market) = normalize(raw, kind: p["kind"] as? String) else { continue }
            let qty = number(p["qty"]) ?? 0
            guard qty != 0 else { continue }                       // 已平仓残行
            let isOption = (p["kind"] as? String)?.lowercased() == "option"
            let mult = number(p["mult"]) ?? (isOption ? 100 : 1)
            let weight = abs(qty * (number(p["mark"]) ?? 0) * mult)
            if var h = merged[symbol] {
                h.weight += weight.isFinite ? weight : 0
                merged[symbol] = h
            } else {
                merged[symbol] = Holding(symbol: symbol, market: market, weight: weight.isFinite ? weight : 0)
                order.append(symbol)
            }
        }
        // 市值大的在前;一样大(或都没有现价)按快照里的先后
        return order.enumerated()
            .sorted { a, b in
                let wa = merged[a.element]!.weight, wb = merged[b.element]!.weight
                return wa != wb ? wa > wb : a.offset < b.offset
            }
            .map { merged[$0.element]! }
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// 期权/指数代码在行情源里的写法(Yahoo):SPX 期权看 ^GSPC,依此类推
    static let indexAliases: [String: String] = [
        "SPX": "^GSPC", "SPXW": "^GSPC", "XSP": "^GSPC",
        "NDX": "^NDX", "NDXP": "^NDX", "XND": "^NDX",
        "RUT": "^RUT", "MRUT": "^RUT",
        "VIX": "^VIX", "DJX": "^DJI",
    ]

    /// 券商代码 → (Whirlpool 代码, 市场);认不出返回 nil
    static func normalize(_ raw: String, kind: String? = nil) -> (String, String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty else { return nil }
        if let alias = indexAliases[s] { return (alias, "us") }
        // 港股/A 股:带交易所后缀或纯数字
        if s.hasSuffix(".HK") { s = String(s.dropLast(3)) }
        if s.hasSuffix(".SS") || s.hasSuffix(".SZ") || s.hasSuffix(".SH") { s = String(s.dropLast(3)) }
        if s.allSatisfy(\.isNumber) {
            if s.count == 6 { return (s, "cn") }
            if (1...5).contains(s.count) {
                let trimmed = String(s.drop { $0 == "0" })
                return (trimmed.isEmpty ? "0" : trimmed, "hk")
            }
            return nil
        }
        // 期货:/ES、ES(kind=future)→ Yahoo 的 ES=F
        if s.hasPrefix("/") || kind?.lowercased().hasPrefix("fut") == true {
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return s.isEmpty ? nil : (s.hasSuffix("=F") ? s : s + "=F", "us")
        }
        // 分级股:BRK B / BRK/B / BRK-B → BRK.B
        if s.range(of: "^[A-Z]{1,5}[ /-][A-Z]$", options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: "[ /-]", with: ".", options: .regularExpression)
        }
        guard s.range(of: "^[A-Z0-9^][A-Z0-9.^=_-]{0,31}$", options: .regularExpression) != nil else { return nil }
        return (s, "us")
    }

    // ── 生成自选条目 ─────────────────────────────────────────────────────────

    /// 持仓 → 自选条目:去掉用户隐藏的,保留用户给每只设过的小数位
    static func entries(from holdings: [Holding], excluded: [String], previous: [WatchEntry]) -> [WatchEntry] {
        let hidden = Set(excluded.map { $0.uppercased() })
        let decimals = Dictionary(previous.map { ($0.symbol, $0.decimals) }, uniquingKeysWith: { a, _ in a })
        return holdings.filter { !hidden.contains($0.symbol) }.map {
            WatchEntry(symbol: $0.symbol, market: $0.market, decimals: decimals[$0.symbol] ?? nil)
        }
    }

    static func read(_ url: URL = defaultURL) -> Result<Snapshot, ReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing(url.path)) }
        guard let data = try? Data(contentsOf: url), let holdings = parse(data) else {
            return .failure(.unreadable(url.path))
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return .success(Snapshot(holdings: holdings, modified: modified))
    }

    static func modified(_ url: URL = defaultURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 把快照套到全部跟随池上;返回是否有池子变了
    @discardableResult
    static func apply(_ holdings: [Holding], to lists: inout [Watchlist]) -> Bool {
        var changed = false
        for i in lists.indices where lists[i].source == sourceKey {
            let next = entries(from: holdings, excluded: lists[i].excluded ?? [], previous: lists[i].entries)
            if next != lists[i].entries { lists[i].entries = next; changed = true }
        }
        return changed
    }
}
