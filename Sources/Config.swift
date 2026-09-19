import Foundation

// 自选池条目。market 决定涨跌配色习惯("cn"/"hk" 红涨绿跌,其余绿涨红跌)。
struct WatchEntry: Codable, Equatable {
    var symbol: String
    var market: String
    var decimals: Int? = nil     // 价格小数位;nil = 自动(行情源提示 → 市场规则 → 2 位)
}

/// 一套命名自选池(可建多套,菜单/⌥单击/CLI 快速切换)
struct Watchlist: Codable, Equatable {
    var name: String
    var entries: [WatchEntry]
}

struct TickerConfig: Codable {
    // Ticker display
    var tickerEnabled:     Bool              = true
    var defaultColor:      String            = "white"
    var defaultWidth:      Int               = 20
    var ledDotSize:        Int               = 2      // 点阵字号:1=S 2=M(默认) 3=L;菜单栏超限自动钳中档
    var marqueeFont:       String            = "led"  // 跑马灯字体:led=LED点阵 system=系统字体 mono=等宽字体
    var showDockIcon:      Bool              = false  // 程序坞显示图标:给常驻进程一个可见抓手(可右键退出)
    var scrollSpeed:       Double            = 0.0222  // ≈45 列/秒
    var defaultPause:      Double            = 0      // 每轮开头停留秒数,0=连续滚
    var customChars:       [String: [UInt8]] = [:]
    var transparent:       Bool              = true
    // 外观方案(Theme.swift ColorScheme):adaptive=中性色随明暗、保留红绿(默认);
    // mono=单色随明暗;amber/green=固定底色。旧值 auto→mono,white/black→adaptive。
    var transparentColor:  String            = "adaptive"
    var marqueeSeparator:  String            = "   "   // 标的间空隙(3 空格)
    var changeArrows:      Bool              = true   // 涨跌用 ▲/▼(关=+/-号)

