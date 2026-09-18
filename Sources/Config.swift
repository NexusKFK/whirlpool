import Foundation

// 自选池条目。market 决定涨跌配色习惯("cn"/"hk" 红涨绿跌,其余绿涨红跌)。
struct WatchEntry: Codable, Equatable {
    var symbol: String
    var market: String
}

struct TickerConfig: Codable {
    // Ticker display
    var tickerEnabled:     Bool              = true
    var defaultColor:      String            = "white"
    var defaultWidth:      Int               = 20
    var scrollSpeed:       Double            = 0.0222  // ≈45 列/秒
    var defaultPause:      Double            = 0      // 每轮开头停留秒数,0=连续滚
    var customChars:       [String: [UInt8]] = [:]
    var transparent:       Bool              = true
    // 彩色透明模式:点阵自带颜色。"auto" 会退化成菜单栏单色(吃掉涨跌色)。
    var transparentColor:  String            = "white"
    var marqueeSeparator:  String            = "   "   // 标的间空隙(3 空格)
    var changeArrows:      Bool              = true   // 涨跌用 ▲/▼(关=+/-号)

    // Quote loop — 一轮滚完自动拉新行情再入队,循环不息
    var quoteLoop:         Bool              = true
    var watchlist:         [WatchEntry]      = [
        WatchEntry(symbol: "AAPL",   market: "us"),
        WatchEntry(symbol: "SPY",    market: "us"),
        WatchEntry(symbol: "600519", market: "cn"),
        WatchEntry(symbol: "510300", market: "cn"),
    ]
    var pausePerSymbol:    Double            = 0      // >0 时每个标的滚到左缘停留 N 秒
    var redUpMarkets:      [String]          = ["cn", "hk"]
    var provider:          String            = "real" // demo | real(见 RealProvider.swift)

