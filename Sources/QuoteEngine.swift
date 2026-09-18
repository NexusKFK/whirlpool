import Foundation

struct Quote {
    let price: Double
    let changePct: Double
    let series: [Double]?   // 当日分钟线(降采样后),board 缩略图用
}

// Board 模式一行的展示数据(market 随行,配色习惯到渲染层再定)
struct BoardRow {
    let symbol: String
    let price: String
    let change: String   // 带符号带 %
    let up: Bool
    let market: String
    let series: [Double]?
}

protocol QuoteProvider {
    var name: String { get }
    /// 拉一轮行情,任意线程回调;空字典 = 本轮放弃(显示层保持 idle)。
    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void)
}

enum QuoteEngine {

    static func provider(for key: String) -> QuoteProvider {
        key == "real" ? RealProvider() : DemoProvider()
    }

    /// 拼跑马灯文本。基底色由配置给(默认白),只有涨跌幅段着色,完事 \c[] 复位。
    /// pausePerSymbol > 0 时在每个标的前埋 \p 暂停标记,标的滚到左缘停留 N 秒。
    static func marqueeText(entries: [WatchEntry], quotes: [String: Quote],
                            redUpMarkets: [String], pausePerSymbol: Double,
                            separator: String = " ♦ ") -> String {
        let parts = entries.compactMap { e -> String? in
            guard let q = quotes[e.symbol] else { return nil }
            let up    = q.changePct >= 0
            let redUp = redUpMarkets.contains(e.market)
            let color = up ? (redUp ? "red" : "green") : (redUp ? "green" : "red")
            let sign  = up ? "+" : ""
            let price = q.price >= 1000 ? String(format: "%.1f", q.price)
                                        : String(format: "%.2f", q.price)
            let pause = pausePerSymbol > 0 ? "\\p[\(pausePerSymbol)]" : ""
            return "\(pause)\(e.symbol) \(price) \\c[\(color)]\(sign)\(String(format: "%.2f", q.changePct))%\\c[]"
        }
        return parts.joined(separator: separator)
    }

    static func boardRows(entries: [WatchEntry], quotes: [String: Quote]) -> [BoardRow] {
        entries.compactMap { e in
            guard let q = quotes[e.symbol] else { return nil }
            let price  = q.price >= 1000 ? String(format: "%.1f", q.price)
                                         : String(format: "%.2f", q.price)
            let change = String(format: "%@%.2f%%", q.changePct >= 0 ? "+" : "", q.changePct)
            return BoardRow(symbol: e.symbol, price: price, change: change,
                            up: q.changePct >= 0, market: e.market, series: q.series)
        }
    }
}

// 演示源:本地随机游走,无网络。首轮种子数字仅为了让屏幕上有东西滚。
final class DemoProvider: QuoteProvider {
    var name: String { "demo" }

    private var last: [String: Quote] = [
        "AAPL":   Quote(price: 228.90,  changePct: 0.82,  series: DemoProvider.walk(228.90, 40)),
        "SPY":    Quote(price: 566.40,  changePct: -0.31, series: DemoProvider.walk(566.40, 40)),
        "600519": Quote(price: 1487.00, changePct: 1.24,  series: DemoProvider.walk(1487.00, 40)),
        "510300": Quote(price: 3.94,    changePct: -0.51, series: DemoProvider.walk(3.94, 40)),
    ]

    private static func walk(_ end: Double, _ n: Int) -> [Double] {
        // 从 end 倒着随机游走出一条演示曲线
        var pts: [Double] = [end]
        for _ in 1..<n { pts.append(pts.last! * (1 + Double.random(in: -0.002...0.002))) }
        return pts.reversed()
    }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        var out: [String: Quote] = [:]
        for e in entries {
            let base  = last[e.symbol] ?? Quote(price: 100, changePct: 0, series: nil)
            let drift = Double.random(in: -0.6...0.6)
            var series = base.series ?? []
            series.append(max(0.01, (series.last ?? base.price) * (1 + drift / 400)))
            if series.count > 60 { series.removeFirst(series.count - 60) }
            out[e.symbol] = Quote(
                price:     max(0.01, base.price * (1 + drift / 400)),
                changePct: min(9.99, max(-9.99, base.changePct + drift / 3)),
                series:    series
            )
        }
        last = out
        completion(out)
    }
}
