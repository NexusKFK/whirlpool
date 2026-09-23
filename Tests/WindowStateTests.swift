import AppKit

func runWindowStateTests() throws {
    _ = NSApplication.shared
    let area = NSRect(x: -1200, y: 0, width: 1200, height: 800)
    let fitted = constrainedFrame(NSRect(x: -100, y: 790, width: 600, height: 40), inside: area)
    precondition(fitted == NSRect(x: -608, y: 752, width: 600, height: 40), "wide bars stay inside a display with negative coordinates")
    let oversized = constrainedFrame(NSRect(x: -5000, y: -5000, width: 1600, height: 900), inside: area)
    precondition(oversized.origin == NSPoint(x: -1192, y: 8), "oversized windows retain a reachable corner")
    precondition(placementScreen("auto") == NSScreen.screens.first, "automatic placement uses the primary display")
    precondition(abs(menuTickerWidth(requested: 1200, screenWidth: 2048) - 819.2) < 0.001)
    precondition(menuTickerWidth(requested: 280, screenWidth: 2048) == 280)
    precondition(menuTickerWidth(requested: 80, screenWidth: 1440) == 120)
    let usable = NSRect(x: -1200, y: 70, width: 1200, height: 700)
    precondition(floatingTickerWidth(fraction: 0.50, legacyWidth: 360, inside: usable) == 588)
    precondition(floatingTickerWidth(fraction: 1, legacyWidth: 360, inside: usable) == 1176)
    precondition(floatingTickerWidth(fraction: nil, legacyWidth: 360, inside: usable) == 360)
    let centered = anchoredTickerFrame(size: NSSize(width: 600, height: 40), placement: "bottom-center", inside: usable)
    precondition(centered == NSRect(x: -900, y: 82, width: 600, height: 40), "bottom anchors avoid the Dock and support negative screen coordinates")
    let right = anchoredTickerFrame(size: NSSize(width: 800, height: 40), placement: "top-right", inside: usable)
    precondition(right.maxX == usable.maxX - 12 && right.maxY == usable.maxY - 12)
    precondition(resizedTickerWidth(startWidth: 600, delta: -50, leftEdge: true, placement: "bottom-center") == 700)
    precondition(resizedTickerWidth(startWidth: 600, delta: 50, leftEdge: false, placement: "bottom-left") == 650)
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

    config.lockPosition = false
    let bar = BarWindow(config: config)
    let initialWidth = bar.frame.width
    let anchoredCenter = bar.frame.midX
    config.ledDotSize = 3; bar.config = config
    precondition(bar.frame.width == initialWidth && bar.frame.midX == anchoredCenter, "changing the font does not change the capsule width or anchor")
    config.barWidthFraction = 0.75; bar.config = config
    precondition(bar.frame.width > initialWidth && abs(bar.frame.midX - anchoredCenter) <= 0.5, "anchored width changes expand around the bottom center")
    bar.beginDragging(); bar.finishDragging()
    precondition(bar.config.barPlacement == "bottom-center", "a click without movement must not release the anchor")
    var screenChanges = 0
    bar.onScreenChange = { screenChanges += 1 }
    bar.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: bar))
    precondition(screenChanges == 1, "cross-screen moves rebuild the ticker width even at the same scale")
    var origin: [Double]?
    var layout: TickerConfig?
    bar.onOriginChange = { origin = $0 }
    bar.onLayoutChange = { layout = $0 }
    bar.beginDragging()
    bar.setFrameOrigin(NSPoint(x: 140, y: 160))
    bar.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: bar))
    precondition(origin == [140, 160], "drag position is shared immediately, before the debounced save")
    precondition(layout?.barPlacement == "free", "dragging immediately replaces the anchor with free placement")
    bar.finishDragging()
    let draggedOrigin = bar.frame.origin
    config = layout!; config.barClickThrough = true; bar.config = config
    precondition(bar.frame.origin == draggedOrigin && bar.ignoresMouseEvents,
                 "menu settings retain the latest drag position")
    let blockedWidth = bar.frame.width
    bar.beginResizing(leftEdge: false, at: 0); bar.resize(to: -100); bar.finishResizing()
    precondition(bar.frame.width == blockedWidth, "click-through prevents edge resizing")
    config.barClickThrough = false; config.lockPosition = true; bar.config = config
    bar.beginResizing(leftEdge: false, at: 0); bar.resize(to: -100); bar.finishResizing()
    precondition(bar.frame.width == blockedWidth, "position lock prevents resizing as well as moving")
    config.lockPosition = false; bar.config = config
    let freeCenter = bar.frame.midX
    bar.beginResizing(leftEdge: false, at: 0); bar.resize(to: -30); bar.finishResizing()
    precondition(bar.frame.width < blockedWidth && abs(bar.frame.midX - freeCenter) <= 0.5, "free edge resizing retains the center")
    precondition(layout?.barWidthFraction == bar.config.barWidthFraction, "drag resizing shares its percentage immediately")
    // Resetting before the pending drag save fires must not resurrect the old position.
    config = bar.config; config.barOrigin = nil; config.barPlacement = "bottom-center"; bar.config = config
    try writeConfig(config, to: configURL)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let saved = try readConfig(at: configURL)
    precondition(saved.barOrigin == nil, "reset cancels an older pending drag save")
    precondition(ConfigWindowController.decimalChoices.contains(7) && ConfigWindowController.decimalChoices.contains(8))
    print("PASS: window anchors, independent width, drag/resize synchronization, locks, board state and position-reset races")
}
