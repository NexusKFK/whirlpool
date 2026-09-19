import AppKit

/// A draft-based, keyboard-accessible settings window. Cancel never writes config.
final class ConfigWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onApplied: ((TickerConfig) -> Void)?
    private var config: TickerConfig
    private var entries: [WatchEntry] = []
    private var window: NSWindow?
    private let table = NSTableView()
    private let mode = NSPopUpButton()
    private let source = NSPopUpButton()
    private let language = NSPopUpButton()
    private let size = NSPopUpButton()
    private let refresh = NSTextField()
    private let speed = NSSlider(value: 30, minValue: 10, maxValue: 50, target: nil, action: nil)
    private let width = NSSlider(value: 20, minValue: 8, maxValue: 60, target: nil, action: nil)
    private let speedValue = NSTextField(labelWithString: "")
    private let widthValue = NSTextField(labelWithString: "")
    private let arrows = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pixels = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let flashes = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let redUp = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let resetNote = NSTextField(labelWithString: "")
    private var resetPositions = false
    private var lastLanguage = ""

    static var markets: [(key: String, label: String)] {
        [("us", L("US / Global")), ("cn", L("China A-shares")),
         ("hk", L("Hong Kong")), ("crypto", L("Crypto"))]
    }

    init(config: TickerConfig) { self.config = config; super.init() }
    func reload(config: TickerConfig) { self.config = config }

    func show() {
        if window?.isVisible == true { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        if window == nil || lastLanguage != L10n.language {
            window?.close()
            buildWindow()
            lastLanguage = L10n.language
        }
        entries = config.watchlist
        table.reloadData()
        mode.selectItem(at: TickerConfig.displayModes.firstIndex { $0.key == config.displayMode } ?? 0)
        source.selectItem(at: config.provider == "real" ? 0 : 1)
        language.selectItem(at: ["system", "en", "zh-Hans"].firstIndex(of: config.language) ?? 0)
        refresh.stringValue = String(Int(config.boardRefresh))
        speed.doubleValue = 1 / config.scrollSpeed
        width.integerValue = config.defaultWidth
        size.selectItem(at: max(0, min(2, config.ledDotSize - 1)))
        arrows.state = config.changeArrows ? .on : .off
        pixels.state = config.boardPixelFont ? .on : .off
        flashes.state = config.marqueeBlink ? .on : .off
        redUp.state = config.redUpMarkets.contains("cn") && config.redUpMarkets.contains("hk") ? .on : .off
        resetPositions = false
        resetNote.stringValue = ""
        updateValues()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 550),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = L("Whirlpool Settings")
        w.minSize = NSSize(width: 660, height: 550)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("WhirlpoolSettings")
        window = w
        let tabs = NSTabView()
        for (title, view) in [(L("Watchlist"), watchlistTab()), (L("Display"), displayTab()), (L("General"), generalTab())] {
            let tab = NSTabViewItem(identifier: title)
            tab.label = title
            tab.view = view
            tabs.addTabViewItem(tab)
        }
        let cancel = button("Cancel", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", #selector(save))
        save.keyEquivalent = "\r"
        w.defaultButtonCell = save.cell as? NSButtonCell
        let footer = NSStackView(views: [NSView(), cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 10
        let root = NSView()
        for view in [tabs, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        w.contentView = root
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func watchlistTab() -> NSView {
        // This table is reused when changing language; remove old columns first.
        for column in table.tableColumns { table.removeTableColumn(column) }
        let symbol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        symbol.title = L("Symbol"); symbol.width = 325; symbol.minWidth = 200
        let market = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("market"))
        market.title = L("Market"); market.width = 205; market.minWidth = 180
        table.addTableColumn(symbol); table.addTableColumn(market)
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 34
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(L("Watchlist"))
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let actions = NSStackView(views: [button("Add", #selector(add)), button("Remove", #selector(remove)),
                                         button("Move Up", #selector(up)), button("Move Down", #selector(down))])
        actions.orientation = .horizontal; actions.spacing = 8
        let content = stack([note("Symbols scroll in this order. Double-click a symbol to edit it."), scroll, actions,
                             note("Examples: AAPL, ^GSPC, 600519, 00700, BTC-USD")])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        return content
    }

    private func displayTab() -> NSView {
        mode.removeAllItems(); mode.addItems(withTitles: TickerConfig.displayModes.map(\.label))
        mode.setAccessibilityLabel(L("Display mode"))
        speed.target = self; speed.action = #selector(sliderChanged); speed.isContinuous = true
        width.target = self; width.action = #selector(sliderChanged); width.isContinuous = true
        speed.setAccessibilityLabel(L("Scroll speed")); width.setAccessibilityLabel(L("Display width"))
        for control in [speed, width] { control.widthAnchor.constraint(equalToConstant: 210).isActive = true }
        arrows.title = L("Use ▲ / ▼ for price changes")
        pixels.title = L("Use pixel font on the quote board")
        flashes.title = L("Flash changed price suffixes")
        size.removeAllItems(); size.addItems(withTitles: [L("Small"), L("Medium"), L("Large")])
        size.setAccessibilityLabel(L("Marquee size"))
        resetNote.font = .systemFont(ofSize: 11); resetNote.textColor = .secondaryLabelColor
        return stack([formRow("Display mode", [mode]), formRow("Scroll speed", [speed, speedValue]),
                      formRow("Display width", [width, widthValue]), formRow("Marquee size", [size]),
                      note("Large is clamped to Medium inside the menu bar; the floating ticker uses the full size."),
                      arrows, pixels, flashes,
                      note("Flash color follows the previous quote; daily change keeps its own color."),
                      button("Reset Floating Windows", #selector(resetWindows)), resetNote, NSView()])
    }

    private func generalTab() -> NSView {
        source.removeAllItems(); source.addItems(withTitles: [L("Yahoo / Tencent"), L("Demo (simulated prices)")])
        language.removeAllItems(); language.addItems(withTitles: [L("System Default"), "English", "简体中文"])
        refresh.widthAnchor.constraint(equalToConstant: 80).isActive = true
        refresh.setAccessibilityLabel(L("Refresh interval"))
        source.setAccessibilityLabel(L("Data source")); language.setAccessibilityLabel(L("Language"))
        redUp.title = L("Red means up in China / Hong Kong")
        return stack([formRow("Language", [language]), note("Language changes apply after saving."),
                      formRow("Data source", [source]), formRow("Refresh interval", [refresh, NSTextField(labelWithString: L("seconds"))]),
                      note("30 seconds is recommended. Short intervals may be rate-limited. All displays share one request cycle."),
                      redUp, note("Your watchlist stays on this device. Symbols are sent only to the selected quote provider."), NSView()])
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical; result.alignment = .leading; result.spacing = 14
        result.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            if view is NSScrollView { view.widthAnchor.constraint(equalTo: result.widthAnchor, constant: -40).isActive = true }
        }
        return result
    }
    private func formRow(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: L(title))
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        return row
    }
    private func note(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L(title))
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 560
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: L(title), target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue == "symbol" {
            let field = NSTextField(string: entries[row].symbol)
            field.isBordered = false; field.drawsBackground = false
            field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            field.delegate = self
            field.tag = row; field.target = self; field.action = #selector(symbolEdited(_:))
            field.setAccessibilityLabel(L("Symbol"))
            return field
        }
        let popup = NSPopUpButton()
        popup.addItems(withTitles: Self.markets.map(\.label))
        popup.selectItem(at: Self.markets.firstIndex { $0.key == entries[row].market } ?? 0)
        popup.tag = row; popup.target = self; popup.action = #selector(marketEdited(_:))
        popup.setAccessibilityLabel(L("Market"))
        return popup
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { symbolEdited(field) }
    }
    @objc private func symbolEdited(_ field: NSTextField) {
        if entries.indices.contains(field.tag) { entries[field.tag].symbol = field.stringValue }
    }
    @objc private func marketEdited(_ popup: NSPopUpButton) {
        if entries.indices.contains(popup.tag) { entries[popup.tag].market = Self.markets[popup.indexOfSelectedItem].key }
    }
    private func finishEditing() { window?.makeFirstResponder(nil) }
    @objc private func add() {
        finishEditing(); entries.append(WatchEntry(symbol: "", market: "us")); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: entries.count - 1), byExtendingSelection: false)
        table.scrollRowToVisible(entries.count - 1)
        if let field = table.view(atColumn: 0, row: entries.count - 1, makeIfNecessary: true) as? NSTextField { window?.makeFirstResponder(field) }
    }
    @objc private func remove() {
        finishEditing(); let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        entries.remove(at: row); table.reloadData()
    }
    private func move(_ delta: Int) {
        finishEditing(); let row = table.selectedRow, next = row + delta
        guard entries.indices.contains(row), entries.indices.contains(next) else { return }
        entries.swapAt(row, next); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    }
    @objc private func up() { move(-1) }
    @objc private func down() { move(1) }
    @objc private func sliderChanged() { updateValues() }
    private func updateValues() {
        speedValue.stringValue = "\(Int(speed.doubleValue)) \(L("columns / sec"))"
        // 宽度按物理尺寸锚定(M 档 1 字符≈18pt):换字号不改变条的实际宽度
        widthValue.stringValue = "\(width.integerValue) \(L("characters")) · ≈\(width.integerValue * 18 + 8) pt"
    }
    @objc private func resetWindows() { resetPositions = true; resetNote.stringValue = L("Window positions will reset after you save.") }
    @objc private func cancel() { window?.close() }
    private func error(_ message: String, title: String = "Invalid Settings") {
        let alert = NSAlert(); alert.messageText = L(title); alert.informativeText = L(message)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    @objc private func save() {
        finishEditing()
        let cleaned = entries.map { WatchEntry(symbol: $0.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), market: $0.market) }
        guard !cleaned.isEmpty else { error("Add at least one symbol."); return }
        guard Self.validEntries(cleaned) else { error("Use unique symbols with valid market codes."); return }
        guard let interval = Double(refresh.stringValue), interval.isFinite, (5...3600).contains(interval) else {
            error("Enter a refresh interval from 5 to 3600 seconds."); return
        }
        var draft = config
        draft.watchlist = cleaned
        draft.displayMode = TickerConfig.displayModes[mode.indexOfSelectedItem].key
        draft.provider = source.indexOfSelectedItem == 0 ? "real" : "demo"
        draft.language = ["system", "en", "zh-Hans"][language.indexOfSelectedItem]
        draft.boardRefresh = interval
        draft.scrollSpeed = 1 / speed.doubleValue
        draft.defaultWidth = width.integerValue
        draft.ledDotSize = size.indexOfSelectedItem + 1
        draft.changeArrows = arrows.state == .on
        draft.boardPixelFont = pixels.state == .on
        draft.marqueeBlink = flashes.state == .on
        draft.redUpMarkets.removeAll { ["cn", "hk"].contains($0) }
        if redUp.state == .on { draft.redUpMarkets += ["cn", "hk"] }
        if resetPositions { draft.boardOrigin = nil; draft.barOrigin = nil }
        guard saveConfig(draft) else { error(configPath(), title: "Could Not Save Settings"); return }
        config = draft; onApplied?(draft); window?.close()
    }
    static func validEntries(_ entries: [WatchEntry]) -> Bool {
        var seen = Set<String>()
        return entries.allSatisfy { entry in
            let pattern: String
            switch entry.market {
            case "cn": pattern = "^[0-9]{6}$"
            case "hk": pattern = "^[0-9]{1,5}$"
            case "us", "crypto": pattern = "^[A-Z0-9^][A-Z0-9.^=_-]{0,31}$"
            default: return false
            }
            let identity = entry.market == "hk" ? String(repeating: "0", count: max(0, 5 - entry.symbol.count)) + entry.symbol : entry.symbol
            return seen.insert(identity).inserted && entry.symbol.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
