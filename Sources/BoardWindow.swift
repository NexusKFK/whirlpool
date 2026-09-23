import AppKit

// 缩略图模式(board):贴在程序坞两端空位的报价小卡。
// 每行 = 代码/价格/涨跌幅 + 当日分钟线缩略图;无标题,更透。
// 左键整卡拖动(位置落配置),右键弹菜单(与状态栏菜单同源)。
// 程序坞本体不容第三方塞内容,但底部条两端是 Dock 图标排剩下的空白,
// 一块浮层小窗占在那里,视觉上就是坞的延伸。
final class BoardWindow: NSPanel, NSWindowDelegate {

    private let container = BoardContainerView()
    private var programmaticMove = false
    private var lastPrices: [String: Double] = [:]   // 上一笔价格,只闪变化位及后续小位
    private var lastUpdate: (entries: [WatchEntry], quotes: [String: Quote], redUp: [String],
                             date: Date, arrows: Bool, status: String, now: Date)?
    private var saveWork: DispatchWorkItem?
    /// 双击/右键某行打开图表
    var onOpenChart: ((WatchEntry) -> Void)?
    var onOriginChange: (([Double]) -> Void)?

    var config: TickerConfig {
        didSet {
            if oldValue.boardOrigin != config.boardOrigin { saveWork?.cancel() }
            isMovableByWindowBackground = !config.lockPosition
            for row in container.subviews.compactMap({ $0 as? BoardRowView }) { row.locked = config.lockPosition }
            if oldValue.watchlist != config.watchlist || oldValue.provider != config.provider {
                resetPriceHistory()
                update(entries: config.watchlist, quotes: [:], redUpMarkets: config.redUpMarkets,
                       at: Date(), status: "Loading quotes…")
            } else if oldValue.marqueeFont != config.marqueeFont || oldValue.ledDotSize != config.ledDotSize
                || oldValue.transparentColor != config.transparentColor || oldValue.marqueeBlink != config.marqueeBlink
                || oldValue.changeArrows != config.changeArrows || oldValue.redUpMarkets != config.redUpMarkets {
                lastUpdate?.arrows = config.changeArrows
                lastUpdate?.redUp = config.redUpMarkets
                redraw()
            }
            if oldValue.boardOrigin != config.boardOrigin || oldValue.displayScreen != config.displayScreen
                || oldValue.boardCorner != config.boardCorner { reposition() }
        }
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
        isMovableByWindowBackground = !config.lockPosition
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        container.material = .underWindowBackground   // 比标题栏材质透得多
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.onAppearanceChange = { [weak self] in self?.redraw() }
        contentView = container
        update(entries: config.watchlist, quotes: [:], redUpMarkets: config.redUpMarkets,
               at: Date(), changeArrows: config.changeArrows, status: "Loading quotes…")
    }

