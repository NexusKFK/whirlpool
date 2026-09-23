import AppKit
import ServiceManagement

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class SettingsPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.45).setFill(); shape.fill()
        NSColor.separatorColor.setStroke(); shape.lineWidth = 0.5; shape.stroke()
    }
}

/// A draft-based, keyboard-accessible settings window. Cancel never writes config.
final class ConfigWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onApplied: ((TickerConfig) -> Void)?
    var currentConfig: (() -> TickerConfig?)?
    private var config: TickerConfig
    private var entries: [WatchEntry] = []          // 正在编辑的那一套
    private var lists: [Watchlist] = []             // 全部自选池草稿
    private var currentList = 0
    private let listPicker = NSPopUpButton()
    private let deleteList = NSButton()
    private var window: NSWindow?
    private let table = NSTableView()
    private let pages = NSTabView()
    private var navigation: [NSButton] = []
    private var surfaces: [SettingsChoiceButton] = []
    private var anchors: [SettingsChoiceButton] = []
    private let preview = LayoutPreviewView(frame: .zero)
    private let placementName = NSTextField(labelWithString: "")
    private let freePlacement = NSButton()
    private var floatingControls: NSView?
    private var menuControls: NSView?
    private var windowControls: NSView?
    private var placementEdited = false
    private var floatingWidthEdited = false
    private var menuWidthEdited = false
    private var draftPlacement = "bottom-center"
    private var draftOrigin: [Double]?
    private let source = NSPopUpButton()
    private let language = NSPopUpButton()
    private let size = SettingsChoiceGroup()
    private let font = SettingsChoiceGroup()
    private let refresh = NSTextField()
    private let speed = NSSlider(value: 30, minValue: 10, maxValue: 50, target: nil, action: nil)
    private let width = NSSlider(value: 60, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let menuWidth = NSSlider(value: 360, minValue: 144, maxValue: 600, target: nil, action: nil)
    private let menuWidthValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")
    private let widthValue = NSTextField(labelWithString: "")
    private let arrows = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let flashes = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let redUp = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dock = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let scheme = SettingsChoiceGroup()
    private let barBackground = SettingsChoiceGroup()
    private let screenPicker = NSPopUpButton()
    private let lock = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let clickThrough = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var screenKeys: [String] = []
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
    func reload(config: TickerConfig) {
        if window?.isVisible == true { syncLayout(from: config) }
        else { self.config = config }
    }

    /// Keep an untouched layout draft aligned with real-window drags, without discarding edits.
    func syncLayout(from latest: TickerConfig) {
        if !placementEdited {
            config.barOrigin = latest.barOrigin; config.barPlacement = latest.barPlacement
            draftOrigin = latest.barOrigin; draftPlacement = latest.barPlacement
        }
        if !floatingWidthEdited {
            config.barWidthFraction = latest.barWidthFraction
            config.defaultWidth = latest.defaultWidth
            width.minValue = min(20, displayedFraction(latest) * 100)
            width.doubleValue = displayedFraction(latest) * 100
        }
        if window?.isVisible == true { updateValues() }
    }

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
        for button in surfaces { button.state = config.displayMode.split(separator: ",").contains(Substring(button.key)) ? .on : .off; button.needsDisplay = true }
        source.selectItem(at: config.provider == "real" ? 0 : 1)
        language.selectItem(at: ["system", "en", "zh-Hans"].firstIndex(of: config.language) ?? 0)
        refresh.stringValue = String(Int(config.boardRefresh))
        speed.doubleValue = 1 / config.scrollSpeed
        draftPlacement = config.barPlacement; draftOrigin = config.barOrigin
        placementEdited = false; floatingWidthEdited = false; menuWidthEdited = false
        reloadScreens()
        width.minValue = min(20, displayedFraction(config) * 100)
        width.doubleValue = displayedFraction(config) * 100
        let menuPoints = config.menuWidthPoints ?? Double(config.defaultWidth * 18 + 8)
        menuWidth.minValue = 120; menuWidth.maxValue = max(menuScreenWidth * 0.40, menuPoints)
        menuWidth.doubleValue = menuPoints
        size.selectItem(at: max(0, min(2, config.ledDotSize - 1)))
        font.selectItem(at: ["led", "system", "mono"].firstIndex(of: config.marqueeFont) ?? 0)
        arrows.state = config.changeArrows ? .on : .off
        flashes.state = config.marqueeBlink ? .on : .off
        redUp.state = config.redUpMarkets.contains("cn") && config.redUpMarkets.contains("hk") ? .on : .off
        dock.state = config.showDockIcon ? .on : .off
        scheme.selectItem(at: ColorScheme.allCases.firstIndex(of: config.colorScheme) ?? 0)
        barBackground.selectItem(at: config.barBackground == "none" ? 1 : 0)
        lock.state = config.lockPosition ? .on : .off
        clickThrough.state = config.barClickThrough ? .on : .off
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 740),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = L("Whirlpool Settings")
        w.contentMinSize = NSSize(width: 780, height: 540)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if ProcessInfo.processInfo.environment["WHIRLPOOL_CONFIG"] == nil { w.setFrameAutosaveName("WhirlpoolSettingsV2") }
        // Keep the footer reachable on laptops and scaled displays; long tabs scroll instead.
        if let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = NSSize(width: min(max(780, w.frame.width), area.width),
                              height: min(w.frame.height, area.height))
            w.setFrame(NSRect(origin: w.frame.origin, size: size), display: false)
        }
        window = w
        for item in pages.tabViewItems { pages.removeTabViewItem(item) }
        pages.tabViewType = .noTabsNoBorder
        navigation = []
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .withinWindow; sidebar.state = .active
        let sideStack = NSStackView(); sideStack.orientation = .vertical; sideStack.alignment = .leading; sideStack.spacing = 8
        let brand = NSTextField(labelWithString: "Whirlpool")
        brand.font = .systemFont(ofSize: 16, weight: .semibold)
        sideStack.addArrangedSubview(brand)
        sideStack.setCustomSpacing(20, after: brand)
        let sections: [(String, String, String, NSView)] = [
            ("watchlist", "Watchlist", "list.bullet", scrollable(watchlistTab())),
            ("layout", "Layout", "rectangle.3.group", scrollable(displayTab())),
            ("appearance", "Appearance", "paintpalette", scrollable(appearanceTab())),
            ("general", "General", "gearshape", scrollable(generalTab()))]
        for (key, title, symbol, content) in sections {
            let item = NSTabViewItem(identifier: key); item.view = content; pages.addTabViewItem(item)
            let nav = SettingsChoiceButton(L(title), artwork: .navigation)
            nav.identifier = NSUserInterfaceItemIdentifier("settings-page-" + key)
            let pageIndex = navigation.count
            nav.onChoose = { [weak self] in self?.selectPage(pageIndex) }
            nav.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); nav.imagePosition = .imageLeading
            nav.alignment = .left; nav.font = .systemFont(ofSize: 13, weight: .medium)
            nav.widthAnchor.constraint(equalToConstant: 136).isActive = true
            nav.heightAnchor.constraint(equalToConstant: 34).isActive = true
            sideStack.addArrangedSubview(nav); navigation.append(nav)
        }
        sidebar.addSubview(sideStack); sideStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sideStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), sideStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26)])
        selectPage(1)
        let cancel = button("Cancel", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", #selector(save))
        save.keyEquivalent = "\r"
        w.defaultButtonCell = save.cell as? NSButtonCell
        save.identifier = NSUserInterfaceItemIdentifier("settings-save")
        cancel.identifier = NSUserInterfaceItemIdentifier("settings-cancel")
        let footer = NSStackView(views: [note("Changes apply after saving."), NSView(), cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 10
        let root = SettingsBackgroundView()
        for view in [sidebar, pages, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        w.contentView = root
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 168),
            pages.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            pages.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 4),
            pages.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            pages.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func selectPage(_ index: Int) {
        pages.selectTabViewItem(at: index)
        for (i, button) in navigation.enumerated() { button.state = i == index ? .on : .off; button.needsDisplay = true }
    }

    private func scrollable(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        let fitHeight = document.heightAnchor.constraint(equalTo: content.heightAnchor)
        // Below every control's hugging priority: unused height belongs below
        // the content, never inside a form row or its labels.
        fitHeight.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor), fitHeight,
        ])
        return scroll
    }

    private func watchlistTab() -> NSView {
        // This table is reused when changing language; remove old columns first.
        for column in table.tableColumns { table.removeTableColumn(column) }
        // 代码列吃掉多余宽度;市场/小数位定宽,任何窗口宽度下都不会被挤出表格右缘
        let symbol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        symbol.title = L("Symbol"); symbol.width = 200; symbol.minWidth = 120
        symbol.resizingMask = .autoresizingMask
        let market = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("market"))
        market.title = L("Market"); market.width = 190; market.minWidth = 170
        market.resizingMask = .userResizingMask
        let decimals = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("decimals"))
        decimals.title = L("Decimals"); decimals.width = 120; decimals.minWidth = 110
        decimals.resizingMask = .userResizingMask
        table.addTableColumn(symbol); table.addTableColumn(market); table.addTableColumn(decimals)
        table.delegate = self; table.dataSource = self
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 40                                        // 控件上下各留出呼吸空间
        table.intercellSpacing = NSSize(width: 12, height: 0)       // 列间距;行间靠行高,斑马纹不断
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(L("Watchlist"))
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        listPicker.target = self; listPicker.action = #selector(listPicked)
        listPicker.setAccessibilityLabel(L("Watchlist"))
        listPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        deleteList.title = L("Delete List"); deleteList.bezelStyle = .rounded
        deleteList.target = self; deleteList.action = #selector(removeList)
        let listRow = NSStackView(views: [NSTextField(labelWithString: L("Current list")), listPicker,
                                          button("New List", #selector(newList)),
                                          button("Rename…", #selector(renameList)), deleteList])
        listRow.orientation = .horizontal; listRow.alignment = .centerY; listRow.spacing = 8

        let actions = NSStackView(views: [button("Add", #selector(add)), button("Remove", #selector(remove)),
                                         button("Move Up", #selector(up)), button("Move Down", #selector(down))])
        actions.orientation = .horizontal; actions.spacing = 8
        let content = stack([pageTitle("Watchlist", "Organize the symbols you follow."), listRow,
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
        let cards = NSStackView(); cards.orientation = .horizontal; cards.distribution = .fillEqually; cards.spacing = 10
        surfaces = [("marquee", "Menu Bar Ticker"), ("bar", "Floating Ticker"), ("board", "Quote Board")].map { key, title in
            let choice = SettingsChoiceButton(L(title), key: key, artwork: .surface)
            choice.identifier = NSUserInterfaceItemIdentifier("surface-" + key)
            choice.setAccessibilityRole(.checkBox)
            choice.onChoose = { [weak self, weak choice] in
                guard let self, let choice else { return }
                // The button has already toggled before sending its action.
                // Keep at least one display selected without undoing other clicks.
                if !self.surfaces.contains(where: { $0.state == .on }) { choice.state = .on }
                choice.needsDisplay = true
                self.updateValues()
            }
            choice.heightAnchor.constraint(equalToConstant: 78).isActive = true
            cards.addArrangedSubview(choice); return choice
        }
        screenPicker.setAccessibilityLabel(L("Screen"))
        screenPicker.target = self; screenPicker.action = #selector(screenChanged)
        screenPicker.identifier = NSUserInterfaceItemIdentifier("layout-screen")
        preview.identifier = NSUserInterfaceItemIdentifier("layout-preview")
        preview.setAccessibilityLabel(L("Desktop preview. Drag the ticker or its edges to adjust the layout."))
        preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
        preview.onEdit = { [weak self] placement, fraction, position in
            guard let self else { return }
            if abs(self.width.doubleValue / 100 - fraction) > 0.0001 { self.floatingWidthEdited = true }
            self.width.doubleValue = fraction * 100
            self.draftPlacement = placement; self.placementEdited = true
            self.draftOrigin = self.origin(for: position)
            self.updateValues()
        }
        width.target = self; width.action = #selector(floatingWidthChanged); width.isContinuous = true
        width.identifier = NSUserInterfaceItemIdentifier("floating-width")
        width.setAccessibilityLabel(L("Share of available screen width"))
        menuWidth.target = self; menuWidth.action = #selector(menuWidthChanged); menuWidth.isContinuous = true
        menuWidth.identifier = NSUserInterfaceItemIdentifier("menu-width")
        menuWidth.setAccessibilityLabel(L("Menu bar width"))
        anchors = []
        let anchorRows = NSStackView(); anchorRows.orientation = .vertical; anchorRows.spacing = 6; anchorRows.alignment = .leading
        for edge in ["top", "bottom"] {
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 6
            for alignment in ["left", "center", "right"] {
                let key = edge + "-" + alignment
                let b = SettingsChoiceButton(Self.placementLabel(key), key: key, artwork: .anchor)
                b.identifier = NSUserInterfaceItemIdentifier("placement-" + key)
                b.toolTip = Self.placementLabel(key)
                b.onChoose = { [weak self] in self?.choosePlacement(key) }
                b.widthAnchor.constraint(equalToConstant: 46).isActive = true
                b.heightAnchor.constraint(equalToConstant: 32).isActive = true
                row.addArrangedSubview(b); anchors.append(b)
            }
            anchorRows.addArrangedSubview(row)
        }
        freePlacement.title = L("Free position"); freePlacement.bezelStyle = .rounded
        freePlacement.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
        freePlacement.imagePosition = .imageLeading; freePlacement.target = self; freePlacement.action = #selector(freePicked)
        freePlacement.identifier = NSUserInterfaceItemIdentifier("placement-free")
        anchorRows.addArrangedSubview(freePlacement)
        placementName.font = .systemFont(ofSize: 11); placementName.textColor = .secondaryLabelColor
        let anchorColumn = column([heading("Position"), anchorRows, placementName], spacing: 8)
        anchorColumn.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let widthPresets = NSStackView(); widthPresets.orientation = .horizontal; widthPresets.distribution = .fillEqually; widthPresets.spacing = 6
        for (label, value) in [("¼", 25), ("½", 50), ("⅔", 67), (L("Fill"), 100)] {
            let b = NSButton(title: label, target: self, action: #selector(widthPreset(_:))); b.bezelStyle = .rounded; b.tag = value
            b.setAccessibilityLabel(String(format: L("%d percent of screen"), value)); widthPresets.addArrangedSubview(b)
        }
        let widthColumn = column([heading("Share of available screen width"), widthValue, width, widthPresets,
                                  note("Centered grows both ways. Left and right keep their edge.")], spacing: 8)
        let geometry = NSStackView(views: [anchorColumn, widthColumn]); geometry.orientation = .horizontal; geometry.alignment = .top; geometry.spacing = 22; geometry.distribution = .fill
        widthColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let floatingGroup = panel([geometry])
        floatingGroup.identifier = NSUserInterfaceItemIdentifier("floating-controls")
        floatingControls = floatingGroup
        let menuPresetRow = NSStackView(); menuPresetRow.orientation = .horizontal; menuPresetRow.spacing = 8
        for (title, points) in [("Compact", 180), ("Standard", 280), ("Wide", 400)] {
            let b = NSButton(title: L(title), target: self, action: #selector(menuPreset(_:))); b.tag = points; b.bezelStyle = .rounded; menuPresetRow.addArrangedSubview(b)
        }
        let menuHeader = NSStackView(views: [heading("Menu bar width"), NSView(), menuWidthValue]); menuHeader.orientation = .horizontal
        let menuGroup = panel([menuHeader, menuWidth, menuPresetRow, note("Independent from the floating ticker. macOS may hide wide items when the menu bar is full.")])
        menuGroup.identifier = NSUserInterfaceItemIdentifier("menu-controls")
        menuControls = menuGroup
        lock.title = L("Lock floating windows in place")
        lock.target = self; lock.action = #selector(sliderChanged)
        resetNote.font = .systemFont(ofSize: 11); resetNote.textColor = .secondaryLabelColor
        let reset = button("Reset Floating Windows", #selector(resetWindows))
        reset.identifier = NSUserInterfaceItemIdentifier("reset-windows")
        let options = column([lock, leadingRow([reset]), resetNote], spacing: 8)
        windowControls = options
        let displays = column([heading("Display areas"), cards, note("Select one or more displays.")], spacing: 8)
        let desktop = column([formRow("Screen", [screenPicker]), preview,
                              note("Preview only. Drag the strip or its edges; positions stay clear of the Dock.")], spacing: 8)
        return stack([pageTitle("Layout", "Choose where quotes appear, then shape each display."), displays,
                      desktop, floatingGroup, menuGroup, options])
    }

    private func appearanceTab() -> NSView {
        arrows.title = L("Use ▲ / ▼ for price changes")
        flashes.title = L("Flash changed price suffixes")
        size.configure([L("Small"), L("Medium"), L("Large")])
        size.setAccessibilityLabel(L("Text size"))
        font.configure([L("LED dots"), L("System Font"), L("Monospaced")], keys: ["led", "system", "mono"], artwork: .font)
        font.setAccessibilityLabel(L("Display font"))
        scheme.configure(ColorScheme.allCases.map(\.label), keys: ColorScheme.allCases.map(\.rawValue), artwork: .color)
        scheme.setAccessibilityLabel(L("Colors"))
        barBackground.configure([L("Glass"), L("Transparent")], keys: ["glass", "none"], artwork: .background)
        barBackground.onChange = { [weak self] in self?.updateValues() }
        barBackground.setAccessibilityLabel(L("Floating ticker background"))
        font.onChange = { [weak self] in self?.updateValues() }; size.onChange = { [weak self] in self?.updateValues() }
        speed.target = self; speed.action = #selector(sliderChanged); speed.isContinuous = true
        speed.setAccessibilityLabel(L("Scroll speed"))
        speed.widthAnchor.constraint(equalToConstant: 180).isActive = true
        hover.title = L("Pause scrolling while the pointer is over the ticker")
        clickThrough.title = L("Let clicks pass through the floating ticker")
        let dotSize = column([formRow("Text size", [size]),
                              note("Font, size and colors apply to all displays. Large LED dots use Medium inside the menu bar.")], spacing: 8)
        return stack([pageTitle("Appearance", "See the style before you choose it."),
                      panel([heading("Display font"), font, dotSize]), panel([heading("Colors"), scheme]),
                      panel([heading("Floating ticker background"), barBackground]),
                      panel([formRow("Scroll speed", [speed, speedValue]), arrows, flashes, hover, clickThrough,
                             note("Turn off click-through from the menu bar context menu.")])])
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
        return stack([pageTitle("General", "Data, language and startup."),
                      panel([formRow("Language", [language]), note("Language changes apply after saving.")]),
                      panel([formRow("Data source", [source]), formRow("Refresh interval", [refresh, NSTextField(labelWithString: L("seconds"))]),
                      note("30 seconds is recommended. Short intervals may be rate-limited. All displays share one request cycle."),
                      smart, note("Uses exchange calendars with holidays and half days (NYSE, SSE/SZSE, HKEX); crypto, futures and FX count as always open. Refreshing resumes at the next open."),
                      redUp]), panel([login, dock, note("The Dock icon gives a visible handle on the running app — right-click it to quit or relaunch."),
                      updates, note("Once a day Whirlpool asks GitHub for the latest release (no identifiers sent). New versions appear in the menu and scroll by once."),
                      note("Your watchlist stays on this device. Symbols are sent only to the selected quote provider.")])])
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical; result.alignment = .leading; result.spacing = 18
        result.setHuggingPriority(.required, for: .vertical)
        result.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: result.widthAnchor, constant: -40).isActive = true
        }
        return result
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views); result.orientation = .vertical; result.alignment = .leading; result.spacing = spacing
        result.setHuggingPriority(.required, for: .vertical)
        for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        return result
    }
    private func leadingRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views + [NSView()])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        return row
    }
    private func panel(_ views: [NSView]) -> NSView {
        let panel = SettingsPanelView()
        let content = column(views, spacing: 10)
        content.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
        ])
        return panel
    }
    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: L(title)); label.font = .systemFont(ofSize: 12, weight: .semibold); return label
    }
    private func pageTitle(_ title: String, _ subtitle: String) -> NSView {
        let label = NSTextField(labelWithString: L(title)); label.font = .systemFont(ofSize: 23, weight: .semibold)
        return column([label, note(subtitle)], spacing: 5)
    }
    private func separator() -> NSBox { let line = NSBox(); line.boxType = .separator; return line }
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
        label.preferredMaxLayoutWidth = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: L(title), target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    static let decimalChoices: [Int?] = [nil, 0, 1, 2, 3, 4, 5, 6, 7, 8]

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue == "decimals" {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: Self.decimalChoices.map { $0.map(String.init) ?? L("Auto") })
            popup.selectItem(at: Self.decimalChoices.firstIndex(of: entries[row].decimals) ?? 0)
            popup.tag = row; popup.target = self; popup.action = #selector(decimalsEdited(_:))
            popup.setAccessibilityLabel(L("Decimals"))
            return Self.cell(popup)
        }
        if tableColumn?.identifier.rawValue == "symbol" {
            let field = NSTextField(string: entries[row].symbol)
            field.isBordered = false; field.drawsBackground = false
            field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.placeholderString = "AAPL"
            field.delegate = self
            field.tag = row; field.target = self; field.action = #selector(symbolEdited(_:))
            field.setAccessibilityLabel(L("Symbol"))
            return Self.cell(field, inset: 6)
        }
        let popup = NSPopUpButton()
        popup.addItems(withTitles: Self.markets.map(\.label))
        popup.selectItem(at: Self.markets.firstIndex { $0.key == entries[row].market } ?? 0)
        popup.tag = row; popup.target = self; popup.action = #selector(marketEdited(_:))
        popup.setAccessibilityLabel(L("Market"))
        return Self.cell(popup)
    }

    /// 单元格容器:控件在行内垂直居中、两侧留白(直接返回控件时会被钉在行顶、贴满列宽)
    static func cell(_ control: NSView, inset: CGFloat = 2) -> NSTableCellView {
        let cell = NSTableCellView()
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -inset),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let field = control as? NSTextField { cell.textField = field }
        return cell
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
        if let field = (table.view(atColumn: 0, row: entries.count - 1, makeIfNecessary: true) as? NSTableCellView)?.textField {
            window?.makeFirstResponder(field)
        }
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
    @objc private func floatingWidthChanged() {
        let previousWidth = (previewArea.width - 24) * preview.fraction
        width.doubleValue = max(20, width.doubleValue)
        floatingWidthEdited = true
        if draftPlacement == "free", let origin = draftOrigin, origin.count == 2 {
            let desired = NSRect(x: origin[0] + (previousWidth - previewWindowSize.width) / 2, y: origin[1], width: previewWindowSize.width, height: previewWindowSize.height)
            let clamped = constrainedFrame(desired, inside: previewArea, margin: 12)
            draftOrigin = [clamped.minX, clamped.minY]; placementEdited = true
        }
        updateValues()
    }
    @objc private func menuWidthChanged() { menuWidthEdited = true; updateValues() }
    @objc private func widthPreset(_ sender: NSButton) { width.doubleValue = Double(sender.tag); floatingWidthChanged() }
    @objc private func menuPreset(_ sender: NSButton) { menuWidth.doubleValue = Double(sender.tag); menuWidthEdited = true; updateValues() }
    private var selectedScreenKey: String { screenKeys.indices.contains(screenPicker.indexOfSelectedItem) ? screenKeys[screenPicker.indexOfSelectedItem] : config.displayScreen }
    private var menuScreenWidth: CGFloat { placementScreen(selectedScreenKey)?.frame.width ?? 1440 }
    private var previewScreen: NSScreen? {
        if draftPlacement == "free", let origin = draftOrigin, origin.count == 2,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: origin[0], y: origin[1])) }) { return screen }
        return placementScreen(selectedScreenKey)
    }
    private var previewArea: NSRect { previewScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }
    private func displayedFraction(_ config: TickerConfig) -> Double {
        if let fraction = config.barWidthFraction { return fraction }
        let legacy = CGFloat(config.defaultWidth * 18 + (config.marqueeFont == "led" ? 8 : 0) + (config.barBackground == "glass" ? 20 : 0))
        return min(1, max(0.01, legacy / max(1, previewArea.width - 24)))
    }
    private var previewWindowSize: NSSize {
        let h: CGFloat = font.indexOfSelectedItem == 0 ? CGFloat(8 * (size.indexOfSelectedItem + 2) + 10) : 32
        let fraction = width.doubleValue / 100
        return NSSize(width: ((previewArea.width - 24) * fraction).rounded(), height: h)
    }
    private func origin(for normalized: NSPoint) -> [Double] {
        let area = previewArea.insetBy(dx: 12, dy: 12), size = previewWindowSize
        return [Double(area.minX + max(0, area.width - size.width) * normalized.x), Double(area.minY + max(0, area.height - size.height) * normalized.y)]
    }
    private func choosePlacement(_ key: String) { draftPlacement = key; draftOrigin = nil; placementEdited = true; updateValues() }
    @objc private func freePicked() {
        if draftPlacement != "free" {
            let frame = anchoredTickerFrame(size: previewWindowSize, placement: draftPlacement, inside: previewArea)
            draftOrigin = [frame.minX, frame.minY]
        }
        draftPlacement = "free"; placementEdited = true; updateValues()
    }
    @objc private func screenChanged() {
        draftOrigin = nil
        if draftPlacement == "free" { draftPlacement = "bottom-center" }
        placementEdited = true; updateValues()
    }
    static func placementLabel(_ key: String) -> String {
        L(["top-left": "Top left", "top-center": "Top center", "top-right": "Top right", "bottom-left": "Bottom left", "bottom-center": "Bottom center", "bottom-right": "Bottom right", "free": "Free position"][key] ?? "Bottom center")
    }
    private func updateValues() {
        speedValue.stringValue = "\(Int(speed.doubleValue)) \(L("columns / sec"))"
        widthValue.stringValue = "\(Int(width.doubleValue.rounded()))% · \(Int(previewWindowSize.width)) pt"
        let actualMenuWidth = menuTickerWidth(requested: menuWidth.doubleValue, screenWidth: menuScreenWidth)
        menuWidthValue.stringValue = actualMenuWidth < menuWidth.doubleValue
            ? String(format: L("%d pt · %d pt on this screen"), menuWidth.integerValue, Int(actualMenuWidth))
            : "\(menuWidth.integerValue) pt"
        menuWidthValue.identifier = NSUserInterfaceItemIdentifier("menu-width-value")
        widthValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        menuWidthValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        placementName.stringValue = Self.placementLabel(draftPlacement)
        preview.placement = draftPlacement; preview.fraction = width.doubleValue / 100
        preview.menuFraction = actualMenuWidth / max(1, menuScreenWidth)
        preview.menuOn = surfaces.first { $0.key == "marquee" }?.state == .on
        preview.barOn = surfaces.first { $0.key == "bar" }?.state == .on
        preview.boardOn = surfaces.first { $0.key == "board" }?.state == .on
        preview.glass = barBackground.indexOfSelectedItem == 0
        // Lock applies to real windows; the draft preview remains editable deliberately.
        preview.locked = false
        if let origin = draftOrigin, origin.count == 2 {
            let area = previewArea.insetBy(dx: 12, dy: 12), size = previewWindowSize
            preview.freePosition = NSPoint(x: min(1, max(0, (origin[0] - area.minX) / max(1, area.width - size.width))),
                                           y: min(1, max(0, (origin[1] - area.minY) / max(1, area.height - size.height))))
        } else { preview.freePosition = NSPoint(x: 0.5, y: 0) }
        for button in anchors { button.state = button.key == draftPlacement ? .on : .off; button.needsDisplay = true }
        freePlacement.state = draftPlacement == "free" ? .on : .off
        floatingControls?.isHidden = !preview.barOn
        menuControls?.isHidden = !preview.menuOn
        windowControls?.isHidden = !preview.barOn && !preview.boardOn
        resetNote.isHidden = resetNote.stringValue.isEmpty
    }
    /// 显示器列表:自动 + 当前连接的屏;已选但未连接的屏保留为一项,免得悄悄改掉用户选择
    private func reloadScreens() {
        screenPicker.removeAllItems()
        screenKeys = ["auto"]
        screenPicker.addItem(withTitle: L("Automatic (primary display)"))
        for screen in NSScreen.screens {
            guard let id = screen.stableID else { continue }
            screenKeys.append(id)
            screenPicker.addItem(withTitle: screen.displayLabel)
        }
        if !screenKeys.contains(config.displayScreen) {
            screenKeys.append(config.displayScreen)
            screenPicker.addItem(withTitle: L("Disconnected display"))
        }
        screenPicker.selectItem(at: screenKeys.firstIndex(of: config.displayScreen) ?? 0)
    }

    @objc private func resetWindows() {
        resetNote.stringValue = L("Window positions will reset after you save.")
        resetPositions = true; choosePlacement("bottom-center")
    }
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
                self.selectPage(0)
                self.error(String(format: L("List “%@”: "), list.name) + L(message))
            }
            guard !cleaned.isEmpty else { showProblem("Add at least one symbol."); return }
            guard Self.validEntries(cleaned) else { showProblem("Use unique symbols with valid market codes."); return }
            cleanedLists.append(Watchlist(name: list.name, entries: cleaned))
        }
        guard let interval = Double(refresh.stringValue), interval.isFinite, (5...3600).contains(interval) else {
            selectPage(3)
            error("Enter a refresh interval from 5 to 3600 seconds."); return
        }
        var draft = config
        // A settings draft can stay open while floating windows are being dragged.
        if let latest = currentConfig?() {
            draft.barOrigin = latest.barOrigin; draft.boardOrigin = latest.boardOrigin
            draft.barPlacement = latest.barPlacement; draft.barWidthFraction = latest.barWidthFraction
            draft.menuWidthPoints = latest.menuWidthPoints
        }
        draft.watchlists = cleanedLists
        draft.activeWatchlist = currentList
        draft.displayMode = ["marquee", "bar", "board"].filter { key in surfaces.first { $0.key == key }?.state == .on }.joined(separator: ",")
        draft.provider = source.indexOfSelectedItem == 0 ? "real" : "demo"
        draft.language = ["system", "en", "zh-Hans"][language.indexOfSelectedItem]
        draft.boardRefresh = interval
        draft.scrollSpeed = 1 / speed.doubleValue
        if floatingWidthEdited { draft.barWidthFraction = width.doubleValue / 100 }
        if menuWidthEdited { draft.menuWidthPoints = menuWidth.doubleValue }
        if placementEdited { draft.barPlacement = draftPlacement; draft.barOrigin = draftOrigin }
        draft.ledDotSize = size.indexOfSelectedItem + 1
        draft.marqueeFont = ["led", "system", "mono"][max(0, min(2, font.indexOfSelectedItem))]
        draft.changeArrows = arrows.state == .on
        draft.marqueeBlink = flashes.state == .on
        draft.redUpMarkets.removeAll { ["cn", "hk"].contains($0) }
        if redUp.state == .on { draft.redUpMarkets += ["cn", "hk"] }
        draft.showDockIcon = dock.state == .on
        draft.transparentColor = ColorScheme.allCases[max(0, scheme.indexOfSelectedItem)].rawValue
        draft.barBackground = barBackground.indexOfSelectedItem == 1 ? "none" : "glass"
        draft.hoverPause = hover.state == .on
        draft.smartRefresh = smart.state == .on
        draft.checkUpdates = updates.state == .on
        draft.lockPosition = lock.state == .on
        draft.barClickThrough = clickThrough.state == .on
        let screenKey = screenKeys.indices.contains(screenPicker.indexOfSelectedItem) ? screenKeys[screenPicker.indexOfSelectedItem] : "auto"
        if screenKey != config.displayScreen {
            // 换了显示器:浮窗丢掉旧位置,落到新屏的默认位置
            draft.displayScreen = screenKey
            if !placementEdited { draft.barOrigin = nil }
            draft.boardOrigin = nil
        }
        if resetPositions { draft.boardOrigin = nil }
        draft.normalize()
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
