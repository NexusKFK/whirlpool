import AppKit

// GPU 跑马灯(1.8)回归:条带像素与旧逐帧渲染一致、闪变时机与旧判据一致、
// 明暗配色对比度、配置迁移、交易时段、图表链接、时间线引擎推进。

private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if !condition { fatalError("FAIL line \(line): \(message())") }
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    guard let ctx = makeBitmapContext(pixelsWide: image.width, pixelsHigh: image.height), let data = ctx.data else {
        return (0, 0, 0, 0)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    let i = (y * image.width + x) * 4
    return (p[i], p[i + 1], p[i + 2], p[i + 3])
}

private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

private func contrast(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

func runGPUMarqueeTests() throws {
    // 1) 闪变触发列 = 旧 ScrollFlashes 逐列模拟的第一次触发列
    for (group, w, v) in [(10..<14, 200, 60), (2..<5, 200, 60), (190..<198, 200, 60),
                          (10..<100, 120, 30), (50..<58, 40, 90), (0..<3, 300, 120)] {
        var flashes = ScrollFlashes(columns: Dictionary(uniqueKeysWithValues: group.map { ($0, LEDColor.green) }))
        var first: Int?
        for off in 0...w where first == nil {
            if !flashes.colors(offset: off, visibleColumns: v, roundLength: w, now: Double(off) * 10).isEmpty { first = off }
        }
        let predicted = MarqueeEngine.flashStartCol(group, roundLength: w, viewport: v)
        check(predicted.map { Int($0.rounded(.up)) } == first,
              "flash start \(group) W=\(w) V=\(v): predicted \(String(describing: predicted)) legacy \(String(describing: first))")
    }
    print("PASS: GPU flash timing matches the legacy per-column readability rule")

    // 2) LED 条带与旧逐帧渲染逐点一致(暗底彩色透明、2x)
    let text = QuoteEngine.marqueeText(
        entries: [WatchEntry(symbol: "TLT", market: "us"), WatchEntry(symbol: "SPY", market: "us")],
        quotes: ["TLT": Quote(price: 81.30, changePct: -0.59, series: nil, sessionStart: nil, sessionEnd: nil),
                 "SPY": Quote(price: 675.10, changePct: 0.42, series: nil, sessionStart: nil, sessionEnd: nil)],
        redUpMarkets: [], pausePerSymbol: 0, previousTicks: ["TLT": 81.20])
    let stream = buildScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
    let style = LEDStyle(tone: .dark, mono: false, panel: false)
    let art = makeLEDArt(stream: stream, dot: 2, style: style, scale: 2)
    check(art.totalCols == stream.columns.count && art.width == CGFloat(stream.columns.count * 3), "strip geometry")
    let legacy = renderScrollFrame(columns: stream.columns, offset: 0, displayWidth: 30, dot: 2, style: style, scale: 2)
    let legacyCG = try unwrapCG(legacy.cgImageForLayer(scale: 2))
    let tile = art.tiles[0].image
    for column in edgeFadeCols..<min(stream.columns.count, 30 * 6 - edgeFadeCols) {
        for bit in 0..<8 {
            let on = stream.columns[column].value & (1 << bit) != 0
            let sx = column * 3 * 2, sy = (3 + bit * 3) * 2
            let a = pixel(tile, x: sx, y: sy)
            let b = pixel(legacyCG, x: sx + paddingH * 2, y: sy)
            check(on == (a.a == 255), "strip dot presence col \(column) bit \(bit)")
            if on { check(a.r == b.r && a.g == b.g && a.b == b.b, "strip dot color col \(column) bit \(bit): \(a) vs \(b)") }
        }
    }
    // 叠层只含闪变列、闪现色、点位与底图重合
    check(art.flashes.count == flashGroups(stream.blinkCols).count && !art.flashes.isEmpty, "flash overlay count")
    for flash in art.flashes {
        let expected = style.packed(flash.color)
        for (i, column) in flash.cols.enumerated() {
            for bit in 0..<8 where stream.columns[column].value & (1 << bit) != 0 {
                let p = pixel(flash.tile.image, x: i * 3 * 2, y: (3 + bit * 3) * 2)
                let packed = UInt32(p.r) | UInt32(p.g) << 8 | UInt32(p.b) << 16 | UInt32(p.a) << 24
                check(packed == expected, "flash overlay pixel col \(column)")
            }
        }
    }
    let mono = makeLEDArt(stream: stream, dot: 2, style: LEDStyle(tone: .light, mono: true), scale: 2)
    check(mono.flashes.isEmpty, "monochrome has no color flashes")
    print("PASS: LED GPU strip matches legacy frame pixels; overlays cover only changed digits")

    // 3) 文本条带:宽度对齐 3pt 虚拟列,叠层落在串内
    let textStream = buildTextScrollStream(text: "SPY 675.10 \\c[green]▲0.42%\\c[]   TLT 8\\b[1:red]1.30\\b[0]   ",
                                           defaultColor: .white, onClickCommand: nil)
    let strip = TextStrip(stream: textStream, font: .monospacedDigitSystemFont(ofSize: 14, weight: .regular),
                          defaultColor: .white, style: LEDStyle(tone: .light))
    let textArt = strip.makeArt(scale: 2)
    check(textArt.width == CGFloat(textArt.totalCols) * 3, "text strip width aligned to virtual columns")
    check(textArt.flashes.count == 1, "one text flash overlay")
    if let f = textArt.flashes.first {
        check(f.tile.x >= 0 && f.tile.x + f.tile.width <= textArt.width + 0.5, "text overlay inside strip")
        check(f.tile.image.width > 0, "text overlay rendered")
    }
    print("PASS: text GPU strip geometry and flash overlay")

    // 4) 明暗配色:亮底中性色与涨跌色对白底 ≥3:1,暗底对黑底 ≥3:1
    let white = (r: 1.0, g: 1.0, b: 1.0), black = (r: 0.0, g: 0.0, b: 0.0)
    for c in [LEDColor.white, .green, .red, .amber] {
        check(contrast(LEDStyle(tone: .light).rgb(c), white) >= 3, "light \(c) contrast \(contrast(LEDStyle(tone: .light).rgb(c), white))")
        check(contrast(LEDStyle(tone: .dark).rgb(c), black) >= 3, "dark \(c) contrast")
    }
    check(LEDStyle(tone: .light, panel: true).rgb(.white) == (1, 1, 1), "panel ignores light tone")
    check(LEDStyle(tone: .light, mono: true).rgb(.red) == LEDStyle(tone: .light).rgb(.white), "mono collapses colors")
    print("PASS: adaptive palette contrast in light and dark")

    // 5) 配置迁移:旧 auto→mono,white/black→adaptive,新字段有默认值
    for (old, new) in [("auto", "mono"), ("white", "adaptive"), ("black", "adaptive"), ("amber", "amber"), ("green", "green"), ("bogus", "adaptive")] {
        let cfg = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"transparentColor\":\"\(old)\"}".utf8))
        check(cfg.transparentColor == new, "scheme migration \(old) → \(cfg.transparentColor)")
    }
    let defaults = try JSONDecoder().decode(TickerConfig.self, from: Data("{}".utf8))
    check(defaults.barBackground == "glass" && defaults.hoverPause && defaults.smartRefresh, "new field defaults")
    print("PASS: appearance scheme migration and new defaults")

    // 6) 交易时段
    func date(_ s: String, _ zone: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    let spy = WatchEntry(symbol: "SPY", market: "us"), moutai = WatchEntry(symbol: "600519", market: "cn")
    let tencent = WatchEntry(symbol: "700", market: "hk"), btc = WatchEntry(symbol: "BTC-USD", market: "crypto")
    check(MarketClock.isOpen(spy, at: date("2026-09-18 10:00", "America/New_York")), "US open Friday 10:00")
    check(!MarketClock.isOpen(spy, at: date("2026-09-19 10:00", "America/New_York")), "US closed Saturday")
    check(!MarketClock.isOpen(spy, at: date("2026-09-18 16:30", "America/New_York")), "US closed after 16:05")
    check(MarketClock.isOpen(moutai, at: date("2026-09-18 10:00", "Asia/Shanghai")), "CN open 10:00")
    check(!MarketClock.isOpen(moutai, at: date("2026-09-18 12:00", "Asia/Shanghai")), "CN lunch break")
    check(MarketClock.isOpen(tencent, at: date("2026-09-18 15:30", "Asia/Hong_Kong")), "HK open 15:30")
    check(MarketClock.isOpen(btc, at: date("2026-09-19 03:00", "UTC")), "crypto always open")
    check(MarketClock.isOpen(WatchEntry(symbol: "ES=F", market: "us"), at: date("2026-09-18 20:00", "America/New_York")), "futures treated as open")
    let saturday = date("2026-09-19 12:00", "America/New_York")
    check(MarketClock.nextOpen(spy, after: saturday) == date("2026-09-21 09:25", "America/New_York"), "next US open Monday")
    check(MarketClock.refreshInterval([spy, moutai], base: 30, now: saturday) == 1800, "weekend backs off to 30 min")
    check(MarketClock.refreshInterval([spy, btc], base: 30, now: saturday) == 30, "crypto keeps base cadence")
    let beforeOpen = date("2026-09-21 09:20", "America/New_York")
    check(MarketClock.refreshInterval([spy], base: 30, now: beforeOpen) == 305, "resumes right at the open")
    print("PASS: market sessions, next open and smart refresh cadence")

    // 7) 图表链接
    check(chartURL(for: spy)?.absoluteString == "https://www.tradingview.com/chart/?symbol=SPY", "US chart")
    check(chartURL(for: moutai)?.absoluteString == "https://www.tradingview.com/chart/?symbol=SSE:600519", "CN chart")
    check(chartURL(for: WatchEntry(symbol: "000001", market: "cn"))?.absoluteString.hasSuffix("SZSE:000001") == true, "SZ chart")
    check(chartURL(for: WatchEntry(symbol: "00700", market: "hk"))?.absoluteString.hasSuffix("HKEX:700") == true, "HK chart")
    check(chartURL(for: WatchEntry(symbol: "^GSPC", market: "us"))?.absoluteString.hasSuffix("SP:SPX") == true, "index chart")
    check(chartURL(for: btc)?.host == "finance.yahoo.com", "crypto chart via Yahoo")
    check(chartURL(for: WatchEntry(symbol: "SH000001", market: "cn"))?.absoluteString == "https://www.tradingview.com/chart/?symbol=SSE:000001",
          "an exchange prefix picks the SSE Composite chart")
    check(chartURL(for: WatchEntry(symbol: "430047", market: "cn"))?.absoluteString == "https://gu.qq.com/bj430047",
          "Beijing codes open Tencent's quote page")
    print("PASS: chart links")

    // 8) 时间线引擎:滚完一轮自动接下一条、轮内定时暂停生效、预取只发一次
    let engine = MarqueeEngine()
    let view = MarqueeView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    var needs = 0
    engine.surfaces = { [view] }
    engine.viewportCols = { _ in 60 }
    engine.viewportWidth = { _ in 180 }
    engine.colsPerSecond = 2000
    engine.loopsQuotes = { true }
    engine.onNeedsQuotes = { needs += 1 }
    engine.buildRound = { msg in
        let s = buildScrollStream(text: msg.text, defaultColor: .white, onClickCommand: nil)
        return MarqueeRound(totalCols: s.columns.count, pauses: s.pauses, flashes: flashGroups(s.blinkCols)) { _ in
            makeLEDArt(stream: s, dot: 2, style: LEDStyle(), scale: 2)
        }
    }
    var first = TickerMessage(kind: .scroll, text: "AAPL 228.90 \\p[0.05]SPY 566.40   ", priority: .normal,
                              duration: 0, onClickCommand: nil, width: nil)
    first.isQuoteCycle = true
    let started = Date()
    engine.enqueue(first)
    check(engine.phase == .scrolling, "engine starts scrolling")
    var sawPause = false
    var second = TickerMessage(kind: .scroll, text: "QQQ 500.00   ", priority: .normal,
                               duration: 0, onClickCommand: nil, width: nil)
    second.isQuoteCycle = true
    engine.enqueue(second)
    while engine.current?.text != second.text, Date().timeIntervalSince(started) < 3 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        if engine.phase == .paused { sawPause = true }
    }
    check(engine.current?.text == second.text, "advanced to the queued round")
    check(sawPause, "timed in-stream pause observed")
    check(Date().timeIntervalSince(started) >= 0.05, "pause held for its duration")
    check(needs >= 1, "prefetch requested quotes")
    // 队列空了:行情轮原样重播,不停下
    while engine.queueCount == 0, Date().timeIntervalSince(started) < 3, engine.phase != .idle {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        if needs >= 3 { break }
    }
    check(engine.phase == .scrolling && engine.current?.text == second.text, "starved quote round replays instead of freezing")
    engine.hold()
    let heldAt = engine.currentCol
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(engine.currentCol == heldAt, "hover hold stops motion")
    engine.resume()
    engine.stop()
    check(engine.phase == .idle && engine.queueCount == 0, "stop clears the engine")
    engine.loopsQuotes = { false }
    engine.enqueue(TickerMessage(kind: .standby, text: "WAIT", priority: .normal,
                                duration: 0.02, onClickCommand: nil, width: nil))
    engine.enqueue(TickerMessage(kind: .scroll, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil))
    engine.colsPerSecond = 1
    engine.enqueue(second)
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    check(engine.current?.text == second.text && engine.phase == .scrolling,
          "an empty queued message must not stall all subsequent messages")
    engine.stop()
    // A hover can begin before data arrives, and must survive an interrupt / standby banner.
    engine.hold()
    engine.enqueue(second)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    check(engine.currentCol == 0, "hover before data arrives holds the next round")
    engine.interrupt(with: first)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    check(engine.currentCol == 0, "urgent messages preserve hover pause")
    engine.interrupt(with: TickerMessage(kind: .standby, text: "WAIT", priority: .normal,
                                       duration: 0.02, onClickCommand: nil, width: nil))
    engine.enqueue(second)
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    check(engine.phase == .scrolling && engine.currentCol == 0, "hover survives a standby banner")
    engine.resume()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    check(engine.currentCol > 0, "leaving the ticker resumes the held message")
    engine.stop()
    engine.defaultPause = 0.3
    engine.enqueue(second)
    check(engine.phase == .paused, "round begins with a timed pause")
    engine.hold()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    engine.resume()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    check(engine.phase == .paused, "hover does not discard the remaining timed pause")
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    check(engine.phase == .scrolling && engine.currentCol > 0, "timed pause completes after hover ends")
    engine.stop()
    print("PASS: timeline engine advances rounds, honors pauses, prefetches and replays when starved")
}

private func unwrapCG(_ image: CGImage?) throws -> CGImage {
    guard let image else { fatalError("missing image") }
    return image
}
