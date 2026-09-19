import AppKit

func runWindowStateTests() throws {
    _ = NSApplication.shared
    var config = TickerConfig()
    config.watchlist = [WatchEntry(symbol: "AAPL", market: "us")]
    config.boardOrigin = [100, 100]
    let board = BoardWindow(config: config)
    let quote = Quote(price: 81.3, changePct: -1, series: nil, sessionStart: nil, sessionEnd: nil)
    board.update(entries: config.watchlist, quotes: ["AAPL": quote], redUpMarkets: [], at: Date())
    func rows() -> [BoardRowView] { board.contentView!.subviews.compactMap { $0 as? BoardRowView } }
    precondition(rows().count == 1 && rows()[0].entry?.symbol == "AAPL")
    config.lockPosition = true; board.config = config
    precondition(rows().allSatisfy(\.locked), "locking must update existing rows before the next quote arrives")
    config.watchlist = [WatchEntry(symbol: "SPY", market: "us")]; board.config = config
    precondition(rows().isEmpty, "the old watchlist must disappear even if the next fetch fails")
    board.update(entries: config.watchlist, quotes: ["SPY": quote], redUpMarkets: [], at: Date())
    precondition(rows().first?.entry?.symbol == "SPY")
    config.provider = "demo"; board.config = config
    precondition(rows().isEmpty, "switching providers must discard the old provider's prices")

    let bar = BarWindow(config: config)
    var origin: [Double]?
    bar.onOriginChange = { origin = $0 }
    bar.setFrameOrigin(NSPoint(x: 140, y: 160))
    bar.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: bar))
    precondition(origin == [140, 160], "drag position is shared immediately, before the debounced save")
    config.barOrigin = origin; config.barClickThrough = true; bar.config = config
    precondition(bar.frame.origin == NSPoint(x: 140, y: 160) && bar.ignoresMouseEvents,
                 "menu settings retain the latest drag position")
    // Resetting before the pending drag save fires must not resurrect the old position.
    config.barOrigin = nil; bar.config = config
    try writeConfig(config, to: configURL)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let saved = try readConfig(at: configURL)
    precondition(saved.barOrigin == nil, "reset cancels an older pending drag save")
    precondition(ConfigWindowController.decimalChoices.contains(7) && ConfigWindowController.decimalChoices.contains(8))
    print("PASS: board list/source changes, immediate row locking, drag synchronization and position-reset races")
}
