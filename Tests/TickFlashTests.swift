import AppKit

struct TickFlashTests {
    func testSuffixIncludesUnchangedLowerPlaces() throws {
        for (old, new, prefix, suffix) in [
            (81.20, 81.30, "81.", "30"),
            (81.30, 81.20, "81.", "20"),
            (759.71, 759.72, "759.7", "2"),
            (123.45, 133.45, "1", "33.45"),
            (199.90, 200.90, "", "200.90"),
            (99.90, 100.90, "", "100.90"),
            (100.90, 99.90, "", "99.90"),
            (1000.01, 1000.02, "1000.0", "2")
        ] {
            let flash = try unwrap(PriceFlash.between(old, and: new, redUp: false))
            expectEqual(flash.prefix, prefix)
            expectEqual(flash.suffix, suffix)
            expectEqual(flash.color, new > old ? .green : .red)
        }
    }

    func testFirstQuoteUnchangedAndInvisibleChangesDoNotFlash() {
        expectNil(PriceFlash.between(nil, and: 81.20, redUp: false))
        expectNil(PriceFlash.between(81.20, and: 81.20, redUp: false))
        expectNil(PriceFlash.between(81.201, and: 81.204, redUp: false))
        expectNil(PriceFlash.between(.nan, and: 81.20, redUp: false))
        expectNil(PriceFlash.between(81.20, and: .infinity, redUp: false))
    }

    func testMarketDirectionPreference() {
        expectEqual(PriceFlash.between(81.20, and: 81.30, redUp: true)?.color, .red)
        expectEqual(PriceFlash.between(81.30, and: 81.20, redUp: true)?.color, .green)
    }

    func testMarqueeUsesTickDirectionIndependentOfDayChange() {
        let entries = [WatchEntry(symbol: "TLT", market: "us")]
        let quote = Quote(price: 81.30, changePct: -0.59, series: nil, sessionStart: nil, sessionEnd: nil)
        let text = QuoteEngine.marqueeText(entries: entries, quotes: ["TLT": quote],
                                          redUpMarkets: [], pausePerSymbol: 0,
                                          previousTicks: ["TLT": 81.20])
        expectEqual(text, "TLT 81.\\b[1:green]30\\b[0] \\c[red]▼0.59%\\c[]   ")
        let stream = buildScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
        expectEqual(Set(stream.blinkCols.keys), Set(42..<54))
        expectTrue(stream.blinkCols.values.allSatisfy { $0 == .green })
        expectTrue(stream.columns[42..<54].allSatisfy { $0.color == .white })
        expectTrue(stream.columns[60..<96].allSatisfy { $0.color == .red })
    }

    func testOnlyPercentChangeAndDisabledAnimationDoNotFlashPrice() {
        let entries = [WatchEntry(symbol: "TLT", market: "us")]
        let quote = Quote(price: 81.30, changePct: -0.59, series: nil, sessionStart: nil, sessionEnd: nil)
        for (previous, enabled) in [(81.30, true), (81.20, false)] {
            let text = QuoteEngine.marqueeText(entries: entries, quotes: ["TLT": quote],
                                              redUpMarkets: [], pausePerSymbol: 0,
                                              blinkChanged: enabled, previousTicks: ["TLT": previous])
            expectFalse(text.contains("\\b["))
        }
    }

    func testPricePrecisionMatchesBetweenDisplays() {
        let quote = Quote(price: 1000.02, changePct: 0, series: nil, sessionStart: nil, sessionEnd: nil)
        let rows = QuoteEngine.boardRows(entries: [WatchEntry(symbol: "TEST", market: "us")], quotes: ["TEST": quote])
        expectEqual(rows.first?.price, "1000.02")
    }

    func testOffscreenTickFlashesWhenItBecomesReadableAndOnlyOnce() {
        var flashes = ScrollFlashes(columns: Dictionary(uniqueKeysWithValues: (90..<102).map { ($0, LEDColor.green) }))
        expectTrue(flashes.colors(offset: 0, visibleColumns: 60, roundLength: 180, now: 0).isEmpty)
        // Still inside the right-edge fade: wait for the entire suffix to be readable.
        expectTrue(flashes.colors(offset: 45, visibleColumns: 60, roundLength: 180, now: 4).isEmpty)
        let first = flashes.colors(offset: 50, visibleColumns: 60, roundLength: 180, now: 5)
        expectEqual(Set(first.keys), Set(90..<102))
        expectTrue(flashes.colors(offset: 51, visibleColumns: 60, roundLength: 180, now: 5.3).values.allSatisfy { $0 == .green })
        expectTrue(flashes.colors(offset: 52, visibleColumns: 60, roundLength: 180, now: 5.6).isEmpty)
        // The repeated canvas used for seamless wrapping does not replay the pulse.
        expectTrue(flashes.colors(offset: 230, visibleColumns: 60, roundLength: 180, now: 10).isEmpty)
    }

