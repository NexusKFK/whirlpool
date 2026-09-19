import AppKit
import ImageIO
import UniformTypeIdentifiers

// README 演示动图(docs/img/whirlpool-demo.gif):画面元素全部来自 app 自己的渲染代码
// (LED/文本条带、像素字、分时线),演示数据,不录屏、不含任何个人信息。用 tools/make-demo-gif.sh 生成。
@main
struct DemoGIF {
    static let W = 960, H = 300, fps = 25.0, sceneSeconds = 4.8

    static let entries = [WatchEntry(symbol: "SPY", market: "us"), WatchEntry(symbol: "QQQ", market: "us"),
                          WatchEntry(symbol: "AAPL", market: "us"), WatchEntry(symbol: "NVDA", market: "us"),
                          WatchEntry(symbol: "600519", market: "cn"), WatchEntry(symbol: "700", market: "hk"),
                          WatchEntry(symbol: "BTC-USD", market: "crypto")]
    static func walk(_ start: Double, _ drift: Double, _ n: Int = 60) -> [SeriesPt] {
        var v = start; var out: [SeriesPt] = []
        for i in 0..<n { v *= 1 + drift / Double(n) + sin(Double(i) * 0.7) * 0.0012; out.append(SeriesPt(t: Double(i), v: v)) }
        return out
    }
    static let quotes: [String: Quote] = [
        "SPY": Quote(price: 761.69, changePct: 0.13, series: walk(760.7, 0.0015), sessionStart: 0, sessionEnd: 80),
        "QQQ": Quote(price: 612.40, changePct: -0.42, series: walk(615.0, -0.004), sessionStart: 0, sessionEnd: 80),
        "AAPL": Quote(price: 238.55, changePct: 1.02, series: walk(236.1, 0.01), sessionStart: 0, sessionEnd: 80),
        "NVDA": Quote(price: 176.30, changePct: -0.85, series: walk(177.8, -0.008), sessionStart: 0, sessionEnd: 80),
        "600519": Quote(price: 1257.12, changePct: -0.78, series: nil, sessionStart: nil, sessionEnd: nil),
        "700": Quote(price: 419.00, changePct: -1.64, series: nil, sessionStart: nil, sessionEnd: nil),
        "BTC-USD": Quote(price: 81228.61, changePct: 2.10, series: nil, sessionStart: nil, sessionEnd: nil),
    ]
    static let previous: [String: Double] = ["SPY": 761.52, "QQQ": 612.55, "AAPL": 238.41, "BTC-USD": 81230.02]

    struct Scene { let tone: Tone; let wallpaper: NSColor; let menuBar: NSColor; let menuText: NSColor; let placeholder: NSColor
                   let glass: NSColor; let glassBorder: NSColor; let card: NSColor; let cardBorder: NSColor; let caption: String }

    static func context(_ w: Int, _ h: Int) -> CGContext { makeBitmapContext(pixelsWide: w, pixelsHigh: h)! }

