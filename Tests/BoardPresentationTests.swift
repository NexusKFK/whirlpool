import AppKit

func runBoardPresentationTests() throws {
    let savedLanguage = L10n.language
    defer { L10n.language = savedLanguage }
    L10n.language = "en"
    let iso = ISO8601DateFormatter()
    let saturday = iso.date(from: "2026-09-19T12:00:00Z")!
    let fridayClose = iso.date(from: "2026-09-18T20:00:00Z")!
    let mondayOpen = iso.date(from: "2026-09-21T14:00:00Z")!
    let spy = WatchEntry(symbol: "SPY", market: "us")
    let crypto = WatchEntry(symbol: "BTC-USD", market: "crypto")
    var quote = Quote(price: 773.38, changePct: -0.02, series: nil, sessionStart: nil, sessionEnd: nil, marketTime: fridayClose)
    func state(_ entries: [WatchEntry] = [spy], quotes: [String: Quote]? = nil,
               now: Date = saturday, provider: String = "real", status: String = "Updated", checked: Date = saturday) -> BoardStatus {
        BoardStatus.make(entries: entries, quotes: quotes ?? ["SPY": quote], provider: provider, status: status, checkedAt: checked, now: now)
    }
    let closed = state()
    precondition(closed.text.hasPrefix("Markets closed · Last quote "))
    precondition(closed.text == state(checked: saturday.addingTimeInterval(-1800)).text,
                 "Polling must not advance the closed-market quote timestamp")
    precondition(closed.detail.contains("Checked at") && closed.closedSymbols == ["SPY"])
    precondition(!state(now: mondayOpen).text.contains("Markets closed"))
    precondition(!state([spy, crypto]).text.contains("Markets closed"), "A mixed list with crypto is not all closed")
    precondition(state(provider: "demo", status: "Demo · simulated prices").closedSymbols.isEmpty)
    for error in ["Offline · showing last prices", "Rate limited · retrying later", "Some quotes unavailable · showing last prices"] {
        precondition(state(status: error).text == error, "Market closure must not hide feed errors")
    }
    quote.marketTime = nil
    precondition(state().text == "Markets closed · Last available quotes", "Never substitute poll time for an unknown trade time")
    quote.marketTime = saturday.addingTimeInterval(-120)
    precondition(state().closedSymbols.isEmpty, "A recent trade overrides the calendar")
    quote.marketTime = saturday.addingTimeInterval(600)
    precondition(state().closedSymbols == ["SPY"], "A corrupt future timestamp cannot keep a closed market live")
    quote.marketTime = fridayClose
    L10n.language = "zh-Hans"
    precondition(state().text.hasPrefix("休市 · 最近行情 "))

    let previousDay = [SeriesPt(t: 100, v: 2), SeriesPt(t: 160, v: 3), SeriesPt(t: 200, v: 2.5)]
    let previousRange = SparklineView.timeRange(points: previousDay, session: (300, 600))!
    precondition(previousRange.start == 100 && previousRange.end == 200, "Previous-day curves must not collapse into a vertical line")
    let earlyRange = SparklineView.timeRange(points: previousDay, session: (100, 600))!
    precondition(earlyRange.start == 100 && earlyRange.end == 600, "Live intraday curves retain the full-session time axis")
    precondition(SparklineView.timeRange(points: [], session: (100, 600)) == nil)
    print("PASS: board closed/live/mixed states, trade-time accuracy, feed errors, and previous-session sparklines")

    var config = TickerConfig()
    config.provider = "real"; config.marqueeFont = "system"; config.ledDotSize = 3
    config.boardOrigin = [100, 100]
    config.watchlist = [spy, WatchEntry(symbol: "QQQ", market: "us"), WatchEntry(symbol: "LLY", market: "us"),
                        WatchEntry(symbol: "WMT", market: "us"), WatchEntry(symbol: "GOOGL", market: "us")]
    let prices = [773.38, 747.46, 1170.14, 110.12, 351.16]
    let changes = [-0.02, 0.81, 0.45, 2.49, -1.07]
    var quotes: [String: Quote] = [:]
    for (i, entry) in config.watchlist.enumerated() {
        let points = (0..<30).map { n in SeriesPt(t: 100 + Double(n) * 5, v: prices[i] * (1 + sin(Double(n) * 0.4) * 0.002)) }
        quotes[entry.symbol] = Quote(price: prices[i], changePct: changes[i], series: points,
                                     sessionStart: 300, sessionEnd: 600, marketTime: fridayClose)
    }
    let board = BoardWindow(config: config)
    defer { board.orderOut(nil) }
    precondition(board.contentView!.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("Loading quotes…") },
                 "The first network request must show a loading message, not an empty panel")
    board.appearance = NSAppearance(named: .darkAqua)
    func update(now: Date = saturday) {
        board.update(entries: config.watchlist, quotes: quotes, redUpMarkets: [], at: saturday, now: now)
    }
    func rows() -> [BoardRowView] { board.contentView!.subviews.compactMap { $0 as? BoardRowView } }
    func field(_ key: String, row: Int = 0) -> NSTextField { rows()[row].subviews.first { $0.identifier?.rawValue == "board-" + key } as! NSTextField }
    func textColor(_ key: String, index: Int = 0) -> NSColor {
        field(key).attributedStringValue.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor
    }
    update()
    precondition(rows().count == 5 && rows()[0].subviews.contains { $0 is NSTextField }, "A legacy boardPixelFont=true must not override the selected system font")
    precondition((field("price").attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 17)
    let footer = board.contentView!.subviews.first { $0.identifier?.rawValue == "board-status" }!
    precondition(rows().last!.frame.minY - footer.frame.maxY == 2, "Only a small single gap separates the rows and footer")
    for font in ["system", "mono", "led"] {
        config.marqueeFont = font; board.config = config
        for row in rows() {
            let cells = row.subviews.filter { $0.identifier?.rawValue.hasPrefix("board-") == true }
            precondition(cells.count == 3)
            precondition(cells[0].frame.maxX <= cells[1].frame.minX - 12 && cells[1].frame.maxX <= cells[2].frame.minX - 12)
            precondition(cells.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= row.bounds.height })
            for label in cells.compactMap({ $0 as? NSTextField }) {
                precondition(ceil(label.cell!.cellSize.width) <= label.frame.width,
                             "Every price digit and percent sign must fit the native text cell")
            }
        }
        precondition((rows()[0].subviews.first { $0.identifier?.rawValue == "board-price" } is NSImageView) == (font == "led"),
                     "A font change must repaint existing quotes immediately")
    }
    config.marqueeFont = "system"; config.transparentColor = "amber"; board.config = config
    let dark = LEDStyle(tone: .dark)
    precondition(textColor("symbol") == dark.nsColor(.amber) && textColor("price") == dark.nsColor(.amber))
    precondition(textColor("change") == dark.nsColor(.red))
    config.transparentColor = "mono"; board.config = config
    precondition(textColor("price") == textColor("change"), "Monochrome includes percentages")
    config.transparentColor = "adaptive"; config.marqueeBlink = false; board.config = config
    quotes["SPY"]!.marketTime = mondayOpen
    quotes["SPY"] = Quote(price: 773.48, changePct: -0.02, series: nil, sessionStart: nil, sessionEnd: nil, marketTime: mondayOpen)
    update(now: mondayOpen)
    precondition(textColor("price", index: 4) == dark.nsColor(.white), "The board honors the shared flash switch")
    config.marqueeBlink = true; board.config = config
    quotes["SPY"] = Quote(price: 773.58, changePct: -0.02, series: nil, sessionStart: nil, sessionEnd: nil, marketTime: mondayOpen)
    update(now: mondayOpen)
    precondition(textColor("price", index: 3) == dark.nsColor(.white) && textColor("price", index: 4) == dark.nsColor(.green)
                 && textColor("price", index: 5) == dark.nsColor(.green), "Flash the changed place and all smaller places")
    RunLoop.main.run(until: Date().addingTimeInterval(PriceFlash.duration + 0.05))
    precondition(textColor("price", index: 4) == dark.nsColor(.white)
                 && (field("price").attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right,
                 "Flash expiry preserves the right-aligned price column")
    quotes["SPY"] = Quote(price: 773.68, changePct: -0.02, series: nil, sessionStart: nil, sessionEnd: nil, marketTime: fridayClose)
    update()
    precondition(textColor("price", index: 4) == dark.nsColor(.white), "Closed-market corrections do not flash as live trades")
    board.appearance = NSAppearance(named: .aqua)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(textColor("price") == LEDStyle(tone: .light).nsColor(.white), "Appearance changes repaint cached quotes")
    print("PASS: board unified font/size/palette, column alignment, compact footer, flash switch and appearance redraw")

    guard let path = ProcessInfo.processInfo.environment["WHIRLPOOL_BOARD_SNAPSHOTS"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for language in ["en", "zh-Hans"] {
        L10n.language = language
        for (tone, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            board.appearance = NSAppearance(named: appearance)
            for font in ["system", "mono", "led"] {
                config.marqueeFont = font; config.ledDotSize = font == "led" ? 2 : 3; board.config = config; update()
                board.orderFrontRegardless(); board.displayIfNeeded()
                let root = board.contentView!, rep = board.contentView!.bitmapImageRepForCachingDisplay(in: board.contentView!.bounds)!
                board.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(language)-\(tone)-\(font).png"))
            }
        }
    }
    print("PASS: native quote board snapshots in English/Chinese, light/dark and all three fonts")
}
