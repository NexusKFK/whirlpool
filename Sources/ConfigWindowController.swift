import AppKit
import ServiceManagement

/// A draft-based, keyboard-accessible settings window. Cancel never writes config.
final class ConfigWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onApplied: ((TickerConfig) -> Void)?
    private var config: TickerConfig
    private var entries: [WatchEntry] = []          // 正在编辑的那一套
    private var lists: [Watchlist] = []             // 全部自选池草稿
    private var currentList = 0
    private let listPicker = NSPopUpButton()
    private let deleteList = NSButton()
    private var window: NSWindow?
    private let table = NSTableView()
    private let mode = NSPopUpButton()
    private let source = NSPopUpButton()
    private let language = NSPopUpButton()
    private let size = NSPopUpButton()
    private let font = NSPopUpButton()
    private let refresh = NSTextField()
    private let speed = NSSlider(value: 30, minValue: 10, maxValue: 50, target: nil, action: nil)
    private let width = NSSlider(value: 20, minValue: 8, maxValue: 60, target: nil, action: nil)
    private let speedValue = NSTextField(labelWithString: "")
    private let widthValue = NSTextField(labelWithString: "")
    private let arrows = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pixels = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let flashes = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let redUp = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dock = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let scheme = NSPopUpButton()
    private let barBackground = NSPopUpButton()
    private let hover = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let smart = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let updates = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
        lists = config.watchlists
        currentList = min(max(0, config.activeWatchlist), max(0, lists.count - 1))
        entries = lists.isEmpty ? [] : lists[currentList].entries
        reloadListPicker()
        table.reloadData()
        mode.selectItem(at: TickerConfig.displayModes.firstIndex { $0.key == config.displayMode } ?? 0)
        source.selectItem(at: config.provider == "real" ? 0 : 1)
        language.selectItem(at: ["system", "en", "zh-Hans"].firstIndex(of: config.language) ?? 0)
        refresh.stringValue = String(Int(config.boardRefresh))
        speed.doubleValue = 1 / config.scrollSpeed
        width.integerValue = config.defaultWidth
        size.selectItem(at: max(0, min(2, config.ledDotSize - 1)))
        font.selectItem(at: ["led", "system", "mono"].firstIndex(of: config.marqueeFont) ?? 0)
        arrows.state = config.changeArrows ? .on : .off
        pixels.state = config.boardPixelFont ? .on : .off
        flashes.state = config.marqueeBlink ? .on : .off
        redUp.state = config.redUpMarkets.contains("cn") && config.redUpMarkets.contains("hk") ? .on : .off
        dock.state = config.showDockIcon ? .on : .off
        scheme.selectItem(at: ColorScheme.allCases.firstIndex(of: config.colorScheme) ?? 0)
        barBackground.selectItem(at: config.barBackground == "none" ? 1 : 0)
        hover.state = config.hoverPause ? .on : .off
        smart.state = config.smartRefresh ? .on : .off
        updates.state = config.checkUpdates ? .on : .off
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        resetPositions = false
        resetNote.stringValue = ""
        updateValues()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = L("Whirlpool Settings")
        w.minSize = NSSize(width: 660, height: 700)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("WhirlpoolSettings")
        // 旧版本记住的窗口可能比新内容矮:恢复后不足最小尺寸就撑开,免得底部选项被裁
        if w.contentLayoutRect.height < 700 || w.contentLayoutRect.width < 660 {
            w.setContentSize(NSSize(width: max(660, w.contentLayoutRect.width), height: 700))
        }
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
        symbol.title = L("Symbol"); symbol.width = 250; symbol.minWidth = 160
        let market = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("market"))
        market.title = L("Market"); market.width = 180; market.minWidth = 150
        let decimals = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("decimals"))
        decimals.title = L("Decimals"); decimals.width = 110; decimals.minWidth = 100
        table.addTableColumn(symbol); table.addTableColumn(market); table.addTableColumn(decimals)
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 34
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(L("Watchlist"))
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        listPicker.target = self; listPicker.action = #selector(listPicked)
        listPicker.setAccessibilityLabel(L("Watchlist"))
        listPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        deleteList.title = L("Delete List"); deleteList.bezelStyle = .rounded
        deleteList.target = self; deleteList.action = #selector(removeList)
        let listRow = NSStackView(views: [NSTextField(labelWithString: L("Current list")), listPicker,
                                          button("New List", #selector(newList)),
                                          button("Rename…", #selector(renameList)), deleteList])
        listRow.orientation = .horizontal; listRow.alignment = .centerY; listRow.spacing = 8

        let actions = NSStackView(views: [button("Add", #selector(add)), button("Remove", #selector(remove)),
                                         button("Move Up", #selector(up)), button("Move Down", #selector(down))])
        actions.orientation = .horizontal; actions.spacing = 8
        let content = stack([listRow,
                             note("The list selected here is shown after saving. Switch lists from the menu or Option-click the ticker."),
                             scroll, actions,
                             note("Examples: AAPL, ^GSPC, 600519, 00700, BTC-USD. Decimals: Auto uses the data source's precision (A-share ETFs 3, FX 4, low-priced crypto more).")])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        return content
    }

    // ── 多自选池 ──

    private func syncCurrentList() {
        finishEditing()
        if lists.indices.contains(currentList) { lists[currentList].entries = entries }
    }

    private func reloadListPicker() {
        listPicker.removeAllItems()
        listPicker.addItems(withTitles: lists.map(\.name))
        listPicker.selectItem(at: currentList)
        deleteList.isEnabled = lists.count > 1
    }

    @objc private func listPicked() {
        syncCurrentList()
        currentList = max(0, listPicker.indexOfSelectedItem)
        entries = lists[currentList].entries
        table.reloadData()
    }

    @objc private func newList() {
        syncCurrentList()
        var n = lists.count + 1
        while lists.contains(where: { $0.name == "\(L("Watchlist")) \(n)" }) { n += 1 }
        lists.append(Watchlist(name: "\(L("Watchlist")) \(n)", entries: []))
        currentList = lists.count - 1
        entries = []
        reloadListPicker()
        table.reloadData()
        add()
    }

    @objc private func renameList() {
        syncCurrentList()
        guard lists.indices.contains(currentList), let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Rename List")
        let field = NSTextField(string: lists[currentList].name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename")); alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            guard !self.lists.enumerated().contains(where: { $0.offset != self.currentList && $0.element.name == name }) else {
                self.error("A list with this name already exists."); return
            }
            self.lists[self.currentList].name = name
            self.reloadListPicker()
        }
    }

    @objc private func removeList() {
        syncCurrentList()
        guard lists.count > 1, lists.indices.contains(currentList) else { return }
        lists.remove(at: currentList)
        currentList = min(currentList, lists.count - 1)
        entries = lists[currentList].entries
        reloadListPicker()
        table.reloadData()
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
        font.removeAllItems(); font.addItems(withTitles: [L("LED dots"), L("System Font"), L("Monospaced")])
        font.setAccessibilityLabel(L("Ticker font"))
        resetNote.font = .systemFont(ofSize: 11); resetNote.textColor = .secondaryLabelColor
        scheme.removeAllItems(); scheme.addItems(withTitles: ColorScheme.allCases.map(\.label))
        scheme.setAccessibilityLabel(L("Colors"))
        barBackground.removeAllItems(); barBackground.addItems(withTitles: [L("Glass"), L("Transparent")])
        barBackground.setAccessibilityLabel(L("Floating ticker background"))
        hover.title = L("Pause scrolling while the pointer is over the ticker")
        return stack([formRow("Display mode", [mode]), formRow("Scroll speed", [speed, speedValue]),
                      formRow("Display width", [width, widthValue]), formRow("Marquee size", [size]),
                      formRow("Ticker font", [font]),
                      note("Large is clamped to Medium inside the menu bar for LED dots. The quote board keeps its own font setting."),
                      formRow("Colors", [scheme]),
                      note("Adaptive keeps red/green and switches the neutral color between white and near-black to follow light or dark menu bars."),
                      formRow("Floating ticker background", [barBackground]),
                      arrows, pixels, flashes, hover,
                      button("Reset Floating Windows", #selector(resetWindows)), resetNote, NSView()])
    }

    private func generalTab() -> NSView {
        source.removeAllItems(); source.addItems(withTitles: [L("Yahoo / Tencent"), L("Demo (simulated prices)")])
        language.removeAllItems(); language.addItems(withTitles: [L("System Default"), "English", "简体中文"])
        refresh.widthAnchor.constraint(equalToConstant: 80).isActive = true
        refresh.setAccessibilityLabel(L("Refresh interval"))
        source.setAccessibilityLabel(L("Data source")); language.setAccessibilityLabel(L("Language"))
        redUp.title = L("Red means up in China / Hong Kong")
        dock.title = L("Show Dock icon")
        login.title = L("Launch at login")
        smart.title = L("Refresh slowly while all watched markets are closed")
        updates.title = L("Check for updates automatically")
        return stack([formRow("Language", [language]), note("Language changes apply after saving."),
                      formRow("Data source", [source]), formRow("Refresh interval", [refresh, NSTextField(labelWithString: L("seconds"))]),
                      note("30 seconds is recommended. Short intervals may be rate-limited. All displays share one request cycle."),
                      smart, note("Uses exchange calendars with holidays and half days (NYSE, SSE/SZSE, HKEX); crypto, futures and FX count as always open. Refreshing resumes at the next open."),
                      redUp, login, dock, note("The Dock icon gives a visible handle on the running app — right-click it to quit or relaunch."),
                      updates, note("Once a day Whirlpool asks GitHub for the latest release (no identifiers sent). New versions appear in the menu and scroll by once."),
                      note("Your watchlist stays on this device. Symbols are sent only to the selected quote provider."), NSView()])
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
    static let decimalChoices: [Int?] = [nil, 0, 1, 2, 3, 4, 5, 6]

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue == "decimals" {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: Self.decimalChoices.map { $0.map(String.init) ?? L("Auto") })
            popup.selectItem(at: Self.decimalChoices.firstIndex(of: entries[row].decimals) ?? 0)
            popup.tag = row; popup.target = self; popup.action = #selector(decimalsEdited(_:))
            popup.setAccessibilityLabel(L("Decimals"))
            return popup
        }
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
    @objc private func decimalsEdited(_ popup: NSPopUpButton) {
        if entries.indices.contains(popup.tag) { entries[popup.tag].decimals = Self.decimalChoices[max(0, popup.indexOfSelectedItem)] }
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
        syncCurrentList()
        var cleanedLists: [Watchlist] = []
        for (i, list) in lists.enumerated() {
            // 保留小数位等条目字段,只规整代码
            let cleaned = list.entries.map { e -> WatchEntry in
                var e = e; e.symbol = e.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); return e
            }.filter { !$0.symbol.isEmpty }
            let showProblem = { (message: String) in
                self.currentList = i; self.entries = self.lists[i].entries
                self.reloadListPicker(); self.table.reloadData()
                self.error(String(format: L("List “%@”: "), list.name) + L(message))
            }
            guard !cleaned.isEmpty else { showProblem("Add at least one symbol."); return }
            guard Self.validEntries(cleaned) else { showProblem("Use unique symbols with valid market codes."); return }
            cleanedLists.append(Watchlist(name: list.name, entries: cleaned))
        }
        guard let interval = Double(refresh.stringValue), interval.isFinite, (5...3600).contains(interval) else {
            error("Enter a refresh interval from 5 to 3600 seconds."); return
        }
        var draft = config
        draft.watchlists = cleanedLists
        draft.activeWatchlist = currentList
        draft.displayMode = TickerConfig.displayModes[mode.indexOfSelectedItem].key
        draft.provider = source.indexOfSelectedItem == 0 ? "real" : "demo"
        draft.language = ["system", "en", "zh-Hans"][language.indexOfSelectedItem]
        draft.boardRefresh = interval
        draft.scrollSpeed = 1 / speed.doubleValue
        draft.defaultWidth = width.integerValue
        draft.ledDotSize = size.indexOfSelectedItem + 1
        draft.marqueeFont = ["led", "system", "mono"][max(0, min(2, font.indexOfSelectedItem))]
        draft.changeArrows = arrows.state == .on
        draft.boardPixelFont = pixels.state == .on
        draft.marqueeBlink = flashes.state == .on
        draft.redUpMarkets.removeAll { ["cn", "hk"].contains($0) }
        if redUp.state == .on { draft.redUpMarkets += ["cn", "hk"] }
        draft.showDockIcon = dock.state == .on
        draft.transparentColor = ColorScheme.allCases[max(0, scheme.indexOfSelectedItem)].rawValue
        draft.barBackground = barBackground.indexOfSelectedItem == 1 ? "none" : "glass"
        draft.hoverPause = hover.state == .on
        draft.smartRefresh = smart.state == .on
        draft.checkUpdates = updates.state == .on
        if resetPositions { draft.boardOrigin = nil; draft.barOrigin = nil }
        guard saveConfig(draft) else { error(configPath(), title: "Could Not Save Settings"); return }
        config = draft; onApplied?(draft)
        applyLoginItem(login.state == .on)
        window?.close()
    }

    /// 开机自启:系统登录项(SMAppService),状态以系统为准,不写配置
    private func applyLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could Not Change Login Item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
