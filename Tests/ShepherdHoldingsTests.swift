import AppKit

// 跟随 Shepherd 持仓的自选池。示例持仓全部虚构。

private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if !condition { fatalError("FAIL line \(line): \(message())") }
}

private let fixture = """
{"asof": "demo", "accounts": [], "positions": [
  {"sym": "MSFT", "kind": "stock",  "qty": 2,  "mark": 100, "mult": 1},
  {"sym": "AAPL", "kind": "option", "qty": 1,  "mark": 4,   "mult": 100, "right": "C", "strike": 250},
  {"sym": "AAPL", "kind": "option", "qty": -1, "mark": 1,   "mult": 100, "right": "C", "strike": 270},
  {"sym": "AAPL", "kind": "stock",  "qty": 1,  "mark": 200},
  {"sym": "KO",   "kind": "stock",  "qty": 0,  "mark": 60},
  {"sym": "SPXW", "kind": "option", "qty": 1,  "mark": 2},
  {"sym": "BRK B","kind": "stock",  "qty": 1,  "mark": 50},
  {"sym": "0700.HK", "kind": "stock", "qty": 100, "mark": "3"},
  {"sym": "600519", "kind": "stock", "qty": 1},
  {"sym": "/ES",  "kind": "future", "qty": 1},
  {"sym": "bad symbol!", "kind": "stock", "qty": 5, "mark": 1},
  {"kind": "stock", "qty": 5, "mark": 1}
]}
"""

