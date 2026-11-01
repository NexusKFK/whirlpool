import AppKit
import ImageIO
import UniformTypeIdentifiers

// README 持仓看板演示图(docs/img/portfolio-panel*.png):画面就是 app 自己的 PortfolioWindow,
// 喂一份虚构快照(下面 demoJSON 里的持仓、价格、账户号全是编的,与任何真实账户无关)。
// 请求在进程内被 DemoFeeder 拦下,不连网关、不连网络,不录屏。用 tools/make-demo-portfolio.sh 生成。
//
// 左:深色 + 月亮开(实时/盘后口径,盈亏红绿,金额明文);右:浅色 + 月亮关(收盘快照,盈亏灰色,资金打码)。
// 注意:实时那块的页脚和小月亮按运行时刻的美股时段决定;非常规时段运行才会出现「盘后」字样。

final class DemoFeeder: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path.hasSuffix("snapshot.json") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let extended = request.url?.query?.contains("extended=1") == true
        let body = Data((extended ? DemoPortfolio.liveJSON : DemoPortfolio.closeJSON).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct DemoPortfolio {
    // 虚构持仓:三只正股、一组看涨垂直价差、一张看跌期权。数字之间自洽(盈亏=现价与成本之差)。
    static let positions = """
      {"label":"AAPL","kind":"STK","secType":"STK","qty":50,"last":230.0,"mktValue":11500.0,"costBasis":10000.0,
       "unrealized":1500.0,"unrealizedPct":15.0,"dayPnl":100.0},
      {"label":"MSFT","kind":"STK","secType":"STK","qty":20,"last":480.0,"mktValue":9600.0,"costBasis":10000.0,
       "unrealized":-400.0,"unrealizedPct":-4.0,"dayPnl":-60.0},
      {"label":"COST","kind":"STK","secType":"STK","qty":10,"last":990.0,"mktValue":9900.0,"costBasis":9000.0,
       "unrealized":900.0,"unrealizedPct":10.0,"dayPnl":50.0},
      {"label":"AMZN 230/260C 27JAN15","kind":"SPREAD","secType":"OPT","qty":2,"legCount":2,"spreadCount":2,
       "netCost":1600.0,"netMark":2000.0,"unrealized":400.0,"unrealizedPct":25.0,"dayPnl":80.0},
      {"label":"QQQ 540P 26DEC18","kind":"OPT","secType":"OPT","qty":1,"last":9.0,"mktValue":900.0,"costBasis":1200.0,
       "unrealized":-300.0,"unrealizedPct":-25.0,"dayPnl":-40.0}
    """
    static let summary = #"{"NetLiquidation":60000.0,"AvailableFunds":20000.0,"TotalCashValue":18000.0}"#
    static let liveJSON = #"{"connected":true,"time":"2026-10-30T19:30:00-04:00","mode":"live","account":"DU0000000","#
        + #""pnl":{"daily":130.0},"summary":"# + summary + #","positions":["# + positions + "]}"
    static let closeJSON = #"{"connected":true,"time":"2026-10-30T16:00:00-04:00","mode":"close","account":"DU0000000","#
        + #""pnl":{"daily":130.0},"summary":"# + summary + #","positions":["# + positions + "]}"

    /// 一块看板:建窗、喂快照、等它画好,再把内容视图离屏截成位图
    static func panel(dark: Bool, extended: Bool, privacy: Bool) -> NSBitmapImageRep {
        var config = TickerConfig()
        config.positionsExtendedHours = extended
        config.positionsPrivacy = privacy
        let window = PortfolioWindow(config: config)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var done = false
        window.fetch { done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // 首份快照有 0.4 秒的转圈下限(月亮切换才有,这里没有),多跑一会让视图落定
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    struct Side { let dark: Bool; let extended: Bool; let privacy: Bool; let caption: (en: String, zh: String) }

    /// 两块看板并排:各自铺一半壁纸,圆角裁切 + 投影,下方一行说明
    static func compose(language: String) -> CGImage {
        L10n.language = language
        let zh = language == "zh-Hans"
        let sides = [
            Side(dark: true, extended: true, privacy: false,
                 caption: ("Moon on: live quotes, incl. pre-market and after hours", "月亮开：跟实时行情，盘前盘后也更新")),
            Side(dark: false, extended: false, privacy: true,
                 caption: ("Moon off: last regular close · eye hides balances", "月亮关：最近一次收盘快照；眼睛按钮遮住资金")),
        ]
        let reps = sides.map { panel(dark: $0.dark, extended: $0.extended, privacy: $0.privacy) }
        let s = 2.0                                   // 位图是 2 倍像素
        let pad = 40 * s, captionH = 40 * s
        let halfW = reps.map { Double($0.pixelsWide) }.max()! + pad * 2
        let panelH = reps.map { Double($0.pixelsHigh) }.max()!
        let W = Int(halfW * 2), H = Int(pad + panelH + captionH)
        let ctx = makeBitmapContext(pixelsWide: W, pixelsHigh: H)!
        let walls = [NSColor(srgbRed: 0.11, green: 0.13, blue: 0.19, alpha: 1), NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1)]
        let ink = [NSColor(white: 0.92, alpha: 1), NSColor(white: 0.12, alpha: 1)]
        for (i, rep) in reps.enumerated() {
            let x0 = Double(i) * halfW
            ctx.setFillColor(walls[i].cgColor); ctx.fill(CGRect(x: x0, y: 0, width: halfW, height: Double(H)))
            let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
            let r = CGRect(x: x0 + (halfW - w) / 2, y: captionH + (panelH - h), width: w, height: h)
            let path = CGPath(roundedRect: r, cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 24 * s, color: NSColor(white: 0, alpha: sides[i].dark ? 0.55 : 0.22).cgColor)
            ctx.addPath(path); ctx.setFillColor(walls[i].cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.draw(rep.cgImage!, in: r)
            ctx.restoreGState()
            ctx.saveGState(); ctx.addPath(path); ctx.setStrokeColor(NSColor(white: sides[i].dark ? 1 : 0, alpha: 0.10).cgColor)
            ctx.setLineWidth(1 * s); ctx.strokePath(); ctx.restoreGState()
            let text = NSAttributedString(string: zh ? sides[i].caption.zh : sides[i].caption.en, attributes: [
                .font: NSFont.systemFont(ofSize: 13 * s, weight: .medium), .foregroundColor: ink[i].withAlphaComponent(0.8)])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: CGPoint(x: x0 + (halfW - text.size().width) / 2, y: (captionH - text.size().height) / 2 + 2 * s))
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        // 2 倍像素按 144 dpi 标注,GitHub 以 width 属性控制显示大小
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        print(CGImageDestinationFinalize(dest) ? "written \(path) \(image.width)x\(image.height)" : "failed \(path)")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        URLProtocol.registerClass(DemoFeeder.self)
        let dir = CommandLine.arguments[1]
        write(compose(language: "en"), to: dir + "/portfolio-panel.png")
        write(compose(language: "zh-Hans"), to: dir + "/portfolio-panel.zh.png")
    }
}