    func testEachPriceHasItsOwnClock() {
        var columns = Dictionary(uniqueKeysWithValues: (20..<32).map { ($0, LEDColor.red) })
        for i in 90..<102 { columns[i] = .green }
        var flashes = ScrollFlashes(columns: columns)
        expectEqual(Set(flashes.colors(offset: 0, visibleColumns: 60, roundLength: 180, now: 0).keys), Set(20..<32))
        expectTrue(flashes.colors(offset: 0, visibleColumns: 60, roundLength: 180, now: 1).isEmpty)
        expectEqual(Set(flashes.colors(offset: 50, visibleColumns: 60, roundLength: 180, now: 8).keys), Set(90..<102))
    }

    func testRenderedPulseColorsTheSuffixAndRestoresOriginalPixels() throws {
        let saved = (renderTransparent, renderColoredTransparent, renderScale)
        defer { (renderTransparent, renderColoredTransparent, renderScale) = saved }
        renderTransparent = true
        renderColoredTransparent = true
        renderScale = 2
        let text = QuoteEngine.marqueeText(
            entries: [WatchEntry(symbol: "TLT", market: "us")],
            quotes: ["TLT": Quote(price: 81.30, changePct: -0.59, series: nil, sessionStart: nil, sessionEnd: nil)],
            redUpMarkets: [], pausePerSymbol: 0, previousTicks: ["TLT": 81.20])
        let stream = buildScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
        var flashes = ScrollFlashes(columns: stream.blinkCols)
        let active = flashes.colors(offset: 0, visibleColumns: 120, roundLength: stream.columns.count, now: 0)
        let expired = flashes.colors(offset: 0, visibleColumns: 120, roundLength: stream.columns.count, now: 1)
        let normal = renderScrollFrame(columns: stream.columns, offset: 0, displayWidth: 20)
        let pulse = renderScrollFrame(columns: stream.columns, offset: 0, displayWidth: 20, flash: active)
        let restored = renderScrollFrame(columns: stream.columns, offset: 0, displayWidth: 20, flash: expired)
        let normalRep = try unwrap(normal.representations.first as? NSBitmapImageRep)
        let pulseRep = try unwrap(pulse.representations.first as? NSBitmapImageRep)
        let restoredRep = try unwrap(restored.representations.first as? NSBitmapImageRep)
        for column in 12..<stream.columns.count {
            for bit in 0..<8 where stream.columns[column].value & (1 << bit) != 0 {
                let x = (paddingH + column * colW) * renderScale
                let y = (3 + bit * rowH) * renderScale
                let original = try unwrap(normalRep.colorAt(x: x, y: y))
                let highlighted = try unwrap(pulseRep.colorAt(x: x, y: y))
                expectEqual(original.alphaComponent, highlighted.alphaComponent)
                expectEqual(original, restoredRep.colorAt(x: x, y: y))
                if (42..<54).contains(column) {
                    expectLessThan(highlighted.redComponent, 0.01)
                    expectGreaterThan(highlighted.greenComponent, 0.99)
                } else {
                    expectEqual(original, highlighted)
                }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["WHIRLPOOL_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, rep) in [("normal", normalRep), ("pulse", pulseRep), ("restored", restoredRep)] {
                try unwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
            }
        }
    }

    func testTextStreamMarkersAndStripGeometry() {
        let saved = (renderTransparent, renderColoredTransparent)
        defer { (renderTransparent, renderColoredTransparent) = saved }
        renderTransparent = false
        renderColoredTransparent = false
        let text = "SPY \\c[green]675.10\\c[] \\b[1:red]0.42\\b[0]%\\p[2]END"
        let stream = buildTextScrollStream(text: text, defaultColor: .white, onClickCommand: nil)
        expectTrue(stream.runs.contains { $0.text == "SPY " && $0.color == .white && $0.blink == nil })
        expectTrue(stream.runs.contains { $0.text == "675.10" && $0.color == .green })
        let blink = stream.runs.filter { $0.blink == .red }.map { $0.text }.joined()
        expectEqual(blink, "0.42")
        expectEqual(stream.pauses.count, 1)
        let strip = TextStrip(stream: stream, font: .monospacedDigitSystemFont(ofSize: 14, weight: .regular),
                              defaultColor: .white)
        expectTrue(strip.totalCols > 0)
        expectTrue(strip.pauses.count == 1 && strip.pauses[0].at > 0)   // 暂停换算到虚拟列
        expectFalse(strip.blinkCols.isEmpty)
        // \g 自定义字形是 LED 专属,文本模式整段跳过
        let glyph = buildTextScrollStream(text: "\\g[heart]A", defaultColor: .white, onClickCommand: nil)
        expectEqual(glyph.runs.map { $0.text }.joined(), "A")
    }

    func testShortStreamAndOversizedFlashStayBounded() {
        var short = ScrollFlashes(columns: [10: .red, 11: .red])
        let colors = short.colors(offset: 0, visibleColumns: 90, roundLength: 30, now: 0)
        expectEqual(Set(colors.keys), Set([10, 11, 40, 41, 70, 71]))
        expectTrue(short.colors(offset: 1, visibleColumns: 90, roundLength: 30, now: 1).isEmpty)
        var long = ScrollFlashes(columns: Dictionary(uniqueKeysWithValues: (10..<100).map { ($0, LEDColor.red) }))
        expectEqual(Set(long.colors(offset: 0, visibleColumns: 30, roundLength: 120, now: 0).keys), Set(10..<30))
    }
}

// No XCTest dependency: runs on machines with only Command Line Tools installed.
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    if !value { fatalError("Expectation failed", file: file, line: line) }
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    expectTrue(!value, file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    expectTrue(value == nil, file: file, line: line)
}
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                       file: StaticString = #file, line: UInt = #line) {
    if actual != expected { fatalError("Expected \(expected), got \(actual)", file: file, line: line) }
}
private func expectLessThan<T: Comparable>(_ actual: T, _ expected: T,
                                          file: StaticString = #file, line: UInt = #line) {
    expectTrue(actual < expected, file: file, line: line)
}
private func expectGreaterThan<T: Comparable>(_ actual: T, _ expected: T,
                                             file: StaticString = #file, line: UInt = #line) {
    expectTrue(actual > expected, file: file, line: line)
}
private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { fatalError("Unexpected nil", file: file, line: line) }
    return value
}