    // Board 模式(缩略图报价卡,贴程序坞两端空位)
    var displayMode:       String            = "marquee" // 可组合: marquee|board|bar,逗号分隔;both=旧别名
    var boardCorner:       String            = "right"   // 程序坞左端 | 右端
    var boardOrigin:       [Double]?         = nil       // 手动拖动后记忆 [x, y]
    var boardRefresh:      Double            = 30        // 秒
    var barOrigin:         [Double]?         = nil       // 底部条手动拖动后记忆
    var boardPixelFont:    Bool              = true      // 报价卡用 LED 像素字体(关=系统字体)
    var marqueeBlink:      Bool              = true      // 跑马灯换数时闪变化的数字
    var language: String = "system"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tickerEnabled, defaultColor, defaultWidth, scrollSpeed, defaultPause, customChars, transparent, transparentColor, marqueeSeparator, changeArrows, quoteLoop, watchlist, pausePerSymbol, redUpMarkets, provider, displayMode, boardCorner, boardOrigin, boardRefresh, barOrigin, boardPixelFont, marqueeBlink, language
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tickerEnabled = try values.decodeIfPresent(type(of: tickerEnabled), forKey: .tickerEnabled) ?? tickerEnabled
        defaultColor = try values.decodeIfPresent(type(of: defaultColor), forKey: .defaultColor) ?? defaultColor
        defaultWidth = try values.decodeIfPresent(type(of: defaultWidth), forKey: .defaultWidth) ?? defaultWidth
        scrollSpeed = try values.decodeIfPresent(type(of: scrollSpeed), forKey: .scrollSpeed) ?? scrollSpeed
        defaultPause = try values.decodeIfPresent(type(of: defaultPause), forKey: .defaultPause) ?? defaultPause
        customChars = try values.decodeIfPresent(type(of: customChars), forKey: .customChars) ?? customChars
        transparent = try values.decodeIfPresent(type(of: transparent), forKey: .transparent) ?? transparent
        transparentColor = try values.decodeIfPresent(type(of: transparentColor), forKey: .transparentColor) ?? transparentColor
        marqueeSeparator = try values.decodeIfPresent(type(of: marqueeSeparator), forKey: .marqueeSeparator) ?? marqueeSeparator
        changeArrows = try values.decodeIfPresent(type(of: changeArrows), forKey: .changeArrows) ?? changeArrows
        quoteLoop = try values.decodeIfPresent(type(of: quoteLoop), forKey: .quoteLoop) ?? quoteLoop
        watchlist = try values.decodeIfPresent(type(of: watchlist), forKey: .watchlist) ?? watchlist
        pausePerSymbol = try values.decodeIfPresent(type(of: pausePerSymbol), forKey: .pausePerSymbol) ?? pausePerSymbol
        redUpMarkets = try values.decodeIfPresent(type(of: redUpMarkets), forKey: .redUpMarkets) ?? redUpMarkets
        provider = try values.decodeIfPresent(type(of: provider), forKey: .provider) ?? provider
        displayMode = try values.decodeIfPresent(type(of: displayMode), forKey: .displayMode) ?? displayMode
        boardCorner = try values.decodeIfPresent(type(of: boardCorner), forKey: .boardCorner) ?? boardCorner
        boardRefresh = try values.decodeIfPresent(type(of: boardRefresh), forKey: .boardRefresh) ?? boardRefresh
        boardPixelFont = try values.decodeIfPresent(type(of: boardPixelFont), forKey: .boardPixelFont) ?? boardPixelFont
        marqueeBlink = try values.decodeIfPresent(type(of: marqueeBlink), forKey: .marqueeBlink) ?? marqueeBlink
        language = try values.decodeIfPresent(type(of: language), forKey: .language) ?? language
        boardOrigin = try values.decodeIfPresent([Double].self, forKey: .boardOrigin)
        barOrigin = try values.decodeIfPresent([Double].self, forKey: .barOrigin)
        normalize()
    }

    mutating func normalize() {
        defaultWidth = min(60, max(8, defaultWidth))
        scrollSpeed = scrollSpeed.isFinite ? min(0.1, max(0.02, scrollSpeed)) : 0.0333
        boardRefresh = boardRefresh.isFinite ? min(3600, max(5, boardRefresh)) : 30
        defaultPause = defaultPause.isFinite ? min(60, max(0, defaultPause)) : 0
        pausePerSymbol = pausePerSymbol.isFinite ? min(60, max(0, pausePerSymbol)) : 0
        if !["system", "en", "zh-Hans"].contains(language) { language = "system" }
        if !["real", "demo"].contains(provider) { provider = "real" }
        if displayMode == "both" { displayMode = "marquee,board" }
        if !Self.displayModes.contains(where: { $0.key == displayMode }) { displayMode = "marquee" }
        for i in watchlist.indices {
            watchlist[i].symbol = watchlist[i].symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        var seen = Set<String>()
        watchlist = watchlist.filter { !$0.symbol.isEmpty && seen.insert($0.symbol).inserted }
        if watchlist.isEmpty { watchlist = TickerConfig().watchlist }
        if boardOrigin?.count != 2 || boardOrigin?.allSatisfy({ $0.isFinite }) != true { boardOrigin = nil }
        if barOrigin?.count != 2 || barOrigin?.allSatisfy({ $0.isFinite }) != true { barOrigin = nil }
    }

    static var displayModes: [(key: String, label: String)] {
        [("marquee", L("Menu Bar Ticker")), ("board", L("Quote Board")),
         ("bar", L("Floating Ticker")), ("marquee,board", L("Menu Bar + Board")),
         ("marquee,bar", L("Menu Bar + Floating Ticker"))]
    }
}

/// The legacy path is retained so upgrades do not lose a user's watchlist.
let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/pinwheel/config.json")
var configReadError: String?

func readConfig(at url: URL) throws -> TickerConfig {
    try JSONDecoder().decode(TickerConfig.self, from: Data(contentsOf: url))
}

func loadConfig() -> TickerConfig {
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        let defaults = TickerConfig()
        saveConfig(defaults)
        return defaults
    }
    do { return try readConfig(at: configURL) }
    catch {
        // Do not overwrite malformed files with defaults.
        configReadError = error.localizedDescription
        return TickerConfig()
    }
}

func writeConfig(_ config: TickerConfig, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(config).write(to: url, options: .atomic)
}

@discardableResult
func saveConfig(_ config: TickerConfig) -> Bool {
    do {
        if configReadError != nil, FileManager.default.fileExists(atPath: configURL.path) {
            let backup = configURL.appendingPathExtension("unreadable-" + UUID().uuidString)
            try FileManager.default.copyItem(at: configURL, to: backup)
            configReadError = nil
        }
        try writeConfig(config, to: configURL); return true
    }
    catch { fputs("Pinwheel: could not save configuration: \(error.localizedDescription)\n", stderr); return false }
}

func configPath() -> String { configURL.path }
