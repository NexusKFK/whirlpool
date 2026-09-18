import AppKit

// 缩略图模式(board):贴在程序坞两端空位的报价小卡。
// 每行 = 代码/价格/涨跌幅 + 当日分钟线缩略图;无标题,更透。
// 左键整卡拖动(位置落配置),右键弹菜单(与状态栏菜单同源)。
// 程序坞本体不容第三方塞内容,但底部条两端是 Dock 图标排剩下的空白,
// 一块浮层小窗占在那里,视觉上就是坞的延伸。
final class BoardWindow: NSPanel, NSWindowDelegate {

    private let container = NSVisualEffectView()
    private var programmaticMove = false
    private var lastPrices: [String: Double] = [:]   // 上一轮价格,变化行做脉冲动效

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
                at date: Date, changeArrows: Bool = true) {
        let rowsData = QuoteEngine.boardRows(entries: entries, quotes: quotes,
                                             changeArrows: changeArrows)
        container.subviews.forEach { $0.removeFromSuperview() }

        let W: CGFloat = 250, inset: CGFloat = 10, rowH: CGFloat = 22
        let H = inset * 2 + CGFloat(rowsData.count) * rowH

        programmaticMove = true
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: H), display: false)
        programmaticMove = false

        let rowW = W - inset * 2
        for (i, r) in rowsData.enumerated() {
            let y = H - inset - CGFloat(i + 1) * rowH
            let row = NSView(frame: NSRect(x: inset, y: y, width: rowW, height: rowH))

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
            let label = Self.rowLabel(r, color: color, width: labelW)
            label.frame = NSRect(x: 0, y: 2, width: labelW, height: rowH - 4)
            row.addSubview(label)

            if let pts = r.series, pts.count > 1 {
                let spark = SparklineView(frame: NSRect(x: rowW - 70, y: 3, width: 66, height: rowH - 6))
                spark.points = pts
                spark.lineColor = color
                row.addSubview(spark)
            }

            // 数字变化:主流 App 式方向色闪光(半透明色块圆角覆盖整行,0.55s 淡出)
            if let old = lastPrices[r.symbol], let now = quotes[r.symbol]?.price, old != now {
                let tickUp = now > old
                let flash: NSColor = redUpMarkets.contains(r.market)
                    ? (tickUp ? .systemRed : .systemGreen)
                    : (tickUp ? .systemGreen : .systemRed)
                Self.flash(row: row, color: flash)
            }
            container.addSubview(row)
        }

        lastPrices = entries.reduce(into: [:]) { acc, e in
            if let q = quotes[e.symbol] { acc[e.symbol] = q.price }
        }

        // 右角锚定随实际宽度重算(手动拖过的位置不动)
        if config.boardOrigin == nil { reposition() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // ── 位置 ─────────────────────────────────────────────────────────────────

    private func reposition() {
        if let o = config.boardOrigin, o.count == 2 {
            programmaticMove = true
            setFrameOrigin(NSPoint(x: o[0], y: o[1]))
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
        saveConfig(config)
    }

    // ── 行渲染 ───────────────────────────────────────────────────────────────
    // 单条 attributed label + 右对齐 tab 站:代码左,价格/涨跌幅右,等宽数字对齐。

    /// 行底闪光:方向色 32% 透明圆角色块 → 0.55s 淡出(Robinhood 式换数提示)
    private static func flash(row: NSView, color: NSColor) {
        row.wantsLayer = true
        row.layer?.cornerRadius = 5
        let from = color.withAlphaComponent(0.32).cgColor
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = from
        anim.toValue = NSColor.clear.cgColor
        anim.duration = 0.55
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.layer?.add(anim, forKey: "priceFlash")
    }

    private static func rowLabel(_ r: BoardRow, color: NSColor, width: CGFloat) -> NSTextField {        let para = NSMutableParagraphStyle()
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
        return NSTextField(labelWithAttributedString: attr)
    }
}

// ── 分钟线缩略图:细线 + 淡填充 ────────────────────────────────────────────────

final class SparklineView: NSView {

    var points: [Double] = [] { didSet { needsDisplay = true } }
    var lineColor: NSColor = .systemGreen

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let minV = points.min()!, maxV = points.max()!
        let span = max(maxV - minV, 0.000001)
        let n = points.count
        let inset: CGFloat = 1.5

        let path = NSBezierPath()
        var first = NSPoint.zero
        var coords: [NSPoint] = []
        for (i, p) in points.enumerated() {
            let x = inset + (bounds.width - inset * 2) * CGFloat(i) / CGFloat(n - 1)
            let v = CGFloat((p - minV) / span)
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
