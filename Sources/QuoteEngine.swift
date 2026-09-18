import Foundation

// 分钟线点:t 是时间锚(单位随源,epoch 或当日秒数),v 是价格
struct SeriesPt {
    let t: Double
    let v: Double
}

struct Quote {
    let price: Double
    let changePct: Double
    let series: [SeriesPt]?      // 当日分钟线,board 缩略图用
    let sessionStart: Double?    // 当天时段起(t 同单位)
    let sessionEnd: Double?
}

// Board 模式一行的展示数据(market 随行,配色习惯到渲染层再定)
struct BoardRow {
    let symbol: String
    let price: String
    let change: String   // 带符号带 %
    let up: Bool
    let flat: Bool       // 0.00 平盘:白色 + 一道杠
    let market: String
    let series: [SeriesPt]?
}

protocol QuoteProvider {
    var name: String { get }
    var cooldownUntil: Date? { get }
    /// 拉一轮行情,任意线程回调;空字典 = 本轮放弃(显示层保持 idle)。
    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void)
}

extension QuoteProvider { var cooldownUntil: Date? { nil } }

enum QuoteEngine {

    static func provider(for key: String) -> QuoteProvider {
        key == "real" ? RealProvider() : DemoProvider()
    }

    /// 拼跑马灯文本。基底色由配置给(默认白),只有涨跌幅段着色,完事 \c[] 复位。
    /// 平盘(|Δ|<0.005):不着色(随基底白),箭头位是一道杠。
    /// 价格按上一笔报价决定闪色,从最高变化位到末尾连续着色;涨跌幅保持当日方向色。
    static func marqueeText(entries: [WatchEntry], quotes: [String: Quote],
                            redUpMarkets: [String], pausePerSymbol: Double,
                            separator: String = "   ", changeArrows: Bool = true,
                            blinkChanged: Bool = true,
                            previousTicks: [String: Double] = [:]) -> String {
        var parts: [String] = []
        for e in entries {
            guard let q = quotes[e.symbol] else { continue }
            let up    = q.changePct >= 0
            let flat  = abs(q.changePct) < 0.005
            let redUp = redUpMarkets.contains(e.market)
            let color = up ? (redUp ? "red" : "green") : (redUp ? "green" : "red")
            var price = PriceFlash.priceText(q.price)
            if blinkChanged, let flash = PriceFlash.between(previousTicks[e.symbol], and: q.price, redUp: redUp) {
                price = "\(flash.prefix)\\b[1:\(flash.color.rawValue)]\(flash.suffix)\\b[0]"
            }
            let change = flat
                ? "-0.00%"
                : changeArrows
                    ? "\(up ? "▲" : "▼")\(String(format: "%.2f", abs(q.changePct)))%"
                    : "\(up ? "+" : "")\(String(format: "%.2f", q.changePct))%"
            let pause = pausePerSymbol > 0 ? "\\p[\(pausePerSymbol)]" : ""
            let core = "\(price) \(flat ? change : "\\c[\(color)]\(change)\\c[]")"   // 价格与涨跌段之间留一个空格
            parts.append("\(pause)\(e.symbol) \(core)")
        }
        // 串尾补一份空隙:环绕接缝处同宽,否则 % 会粘住下一个 ticker
        return parts.joined(separator: separator) + separator
    }

    static func boardRows(entries: [WatchEntry], quotes: [String: Quote],
                          changeArrows: Bool = true) -> [BoardRow] {
        entries.compactMap { e in
            guard let q = quotes[e.symbol] else { return nil }
            let price = PriceFlash.priceText(q.price)
            let up   = q.changePct >= 0
            let flat = abs(q.changePct) < 0.005
            let change = flat
                ? "-0.00%"
                : changeArrows
                    ? "\(up ? "▲" : "▼")\(String(format: "%.2f", abs(q.changePct)))%"
                    : "\(up ? "+" : "")\(String(format: "%.2f", q.changePct))%"
            return BoardRow(symbol: e.symbol, price: price, change: change,
                            up: up, flat: flat, market: e.market, series: q.series)
        }
    }
}

// 演示源:本地随机游走,无网络。首轮种子数字仅为了让屏幕上有东西滚。
final class DemoProvider: QuoteProvider {
    var name: String { "demo" }

    private var last: [String: Quote] = [
        "AAPL":   Quote(price: 228.90,  changePct: 0.82,  series: DemoProvider.walk(228.90, 40),  sessionStart: 0, sessionEnd: 1),
        "SPY":    Quote(price: 566.40,  changePct: -0.31, series: DemoProvider.walk(566.40, 40),  sessionStart: 0, sessionEnd: 1),
        "600519": Quote(price: 1487.00, changePct: 1.24,  series: DemoProvider.walk(1487.00, 40), sessionStart: 0, sessionEnd: 1),
        "510300": Quote(price: 3.94,    changePct: -0.51, series: DemoProvider.walk(3.94, 40),    sessionStart: 0, sessionEnd: 1),
    ]

    private static func walk(_ end: Double, _ n: Int) -> [SeriesPt] {
        // 从 end 倒着随机游走,时间铺在"当天"前 15% —— 像刚开盘的样子
        var vals: [Double] = [end]
        for _ in 1..<n { vals.append(vals.last! * (1 + Double.random(in: -0.002...0.002))) }
        return vals.reversed().enumerated().map { SeriesPt(t: Double($0.offset) / Double(n - 1) * 0.15, v: $0.element) }
    }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        var out: [String: Quote] = [:]
        for e in entries {
            let base  = last[e.symbol] ?? Quote(price: 100, changePct: 0, series: nil,
                                                sessionStart: 0, sessionEnd: 1)
            let drift = Double.random(in: -0.6...0.6)
            var series = base.series ?? []
            let lastT = series.last?.t ?? 0
            series.append(SeriesPt(t: min(0.95, lastT + 0.15 / 40),
                                   v: max(0.01, (series.last?.v ?? base.price) * (1 + drift / 400))))
            if series.count > 60 { series.removeFirst(series.count - 60) }
            out[e.symbol] = Quote(
                price:     max(0.01, base.price * (1 + drift / 400)),
                changePct: min(9.99, max(-9.99, base.changePct + drift / 3)),
                series:    series,
                sessionStart: 0, sessionEnd: 1
            )
        }
        last = out
        completion(out)
    }
}
