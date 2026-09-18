import Foundation

private final class TestProvider: QuoteProvider {
    var name = "real"
    var cooldownUntil: Date?
    var calls = 0
    var responses: [([String: Quote]) -> Void] = []
    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) { calls += 1; responses.append(completion) }
}

func runCoreTests() throws {
    let oldJSON = Data("{\"watchlist\":[{\"symbol\":\"QQQ\",\"market\":\"us\"}],\"defaultWidth\":55,\"provider\":\"real\"}".utf8)
    let migrated = try JSONDecoder().decode(TickerConfig.self, from: oldJSON)
    precondition(migrated.watchlist.first?.symbol == "QQQ" && migrated.defaultWidth == 55 && migrated.language == "system")
    let clamped = try JSONDecoder().decode(TickerConfig.self, from: Data("{\"scrollSpeed\":0,\"boardRefresh\":-1,\"defaultWidth\":1000,\"boardOrigin\":[1],\"language\":\"unknown\",\"ledDotSize\":9}".utf8))
    precondition(clamped.scrollSpeed == 0.02 && clamped.boardRefresh == 5 && clamped.defaultWidth == 60 && clamped.boardOrigin == nil && clamped.language == "system" && clamped.ledDotSize == 3)
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
    print("PASS: watchlist validation and Hong Kong symbol normalization")

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
}