    func update(entries: [WatchEntry], quotes: [String: Quote], redUpMarkets: [String],
                at date: Date, changeArrows: Bool = true, status: String = "Updated", now: Date = Date()) {
        lastUpdate = (entries, quotes, redUpMarkets, date, changeArrows, status, now)
        // 点阵字把颜色烤进位图:必须按报价卡自己的明暗解析 labelColor 等动态色
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            build(entries: entries, quotes: quotes, redUpMarkets: redUpMarkets, at: date,
                  changeArrows: changeArrows, status: status, flash: true, now: now)
        }
        lastPrices = lastPrices.filter { key, _ in entries.contains { $0.symbol == key } }
        for e in entries {
            if let q = quotes[e.symbol] { lastPrices[e.symbol] = q.price }
        }
    }

    /// 系统明暗切换:用上一份数据原样重画(不闪变)
    private func redraw() {
        guard let u = lastUpdate else { return }
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            build(entries: u.entries, quotes: u.quotes, redUpMarkets: u.redUp, at: u.date,
                  changeArrows: u.arrows, status: u.status, flash: false, now: u.now)
        }
    }

    private func build(entries: [WatchEntry], quotes: [String: Quote], redUpMarkets: [String],
                       at date: Date, changeArrows: Bool, status: String, flash: Bool, now: Date) {
        let rowsData = QuoteEngine.boardRows(entries: entries, quotes: quotes, changeArrows: changeArrows)
        container.subviews.forEach { $0.removeFromSuperview() }
        let style = LEDStyle(tone: Tone.of(container.effectiveAppearance), mono: config.colorScheme == .mono)
        let base = style.nsColor(config.colorScheme.baseColor)
        let state = BoardStatus.make(entries: entries, quotes: quotes, provider: config.provider,
                                     status: status, checkedAt: date, now: now)
        let pixel = config.marqueeFont == "led"
        let dot = config.ledDotSize
        let fontSize: CGFloat = dot == 1 ? 12 : dot == 3 ? 17 : 14
        let font: NSFont = config.marqueeFont == "mono"
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        func measure(_ text: String) -> CGFloat {
            if pixel { return Self.pixelTextWidth(text, dot: dot) }
            // NSTextField has its own text insets; NSString width alone clips
            // the last digit or percent sign, particularly with tabular fonts.
            return ceil(Self.textLabel(text, font: font, color: base, flash: nil, style: style, alignment: .right).frame.width)
        }
        // Measure columns independently: their longest values may be on different rows.
        let symbolW = rowsData.map { measure($0.symbol) }.max() ?? 36
        let priceW = rowsData.map { measure($0.price) }.max() ?? 60
        let changeW = rowsData.map { measure($0.change) }.max() ?? 60
        let inset: CGFloat = 12, gap: CGFloat = 12, sparkW: CGFloat = 64
        let W = max(300, inset * 2 + symbolW + priceW + changeW + sparkW + gap * 3)
        let rowH: CGFloat = pixel ? CGFloat(8 * dot + 8) : ceil(font.ascender - font.descender) + 8
        let footerH: CGFloat = 16, footerBottom: CGFloat = 6, footerGap: CGFloat = 2, top: CGFloat = 8
        let H = top + CGFloat(rowsData.count) * rowH + footerGap + footerH + footerBottom

        programmaticMove = true
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: H), display: false)
        programmaticMove = false

        let rowW = W - inset * 2
        for (i, r) in rowsData.enumerated() {
            let y = H - top - CGFloat(i + 1) * rowH
            let row = BoardRowView(frame: NSRect(x: inset, y: y, width: rowW, height: rowH))
            row.entry = entries.first { $0.symbol == r.symbol }
            row.onOpenChart = { [weak self] e in self?.onOpenChart?(e) }
            row.menuProvider = { [weak self] in self?.menuProvider?() }
            row.locked = config.lockPosition
            row.toolTip = L("Double-click to open chart")
            if state.closedSymbols.contains(r.symbol) { row.toolTip! += "\n" + L("Markets closed") }
            if let time = quotes[r.symbol]?.marketTime {
                row.toolTip! += " · " + L("Last quote") + " " + BoardStatus.timestamp(time, relativeTo: now)
            }
            let priceFlash = flash && config.marqueeBlink && !state.closedSymbols.contains(r.symbol) ? quotes[r.symbol].flatMap {
                PriceFlash.between(lastPrices[r.symbol], and: $0.price,
                                   redUp: redUpMarkets.contains(r.market), decimals: r.decimals)
            } : nil
            let red = r.up == redUpMarkets.contains(r.market)
            let color = r.flat ? base : style.nsColor(red ? .red : .green)
            let changeX = rowW - sparkW - gap - changeW
            let priceX = changeX - gap - priceW
            let symbolWidth = priceX - gap
            if pixel {
                let symIV = Self.pixelIV(r.symbol, base, dot: dot)
                let pxIV = Self.pixelIV(r.price, base, flash: priceFlash, style: style, dot: dot)
                let chgIV = Self.pixelIV(r.change, color, dot: dot)
                let cy = (rowH - symIV.frame.height) / 2
                chgIV.frame.origin = NSPoint(x: changeX + changeW - chgIV.frame.width, y: cy)
                pxIV.frame.origin = NSPoint(x: priceX + priceW - pxIV.frame.width, y: cy)
                symIV.frame.origin = NSPoint(x: 0, y: cy)
                symIV.identifier = .init("board-symbol"); pxIV.identifier = .init("board-price"); chgIV.identifier = .init("board-change")
                symIV.setAccessibilityLabel(r.symbol); pxIV.setAccessibilityLabel(r.price); chgIV.setAccessibilityLabel(r.change)
                row.addSubview(symIV); row.addSubview(pxIV); row.addSubview(chgIV)
            } else {
                for (key, text, x, width, tint, pulse) in [
                    ("symbol", r.symbol, CGFloat(0), symbolWidth, base, nil as PriceFlash?),
                    ("price", r.price, priceX, priceW, base, priceFlash),
                    ("change", r.change, changeX, changeW, color, nil as PriceFlash?)
                ] {
                    let label = Self.textLabel(text, font: font, color: tint, flash: pulse, style: style,
                                               alignment: key == "symbol" ? .left : .right)
                    label.identifier = .init("board-" + key)
                    label.frame = NSRect(x: x, y: floor((rowH - label.frame.height) / 2), width: width, height: label.frame.height)
                    row.addSubview(label)
                }
            }

            if let pts = r.series, pts.count > 1 {
                let spark = SparklineView(frame: NSRect(x: rowW - sparkW, y: 4, width: sparkW, height: rowH - 8))
                spark.points = pts
                spark.lineColor = color
                if let q = quotes[r.symbol] {
                    if q.changePct > -99 { spark.baseline = q.price / (1 + q.changePct / 100) }
                    if let st = q.sessionStart, let en = q.sessionEnd { spark.session = (st, en) }
                }
                row.addSubview(spark)
            }
            container.addSubview(row)
        }

        let footer = NSTextField(labelWithString: state.text)
        footer.identifier = .init("board-status")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: inset, y: footerBottom, width: rowW, height: footerH)
        footer.toolTip = state.detail
        container.addSubview(footer)
        // Enlarging the font must not strand a manually positioned board offscreen.
        reposition()
    }

    func resetPriceHistory() { lastPrices = [:] }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // ── 位置 ─────────────────────────────────────────────────────────────────

    func reposition() {
        if let origin = reachableOrigin(config.boardOrigin, size: frame.size) {
            let proposed = NSRect(origin: origin, size: frame.size)
            let screen = NSScreen.screens.max {
                let a = $0.frame.intersection(proposed), b = $1.frame.intersection(proposed)
                return a.width * a.height < b.width * b.height
            }
            programmaticMove = true
            setFrameOrigin(screen.map { constrainedFrame(proposed, inside: $0.frame, margin: 0).origin } ?? origin)
            programmaticMove = false
            return
        }
        guard let screen = placementScreen(config.displayScreen) else { return }
        let f = screen.frame   // 用整屏帧而非 visibleFrame:后者的底边在程序坞之上
        let x = config.boardCorner == "left" ? f.minX + 12 : f.maxX - frame.width - 12
        programmaticMove = true
        setFrameOrigin(NSPoint(x: x, y: f.minY + 12))
        programmaticMove = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        config.boardOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if let origin = config.boardOrigin { onOriginChange?(origin) }
        // 拖动过程中会连发;停手 0.5 秒后再落盘一次
        saveWork?.cancel()
        let origin = config.boardOrigin
        let work = DispatchWorkItem {
            if configReadError == nil, var current = try? readConfig(at: configURL) {
                current.boardOrigin = origin
                saveConfig(current)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // ── 行渲染 ───────────────────────────────────────────────────────────────

    private static func pixelTextWidth(_ text: String, dot: Int) -> CGFloat {
        CGFloat(text.uppercased().reduce(0) { $0 + (FONT[$1]?.count ?? 0) } * dot + 2)
    }

    private static func pixelIV(_ text: String, _ color: NSColor, flash: PriceFlash? = nil,
                                style: LEDStyle = LEDStyle(), dot: Int) -> NSImageView {
        let normal = renderPixelText([(text: text, color: color)], dot: dot)
        let img = flash.map {
            renderPixelText([(text: $0.prefix, color: color), (text: $0.suffix, color: style.nsColor($0.color))], dot: dot)
        } ?? normal
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleNone
        iv.frame = NSRect(origin: .zero, size: img.size)
        if flash != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + PriceFlash.duration) { [weak iv] in iv?.image = normal }
        }
        return iv
    }

    private static func textLabel(_ text: String, font: NSFont, color: NSColor,
                                  flash: PriceFlash?, style: LEDStyle, alignment: NSTextAlignment) -> NSTextField {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byClipping
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let label = NSTextField(labelWithAttributedString: attr)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        if let flash {
            let highlighted = NSMutableAttributedString(attributedString: attr)
            highlighted.addAttribute(.foregroundColor, value: style.nsColor(flash.color),
                                     range: NSRange(location: flash.prefix.utf16.count, length: flash.suffix.utf16.count))
            label.attributedStringValue = highlighted
            DispatchQueue.main.asyncAfter(deadline: .now() + PriceFlash.duration) { [weak label] in label?.attributedStringValue = attr }
        }
        label.sizeToFit()
        return label
    }

}

