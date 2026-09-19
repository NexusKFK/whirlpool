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
}

private func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { fatalError("FAIL line \(line): unexpected nil") }
    return value
}
