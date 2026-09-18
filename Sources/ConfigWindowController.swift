import AppKit

// 简易配置窗:自选池增删改 + 显示模式 + 卡片刷新间隔 + 卡片归位。
// 保存即写盘并回调热应用——两处显示(marquee/board)下一轮刷新自动用新自选池。
// 附属于 accessory 应用,窗口照常可输入;CLI `pinwheel --settings` 也能唤出。
final class ConfigWindowController: NSObject, NSWindowDelegate {

    var onApplied: ((TickerConfig) -> Void)?

    static let markets: [(key: String, label: String)] = [
        ("us", "美股"), ("cn", "A股"), ("hk", "港股"), ("crypto", "加密"),
    ]
    private static let modes: [(key: String, label: String)] = [
        ("marquee", "跑马灯(菜单栏)"),
        ("board", "报价卡(程序坞旁)"),
        ("bar", "底部条(屏幕下缘)"),
        ("marquee,board", "跑马灯+报价卡"),
        ("marquee,bar", "跑马灯+底部条"),
    ]

    private var window: NSWindow?
    private let rowsStack = NSStackView()
    private var rowViews: [WatchlistRow] = []
    private let modePopup = NSPopUpButton()
    private let refreshField = NSTextField()
    private let speedSlider = NSSlider(value: 0.0222, minValue: 0.02, maxValue: 0.1,
                                       target: nil, action: nil)
    private let speedValueLabel = NSTextField(labelWithString: "")
    private let arrowsCheck = NSButton(checkboxWithTitle: "涨跌用 ▲/▼(交易所风格)",
                                       target: nil, action: nil)
    private let pixelFontCheck = NSButton(checkboxWithTitle: "报价卡像素字体(与跑马灯同款)",
                                          target: nil, action: nil)
    private let marqueeBlinkCheck = NSButton(checkboxWithTitle: "跑马灯换数闪烁(只闪变化的数字)",
                                             target: nil, action: nil)
    private let widthSlider = NSSlider(value: 20, minValue: 8, maxValue: 60,
                                       target: nil, action: nil)
    private let widthValueLabel = NSTextField(labelWithString: "")
    private var config: TickerConfig

    init(config: TickerConfig) {
        self.config = config
        super.init()
    }

    func reload(config: TickerConfig) {
        self.config = config
    }

