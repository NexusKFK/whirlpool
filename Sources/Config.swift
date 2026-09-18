import Foundation

// 自选池条目。market 决定涨跌配色习惯("cn"/"hk" 红涨绿跌,其余绿涨红跌)。
struct WatchEntry: Codable, Equatable {
    var symbol: String
    var market: String
}

struct TickerConfig: Codable {
    // Ticker display
    var tickerEnabled:     Bool              = true
    var defaultColor:      String            = "amber"
    var defaultWidth:      Int               = 20
    var scrollSpeed:       Double            = 0.05
    var defaultPause:      Double            = 3.0
    var customChars:       [String: [UInt8]] = [:]
    var transparent:       Bool              = true
    // 彩色透明模式:点阵自带颜色,红涨绿跌可见。"auto" 会退化成菜单栏单色。
    var transparentColor:  String            = "amber"

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