    /// 条带在视口里按偏移平铺 + 闪变叠层 + 两缘渐隐(与 MarqueeView 同一套几何)
    static func viewport(_ art: StripArt, width: Int, offset: Double, flashes: Set<Int>) -> CGImage {
        let h = Int(art.height)
        let ctx = context(width, h)
        let shift = CGFloat(offset) * art.pitch
        var base = -shift.truncatingRemainder(dividingBy: art.width)
        if base > 0 { base -= art.width }
        while base < CGFloat(width) {
            for tile in art.tiles { ctx.draw(tile.image, in: CGRect(x: base + tile.x, y: 0, width: tile.width, height: art.height)) }
            for (i, f) in art.flashes.enumerated() where flashes.contains(i) {
                ctx.draw(f.tile.image, in: CGRect(x: base + f.tile.x, y: 0, width: f.tile.width, height: art.height))
            }
            base += art.width
        }
        let fade = min(art.fadeWidth, CGFloat(width) / 3)
        ctx.setBlendMode(.destinationOut)
        let space = CGColorSpaceCreateDeviceGray()
        let opaque = CGColor(gray: 0, alpha: 1), clear = CGColor(gray: 0, alpha: 0)
        let left = CGGradient(colorsSpace: space, colors: [opaque, clear] as CFArray, locations: [0, 1])!
        let right = CGGradient(colorsSpace: space, colors: [clear, opaque] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: fade, height: CGFloat(h)))
        ctx.drawLinearGradient(left, start: .zero, end: CGPoint(x: fade, y: 0), options: []); ctx.restoreGState()
        ctx.saveGState(); ctx.clip(to: CGRect(x: CGFloat(width) - fade, y: 0, width: fade, height: CGFloat(h)))
        ctx.drawLinearGradient(right, start: CGPoint(x: CGFloat(width) - fade, y: 0), end: CGPoint(x: CGFloat(width), y: 0), options: []); ctx.restoreGState()
        return ctx.makeImage()!
    }

    /// 某个闪变组在 [t0, t0+0.55) 内点亮;t0 = 该组第一次完整进入可读区的时刻
    static func activeFlashes(_ art: StripArt, groups: [(cols: Range<Int>, color: LEDColor)], viewportCols: Int,
                              offset: Double, colsPerSecond: Double) -> Set<Int> {
        var on = Set<Int>()
        for (i, g) in groups.enumerated() {
            guard let start = MarqueeEngine.flashStartCol(g.cols, roundLength: art.totalCols, viewport: viewportCols) else { continue }
            let dt = (offset - start) / colsPerSecond
            if dt >= 0 && dt < PriceFlash.duration { on.insert(i) }
        }
        return on
    }

    static func nsImage(_ cg: CGImage) -> NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }

    static func drawText(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func roundRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, fill: NSColor, stroke: NSColor?) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        if let stroke { ctx.addPath(path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(1); ctx.strokePath() }
    }

    /// 报价卡:与 BoardWindow 同款像素字(renderPixelText)与分时线(SparklineView.draw)
    static func board(_ ctx: CGContext, origin: CGPoint, scene: Scene, style: LEDStyle, flashAt t: Double, previousPrices: [String: Double]) {
        let rows = QuoteEngine.boardRows(entries: Array(entries.prefix(4)), quotes: quotes)
        // 卡宽按内容自适应(同 BoardWindow.fittedWidth):最长一行三段点阵 + 分时线 + 内边距
        let textW = rows.map { r in
            [r.symbol, r.price, r.change].map { renderPixelText([(text: $0, color: .white)]).size.width }.reduce(10, +)
        }.max() ?? 200
        let w: CGFloat = textW + 24 + 80, rowH: CGFloat = 26, inset: CGFloat = 12
        let h = inset * 2 + CGFloat(rows.count) * rowH + 14
        roundRect(ctx, CGRect(x: origin.x, y: origin.y, width: w, height: h), 12, fill: scene.card, stroke: scene.cardBorder)
        let appearance = NSAppearance(named: style.tone == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            for (i, r) in rows.enumerated() {
                let y = origin.y + h - inset - CGFloat(i + 1) * rowH
                let color: NSColor = r.flat ? .labelColor : (r.up ? style.nsColor(.green) : style.nsColor(.red))
                let base = style.nsColor(.white)
                let sym = renderPixelText([(text: r.symbol, color: base)])
                var priceSegs: [(text: String, color: NSColor)] = [(r.price, base)]
                if t >= 0, t < PriceFlash.duration, let q = quotes[r.symbol],
                   let f = PriceFlash.between(previousPrices[r.symbol], and: q.price, redUp: false, decimals: r.decimals) {
                    priceSegs = [(f.prefix, base), (f.suffix, style.nsColor(f.color))]
                }
                let price = renderPixelText(priceSegs), change = renderPixelText([(r.change, color)])
                let cy = y + (rowH - sym.size.height) / 2
                let labelRight = origin.x + w - inset - 80
                for (img, x) in [(sym, origin.x + inset), (change, labelRight - change.size.width),
                                 (price, labelRight - change.size.width - 4 - price.size.width)] {
                    if let cg = img.cgImageForLayer(scale: 1) { ctx.draw(cg, in: CGRect(x: x, y: cy, width: img.size.width, height: img.size.height)) }
                }
                if let pts = r.series {
                    let sw = 66, sh = Int(rowH) - 8
                    let sctx = context(sw, sh)
                    sctx.translateBy(x: 0, y: CGFloat(sh)); sctx.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: sctx, flipped: true)
                    let spark = SparklineView(frame: NSRect(x: 0, y: 0, width: sw, height: sh))
                    spark.points = pts; spark.lineColor = color; spark.session = (0, 80)
                    if let q = quotes[r.symbol] { spark.baseline = q.price / (1 + q.changePct / 100) }
                    spark.draw(spark.bounds)
                    NSGraphicsContext.restoreGraphicsState()
                    ctx.draw(sctx.makeImage()!, in: CGRect(x: origin.x + w - inset - 70, y: y + 4, width: CGFloat(sw), height: CGFloat(sh)))
                }
            }
            drawText(ctx, "Updated · 10:32:05", at: CGPoint(x: origin.x + inset, y: origin.y + 6), size: 9, color: .secondaryLabelColor)
        }
    }

    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        renderScale = 1
        let scenes = [
            Scene(tone: .dark, wallpaper: NSColor(srgbRed: 0.11, green: 0.13, blue: 0.19, alpha: 1), menuBar: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1),
                  menuText: NSColor(white: 0.92, alpha: 1), placeholder: NSColor(white: 1, alpha: 0.22),
                  glass: NSColor(white: 1, alpha: 0.09), glassBorder: NSColor(white: 1, alpha: 0.20),
                  card: NSColor(srgbRed: 0.17, green: 0.19, blue: 0.25, alpha: 0.96), cardBorder: NSColor(white: 1, alpha: 0.10),
                  caption: "Whirlpool · LED stock ticker for the macOS menu bar"),
            Scene(tone: .light, wallpaper: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1), menuBar: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                  menuText: NSColor(white: 0.1, alpha: 1), placeholder: NSColor(white: 0, alpha: 0.18),
                  glass: NSColor(white: 1, alpha: 0.75), glassBorder: NSColor(white: 0, alpha: 0.10),
                  card: NSColor(white: 1, alpha: 0.92), cardBorder: NSColor(white: 0, alpha: 0.08),
                  caption: "Adapts to light and dark menu bars"),
        ]
        let text = QuoteEngine.marqueeText(entries: entries, quotes: quotes, redUpMarkets: ["cn", "hk"], pausePerSymbol: 0,
                                           previousTicks: previous)
        let ledStream = buildScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
        let textStream = buildTextScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
        let cps = 30.0
        let frames = Int(sceneSeconds * fps)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames * scenes.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary

        for (si, scene) in scenes.enumerated() {
            let style = LEDStyle(tone: scene.tone)
            let led = makeLEDArt(stream: ledStream, dot: 2, style: style, scale: 1)
            let strip = TextStrip(stream: textStream, font: .monospacedDigitSystemFont(ofSize: 15, weight: .regular), defaultColor: .white, style: style)
            let textArt = strip.makeArt(scale: 1)
            let ledGroups = flashGroups(ledStream.blinkCols), textGroups = flashGroups(strip.blinkCols)
            let menuVW = 540, barVW = 500
            let startLED = Double(si) * 70, startText = Double(si) * 90
            for f in 0..<frames {
                let t = Double(f) / fps
                let ctx = context(W, H)
                ctx.setFillColor(scene.wallpaper.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                // 菜单栏
                let barH: CGFloat = 30
                ctx.setFillColor(scene.menuBar.cgColor); ctx.fill(CGRect(x: 0, y: CGFloat(H) - barH, width: CGFloat(W), height: barH))
                for (x, w) in [(16, 14), (44, 46), (100, 30), (140, 34), (184, 40)] {
                    roundRect(ctx, CGRect(x: CGFloat(x), y: CGFloat(H) - barH + 10, width: CGFloat(w), height: 10), 3, fill: scene.placeholder, stroke: nil)
                }
                drawText(ctx, "Mon 10:32", at: CGPoint(x: CGFloat(W) - 78, y: CGFloat(H) - barH + 7), size: 12, color: scene.menuText, weight: .medium)
                let ledOffset = startLED + t * cps
                let ledView = viewport(led, width: menuVW, offset: ledOffset,
                                       flashes: activeFlashes(led, groups: ledGroups, viewportCols: menuVW / 3, offset: ledOffset, colsPerSecond: cps))
                ctx.draw(ledView, in: CGRect(x: CGFloat(W) - 100 - CGFloat(menuVW), y: CGFloat(H) - barH + (barH - led.height) / 2,
                                             width: CGFloat(menuVW), height: led.height))
                // 说明文字
                drawText(ctx, scene.caption, at: CGPoint(x: 24, y: CGFloat(H) - 72), size: 17, color: scene.menuText, weight: .semibold)
                drawText(ctx, "menu bar ticker  ·  floating ticker  ·  quote board", at: CGPoint(x: 24, y: CGFloat(H) - 96), size: 12,
                         color: scene.menuText.withAlphaComponent(0.6))
                // 报价卡
                board(ctx, origin: CGPoint(x: CGFloat(W) - 356, y: 26), scene: scene, style: style, flashAt: t - 1.2, previousPrices: previous)
                // 浮动行情条(毛玻璃胶囊 + 系统字体条带)
                let capsule = CGRect(x: 24, y: 26, width: CGFloat(barVW) + 24, height: textArt.height + 12)
                roundRect(ctx, capsule, capsule.height / 2, fill: scene.glass, stroke: scene.glassBorder)
                let textOffset = startText + t * cps
                let textView = viewport(textArt, width: barVW, offset: textOffset,
                                        flashes: activeFlashes(textArt, groups: textGroups, viewportCols: barVW / 3, offset: textOffset, colsPerSecond: cps))
                ctx.draw(textView, in: CGRect(x: capsule.minX + 12, y: capsule.minY + 6, width: CGFloat(barVW), height: textArt.height))
                CGImageDestinationAddImage(dest, ctx.makeImage()!, frameProps)
            }
        }
        print(CGImageDestinationFinalize(dest) ? "written" : "failed")
    }
}
