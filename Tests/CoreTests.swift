import Foundation

private final class TestProvider: QuoteProvider {
    var name = "real"
    var cooldownUntil: Date?
    var calls = 0
    var requested: [[WatchEntry]] = []
    var responses: [([String: Quote]) -> Void] = []
    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) { calls += 1; requested.append(entries); responses.append(completion) }
}

func runCoreTests() throws {
    let oldJSON = Data("{\"watchlist\":[{\"symbol\":\"QQQ\",\"market\":\"us\"}],\"defaultWidth\":55,\"provider\":\"real\"}".utf8)
    let migrated = try JSONDecoder().decode(TickerConfig.self, from: oldJSON)
    precondition(migrated.watchlist.first?.symbol == "QQQ" && migrated.defaultWidth == 55 && migrated.language == "system")
    precondition(migrated.barWidthFraction == nil && migrated.menuWidthPoints == nil && migrated.barPlacement == "bottom-center",
                 "1.x settings retain their width until the user changes it")
    precondition(TickerConfig().barWidthFraction == 0.60, "new installations default to a 60-percent floating ticker")
    let oldPosition = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"barOrigin\":[10,20]}".utf8))
    precondition(oldPosition.barPlacement == "free", "manual 1.x positions stay free after upgrading")
    let invalidPosition = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"barOrigin\":[10],\"barWidthFraction\":9,\"menuWidthPoints\":1}".utf8))
    precondition(invalidPosition.barPlacement == "bottom-center" && invalidPosition.barWidthFraction == 1 && invalidPosition.menuWidthPoints == 120)
    for mode in ["marquee", "bar", "board", "marquee,bar", "marquee,board", "bar,board", "marquee,bar,board"] {
        var surfaces = TickerConfig(); surfaces.displayMode = mode; surfaces.normalize()
        precondition(surfaces.displayMode == mode, "all nonempty display combinations remain available")
    }
    var reordered = TickerConfig(); reordered.displayMode = "board,bar,marquee"; reordered.normalize()
    precondition(reordered.displayMode == "marquee,bar,board", "display combinations normalize consistently")
    let layoutRoundTrip = try JSONDecoder().decode(TickerConfig.self, from: JSONEncoder().encode(TickerConfig()))
    precondition(layoutRoundTrip.barWidthFraction == 0.60 && layoutRoundTrip.barPlacement == "bottom-center")
    let clamped = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"scrollSpeed\":0,\"boardRefresh\":-1,\"defaultWidth\":1000,\"boardOrigin\":[1],\"language\":\"unknown\",\"ledDotSize\":9}".utf8))
    precondition(clamped.scrollSpeed == 0.02 && clamped.boardRefresh == 5 && clamped.defaultWidth == TickerConfig.maxWidth && clamped.boardOrigin == nil && clamped.language == "system" && clamped.ledDotSize == 3)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    try writeConfig(migrated, to: file)
    let roundTrip = try readConfig(at: file)
    precondition(roundTrip.watchlist == migrated.watchlist)
    try Data("invalid json".utf8).write(to: file)
    precondition((try? readConfig(at: file)) == nil)
    let untouched = try String(contentsOf: file, encoding: .utf8)
    precondition(untouched == "invalid json")
    print("PASS: configuration migration, bounds, atomic round-trip and malformed-file preservation")

    precondition(ConfigWindowController.validEntries([WatchEntry(symbol: "^GSPC", market: "us"), WatchEntry(symbol: "700", market: "hk")]))
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "AAPL", market: "us"), WatchEntry(symbol: "AAPL", market: "us")]))
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "700", market: "hk"), WatchEntry(symbol: "00700", market: "hk")]))
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "BAD\\c[red]", market: "us")]))
    let real = RealProvider()
    precondition(real.tencentCode(WatchEntry(symbol: "700", market: "hk")) == "hk00700")
    precondition(real.tencentCode(WatchEntry(symbol: "510300", market: "cn")) == "sh510300")
    let aShareCodes: [(String, String)] = [("600519", "sh600519"), ("900901", "sh900901"), ("000001", "sz000001"), ("300750", "sz300750"),
                                           ("SH000001", "sh000001"), ("SZ399001", "sz399001"), ("430047", "bj430047"),
                                           ("830799", "bj830799"), ("920118", "bj920118"), ("BJ430047", "bj430047")]
    for (symbol, code) in aShareCodes {
        precondition(real.tencentCode(WatchEntry(symbol: symbol, market: "cn")) == code, "A-share exchange for \(symbol)")
    }
    precondition(ConfigWindowController.validEntries([WatchEntry(symbol: "SH000001", market: "cn"), WatchEntry(symbol: "000001", market: "cn")]),
                 "the SSE Composite and Ping An Bank are different instruments")
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "SZ000001", market: "cn"), WatchEntry(symbol: "000001", market: "cn")]),
                 "a prefix naming the default exchange is a duplicate")
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "SX000001", market: "cn")])
                 && !ConfigWindowController.validEntries([WatchEntry(symbol: "SH00001", market: "cn")]))
    precondition(!ConfigWindowController.validEntries([WatchEntry(symbol: "600519", market: "cn"), WatchEntry(symbol: "600519", market: "us")]),
                 "symbols stay unique across markets")
    print("PASS: watchlist validation, Hong Kong padding and A-share exchange prefixes")

    let originalLanguage = L10n.language
    L10n.language = "en"; precondition(L("Settings…") == "Settings…")
    L10n.language = "zh-Hans"; precondition(L("Settings…") == "设置…")
    L10n.language = originalLanguage
    precondition(QuoteHTTPClient.retryAfter("120") == 120)
    precondition(QuoteHTTPClient.retryAfter("bogus") == nil)
    let epoch = Date(timeIntervalSince1970: 0)
    precondition(QuoteHTTPClient.retryAfter("Thu, 01 Jan 1970 00:02:00 GMT", now: epoch) == 120)
    precondition(QuoteService.retryDelay(1) == 30 && QuoteService.retryDelay(2) == 60 && QuoteService.retryDelay(20) == 900)
    print("PASS: localization and Retry-After / exponential backoff")
    precondition(UpdateChecker.parseVersion("v1.999999999999999999999999999999.2") == nil,
                 "an overflowing version component must not be silently removed")
    for text in ["\\p[nan]", "\\p[inf]", "\\p[-1]"] {
        precondition(parseCode(text, from: text.startIndex) == nil, "invalid pause durations must not reach the timer")
    }
    let sticky = "\\p[sticky:\(Int.max)]"
    if case .pause(.sticky(_, let count))? = parseCode(sticky, from: sticky.startIndex)?.0 {
        precondition(count == 100, "blink counts are bounded before doubling")
    } else { preconditionFailure("sticky marker must parse") }
    precondition(decodeSocketMessage("{\"type\":\"standby\",\"duration\":1e100}")?.duration == 86400)
    print("PASS: malformed version and message timing values are bounded or rejected")

    var now = Date(timeIntervalSince1970: 1000)
    let provider = TestProvider()
    let service = QuoteService(provider: provider, interval: 30, now: { now })
    let entries = [WatchEntry(symbol: "AAPL", market: "us")]
    let quote = Quote(price: 123.45, changePct: -1, series: nil, sessionStart: nil, sessionEnd: nil)
    var callbacks = 0
    for _ in 0..<2 { service.quotes(for: entries) { result in precondition(result["AAPL"]?.price == 123.45); callbacks += 1 } }
    precondition(provider.calls == 1)
    provider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(callbacks == 2)
    service.quotes(for: entries) { _ in callbacks += 1 }; precondition(provider.calls == 1 && callbacks == 3)
    service.requestRefresh(); service.quotes(for: entries) { _ in }; precondition(provider.calls == 1)
    now = now.addingTimeInterval(31)
    service.quotes(for: entries) { result in precondition(result["AAPL"]?.price == 123.45) }
    precondition(provider.calls == 2)
    provider.responses.removeFirst()([:])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(service.status == "Offline · showing last prices")
    service.requestRefresh(); service.quotes(for: entries) { _ in }; precondition(provider.calls == 2)
    now = now.addingTimeInterval(31); provider.cooldownUntil = now.addingTimeInterval(120)
    service.quotes(for: entries) { _ in }; precondition(provider.calls == 2 && service.status == "Rate limited · retrying later")
    print("PASS: shared in-flight requests, cache, stale quote retention, manual-refresh throttling and rate-limit cooldown")

    let scheduledProvider = TestProvider()
    let scheduled = QuoteService(provider: scheduledProvider, interval: 30, now: { now })
    scheduled.cadence = { _, _, _, _ in 1800 }
    scheduled.quotes(for: entries) { _ in }
    scheduledProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    now = now.addingTimeInterval(60)
    scheduled.cadence = nil
    scheduled.quotes(for: entries) { _ in }
    precondition(scheduledProvider.calls == 2, "turning off smart refresh must release the old 30-minute wait")
    scheduledProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    scheduled.interval = 5
    scheduled.quotes(for: entries) { _ in }
    precondition(scheduledProvider.calls == 2, "changing cadence still honors the minimum request spacing")
    now = now.addingTimeInterval(5)
    scheduled.quotes(for: entries) { _ in }
    precondition(scheduledProvider.calls == 3, "shorter refresh interval takes effect without waiting for the old one")
    scheduledProvider.responses.removeFirst()([:])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    scheduled.cadence = nil; scheduled.interval = 10
    now = now.addingTimeInterval(10)
    scheduled.quotes(for: entries) { _ in }
    precondition(scheduledProvider.calls == 3, "cadence changes must not bypass error backoff")
    print("PASS: refresh-setting changes release normal waits while preserving throttling and backoff")

    let seriesProvider = TestProvider()
    let seriesService = QuoteService(provider: seriesProvider, interval: 1800, now: { now })
    seriesService.quotes(for: entries) { _ in }
    seriesService.invalidate() // The board opened while a summary-only request was running.
    seriesProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    seriesService.quotes(for: entries) { _ in }
    precondition(seriesProvider.calls == 1)
    now = now.addingTimeInterval(5)
    seriesService.quotes(for: entries) { _ in }
    precondition(seriesProvider.calls == 2, "an in-flight summary must not erase a pending request for board series")
    seriesProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    print("PASS: opening the quote board during a summary fetch preserves its request for series")

    let partialProvider = TestProvider()
    let partial = QuoteService(provider: partialProvider, interval: 5, now: { now })
    let pair = entries + [WatchEntry(symbol: "BAD", market: "us")]
    partial.quotes(for: pair) { _ in }
    partialProvider.responses.removeFirst()(["AAPL": quote, "BAD": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    now = now.addingTimeInterval(5)
    partial.quotes(for: pair) { _ in }
    partialProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    now = now.addingTimeInterval(5)
    partial.quotes(for: pair) { result in precondition(result["BAD"]?.price == quote.price) }
    precondition(partialProvider.calls == 3, "one unavailable symbol must not slow healthy symbols")
    precondition(partialProvider.requested.last?.map(\.symbol) == ["AAPL"], "failed symbols honor their own backoff")
    partialProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(partial.status == "Some quotes unavailable · showing last prices")
    now = now.addingTimeInterval(25)
    partial.quotes(for: pair) { _ in }
    precondition(partialProvider.requested.last?.count == 2)
    partialProvider.responses.removeFirst()(["AAPL": quote, "BAD": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(partial.status == "Updated", "recovered symbols clear the stale status")
    print("PASS: partial failures retry independently while healthy prices keep refreshing")

    let demoProvider = TestProvider(); demoProvider.name = "demo"
    let demo = QuoteService(provider: demoProvider, interval: 5, now: { now })
    demo.cadence = { _, _, _, _ in 1800 }
    demo.quotes(for: entries) { _ in }; demoProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02)); now = now.addingTimeInterval(5)
    demo.quotes(for: entries) { _ in }
    precondition(demoProvider.calls == 2, "demo prices must keep moving when real markets are closed")
    demoProvider.responses.removeFirst()(["AAPL": quote])
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
