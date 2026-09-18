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
    var provider:          String            = "demo" // demo | real(见 RealProvider.swift)

    // Board 模式(缩略图报价卡,贴程序坞两端空位)
    var displayMode:       String            = "marquee" // 可组合: marquee|board|bar,逗号分隔;both=旧别名
    var boardCorner:       String            = "right"   // 程序坞左端 | 右端
    var boardOrigin:       [Double]?         = nil       // 手动拖动后记忆 [x, y]
    var boardRefresh:      Double            = 30        // 秒
    var barOrigin:         [Double]?         = nil       // 底部条手动拖动后记忆
}

private let configURL: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pinwheel/config.json")
}()

func loadConfig() -> TickerConfig {
    if let data = try? Data(contentsOf: configURL),
       let decoded = try? JSONDecoder().decode(TickerConfig.self, from: data) {
        return decoded
    }
    let defaults = TickerConfig()
    saveConfig(defaults)
    return defaults
}

func saveConfig(_ config: TickerConfig) {
    let dir = configURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(config) {
        try? data.write(to: configURL)
    }
}

func configPath() -> String {
    configURL.path
}
