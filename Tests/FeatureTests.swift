import AppKit

// 1.9:交易所节假日、按品种小数位、多自选池、新版本检查

private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    if !condition { fatalError("FAIL line \(line): \(message())") }
}

private func date(_ s: String, _ zone: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: zone); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

func runFeatureTests() throws {
    // 1) NYSE 规则推算 = 纽交所官网公布的 2026/2027 休市日与 13:00 提前收盘日
    let nyse2026: Set<String> = ["2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25",
                                 "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25"]
    let nyse2027: Set<String> = ["2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31",
                                 "2027-06-18", "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24"]
    check(MarketClock.nyseHolidays(2026) == nyse2026, "NYSE 2026 \(MarketClock.nyseHolidays(2026).sorted())")
    check(MarketClock.nyseHolidays(2027) == nyse2027, "NYSE 2027 \(MarketClock.nyseHolidays(2027).sorted())")
    check(MarketClock.nyseEarlyClose(2026) == ["2026-11-27", "2026-12-24"], "NYSE 2026 early \(MarketClock.nyseEarlyClose(2026).sorted())")
    check(MarketClock.nyseEarlyClose(2027) == ["2027-11-26"], "NYSE 2027 early \(MarketClock.nyseEarlyClose(2027).sorted())")
    check(MarketClock.easter(2026) == (4, 5) && MarketClock.easter(2027) == (3, 28), "Easter")
    print("PASS: NYSE holiday rules match the official 2026-2027 calendar")

    // 2) 各市场节假日、半日市、提前收盘、跨长假的下一次开盘
    let spy = WatchEntry(symbol: "SPY", market: "us")
    let moutai = WatchEntry(symbol: "600519", market: "cn")
    let tencent = WatchEntry(symbol: "700", market: "hk")
    check(!MarketClock.isOpen(spy, at: date("2026-11-26 11:00", "America/New_York")), "Thanksgiving closed")
    check(MarketClock.isOpen(spy, at: date("2026-11-27 12:30", "America/New_York")), "day after Thanksgiving morning open")
    check(!MarketClock.isOpen(spy, at: date("2026-11-27 13:30", "America/New_York")), "early close at 13:00")
    check(!MarketClock.isOpen(tencent, at: date("2026-02-17 10:00", "Asia/Hong_Kong")), "HK Lunar New Year closed")
    check(MarketClock.isOpen(tencent, at: date("2026-02-16 11:00", "Asia/Hong_Kong")), "HK half day morning open")
    check(!MarketClock.isOpen(tencent, at: date("2026-02-16 13:30", "Asia/Hong_Kong")), "HK half day afternoon closed")
    check(MarketClock.isOpen(tencent, at: date("2026-09-18 12:30", "Asia/Hong_Kong")), "HK extended morning session")
    check(!MarketClock.isOpen(tencent, at: date("2027-02-08 10:00", "Asia/Hong_Kong")), "HK 2027 holiday closed")
    check(!MarketClock.isOpen(moutai, at: date("2026-10-05 10:00", "Asia/Shanghai")), "CN National Day closed")
    check(MarketClock.isOpen(moutai, at: date("2026-10-08 10:00", "Asia/Shanghai")), "CN reopens Oct 8")
    check(MarketClock.nextOpen(moutai, after: date("2026-09-30 16:00", "Asia/Shanghai")) == date("2026-10-08 09:10", "Asia/Shanghai"),
          "next CN open skips Golden Week")
    check(MarketClock.isOpen(moutai, at: date("2027-10-04 10:00", "Asia/Shanghai")), "unpublished CN year falls back to weekdays open")
    // 实时兜底:日历说休市,但 2 分钟前还有成交 → 按原间隔拉
    let holiday = date("2026-10-05 10:00", "Asia/Shanghai")
    check(MarketClock.refreshInterval([moutai], base: 30, now: holiday) > 30, "holiday backs off")
    check(MarketClock.refreshInterval([moutai], base: 30, now: holiday,
                                      lastTrade: ["600519": holiday.addingTimeInterval(-120)]) == 30,
          "fresh trade timestamp overrides the calendar")
    print("PASS: exchange holidays, half days, early closes and live-trade override")

    // 2.0.5:Yahoo 代码按交易所后缀定日历;没有建模日历的交易所不判休市
    let venues: [(String, MarketClock.Exchange?)] = [
        ("SPY", .nyse), ("BRK-B", .nyse), ("BRK.B", .nyse), ("BF.B", .nyse), ("HEI.A", .nyse), ("^GSPC", .nyse), ("^HSI", .hkex), ("0700.HK", .hkex),
        ("000001.SS", .sse), ("399001.SZ", .sse), ("^N225", nil), ("7203.T", nil), ("VOD.L", nil),
        ("ES=F", nil), ("EURUSD=X", nil), ("BTC-USD", nil), ("ETH-EUR", nil)]
    for (symbol, venue) in venues {
        check(MarketClock.exchange(for: WatchEntry(symbol: symbol, market: "us")) == venue, "Yahoo venue for \(symbol)")
    }
    let tokyoMorning = date("2026-09-24 10:00", "Asia/Tokyo")   // 纽约周三 21:00
    let toyota = WatchEntry(symbol: "7203.T", market: "us")
    check(MarketClock.isOpen(toyota, at: tokyoMorning), "Tokyo listing is not held to NYSE hours")
    check(MarketClock.refreshInterval([toyota], base: 30, now: tokyoMorning) == 30
          && MarketClock.refreshInterval([spy, toyota], base: 30, now: tokyoMorning) == 30, "a Tokyo listing keeps the base cadence")
    check(MarketClock.refreshInterval([spy], base: 30, now: tokyoMorning) > 30, "NYSE alone still backs off overnight")
    print("PASS: Yahoo symbols follow their own exchange")

    // 3) 按品种小数位:手动 > 行情源 > 港股价位表 > 2 位;闪变按同一精度比较
    let etf = WatchEntry(symbol: "510300", market: "cn")
    var hinted = Quote(price: 4.582, changePct: 1.1, series: nil, sessionStart: nil, sessionEnd: nil)
    hinted.decimals = 3
    check(QuoteEngine.decimals(for: etf, quote: hinted) == 3, "source hint")
    check(QuoteEngine.decimals(for: WatchEntry(symbol: "510300", market: "cn", decimals: 2), quote: hinted) == 2, "manual override wins")
    check(QuoteEngine.decimals(for: tencent, quote: Quote(price: 0.315, changePct: 0, series: nil, sessionStart: nil, sessionEnd: nil)) == 3, "HK penny tick")
    check(QuoteEngine.decimals(for: tencent, quote: Quote(price: 419, changePct: 0, series: nil, sessionStart: nil, sessionEnd: nil)) == 2, "HK normal")
    check(QuoteEngine.decimals(for: spy, quote: nil) == 2, "default 2")
    check(PriceFlash.priceText(4.582, decimals: 3) == "4.582" && PriceFlash.priceText(1.14895, decimals: 4) == "1.1490", "format")
    let flash = PriceFlash.between(4.580, and: 4.582, redUp: true, decimals: 3)
    check(flash?.prefix == "4.58" && flash?.suffix == "2" && flash?.color == .red, "3-decimal flash suffix")
    check(PriceFlash.between(4.580, and: 4.582, redUp: true) == nil, "2-decimal rounding hides the tick (why precision matters)")
    let text = QuoteEngine.marqueeText(entries: [etf], quotes: ["510300": hinted], redUpMarkets: ["cn"],
                                       pausePerSymbol: 0, previousTicks: ["510300": 4.580])
    check(text.contains("4.58\\b[1:red]2\\b[0]"), "marquee uses per-instrument precision: \(text)")
    let rows = QuoteEngine.boardRows(entries: [etf], quotes: ["510300": hinted])
    check(rows.first?.price == "4.582" && rows.first?.decimals == 3, "board uses per-instrument precision")
    // 腾讯报价串:A 股精度来自价格串,港股交给价位表;时间戳两种格式
    var fields = [String](repeating: "0", count: 40)
    fields[3] = "4.582"; fields[30] = "20260918161452"; fields[32] = "1.10"
    let (code, q) = try unwrap(RealProvider().parseTencentLine("v_sh510300=\"" + fields.joined(separator: "~") + "\""))
    check(code == "sh510300" && q.decimals == 3 && q.marketTime == date("2026-09-18 16:14", "Asia/Shanghai").addingTimeInterval(52),
          "tencent CN precision and time")
    fields[3] = "419.000"; fields[30] = "2026/09/18 16:08:32"
    let (_, hk) = try unwrap(RealProvider().parseTencentLine("v_hk00700=\"" + fields.joined(separator: "~") + "\""))
    check(hk.decimals == nil && hk.marketTime == date("2026-09-18 16:08", "Asia/Hong_Kong").addingTimeInterval(32), "tencent HK")
    // 美股同族布局:精度来自价格串,时间戳是美东的 yyyy-MM-dd 格式
    fields[3] = "338.45"; fields[30] = "2026-09-25 11:41:20"; fields[32] = "0.75"
    let (usCode, us) = try unwrap(RealProvider().parseTencentLine("v_usAAPL=\"" + fields.joined(separator: "~") + "\""))
    check(usCode == "usAAPL" && us.decimals == 2 && us.marketTime == date("2026-09-25 11:41", "America/New_York").addingTimeInterval(20),
          "tencent US precision and time")
    // 简称:A 股/港股取腾讯第 2 段并清理,美股不取(示例名称与价格为虚构)
    fields[1] = "XD示例银行"; fields[3] = "8.88"; fields[30] = "20260918150003"
    let (_, named) = try unwrap(RealProvider().parseTencentLine("v_sh600000=\"" + fields.joined(separator: "~") + "\""))
    check(named.name == "示例银行", "tencent CN short name, ex-dividend prefix removed: \(named.name ?? "nil")")
    fields[1] = "示例科技-W"; fields[3] = "50.000"; fields[30] = "2026/09/18 16:08:32"
    let (_, hkNamed) = try unwrap(RealProvider().parseTencentLine("v_hk09999=\"" + fields.joined(separator: "~") + "\""))
    check(hkNamed.name == "示例科技", "tencent HK short name, -W suffix removed")
    fields[1] = "Example Inc"; fields[3] = "17.35"; fields[30] = "2026-09-25 11:41:20"
    let (_, usNamed) = try unwrap(RealProvider().parseTencentLine("v_usEXMP=\"" + fields.joined(separator: "~") + "\""))
    check(usNamed.name == nil, "US names are not used")
    check(QuoteEngine.cleanName("XDR") == "XDR" && QuoteEngine.cleanName("DR") == "DR", "ASCII-only names are kept as is")
    let cnEntry = WatchEntry(symbol: "600000", market: "cn")
    let usEntry = WatchEntry(symbol: "EXMP", market: "us")
    check(QuoteEngine.label(for: cnEntry, quote: named, symbolNames: true, asciiOnly: false) == "示例银行", "name shown when chosen")
    check(QuoteEngine.label(for: cnEntry, quote: named, symbolNames: false, asciiOnly: false) == "600000", "code shown by default")
    check(QuoteEngine.label(for: cnEntry, quote: named, symbolNames: true, asciiOnly: true) == "600000", "LED dot font keeps the code")
    check(QuoteEngine.label(for: cnEntry, quote: nil, symbolNames: true, asciiOnly: false) == "600000", "no quote, no name")
    var usWithName = usNamed; usWithName.name = "Example Inc"
    check(QuoteEngine.label(for: usEntry, quote: usWithName, symbolNames: true, asciiOnly: false) == "EXMP", "US keeps tickers")
    let namedRows = QuoteEngine.boardRows(entries: [cnEntry], quotes: ["600000": named], symbolNames: true)
    check(namedRows.first?.label == "示例银行" && namedRows.first?.symbol == "600000", "board shows the name, keeps the code as identity")
    let namedText = QuoteEngine.marqueeText(entries: [cnEntry], quotes: ["600000": named], redUpMarkets: [],
                                            pausePerSymbol: 0, symbolNames: true)
    check(namedText.hasPrefix("示例银行 "), "marquee shows the name: \(namedText)")
    var namedConfig = TickerConfig(); namedConfig.symbolNames = true
    let roundTrip = try JSONDecoder().decode(TickerConfig.self, from: JSONEncoder().encode(namedConfig))
    check(roundTrip.symbolNames && !TickerConfig().symbolNames, "symbol name choice saves; default is code")
    check(RealProvider.usCodeAllowed("AAPL") && RealProvider.usCodeAllowed("BRK.A") && RealProvider.usCodeAllowed("BF-B"),
          "plain US tickers allowed")
    check(!RealProvider.usCodeAllowed("^GSPC") && !RealProvider.usCodeAllowed("BTC USD") && !RealProvider.usCodeAllowed(""),
          "odd symbols go straight to Yahoo")
    check(RealProvider().tencentCode(WatchEntry(symbol: "AAPL", market: "us")) == "usAAPL", "tencent US code")
    // 东财:三个上市组前缀候选,^指数给空;diff 行拒停牌 "-";trends2 北京时间 → epoch
    check(RealProvider.eastMoneySecids("SPY") == ["105.SPY", "106.SPY", "107.SPY"] && RealProvider.eastMoneySecids("^GSPC").isEmpty,
          "eastmoney secid candidates")
    let emRow = try unwrap(RealProvider.parseEastMoneyRow(["f2": 929.615, "f3": 0.69, "f12": "GS", "f13": 106, "f124": 1790352659]))
    check(emRow.secid == "106.GS" && emRow.price == 929.615 && emRow.changePct == 0.69, "eastmoney snapshot row")
    check(RealProvider.parseEastMoneyRow(["f2": "-", "f3": "-", "f12": "HALT", "f13": 105]) == nil, "eastmoney halted row rejected")
    check(RealProvider.eastMoneyDecimals(339.345) == 2 && RealProvider.eastMoneyDecimals(0.5234) == 4, "eastmoney precision")
    check(RealProvider.eastMoneySecids("brk.b") == ["105.BRK_B", "106.BRK_B", "107.BRK_B"]
          && RealProvider.yahooUSSymbol("BRK.B") == "BRK-B" && RealProvider.yahooUSSymbol("^GSPC") == "^GSPC"
          && RealProvider.yahooUSSymbol("VOD.L") == "VOD.L" && RealProvider.yahooUSSymbol("0700.HK") == "0700.HK"
          && RealProvider.eastMoneySecids("7203.T").isEmpty && RealProvider.eastMoneySecids("VOD.L").isEmpty,
          "share-class tickers use each source's spelling")
    let em = try unwrap(RealProvider.parseEastMoneyTrends(["2026-09-25 21:30,335.950", "2026-09-25 21:31,336.100", "bad"], preClose: 336.04))
    check(em.series.count == 2 && em.series[0].t == date("2026-09-25 09:30", "America/New_York").timeIntervalSince1970
          && em.end - em.start == 6.5 * 3600 && em.lastPrice == 336.1 && em.preClose == 336.04,
          "eastmoney intraday trend in exchange time")
    check(RealProvider.parseEastMoneyTrends(["2026-09-25 21:30,335.950"], preClose: 1) == nil, "single-point trend ignored")
    print("PASS: per-instrument price precision end to end")

    // 4) 多自选池:旧配置迁移、写回兼容旧键、空池/重名/越界规整、小数位随配置往返
    let old = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"watchlist\":[{\"symbol\":\"qqq\",\"market\":\"us\"}]}".utf8))
    check(old.watchlists.count == 1 && old.watchlist == [WatchEntry(symbol: "QQQ", market: "us")], "migrate single list")
    var cfg = TickerConfig()
    cfg.watchlists = [Watchlist(name: "Tech", entries: [WatchEntry(symbol: "AAPL", market: "us", decimals: 3)]),
                      Watchlist(name: "Tech", entries: [WatchEntry(symbol: "600519", market: "cn")]),
                      Watchlist(name: "Empty", entries: [])]
    cfg.activeWatchlist = 1
    let data = try JSONEncoder().encode(cfg)
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    check((raw["watchlist"] as? [[String: Any]])?.first?["symbol"] as? String == "600519", "legacy key mirrors the active list")
    let back = try JSONDecoder().decode(TickerConfig.self, from: data)
    check(back.watchlists.map(\.name) == ["Tech", "Tech 2"], "empty list dropped, duplicate name suffixed: \(back.watchlists.map(\.name))")
    check(back.activeWatchlist == 1 && back.watchlist.first?.symbol == "600519", "active list survives")
    check(back.watchlists[0].entries.first?.decimals == 3, "decimals round-trip")
    var clamp = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"watchlists\":[{\"name\":\"A\",\"entries\":[{\"symbol\":\"SPY\",\"market\":\"us\"}]}],\"activeWatchlist\":7}".utf8))
    check(clamp.activeWatchlist == 0, "active index clamped")
    clamp.watchlist = [WatchEntry(symbol: "TLT", market: "us")]
    check(clamp.watchlists[0].entries.first?.symbol == "TLT", "watchlist setter edits the active list")
    // 改名前的 ~/.config/pinwheel 配置:只在新配置不存在时复制一次,原文件保留
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("whirlpool-migrate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let legacy = tmp.appendingPathComponent("pinwheel/config.json"), target = tmp.appendingPathComponent("whirlpool/config.json")
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"watchlist\":[{\"symbol\":\"TLT\",\"market\":\"us\"}]}".utf8).write(to: legacy)
    check(migrateLegacyConfig(from: legacy, to: target), "legacy config copied")
    check(try readConfig(at: target).watchlist.first?.symbol == "TLT" && FileManager.default.fileExists(atPath: legacy.path), "migrated content, original kept")
    check(!migrateLegacyConfig(from: legacy, to: target), "migration runs once")
    print("PASS: multiple watchlists with migration and backward-compatible saves")

    // 1.9.1:默认只开菜单栏跑马灯;显示器默认不指定,选择可往返,未连接的屏不致命
    let fresh = TickerConfig()
    check(fresh.displayMode == "marquee" && fresh.displayScreen == "auto", "defaults: menu bar ticker only, automatic screen")
    let decodedDefaults = try JSONDecoder().decode(TickerConfig.self, from: Data("{}".utf8))
    check(decodedDefaults.displayMode == "marquee" && decodedDefaults.displayScreen == "auto", "empty config decodes to menu-bar-only")
    var pinned = TickerConfig(); pinned.displayScreen = "ADB8A3ED-1456-4C11-8A01-20A0696BFBAA"
    check(try JSONDecoder().decode(TickerConfig.self, from: JSONEncoder().encode(pinned)).displayScreen == pinned.displayScreen, "screen choice round-trips")
    check(chosenScreen("auto") == nil && chosenScreen("NOT-CONNECTED") == nil && placementScreen("NOT-CONNECTED") != nil, "unknown screen falls back")
    if let first = NSScreen.screens.first, let id = first.stableID { check(chosenScreen(id)?.displayID == first.displayID, "screen found by stable id") }
    print("PASS: defaults and screen choice")

    // 5) 新版本检查:版本号解析与比较、Release JSON(草稿/预发布忽略)
    check(UpdateChecker.parseVersion("v1.6.0-main") == [1, 6, 0], "tag parse")
    check(UpdateChecker.isNewer("1.9.0", than: "1.8.0") && UpdateChecker.isNewer("1.10", than: "1.9.9"), "newer")
    check(!UpdateChecker.isNewer("1.6.0", than: "1.8.0") && !UpdateChecker.isNewer("1.8", than: "1.8.0"), "not newer")
    check(!UpdateChecker.isNewer("2.0.0", than: "dev"), "dev builds never prompt")
    let release = UpdateChecker.parseRelease(Data("""
        {"tag_name":"v1.9.0-main","name":"Whirlpool v1.9.0","html_url":"https://github.com/NexusKFK/whirlpool/releases/tag/v1.9.0-main","draft":false,"prerelease":false}
        """.utf8))
    check(release?.version == "1.9.0" && release?.page.absoluteString.hasSuffix("v1.9.0-main") == true, "release parse")
    check(UpdateChecker.parseRelease(Data("{\"tag_name\":\"v2.0.0\",\"prerelease\":true}".utf8)) == nil, "prerelease ignored")
    let suite = UserDefaults(suiteName: "whirlpool-tests-\(UUID().uuidString)")!
    let checker = UpdateChecker(current: "1.8.0", defaults: suite)
    let r = UpdateChecker.Release(version: "1.9.0", name: "v1.9.0", page: UpdateChecker.releasesPage)
    check(checker.shouldAnnounce(r) && !checker.shouldAnnounce(r), "announce once per version")
    check(!checker.isSkipped(r), "not skipped yet"); checker.skip(r); check(checker.isSkipped(r), "skip this version")
    print("PASS: update checker version logic and release parsing")

    // 持仓板:盈亏符号跟随 ▲/▼ 开关;多头省略 +,空头写 −;期权小字压成 1@4.25
    check(PortfolioWindow.money(1234.5, sign: true, arrows: true) == "▲$1,234.50", "arrow gain")
    check(PortfolioWindow.money(-1234.5, sign: true, arrows: true) == "▼$1,234.50", "arrow loss")
    check(PortfolioWindow.money(1234.5, sign: true) == "+$1,234.50", "plus gain")
    check(PortfolioWindow.money(-1234.5, sign: true) == "−$1,234.50", "minus loss")
    check(PortfolioWindow.money(0, sign: true, arrows: true) == "$0.00", "zero has no sign")
    check(PortfolioWindow.pct(2.34, arrows: true) == "▲2.3%", "arrow pct gain")
    check(PortfolioWindow.pct(-2.34, arrows: true) == "▼2.3%", "arrow pct loss")
    check(PortfolioWindow.pct(2.34) == "+2.3%", "plus pct")
    check(PortfolioWindow.pct(0, arrows: true) == "0.0%", "flat pct")
    check(PortfolioWindow.quantity(300) == "300" && PortfolioWindow.quantity(-2) == "−2", "quantity signs")
    let firstMouse = FirstMouseButton(title: "", target: nil, action: nil)
    check(firstMouse.acceptsFirstMouse(for: nil), "portfolio buttons accept the first click while the app is inactive")
    func position(_ label: String, kind: String, qty: Double, cost: Double?, legs: Int? = nil,
                  net: Double? = nil, spreads: Int? = nil) -> PortfolioWindow.Snapshot.Position {
        PortfolioWindow.Snapshot.Position(label: label, kind: kind, secType: kind, qty: qty, last: nil,
                                          mktValue: nil, costBasis: cost, unrealized: nil, unrealizedPct: nil,
                                          dayPnl: nil, legCount: legs, netCost: net, netMark: nil, spreadCount: spreads)
    }
    check(PortfolioWindow.detail(position("BIL", kind: "STK", qty: 250, cost: 22090)) == "250 @ $88.36", "long stock sub-line")
    check(PortfolioWindow.detail(position("BIL", kind: "STK", qty: -250, cost: -22090)) == "−250 @ $88.36", "short stock sub-line")
    check(PortfolioWindow.detail(position("KO 26-12-18 60P", kind: "OPT", qty: 1, cost: 425)) == "1 @ $4.25", "long option sub-line")
    check(PortfolioWindow.detail(position("KO 26-12-18 60P", kind: "OPT", qty: -2, cost: -170)) == "−2 @ $0.85", "short option sub-line")
    check(PortfolioWindow.detail(position("XLK 250/260C 26DEC18", kind: "SPREAD", qty: 1, cost: 340,
                                          legs: 2, net: 340, spreads: 1)) == "1 @ $3.40", "single spread sub-line")
    check(PortfolioWindow.detail(position("XLK 250/260C 26DEC18", kind: "SPREAD", qty: 2, cost: 680,
                                          legs: 2, net: 680, spreads: 2)) == "2 @ $3.40", "multiple spreads sub-line")
    let closeSnap = try JSONDecoder().decode(PortfolioWindow.Snapshot.self,
                                             from: Data("{\"connected\":true,\"mode\":\"close\"}".utf8))
    check(closeSnap.mode == "close" && closeSnap.provisional == nil, "close snapshot mode decodes")

    // 正股行价格口径(示例价格为虚构)
    let mondayNight = date("2026-03-09 00:10", "America/New_York")     // 周一凌晨,夜盘时段
    let mondayOpen = date("2026-03-09 11:00", "America/New_York")
    let fridayClose = date("2026-03-06 16:00", "America/New_York")
    let fridayQuote = Quote(price: 50.25, changePct: -3.8, series: nil, sessionStart: nil, sessionEnd: nil,
                            marketTime: fridayClose)
    let ibNight = PortfolioWindow.stockPriceView(mode: "live", connected: true, extendedOn: true,
                                                 feederPrice: 51.10, fallback: nil, snapshotTime: mondayNight,
                                                 now: mondayNight)
    check(ibNight == .init(price: 51.10, moon: true, tone: .normal, dayValid: true),
          "IB online outside the session shows its price with the moon")
    let ibDay = PortfolioWindow.stockPriceView(mode: "live", connected: true, extendedOn: true,
                                               feederPrice: 51.10, fallback: nil, snapshotTime: mondayOpen,
                                               now: mondayOpen)
    check(!ibDay.moon && ibDay.price == 51.10, "regular session never shows the moon")
    let closeView = PortfolioWindow.stockPriceView(mode: "close", connected: true, extendedOn: false,
                                                   feederPrice: 50.25, fallback: nil, snapshotTime: fridayClose,
                                                   now: mondayNight)
    check(!closeView.moon && closeView.price == 50.25, "close snapshot shows the close price without the moon")
    let offlineNight = PortfolioWindow.stockPriceView(mode: "live", connected: false, extendedOn: true,
                                                      feederPrice: 52.00, fallback: fridayQuote,
                                                      snapshotTime: fridayClose, now: mondayNight)
    check(offlineNight == .init(price: 50.25, moon: false, tone: .dim, dayValid: false),
          "gateway offline at night: last regular close, no moon, Friday's move is not today's P&L")
    let todayQuote = Quote(price: 50.25, changePct: 1.2, series: nil, sessionStart: nil, sessionEnd: nil,
                           marketTime: mondayOpen)
    let offlineOpen = PortfolioWindow.stockPriceView(mode: "live", connected: false, extendedOn: true,
                                                     feederPrice: 52.00, fallback: todayQuote,
                                                     snapshotTime: fridayClose, now: mondayOpen)
    check(offlineOpen == .init(price: 50.25, moon: false, tone: .normal, dayValid: true),
          "gateway offline in the session: fallback quote of today still counts as today")
    let offlineBare = PortfolioWindow.stockPriceView(mode: "live", connected: false, extendedOn: true,
                                                     feederPrice: 52.00, fallback: nil,
                                                     snapshotTime: fridayClose, now: mondayNight)
    check(offlineBare.price == 52.00 && !offlineBare.dayValid && offlineBare.tone == .dim,
          "gateway offline without a fallback quote: frozen price, stale day P&L hidden")
    let justDropped = PortfolioWindow.stockPriceView(mode: "live", connected: false, extendedOn: true,
                                                     feederPrice: 52.00, fallback: nil,
                                                     snapshotTime: mondayNight.addingTimeInterval(-60),
                                                     now: mondayNight)
    check(justDropped.dayValid, "a snapshot from a minute ago still shows its day P&L")
    check(PortfolioWindow.stockPrice(123) == "123.00" && PortfolioWindow.stockPrice(0.5) == "0.5000"
          && PortfolioWindow.stockPrice(nil) == "—", "stock price formatting")
    check(PortfolioWindow.parseTime("2026-03-09T00:10:00-04:00") == mondayNight, "feeder time parses")
    // 分时缩略图午休拼接
    let cnPts = [SeriesPt(t: 9.5 * 3600, v: 1), SeriesPt(t: 11.5 * 3600, v: 2), SeriesPt(t: 13 * 3600, v: 2), SeriesPt(t: 14 * 3600, v: 3)]
    let cnBreaks = SparklineView.lunchBreaks(market: "cn", session: (9.5 * 3600, 15 * 3600), points: cnPts)
    check(cnBreaks.count == 1 && cnBreaks[0].start == 11.5 * 3600 && cnBreaks[0].end == 13 * 3600, "A-share lunch break found")
    let c = { (t: Double) in SparklineView.compressed(t, breaks: cnBreaks) }
    check(c(11.5 * 3600) == c(13 * 3600), "11:30 and 13:00 meet at the same x")
    check((c(11.5 * 3600) - c(9.5 * 3600)) / (c(15 * 3600) - c(9.5 * 3600)) == 0.5, "the morning is half of the 4-hour day")
    check(SparklineView.compressed(14 * 3600, breaks: []) == 14 * 3600, "no break, real time")
    let hkMorning = [SeriesPt(t: 9.5 * 3600, v: 1), SeriesPt(t: 11 * 3600, v: 2)]
    check(SparklineView.lunchBreaks(market: "hk", session: (9.5 * 3600, 16 * 3600), points: hkMorning).count == 1,
          "HK lunch hour is squeezed when nothing traded in it")
    let hkThrough = hkMorning + [SeriesPt(t: 12.5 * 3600, v: 2)]
    check(SparklineView.lunchBreaks(market: "hk", session: (9.5 * 3600, 16 * 3600), points: hkThrough).isEmpty,
          "HK lunch hour with trades stays on real time")
    check(SparklineView.lunchBreaks(market: "us", session: (9.5 * 3600, 16 * 3600), points: cnPts).isEmpty
          && SparklineView.lunchBreaks(market: "cn", session: (1.79e9, 1.79e9 + 19_800), points: cnPts).isEmpty,
          "US and epoch-clock series are left alone")
    // A 股和港股同卡:共用 9:30-16:00,只扣共同午休;同一时刻停在同一位置
    let hkPts = [SeriesPt(t: 9.5 * 3600, v: 1), SeriesPt(t: 12 * 3600, v: 2), SeriesPt(t: 13 * 3600, v: 2), SeriesPt(t: 14 * 3600, v: 3)]
    let axis = try unwrap(SparklineView.sharedAxis([("cn", (9.5 * 3600, 15 * 3600), cnPts), ("hk", (9.5 * 3600, 16 * 3600), hkPts)]))
    check(axis.session.start == 9.5 * 3600 && axis.session.end == 16 * 3600, "shared axis spans 9:30-16:00")
    check(axis.breaks.count == 1 && axis.breaks[0].start == 12 * 3600 && axis.breaks[0].end == 13 * 3600, "only the common lunch hour is removed")
    let x = { (t: Double) in
        (SparklineView.compressed(t, breaks: axis.breaks) - SparklineView.compressed(axis.session.start, breaks: axis.breaks))
            / (SparklineView.compressed(axis.session.end, breaks: axis.breaks) - SparklineView.compressed(axis.session.start, breaks: axis.breaks))
    }
    check(abs(x(15 * 3600) - 4.5 / 5.5) < 1e-9, "the A-share close sits at about 82% on the shared axis")
    check(SparklineView.sharedAxis([("cn", (9.5 * 3600, 15 * 3600), cnPts)]) == nil
          && SparklineView.sharedAxis([("hk", (9.5 * 3600, 16 * 3600), hkPts), ("us", (9.5 * 3600, 16 * 3600), hkPts)]) == nil,
          "one local market keeps its own axis")
    check(SparklineView.sharedAxis([("cn", (9.5 * 3600, 15 * 3600), cnPts), ("hk", (9.5 * 3600, 16 * 3600), hkThrough)])?.breaks.isEmpty == true,
          "if HK trades through lunch, nothing is removed")
    print("PASS: portfolio sign style and compact position sub-lines")
}

private func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { fatalError("FAIL line \(line): unexpected nil") }
    return value
}