/// 报价卡底板:明暗切换时通知重画(点阵字颜色是烤进位图的)
private final class BoardContainerView: NSVisualEffectView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.onAppearanceChange?() }
    }
}

/// 报价卡一行:单击拖卡、双击开图表、右键菜单首项为本行图表
final class BoardRowView: NSView {
    var entry: WatchEntry?
    var onOpenChart: ((WatchEntry) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var locked = false

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let entry { onOpenChart?(entry); return }
        if !locked { window?.performDrag(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = menuProvider?() ?? NSMenu()
        if let entry {
            let item = NSMenuItem(title: String(format: L("Open %@ Chart"), entry.symbol),
                                  action: #selector(openChart), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openChart() { if let entry { onOpenChart?(entry) } }
}

// ── 分钟线缩略图:细线 + 淡填充 ────────────────────────────────────────────────

final class SparklineView: NSView {

    var points: [SeriesPt] = [] { didSet { needsDisplay = true } }
    var session: (start: Double, end: Double)? = nil   // 当天时段:x 按真实时间,刚开盘线只画开头一小段
    var lineColor: NSColor = .systemGreen
    var baseline: Double? = nil   // 昨收锚点:波动按真实比例画,平静的日子不夸大成满幅锯齿

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Before the next open Yahoo may return the previous day's points with
    /// today's trading period. Keep that completed curve spread across its own
    /// time range instead of clamping every point to the left edge.
    static func timeRange(points: [SeriesPt], session: (start: Double, end: Double)?) -> (start: Double, end: Double)? {
        guard let first = points.map(\.t).min(), let last = points.map(\.t).max(), last > first else { return nil }
        if let session, session.end > session.start, first >= session.start, last <= session.end {
            return session
        }
        return (first, last)
    }

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
        let timeRange = Self.timeRange(points: points, session: session)

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
            if let se = timeRange {
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