    func show() {
        if window == nil { buildWindow() }
        rebuildRows()
        modePopup.selectItem(at: Self.modes.firstIndex { $0.key == config.displayMode } ?? 0)
        refreshField.stringValue = String(Int(config.boardRefresh))
        speedSlider.doubleValue = min(0.1, max(0.02, config.scrollSpeed))
        updateSpeedLabel()
        widthSlider.doubleValue = Double(min(60, max(8, config.defaultWidth)))
        updateWidthLabel()
        arrowsCheck.state = config.changeArrows ? .on : .off
        pixelFontCheck.state = config.boardPixelFont ? .on : .off
        marqueeBlinkCheck.state = config.marqueeBlink ? .on : .off
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // ── 构建 ─────────────────────────────────────────────────────────────────

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pinwheel 设置"
        w.isReleasedWhenClosed = false
        w.level = .floating   // accessory 应用的窗,不置顶会被别的窗口挡住
        w.delegate = self
        window = w

        let title = NSTextField(labelWithString: "自选池(顺序即显示顺序)")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rowsStack
        scroll.hasVerticalScroller = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor

        let addBtn = NSButton(title: "+ 添加标的", target: self, action: #selector(addRow))
        addBtn.bezelStyle = .rounded

        let modeLabel = NSTextField(labelWithString: "显示模式")
        modePopup.addItems(withTitles: Self.modes.map(\.label))
        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8

        let refreshLabel = NSTextField(labelWithString: "卡片刷新(秒)")
        refreshField.bezelStyle = .roundedBezel
        refreshField.isBezeled = true
        refreshField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let refreshRow = NSStackView(views: [refreshLabel, refreshField])
        refreshRow.orientation = .horizontal
        refreshRow.spacing = 8

        let speedLabel = NSTextField(labelWithString: "跑马灯速度")
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        speedValueLabel.textColor = .secondaryLabelColor
        speedValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let speedRow = NSStackView(views: [speedLabel, speedSlider, speedValueLabel])
        speedRow.orientation = .horizontal
        speedRow.spacing = 8

        let widthLabel = NSTextField(labelWithString: "显示宽度(字符)")
        widthSlider.isContinuous = true
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        widthValueLabel.textColor = .secondaryLabelColor
        widthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let widthRow = NSStackView(views: [widthLabel, widthSlider, widthValueLabel])
        widthRow.orientation = .horizontal
        widthRow.spacing = 8

        arrowsCheck.translatesAutoresizingMaskIntoConstraints = false
        pixelFontCheck.translatesAutoresizingMaskIntoConstraints = false
        marqueeBlinkCheck.translatesAutoresizingMaskIntoConstraints = false

        let resetBtn = NSButton(title: "报价卡归位(清除拖动记忆)", target: self,
                                action: #selector(resetBoardOrigin))
        resetBtn.bezelStyle = .inline
        resetBtn.controlSize = .small

        let separator = NSBox()
        separator.boxType = .separator

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.keyEquivalent = "\u{1b}"
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        w.defaultButtonCell = saveBtn.cell as? NSButtonCell
        let btnRow = NSStackView(views: [cancelBtn, saveBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.alignment = .centerY

        let form = NSStackView(views: [title, scroll, addBtn, separator,
                                       modeRow, refreshRow, speedRow, widthRow,
                                       arrowsCheck, pixelFontCheck, marqueeBlinkCheck, resetBtn, btnRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        form.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(form)
        w.contentView = container

        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: container.topAnchor),
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 190),
            modePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        // 滚动区内容宽随可视宽,超高滚动
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            rowsStack.bottomAnchor.constraint(greaterThanOrEqualTo: clip.bottomAnchor),
        ])
    }

    // ── 行管理 ───────────────────────────────────────────────────────────────

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        config.watchlist.forEach { add(row: $0) }
    }

    @objc private func addRow() { add(row: WatchEntry(symbol: "", market: "us")) }

    private func add(row entry: WatchEntry) {
        let row = WatchlistRow(symbol: entry.symbol, market: entry.market)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            rowViews.removeAll { $0 == row }
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowViews.append(row)
        rowsStack.addArrangedSubview(row)
    }

    // ── 动作 ─────────────────────────────────────────────────────────────────

    @objc private func resetBoardOrigin() {
        config.boardOrigin = nil
        saveConfig(config)
        onApplied?(config)
    }

    @objc private func cancel() { window?.close() }

    @objc private func speedChanged() { updateSpeedLabel() }

    private func updateSpeedLabel() {
        let perSec = 1.0 / max(0.02, speedSlider.doubleValue)
        speedValueLabel.stringValue = String(format: "%.0f 列/秒", perSec)
    }

    @objc private func widthChanged() { updateWidthLabel() }

    private func updateWidthLabel() {
        let pt = widthSlider.doubleValue * 18 + 8
        widthValueLabel.stringValue = String(format: "≈%.0fpt", pt)
    }

    @objc private func save() {
        var entries: [WatchEntry] = []
        for rv in rowViews {
            let s = rv.symbolField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
            guard !s.isEmpty else { continue }
            entries.append(WatchEntry(symbol: s, market: rv.selectedMarket))
        }
        guard !entries.isEmpty else { NSSound.beep(); return }   // 空自选池视作误操作

        config.watchlist = entries
        if Self.modes.indices.contains(modePopup.indexOfSelectedItem) {
            config.displayMode = Self.modes[modePopup.indexOfSelectedItem].key
        }
        if let secs = Double(refreshField.stringValue) {
            config.boardRefresh = min(3600, max(5, secs))
        }
        config.scrollSpeed = min(0.5, max(0.02, speedSlider.doubleValue))
        config.changeArrows = (arrowsCheck.state == .on)
        config.boardPixelFont = (pixelFontCheck.state == .on)
        config.marqueeBlink = (marqueeBlinkCheck.state == .on)
        config.defaultWidth = min(60, max(8, Int(widthSlider.doubleValue)))

        saveConfig(config)
        onApplied?(config)
        window?.close()
    }
}

// ── 单行:[代码输入框] [市场下拉] [−] ─────────────────────────────────────────

private final class WatchlistRow: NSView {

    let symbolField = NSTextField()
    let marketPopup = NSPopUpButton()
    var onRemove: (() -> Void)?

    init(symbol: String, market: String) {
        super.init(frame: .zero)

        symbolField.stringValue = symbol
        symbolField.isBezeled = true
        symbolField.bezelStyle = .roundedBezel
        symbolField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        symbolField.placeholderString = "AAPL / 600519 / 00700"
        symbolField.translatesAutoresizingMaskIntoConstraints = false

        marketPopup.addItems(withTitles: ConfigWindowController.markets.map(\.label))
        if let idx = ConfigWindowController.markets.firstIndex(where: { $0.key == market }) {
            marketPopup.selectItem(at: idx)
        }
        marketPopup.translatesAutoresizingMaskIntoConstraints = false
        marketPopup.controlSize = .small

        let removeBtn = NSButton(title: "−", target: self, action: #selector(removeSelf))
        removeBtn.bezelStyle = .inline
        removeBtn.controlSize = .small
        removeBtn.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [symbolField, marketPopup, removeBtn])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            symbolField.widthAnchor.constraint(equalToConstant: 170),
            marketPopup.widthAnchor.constraint(equalToConstant: 90),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedMarket: String {
        let title = marketPopup.titleOfSelectedItem ?? "美股"
        return ConfigWindowController.markets.first { $0.label == title }?.key ?? "us"
    }

    @objc private func removeSelf() { onRemove?() }
}
