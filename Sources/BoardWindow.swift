import AppKit

// 缩略图模式(board):贴在程序坞两端空位的报价小卡。
// 30s 一刷;左键整卡拖动(位置落配置),右键弹菜单(与状态栏菜单同源)。
// 程序坞本体不容第三方塞内容,但底部条两端是 Dock 图标排剩下的空白,
// 一块浮层小窗占在那里,视觉上就是坞的延伸。
final class BoardWindow: NSPanel, NSWindowDelegate {

    private let container = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "")
    private var programmaticMove = false

    var config: TickerConfig {
        didSet { reposition() }
    }
    var menuProvider: (() -> NSMenu)?

    init(config: TickerConfig) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 232, height: 120),
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

        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        contentView = container

        header.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        header.textColor = .secondaryLabelColor
        container.addSubview(header)

        reposition()
    }

    func update(entries: [WatchEntry], quotes: [String: Quote], redUpMarkets: [String], at date: Date) {
        let rowsData = QuoteEngine.boardRows(entries: entries, quotes: quotes)
        container.subviews.filter { $0 !== header }.forEach { $0.removeFromSuperview() }

        let W: CGFloat = 232, inset: CGFloat = 12, rowH: CGFloat = 17, headerH: CGFloat = 13
        let H = inset * 2 + headerH + 5 + CGFloat(rowsData.count) * rowH

        programmaticMove = true
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: H), display: false)
        programmaticMove = false

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        header.stringValue = "PINWHEEL · \(df.string(from: date))"
        let rowW = W - inset * 2
        header.frame = NSRect(x: inset, y: H - inset - headerH, width: rowW, height: headerH)

        for (i, r) in rowsData.enumerated() {
            let label = Self.rowLabel(r, redUp: redUpMarkets.contains(r.market), width: rowW)
            let y = H - inset - headerH - 5 - CGFloat(i + 1) * rowH + 1
            label.frame = NSRect(x: inset, y: y, width: rowW, height: rowH)
            container.addSubview(label)
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

    private static func rowLabel(_ r: BoardRow, redUp: Bool, width: CGFloat) -> NSTextField {
        let color: NSColor = redUp ? (r.up ? .systemRed : .systemGreen)
                                   : (r.up ? .systemGreen : .systemRed)
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
        return NSTextField(labelWithAttributedString: attr)
    }
}
