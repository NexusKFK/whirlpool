import AppKit

// 缩略图模式(board):贴在程序坞两端空位的报价小卡。
// 每行 = 代码/价格/涨跌幅 + 当日分钟线缩略图;无标题,更透。
// 左键整卡拖动(位置落配置),右键弹菜单(与状态栏菜单同源)。
// 程序坞本体不容第三方塞内容,但底部条两端是 Dock 图标排剩下的空白,
// 一块浮层小窗占在那里,视觉上就是坞的延伸。
final class BoardWindow: NSPanel, NSWindowDelegate {

    private let container = NSVisualEffectView()
    private var programmaticMove = false
    private var lastPrices: [String: Double] = [:]   // 上一笔价格,只闪变化位及后续小位

    var config: TickerConfig {
        didSet { reposition() }
    }
    var menuProvider: (() -> NSMenu)?

    init(config: TickerConfig) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 250, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        delegate = self
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        container.material = .underWindowBackground   // 比标题栏材质透得多
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        contentView = container

        reposition()
    }

    func update(entries: [WatchEntry], quotes: [String: Quote], redUpMarkets: [String],
                at date: Date, changeArrows: Bool = true, status: String = "Updated") {
        let rowsData = QuoteEngine.boardRows(entries: entries, quotes: quotes,
                                             changeArrows: changeArrows)
        container.subviews.forEach { $0.removeFromSuperview() }

        let pixel = config.boardPixelFont
        let W: CGFloat = pixel ? Self.fittedWidth(rows: rowsData) : 250
        let inset: CGFloat = 10
        let rowH: CGFloat = pixel ? 24 : 22
        let H = inset * 2 + CGFloat(rowsData.count) * rowH + 18

        programmaticMove = true
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: H), display: false)
        programmaticMove = false

        let rowW = W - inset * 2
        for (i, r) in rowsData.enumerated() {
            let y = H - inset - CGFloat(i + 1) * rowH
            let row = NSView(frame: NSRect(x: inset, y: y, width: rowW, height: rowH))
            let priceFlash = quotes[r.symbol].flatMap {
                PriceFlash.between(lastPrices[r.symbol], and: $0.price,
                                   redUp: redUpMarkets.contains(r.market))
            }

            // 平盘白,其余按市场习惯红涨绿跌/绿涨红跌
            let color: NSColor
            if r.flat {
                color = .labelColor
            } else {
                color = redUpMarkets.contains(r.market)
                    ? (r.up ? .systemRed : .systemGreen)
                    : (r.up ? .systemGreen : .systemRed)
            }

            let labelW = rowW - 74
            if pixel {
                // 像素字体:三段点阵图,符号左、价格/涨跌右,与跑马灯同款字形
                let base = NSColor.labelColor
                let symIV  = Self.pixelIV(r.symbol, base)
                let pxIV   = Self.pixelIV(r.price, base, flash: priceFlash)
                let chgIV  = Self.pixelIV(r.change, color)
                let cy = (rowH - symIV.frame.height) / 2
                chgIV.frame.origin = NSPoint(x: labelW - chgIV.frame.width, y: cy)
                pxIV.frame.origin  = NSPoint(x: chgIV.frame.minX - 4 - pxIV.frame.width, y: cy)
                symIV.frame.origin = NSPoint(x: 0, y: cy)
                row.addSubview(symIV)
                row.addSubview(pxIV)
                row.addSubview(chgIV)
            } else {
                let label = Self.rowLabel(r, color: color, width: labelW, flash: priceFlash)
                label.frame = NSRect(x: 0, y: 2, width: labelW, height: rowH - 4)
                row.addSubview(label)
            }

            if let pts = r.series, pts.count > 1 {
                let spark = SparklineView(frame: NSRect(x: rowW - 70, y: 3, width: 66, height: rowH - 6))
                spark.points = pts
                spark.lineColor = color
                if let q = quotes[r.symbol] {
                    if q.changePct > -99 {
                        spark.baseline = q.price / (1 + q.changePct / 100)   // 昨收
                    }
                    if let st = q.sessionStart, let en = q.sessionEnd {
                        spark.session = (st, en)
                    }
                }
                row.addSubview(spark)
            }

            container.addSubview(row)
        }

        let footer = NSTextField(labelWithString: L(status) + " · " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium))
        footer.font = .systemFont(ofSize: 9)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: inset, y: 4, width: rowW, height: 14)
        footer.toolTip = footer.stringValue
        container.addSubview(footer)

        lastPrices = lastPrices.filter { key, _ in entries.contains { $0.symbol == key } }
        for e in entries {
            if let q = quotes[e.symbol] { lastPrices[e.symbol] = q.price }
        }

        // 右角锚定随实际宽度重算(手动拖过的位置不动)
        if config.boardOrigin == nil { reposition() }
    }

    func resetPriceHistory() { lastPrices = [:] }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // ── 位置 ─────────────────────────────────────────────────────────────────

    private func reposition() {
        if let origin = reachableOrigin(config.boardOrigin, size: frame.size) {
            programmaticMove = true
            setFrameOrigin(origin)
            programmaticMove = false
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.frame   // 用整屏帧而非 visibleFrame:后者的底边在程序坞之上
        let x = config.boardCorner == "left" ? f.minX + 12 : f.maxX - frame.width - 12
        programmaticMove = true
        setFrameOrigin(NSPoint(x: x, y: f.minY + 12))
        programmaticMove = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        config.boardOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if configReadError == nil, var current = try? readConfig(at: configURL) {
            current.boardOrigin = config.boardOrigin
            saveConfig(current)
        }
    }

    // ── 行渲染 ───────────────────────────────────────────────────────────────
    // 单条 attributed label + 右对齐 tab 站:代码左,价格/涨跌幅右,等宽数字对齐。

    /// 像素模式卡宽按内容自适应:量出最长一行的三段点阵宽度,
    /// 加 sparkline 与内边距,上限 460(字太长宁可换行观感也不无限拉宽)
    private static func fittedWidth(rows: [BoardRow]) -> CGFloat {
        var textW: CGFloat = 0
        for r in rows {
            let w = pixelTextWidth(r.symbol) + 6 + pixelTextWidth(r.price)
                  + 4 + pixelTextWidth(r.change)
            textW = max(textW, w)
        }
        return min(460, 10 * 2 + textW + 74 + 10)
    }

    private static func pixelTextWidth(_ s: String) -> CGFloat {
        var cols = 0
        for ch in s.uppercased() {
            if FONT[ch] != nil { cols += 6 }
        }
        return CGFloat(cols) * 2   // dot 1 + gap 1 = 2pt/列
    }

    private static func pixelIV(_ text: String, _ color: NSColor, flash: PriceFlash? = nil) -> NSImageView {
        let normal = renderPixelText([(text: text, color: color)])
        let img = flash.map {
            renderPixelText([(text: $0.prefix, color: color), (text: $0.suffix, color: nsColor($0.color))])
        } ?? normal
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleNone
        iv.frame = NSRect(origin: .zero, size: img.size)
        if flash != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + PriceFlash.duration) { [weak iv] in
                iv?.image = normal
            }
        }
        return iv
    }

    private static func rowLabel(_ r: BoardRow, color: NSColor, width: CGFloat,
                                 flash: PriceFlash?) -> NSTextField {
        let para = NSMutableParagraphStyle()
        para.tabStops = [
            NSTextTab(type: .rightTabStopType, location: width - 64),
            NSTextTab(type: .rightTabStopType, location: width),
        ]
        let text = "\(r.symbol)\t\(r.price)\t\(r.change)"
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        attr.addAttribute(.font,
                          value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                          range: NSRange(location: 0, length: r.symbol.utf16.count))
        let prefixLen = r.symbol.utf16.count + 1 + r.price.utf16.count + 1
        attr.addAttribute(.foregroundColor, value: color,
                          range: NSRange(location: prefixLen, length: r.change.utf16.count))
        let label = NSTextField(labelWithAttributedString: attr)
        if let flash {
            let highlighted = NSMutableAttributedString(attributedString: attr)
            highlighted.addAttribute(.foregroundColor, value: nsColor(flash.color),
                                     range: NSRange(location: r.symbol.utf16.count + 1 + flash.prefix.utf16.count,
                                                    length: flash.suffix.utf16.count))
            label.attributedStringValue = highlighted
            DispatchQueue.main.asyncAfter(deadline: .now() + PriceFlash.duration) { [weak label] in
                label?.attributedStringValue = attr
            }
        }
        return label
    }
}