func runShepherdHoldingsTests() throws {
    // 1) 解析:期权并到正股、按合计市值排序、已平仓残行和坏代码丢掉
    guard let holdings = ShepherdHoldings.parse(Data(fixture.utf8)) else { fatalError("FAIL: fixture did not parse") }
    let symbols = holdings.map(\.symbol)
    // AAPL 400+100+200=700 > 港股 100×3=300 > MSFT 200 = ^GSPC 200(按先后)> BRK.B 50 > 没有现价的按先后
    check(symbols == ["AAPL", "700", "MSFT", "^GSPC", "BRK.B", "600519", "ES=F"], "order \(symbols)")
    check(holdings.first { $0.symbol == "AAPL" }?.weight == 700, "options merged into the stock")
    check(!symbols.contains("KO"), "zero-quantity rows are skipped")
    check(holdings.first { $0.symbol == "700" }?.market == "hk", "HK suffix and leading zeros")
    check(holdings.first { $0.symbol == "600519" }?.market == "cn", "six digits are A-shares")
    check(holdings.filter { $0.market == "us" }.count == 5, "the rest are US/global")
    print("PASS: Shepherd snapshot parses, merges options into the stock and sorts by size")

    // 阴性对照:不是 Shepherd 快照就返回 nil,而不是空列表
    check(ShepherdHoldings.parse(Data("{\"quotes\": {}}".utf8)) == nil, "missing positions")
    check(ShepherdHoldings.parse(Data("[1, 2]".utf8)) == nil, "not an object")
    check(ShepherdHoldings.parse(Data("{\"positions\": []}".utf8)) == [], "empty holdings is valid")
    check(ShepherdHoldings.normalize("A B C") == nil && ShepherdHoldings.normalize("1234567") == nil, "garbage rejected")
    check(ShepherdHoldings.normalize("brk/b")! == ("BRK.B", "us"), "class shares")
    check(ShepherdHoldings.normalize("NDX")! == ("^NDX", "us"), "index options follow the index")
    print("PASS: non-Shepherd files and odd symbols are rejected")

    // 2) 条目:隐藏的不加回来、用户设过的小数位保留
    let previous = [WatchEntry(symbol: "MSFT", market: "us", decimals: 1)]
    let entries = ShepherdHoldings.entries(from: holdings, excluded: ["es=f"], previous: previous)
    check(!entries.contains { $0.symbol == "ES=F" }, "excluded symbols stay hidden (case-insensitive)")
    check(entries.first { $0.symbol == "MSFT" }?.decimals == 1, "decimals survive a refresh")
    check(entries.first { $0.symbol == "AAPL" }?.decimals == nil, "new symbols use automatic decimals")
    check(ConfigWindowController.validEntries(entries), "generated entries pass the settings validation")
    print("PASS: hidden symbols and decimal overrides survive refreshes")

    // 3) 只改跟随池;没变化时报告 false
    var lists = [Watchlist(name: "Manual", entries: [WatchEntry(symbol: "SPY", market: "us")]),
                 Watchlist(name: "Linked", entries: [], source: ShepherdHoldings.sourceKey, excluded: [])]
    check(ShepherdHoldings.apply(holdings, to: &lists), "first apply changes the linked list")
    check(lists[0].entries.map(\.symbol) == ["SPY"], "manual list untouched")
    check(lists[1].entries.count == holdings.count, "linked list filled")
    check(!ShepherdHoldings.apply(holdings, to: &lists), "second apply is a no-op")
    print("PASS: only linked lists follow the snapshot")

    // 4) 配置:空跟随池不被丢;旧配置没有新字段照样读;未知来源清掉
    var config = TickerConfig()
    config.watchlists = [Watchlist(name: "Manual", entries: [WatchEntry(symbol: "SPY", market: "us")]),
                         Watchlist(name: "Linked", entries: [], source: ShepherdHoldings.sourceKey, excluded: ["x", "X", " "]),
                         Watchlist(name: "Odd", entries: [WatchEntry(symbol: "QQQ", market: "us")], source: "elsewhere", excluded: ["Y"]),
                         Watchlist(name: "Empty", entries: [])]
    config.activeWatchlist = 1
    config.normalize()
    check(config.watchlists.map(\.name) == ["Manual", "Linked", "Odd"], "empty manual list dropped, empty linked kept: \(config.watchlists.map(\.name))")
    check(config.activeWatchlist == 1, "active linked list stays active")
    check(config.watchlists[1].excluded == ["X"], "excluded symbols cleaned")
    check(config.watchlists[2].source == nil && config.watchlists[2].excluded == nil, "unknown source becomes a manual list")
    let round = try JSONDecoder().decode(TickerConfig.self, from: try JSONEncoder().encode(config))
    check(round.watchlists == config.watchlists, "round trip keeps source and hidden symbols")
    let legacy = try JSONDecoder().decode(TickerConfig.self,
        from: Data("{\"watchlists\":[{\"name\":\"Old\",\"entries\":[{\"symbol\":\"SPY\",\"market\":\"us\"}]}]}".utf8))
    check(legacy.watchlists.first?.source == nil && legacy.watchlists.first?.isLinked == false, "old configs read as manual lists")
    print("PASS: linked lists persist in the configuration")

    // 5) 读文件:不存在 / 读不了 / 正常
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whirlpool-shepherd-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("state.json")
    if case .failure(.missing) = ShepherdHoldings.read(file) {} else { fatalError("FAIL: missing file") }
    try Data("not json".utf8).write(to: file)
    if case .failure(.unreadable) = ShepherdHoldings.read(file) {} else { fatalError("FAIL: unreadable file") }
    try Data(fixture.utf8).write(to: file)
    guard case .success(let snapshot) = ShepherdHoldings.read(file) else { fatalError("FAIL: valid file") }
    check(snapshot.holdings == holdings && snapshot.modified != nil, "read returns holdings and modification time")
    print("PASS: missing, unreadable and valid snapshot files")

    // 6) 设置页:新建跟随池、移除=隐藏、保存带上来源、再点不重复建、停止跟随
    _ = NSApplication.shared
    setenv("WHIRLPOOL_SHEPHERD_STATE", file.path, 1)
    defer { unsetenv("WHIRLPOOL_SHEPHERD_STATE") }
    let language = L10n.language; L10n.language = "en"
    defer { L10n.language = language }
    var base = TickerConfig(); base.provider = "demo"; base.language = "en"
    try writeConfig(base, to: configURL)
    let controller = ConfigWindowController(config: base); controller.show()
    let window = NSApp.windows.first { ($0.delegate as AnyObject?) === controller }!
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    func descendants(_ view: NSView) -> [NSView] {
        // 没选中的设置页不在视图树里,从 NSTabView 的各页取
        let pages = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? []
        return [view] + (view.subviews + pages).flatMap(descendants)
    }
    func control<T: NSView>(_ id: String, as type: T.Type) -> T {
        guard let v = descendants(window.contentView!).first(where: { $0.identifier?.rawValue == id }) as? T else { fatalError("Missing control: \(id)") }
        return v
    }
    func click(_ id: String) { control(id, as: NSButton.self).performClick(nil) }
    let picker = control("watchlist-picker", as: NSPopUpButton.self)
    let table = control("watchlist-table", as: NSTableView.self)
    let restore = control("shepherd-restore", as: NSButton.self)
    check(restore.isHidden && control("watchlist-add", as: NSButton.self).isEnabled, "manual list shows manual controls")

    click("follow-shepherd")
    check(picker.titleOfSelectedItem == "Shepherd Holdings" && picker.numberOfItems == 2, "linked list created and selected")
    check(table.numberOfRows == holdings.count, "table shows every holding: \(table.numberOfRows)")
    check(!control("watchlist-add", as: NSButton.self).isEnabled, "adding symbols is disabled on a linked list")
    check(!restore.isHidden && !restore.isEnabled, "nothing hidden yet")
    check(control("shepherd-note", as: NSTextField.self).stringValue.hasPrefix("Follows Shepherd holdings"), "note explains the source")
    // 切到自选页再量排版
    if let tabs = descendants(window.contentView!).compactMap({ $0 as? NSTabView }).first,
       let page = tabs.tabViewItems.firstIndex(where: { $0.view.map { descendants($0).contains(table) } ?? false }) {
        tabs.selectTabViewItem(at: page)
    }
    window.contentView?.layoutSubtreeIfNeeded()
    let follow = control("follow-shepherd", as: NSButton.self)
    let unlink = control("shepherd-unlink", as: NSButton.self)
    let root = window.contentView!
    check(unlink.convert(unlink.bounds, to: root).maxX <= root.bounds.maxX + 0.5, "follow row fits the window")
    check(follow.convert(follow.bounds, to: root).maxX < unlink.convert(unlink.bounds, to: root).minX, "follow row buttons do not overlap")

    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    click("watchlist-remove")
    check(table.numberOfRows == holdings.count - 1 && restore.isEnabled && restore.title == "Show Hidden (1)", "remove hides a symbol")
    var saved: TickerConfig?
    controller.onApplied = { saved = $0 }
    click("settings-save")
    guard let applied = saved, let linked = applied.watchlists.first(where: { $0.isLinked }) else { fatalError("FAIL: linked list not saved") }
    check(linked.excluded == ["AAPL"] && !linked.entries.contains { $0.symbol == "AAPL" }, "hidden symbol saved: \(linked)")
    check(applied.watchlists[applied.activeWatchlist].isLinked, "the new linked list becomes active")
    let reread = try readConfig(at: configURL)
    check(reread.watchlists.first { $0.isLinked }?.excluded == ["AAPL"], "linked list written to disk")

    controller.reload(config: applied); controller.show()
    picker.selectItem(at: 0); _ = picker.sendAction(picker.action, to: picker.target)
    check(control("watchlist-add", as: NSButton.self).isEnabled, "switching back to the manual list re-enables adding")
    click("follow-shepherd")
    check(picker.numberOfItems == 2 && picker.titleOfSelectedItem == "Shepherd Holdings", "follow again selects the existing list")
    click("shepherd-restore")
    check(table.numberOfRows == holdings.count && !restore.isEnabled, "show hidden brings the symbol back")
    click("shepherd-unlink")
    check(control("watchlist-add", as: NSButton.self).isEnabled && restore.isHidden, "stop following makes it a manual list")
    window.close()
    print("PASS: settings create, hide, restore, save and unlink a Shepherd-linked list")

    // 7) 中文:新字符串都有译文,占位符和英文一致;多套列表统一叫「自选池」
    let keys = ["Follow Shepherd Holdings", "Shepherd Holdings", "Stop Following", "Show Hidden (%d)",
                "Shepherd Holdings Not Found",
                "Follows Shepherd holdings (%@, updated %@). Options show their underlying stock; larger positions come first. Remove hides a symbol until you show it again.",
                "Shepherd holdings file not found: %@. The list keeps its last symbols and updates once the file appears.",
                "Shepherd holdings file could not be read: %@. The list keeps its last symbols.",
                "No Shepherd holdings file at %@. Open Shepherd and refresh holdings first, or set WHIRLPOOL_SHEPHERD_STATE to the file path."]
    func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%[@dsf]")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }
    }
    for key in keys {
        guard let zh = L10n.chinese[key] else { fatalError("FAIL: missing Chinese for \(key)") }
        check(placeholders(zh) == placeholders(key), "placeholders differ: \(key)")
        check(!zh.contains("列表"), "use 自选池, not 列表: \(zh)")
    }
    L10n.language = "zh-Hans"
    check(String(format: L("Show Hidden (%d)"), 2) == "恢复隐藏的（2）", "Chinese count label")
    check(L("Shepherd Holdings") == "Shepherd 持仓", "Chinese list name")
    print("PASS: Chinese strings cover the Shepherd list with matching placeholders")
}