@main
struct TickFlashTestRunner {
    static func main() throws {
        let tests = TickFlashTests()
        let cases: [(String, () throws -> Void)] = [
            ("changed suffix includes unchanged lower digits", tests.testSuffixIncludesUnchangedLowerPlaces),
            ("first, unchanged and rounded quotes stay neutral", tests.testFirstQuoteUnchangedAndInvisibleChangesDoNotFlash),
            ("market color preference", tests.testMarketDirectionPreference),
            ("tick direction is independent of daily change", tests.testMarqueeUsesTickDirectionIndependentOfDayChange),
            ("percent-only updates and disabled animation", tests.testOnlyPercentChangeAndDisabledAnimationDoNotFlashPrice),
            ("consistent price precision", tests.testPricePrecisionMatchesBetweenDisplays),
            ("offscreen timing and single pulse per cycle", tests.testOffscreenTickFlashesWhenItBecomesReadableAndOnlyOnce),
            ("independent pulse clocks", tests.testEachPriceHasItsOwnClock),
            ("rendered suffix pixels and color restoration", tests.testRenderedPulseColorsTheSuffixAndRestoresOriginalPixels),
            ("short streams and oversized groups", tests.testShortStreamAndOversizedFlashStayBounded),
            ("text stream markers and strip geometry", tests.testTextStreamMarkersAndStripGeometry),
        ]
        for (name, run) in cases {
            try run()
            print("PASS: \(name)")
        }
        print("\(cases.count) price regression checks passed.")
        try runCoreTests()
        try runGPUMarqueeTests()
        try runFeatureTests()
        try runWindowStateTests()
    }
}