// ── 分钟线缩略图:细线 + 淡填充 ────────────────────────────────────────────────

final class SparklineView: NSView {

    var points: [SeriesPt] = [] { didSet { needsDisplay = true } }
    var session: (start: Double, end: Double)? = nil   // 当天时段:x 按真实时间,刚开盘线只画开头一小段
    var lineColor: NSColor = .systemGreen
    var baseline: Double? = nil   // 昨收锚点:波动按真实比例画,平静的日子不夸大成满幅锯齿

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let minV = points.map(\.v).min()!, maxV = points.map(\.v).max()!

        // 以昨收为中心的对称量程;无基准时退回中点自适应
        let ref: Double, span: Double
        if let base = baseline, base > 0 {
            ref = base
            let dev = max(abs(maxV - base), abs(base - minV), base * 0.0015)
            span = dev * 2
        } else {
            ref = (minV + maxV) / 2
            span = max(maxV - minV, 0.000001)
        }

        let n = points.count
        let inset: CGFloat = 1.5

        // 昨收基准虚线
        if baseline != nil {
            let yc = inset + (bounds.height - inset * 2) * 0.5
            let dash = NSBezierPath()
            dash.move(to: NSPoint(x: 0, y: yc))
            dash.line(to: NSPoint(x: bounds.width, y: yc))
            let pattern: [CGFloat] = [2, 2]
            dash.setLineDash(pattern, count: 2, phase: 0)
            dash.lineWidth = 0.8
            lineColor.withAlphaComponent(0.22).setStroke()
            dash.stroke()
        }

        let path = NSBezierPath()
        var first = NSPoint.zero
        var coords: [NSPoint] = []
        for (i, p) in points.enumerated() {
            let frac: CGFloat
            if let se = session, se.end > se.start {
                let f = (p.t - se.start) / (se.end - se.start)
                frac = CGFloat(min(1.0, max(0.0, f)))
            } else {
                frac = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0
            }
            let x = inset + (bounds.width - inset * 2) * frac
            let v = CGFloat((p.v - (ref - span / 2)) / span)
            let y = inset + (bounds.height - inset * 2) * (1 - v)   // flipped:低值在下
            let pt = NSPoint(x: x, y: y)
            if i == 0 { first = pt; path.move(to: pt) } else { path.line(to: pt) }
            coords.append(pt)
        }

        // 淡填充
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: coords.last!.x, y: bounds.maxY))
        fill.line(to: NSPoint(x: first.x, y: bounds.maxY))
        fill.close()
        lineColor.withAlphaComponent(0.16).setFill()
        fill.fill()

        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        lineColor.setStroke()
        path.stroke()
    }
}