    // Quote loop — 一轮滚完自动拉新行情再入队,循环不息
    var quoteLoop:         Bool              = true
    static let defaultEntries: [WatchEntry] = [
        WatchEntry(symbol: "AAPL",   market: "us"),
        WatchEntry(symbol: "SPY",    market: "us"),
        WatchEntry(symbol: "600519", market: "cn"),
        WatchEntry(symbol: "510300", market: "cn"),
    ]
    var watchlists:        [Watchlist]       = [Watchlist(name: L("Watchlist"), entries: TickerConfig.defaultEntries)]
    var activeWatchlist:   Int               = 0
    /// 当前激活的自选池(显示、拉取都只看它)
    var watchlist: [WatchEntry] {
        get { watchlists.indices.contains(activeWatchlist) ? watchlists[activeWatchlist].entries : (watchlists.first?.entries ?? []) }
        set {
            if watchlists.indices.contains(activeWatchlist) { watchlists[activeWatchlist].entries = newValue }
            else { watchlists = [Watchlist(name: L("Watchlist"), entries: newValue)]; activeWatchlist = 0 }
        }
    }
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
    var barBackground:     String            = "glass"   // 浮动条背板:glass=毛玻璃胶囊(亮/暗自适应) none=透明
    var hoverPause:        Bool              = true      // 鼠标悬停时暂停滚动,方便读数
    var smartRefresh:      Bool              = true      // 所有自选市场休市时放慢拉取,开盘前自动恢复
    var checkUpdates:      Bool              = true      // 每天查一次 GitHub Release,有新版在菜单与跑马灯里提示
    var lockPosition:      Bool              = false     // 锁定浮动条/报价卡位置(不能拖动,右键与悬停照常)
    var barClickThrough:   Bool              = false     // 浮动条点击穿透:鼠标直接落到下面的窗口(从菜单栏图标关闭)
    var displayScreen:     String            = "auto"    // 显示器 UUID:跑马灯只在该屏菜单栏滚动,浮窗落在该屏;auto=不指定
    var language: String = "system"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tickerEnabled, defaultColor, defaultWidth, ledDotSize, marqueeFont, showDockIcon, scrollSpeed, defaultPause, customChars, transparent, transparentColor, marqueeSeparator, changeArrows, quoteLoop, watchlist, pausePerSymbol, redUpMarkets, provider, displayMode, boardCorner, boardOrigin, boardRefresh, barOrigin, boardPixelFont, marqueeBlink, barBackground, hoverPause, smartRefresh, language
        case watchlists, activeWatchlist, checkUpdates, displayScreen, lockPosition, barClickThrough
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tickerEnabled = try values.decodeIfPresent(type(of: tickerEnabled), forKey: .tickerEnabled) ?? tickerEnabled
        defaultColor = try values.decodeIfPresent(type(of: defaultColor), forKey: .defaultColor) ?? defaultColor
        defaultWidth = try values.decodeIfPresent(type(of: defaultWidth), forKey: .defaultWidth) ?? defaultWidth
        ledDotSize = try values.decodeIfPresent(type(of: ledDotSize), forKey: .ledDotSize) ?? ledDotSize
        marqueeFont = try values.decodeIfPresent(type(of: marqueeFont), forKey: .marqueeFont) ?? marqueeFont
        showDockIcon = try values.decodeIfPresent(type(of: showDockIcon), forKey: .showDockIcon) ?? showDockIcon
        scrollSpeed = try values.decodeIfPresent(type(of: scrollSpeed), forKey: .scrollSpeed) ?? scrollSpeed
        defaultPause = try values.decodeIfPresent(type(of: defaultPause), forKey: .defaultPause) ?? defaultPause
        customChars = try values.decodeIfPresent(type(of: customChars), forKey: .customChars) ?? customChars
        transparent = try values.decodeIfPresent(type(of: transparent), forKey: .transparent) ?? transparent
        transparentColor = try values.decodeIfPresent(type(of: transparentColor), forKey: .transparentColor) ?? transparentColor
        marqueeSeparator = try values.decodeIfPresent(type(of: marqueeSeparator), forKey: .marqueeSeparator) ?? marqueeSeparator
        changeArrows = try values.decodeIfPresent(type(of: changeArrows), forKey: .changeArrows) ?? changeArrows
        quoteLoop = try values.decodeIfPresent(type(of: quoteLoop), forKey: .quoteLoop) ?? quoteLoop
        // 多自选池;旧配置只有单个 watchlist → 迁移成第一套
        if let lists = try values.decodeIfPresent([Watchlist].self, forKey: .watchlists), !lists.isEmpty {
            watchlists = lists
            activeWatchlist = try values.decodeIfPresent(Int.self, forKey: .activeWatchlist) ?? 0
        } else if let single = try values.decodeIfPresent([WatchEntry].self, forKey: .watchlist) {
            // 迁移出来的第一套按配置里的界面语言起名(此时全局语言还没切过来)
            let lang = try values.decodeIfPresent(String.self, forKey: .language) ?? "system"
            let saved = L10n.language
            L10n.language = lang
            watchlists = [Watchlist(name: L("Watchlist"), entries: single)]
            L10n.language = saved
            activeWatchlist = 0
        }
        pausePerSymbol = try values.decodeIfPresent(type(of: pausePerSymbol), forKey: .pausePerSymbol) ?? pausePerSymbol
        redUpMarkets = try values.decodeIfPresent(type(of: redUpMarkets), forKey: .redUpMarkets) ?? redUpMarkets
        provider = try values.decodeIfPresent(type(of: provider), forKey: .provider) ?? provider
        displayMode = try values.decodeIfPresent(type(of: displayMode), forKey: .displayMode) ?? displayMode
        boardCorner = try values.decodeIfPresent(type(of: boardCorner), forKey: .boardCorner) ?? boardCorner
        boardRefresh = try values.decodeIfPresent(type(of: boardRefresh), forKey: .boardRefresh) ?? boardRefresh
        boardPixelFont = try values.decodeIfPresent(type(of: boardPixelFont), forKey: .boardPixelFont) ?? boardPixelFont
        marqueeBlink = try values.decodeIfPresent(type(of: marqueeBlink), forKey: .marqueeBlink) ?? marqueeBlink
        barBackground = try values.decodeIfPresent(type(of: barBackground), forKey: .barBackground) ?? barBackground
        hoverPause = try values.decodeIfPresent(type(of: hoverPause), forKey: .hoverPause) ?? hoverPause
        smartRefresh = try values.decodeIfPresent(type(of: smartRefresh), forKey: .smartRefresh) ?? smartRefresh
        checkUpdates = try values.decodeIfPresent(type(of: checkUpdates), forKey: .checkUpdates) ?? checkUpdates
        displayScreen = try values.decodeIfPresent(type(of: displayScreen), forKey: .displayScreen) ?? displayScreen
        lockPosition = try values.decodeIfPresent(type(of: lockPosition), forKey: .lockPosition) ?? lockPosition
        barClickThrough = try values.decodeIfPresent(type(of: barClickThrough), forKey: .barClickThrough) ?? barClickThrough
        language = try values.decodeIfPresent(type(of: language), forKey: .language) ?? language
        boardOrigin = try values.decodeIfPresent([Double].self, forKey: .boardOrigin)
        barOrigin = try values.decodeIfPresent([Double].self, forKey: .barOrigin)
        normalize()
    }

    /// 编码:照写全部字段;另写一份当前池到旧键 watchlist,回退旧版本也读得到自选
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tickerEnabled, forKey: .tickerEnabled)
        try c.encode(defaultColor, forKey: .defaultColor)
        try c.encode(defaultWidth, forKey: .defaultWidth)
        try c.encode(ledDotSize, forKey: .ledDotSize)
        try c.encode(marqueeFont, forKey: .marqueeFont)
        try c.encode(showDockIcon, forKey: .showDockIcon)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(defaultPause, forKey: .defaultPause)
        try c.encode(customChars, forKey: .customChars)
        try c.encode(transparent, forKey: .transparent)
        try c.encode(transparentColor, forKey: .transparentColor)
        try c.encode(marqueeSeparator, forKey: .marqueeSeparator)
        try c.encode(changeArrows, forKey: .changeArrows)
        try c.encode(quoteLoop, forKey: .quoteLoop)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(watchlists, forKey: .watchlists)
        try c.encode(activeWatchlist, forKey: .activeWatchlist)
        try c.encode(pausePerSymbol, forKey: .pausePerSymbol)
        try c.encode(redUpMarkets, forKey: .redUpMarkets)
        try c.encode(provider, forKey: .provider)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(boardCorner, forKey: .boardCorner)
        try c.encodeIfPresent(boardOrigin, forKey: .boardOrigin)
        try c.encode(boardRefresh, forKey: .boardRefresh)
        try c.encodeIfPresent(barOrigin, forKey: .barOrigin)
        try c.encode(boardPixelFont, forKey: .boardPixelFont)
        try c.encode(marqueeBlink, forKey: .marqueeBlink)
        try c.encode(barBackground, forKey: .barBackground)
        try c.encode(hoverPause, forKey: .hoverPause)
        try c.encode(smartRefresh, forKey: .smartRefresh)
        try c.encode(checkUpdates, forKey: .checkUpdates)
        try c.encode(displayScreen, forKey: .displayScreen)
        try c.encode(lockPosition, forKey: .lockPosition)
        try c.encode(barClickThrough, forKey: .barClickThrough)
        try c.encode(language, forKey: .language)
    }

    mutating func normalize() {
        defaultWidth = min(60, max(8, defaultWidth))
        ledDotSize = min(3, max(1, ledDotSize))
        if !["led", "system", "mono"].contains(marqueeFont) { marqueeFont = "led" }
        scrollSpeed = scrollSpeed.isFinite ? min(0.1, max(0.02, scrollSpeed)) : 0.0333
        boardRefresh = boardRefresh.isFinite ? min(3600, max(5, boardRefresh)) : 30
        defaultPause = defaultPause.isFinite ? min(60, max(0, defaultPause)) : 0
        pausePerSymbol = pausePerSymbol.isFinite ? min(60, max(0, pausePerSymbol)) : 0
        if !["system", "en", "zh-Hans"].contains(language) { language = "system" }
        if !["real", "demo"].contains(provider) { provider = "real" }
        transparentColor = ColorScheme(configKey: transparentColor).rawValue
        if !["glass", "none"].contains(barBackground) { barBackground = "glass" }
        displayScreen = displayScreen.trimmingCharacters(in: .whitespaces)
        if displayScreen.isEmpty { displayScreen = "auto" }
        if displayMode == "both" { displayMode = "marquee,board" }
        if !Self.displayModes.contains(where: { $0.key == displayMode }) { displayMode = "marquee" }
        for li in watchlists.indices {
            var list = watchlists[li]
            for i in list.entries.indices {
                list.entries[i].symbol = list.entries[i].symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let d = list.entries[i].decimals { list.entries[i].decimals = min(8, max(0, d)) }
            }
            var seen = Set<String>()
            list.entries = list.entries.filter { !$0.symbol.isEmpty && seen.insert($0.symbol).inserted }
            list.name = list.name.trimmingCharacters(in: .whitespacesAndNewlines)
            watchlists[li] = list
        }
        // 空池丢掉(当前池被丢时退回第一套);全空则恢复默认池
        let activeName = watchlists.indices.contains(activeWatchlist) ? watchlists[activeWatchlist] : nil
        watchlists.removeAll { $0.entries.isEmpty }
        if watchlists.isEmpty { watchlists = [Watchlist(name: L("Watchlist"), entries: Self.defaultEntries)] }
        activeWatchlist = activeName.flatMap { a in watchlists.firstIndex(of: a) } ?? min(max(0, activeWatchlist), watchlists.count - 1)
        // 名称:空名补序号,重名追加序号(CLI 按名切换要唯一)
        var names = Set<String>()
        for i in watchlists.indices {
            let base = watchlists[i].name.isEmpty ? "\(L("Watchlist")) \(i + 1)" : watchlists[i].name
            var name = base, n = 2
            while names.contains(name) { name = "\(base) \(n)"; n += 1 }
            names.insert(name)
            watchlists[i].name = name
        }
        if boardOrigin?.count != 2 || boardOrigin?.allSatisfy({ $0.isFinite }) != true { boardOrigin = nil }
        if barOrigin?.count != 2 || barOrigin?.allSatisfy({ $0.isFinite }) != true { barOrigin = nil }
    }

    var colorScheme: ColorScheme { ColorScheme(configKey: transparentColor) }

    static var displayModes: [(key: String, label: String)] {
        [("marquee", L("Menu Bar Ticker")), ("board", L("Quote Board")),
         ("bar", L("Floating Ticker")), ("marquee,board", L("Menu Bar + Board")),
         ("marquee,bar", L("Menu Bar + Floating Ticker"))]
    }
}

/// WHIRLPOOL_CONFIG 仅供开发:调试实例用独立配置,不动正式配置
let configURL = ProcessInfo.processInfo.environment["WHIRLPOOL_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/whirlpool/config.json")
var configReadError: String?

func readConfig(at url: URL) throws -> TickerConfig {
    try JSONDecoder().decode(TickerConfig.self, from: Data(contentsOf: url))
}

/// 改名前(Pinwheel)的配置位置:首次启动时原样复制过来,旧文件保留不动
let legacyConfigURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/pinwheel/config.json")

func migrateLegacyConfig(from legacy: URL = legacyConfigURL, to target: URL = configURL) -> Bool {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return false }
    do {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: legacy, to: target)
        return true
    } catch {
        fputs("Whirlpool: could not migrate \(legacy.path): \(error.localizedDescription)\n", stderr)
        return false
    }
}

func loadConfig() -> TickerConfig {
    if ProcessInfo.processInfo.environment["WHIRLPOOL_CONFIG"] == nil, migrateLegacyConfig() {
        appLog.notice("migrated configuration from ~/.config/pinwheel")
    }
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
    catch { fputs("Whirlpool: could not save configuration: \(error.localizedDescription)\n", stderr); return false }
}

func configPath() -> String { configURL.path }
