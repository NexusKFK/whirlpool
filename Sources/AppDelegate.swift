import AppKit
import os

/// 生命周期日志:`log show --last 1d --predicate 'subsystem == "local.whirlpool"'`
/// 进程为什么退出(菜单、CLI、其他 app 发来的退出事件、系统注销)都记在这里。
let appLog = Logger(subsystem: "local.whirlpool", category: "app")

// ── App Delegate ───────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var menuSurface: MarqueeView?
    private var config: TickerConfig!
    private var quoteService: QuoteService!
    private var provider: QuoteProvider?
    private var configRevision = 0
    private var cycleInFlight = false
    private var lastTicks: [String: Double] = [:]   // symbol → 上轮价格(判跳动方向)
    private var board: BoardWindow?
    private var boardTimer: Timer?
    private var barWindow: BarWindow?
    private var configWindow: ConfigWindowController?
    private let engine = MarqueeEngine()
    private var userPaused = false
    private var suspended = false                   // 屏幕休眠 / 切走用户:停拉取、停滚动
    private var suspensionReasons = Set<Notification.Name>()
    private var artRefreshPending = false
    private var retryPending = false
    private var quitReason = "unknown"
    private var hoverWatch: Timer?
    private var updater: UpdateChecker?

    // ── 显示宽度=物理宽度,按 M 档字符数锚定(1 字符≈18pt)──
    // 字号切换时按各面点距换算字符数,换字号不再改变条在屏上的实际宽度。
    private func displayCols(dot: Int) -> Int {
        max(4, Int((Double(config.defaultWidth) * 3.0 / Double(LEDLayout(dot: dot).colW)).rounded()))
    }

    /// 菜单栏面宽度上限:屏宽的 40%。整条行情流是浮动 bar 的主场,
    /// 状态项过宽时 macOS 会在应用菜单较长时把它整个藏掉(看上去像"退出了")。
    private func menuBarCols(dot: Int) -> Int {
        let screenW = menuBarScreenWidth
        let cap = Int((screenW * 0.40 - 8) / Double(6 * LEDLayout(dot: dot).colW))
        return max(8, min(displayCols(dot: dot), cap))
    }

    /// 菜单栏宽度上限按哪块屏算:指定的屏,否则主显示器——固定不变。
    /// (以前用 NSScreen.main=有键盘焦点的屏,焦点在两屏间切换时条宽在 810/450pt 间来回跳。
    ///  macOS 会把状态项镜像到每块屏的菜单栏,真身与镜像共用同一宽度,所以按一块屏定死最稳)
    private var menuBarScreenWidth: CGFloat {
        (chosenScreen(config.displayScreen) ?? NSScreen.screens.first)?.frame.width ?? 1440
    }

    // ── 系统字体跑马灯:3pt 一虚拟列,两面同宽 ──
    private var isTextMarquee: Bool { config.marqueeFont != "led" }
    /// 文本视口按显示面各自封顶:菜单栏吃 40% 屏宽上限(过宽会被 macOS 藏掉);
    /// 浮动条只受它所在屏的宽度限制(以前与菜单栏共用 40% 上限,只开浮动条时也被卡在 ~810pt)
    private func textViewportCols(for view: MarqueeView?) -> Int {
        let wanted = config.defaultWidth * 6
        let cap: Int
        if view == nil || view === menuSurface {
            cap = max(48, Int((menuBarScreenWidth * 0.40 - 8) / 3.0))
        } else {
            cap = max(48, Int((barScreenWidth - 60) / 3.0))
        }
        return max(24, min(wanted, cap))
    }

    /// 浮动条所在屏的宽度(已放好就按实际所在屏,否则按设置里选的屏)
    private var barScreenWidth: CGFloat {
        (barWindow?.screen ?? placementScreen(config.displayScreen))?.frame.width ?? 1440
    }

    /// 浮动条 LED 列数:按宽度设置,但不超出所在屏(留出胶囊边距)
    private func barCols(dot: Int) -> Int {
        let cap = Int((barScreenWidth - 60) / Double(6 * LEDLayout(dot: dot).colW))
        return max(8, min(displayCols(dot: dot), cap))
    }

    private var marqueeNSFont: NSFont {
        let size: CGFloat = config.ledDotSize == 1 ? 12 : (config.ledDotSize == 3 ? 17 : 14)
        return config.marqueeFont == "mono"
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private var marqueeOn: Bool { config.displayMode.contains("marquee") }
    private var barOn: Bool { config.displayMode.contains("bar") }
    private var boardOn: Bool { config.displayMode.contains("board") }

    /// 菜单栏放不下 L 档点阵(宿主窗口约 30pt 高),钳回 M;浮动条三档全可用
    private func dot(for view: MarqueeView) -> Int {
        view === menuSurface ? min(config.ledDotSize, 2) : config.ledDotSize
    }

    private func style(for view: MarqueeView) -> LEDStyle {
        LEDStyle(tone: view.tone,
                 mono: config.transparent && config.colorScheme == .mono,
                 panel: !config.transparent)
    }

    /// 代码/价格的底色:透明模式由外观方案决定,黑底面板沿用 defaultColor
    private var baseColor: LEDColor {
        config.transparent ? config.colorScheme.baseColor : LEDColor.from(config.defaultColor)
    }

    // ── Setup ──────────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        config           = loadConfig()
        L10n.language = config.language
        appLog.notice("launch v\(Self.version, privacy: .public) pid \(getpid())")
        installMainMenu()
        applyDockIcon()
        configureEngine()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemAsleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemAwake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemAsleep(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemAwake(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        runSocketServer { [weak self] msg -> String in
            guard let self else { return "error" }
            var reply = "ok"
            DispatchQueue.main.sync { reply = self.receive(msg) }
            return reply
        }

        configureQuoteService()
        applyDisplayMode()
        configureUpdater()
        if let error = configReadError {
            let alert = NSAlert()
            alert.messageText = L("Configuration Could Not Be Read")
            alert.informativeText = L("The original file has been preserved. Check its format before saving new settings.") + "\n\n" + error
            alert.runModal()
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // ── 退出:记录原因,清理 socket ──────────────────────────────────────────────

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 其他进程发来的 Quit Apple Event(Dock 右键退出、osascript、注销、清理工具…)
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication {
            let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            let why = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue
            quitReason = "quit event from \(name)" + (why.map { " (reason \($0))" } ?? "")
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog.notice("terminate: \(self.quitReason, privacy: .public)")
        unlink(socketPath)
    }

    /// Dock 图标模式下点图标:打开设置(否则激活了却没窗口,⌘Q 会误退本 app)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openConfigWindow()   // 浮动条/报价卡算"可见窗口",不能靠 flag 判断
        return false
    }

    /// 设置/关于窗口关掉后把前台还给上一个 app:
    /// 否则本 app 仍是前台,用户按 ⌘Q 想退别的程序,退掉的却是行情
    @objc private func windowWillClose(_ note: Notification) {
        DispatchQueue.main.async {
            let others = NSApp.windows.filter {
                $0.isVisible && !($0 is BarWindow) && !($0 is BoardWindow) && $0.className != "NSStatusBarWindow"
                    && $0 !== note.object as? NSWindow && $0.level == .normal
            }
            if others.isEmpty, NSApp.isActive { NSApp.deactivate() }
        }
    }

    private func installMainMenu() {
        let root = NSMenu()
        let application = NSMenuItem(title: "Whirlpool", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Whirlpool")
        for (title, action, key) in [("About Whirlpool", #selector(showAbout), ""),
                                      ("Check for Updates…", #selector(checkForUpdates), ""),
                                      ("Settings…", #selector(openConfigWindow), ","),
                                      ("Quit Whirlpool", #selector(quit), "q")] {
            let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            item.target = self; appMenu.addItem(item)
        }
        application.submenu = appMenu; root.addItem(application)
        let edit = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: L(title), action: Selector(action), keyEquivalent: key))
        }
        edit.submenu = editMenu; root.addItem(edit)
        NSApp.mainMenu = root
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = item.button else { statusItem = item; return }
        button.title = ""
        button.image = nil
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Whirlpool")
        let surface = MarqueeView(frame: button.bounds)
        surface.autoresizingMask = [.width, .height]
        button.addSubview(surface)
        hook(surface)
        menuSurface = surface
        statusItem = item
    }

    /// 显示面的系统事件:明暗/倍率变化 → 原位重出纹理;悬停 → 暂停
    private func hook(_ surface: MarqueeView) {
        surface.onAppearanceChange = { [weak self] in self?.scheduleArtRefresh() }
        surface.onBackingChange = { [weak self] in self?.scheduleArtRefresh() }
        surface.onHover = { [weak self] inside in self?.hover(inside) }
    }

    private func hover(_ inside: Bool) {
        guard config.hoverPause else { return }
        if inside {
            engine.hold()
            // 菜单弹出等场景可能收不到 mouseExited:悬停期间每 0.5s 核对一次指针位置,离开就恢复
            hoverWatch?.invalidate()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !self.pointerOverTicker() { self.endHover() }
            }
            RunLoop.main.add(t, forMode: .common)
            hoverWatch = t
        } else {
            endHover()
        }
    }

    private func endHover() {
        hoverWatch?.invalidate(); hoverWatch = nil
        engine.resume()
    }

    private func pointerOverTicker() -> Bool {
        let p = NSEvent.mouseLocation
        var views: [NSView] = []
        if let s = menuSurface { views.append(s) }
        if let bar = barWindow, bar.isVisible, let root = bar.contentView { views.append(root) }
        return views.contains { view in
            guard let window = view.window else { return false }
            return window.convertToScreen(view.convert(view.bounds, to: nil)).contains(p)
        }
    }

    private func scheduleArtRefresh() {
        guard !artRefreshPending else { return }
        artRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.artRefreshPending = false
            self.engine.refreshArt()
        }
    }

    // ── 引擎接线 ───────────────────────────────────────────────────────────────

    private func configureEngine() {
        engine.surfaces = { [weak self] in
            guard let self else { return [] }
            var list: [MarqueeView] = []
            if self.marqueeOn, let s = self.menuSurface { list.append(s) }
            if self.barOn, let bar = self.barWindow, bar.isVisible { list.append(bar.surface) }
            return list
        }
        engine.viewportCols = { [weak self] view in
            guard let self else { return 60 }
            if self.isTextMarquee { return self.textViewportCols(for: view) }
            let d = self.dot(for: view)
            return visCols(displayWidth: view === self.menuSurface ? self.menuBarCols(dot: d) : self.barCols(dot: d))
        }
        engine.viewportWidth = { [weak self] view in
            guard let self else { return 180 }
            let pitch = self.isTextMarquee ? 3 : LEDLayout(dot: self.dot(for: view)).colW
            return CGFloat(self.engine.viewportCols(view) * pitch)
        }
        engine.buildRound = { [weak self] msg in self?.buildRound(msg) }
        engine.stillImage = { [weak self] msg, view in self?.stillImage(msg, view) }
        engine.loopsQuotes = { [weak self] in
            guard let self else { return false }
            return self.config.quoteLoop && self.config.tickerEnabled && !self.userPaused && !self.suspended
        }
        engine.onNeedsQuotes = { [weak self] in self?.fetchNextQuoteCycle() }
        engine.onContentSizeChange = { [weak self] in self?.syncSurfaceSizes() }
        applyEngineTiming()
    }

    private func applyEngineTiming() {
        // 滚速语义=屏幕上的物理速度(菜单栏一侧):点阵愈大每列位移愈大,按点距归一
        let pitch = isTextMarquee ? 3 : min(config.ledDotSize, 2) + 1
        engine.colsPerSecond = 1 / (config.scrollSpeed * Double(pitch) / 3.0)
        engine.defaultPause = config.defaultPause
        engine.flashesEnabled = config.marqueeBlink
    }

    private func buildRound(_ msg: TickerMessage) -> MarqueeRound? {
        let base = baseColor
        if isTextMarquee {
            let stream = buildTextScrollStream(text: msg.text, defaultColor: base, onClickCommand: msg.onClickCommand)
            guard !stream.runs.isEmpty else { return nil }
            let font = marqueeNSFont
            let geometry = TextStrip(stream: stream, font: font, defaultColor: base)
            return MarqueeRound(totalCols: geometry.totalCols, pauses: geometry.pauses,
                                flashes: flashGroups(geometry.blinkCols)) { [weak self] view in
                let style = self?.style(for: view) ?? LEDStyle()
                return TextStrip(stream: stream, font: font, defaultColor: base, style: style)
                    .makeArt(scale: view.backingScale)
            }
        }
        let stream = buildScrollStream(text: msg.text, defaultColor: base,
                                       onClickCommand: msg.onClickCommand, customChars: config.customChars)
        guard !stream.columns.isEmpty else { return nil }
        return MarqueeRound(totalCols: stream.columns.count, pauses: stream.pauses,
                            flashes: flashGroups(stream.blinkCols)) { [weak self] view in
            guard let self else { return makeLEDArt(stream: stream, dot: 2, style: LEDStyle(), scale: 2) }
            return makeLEDArt(stream: stream, dot: self.dot(for: view), style: self.style(for: view),
                              scale: view.backingScale)
        }
    }

    /// idle 图标(msg=nil)或 standby 静态帧
    private func stillImage(_ msg: TickerMessage?, _ view: MarqueeView) -> NSImage? {
        let st = style(for: view), scale = view.backingScale, d = dot(for: view)
        guard let msg, msg.kind == .standby else {
            return renderIdleIcon(color: baseColor, dot: d, style: st, scale: scale)
        }
        if isTextMarquee {
            let old = renderScale; renderScale = scale; defer { renderScale = old }
            return renderTextStandbyFrame(text: msg.text, viewportCols: engine.viewportCols(view),
                                          font: marqueeNSFont, defaultColor: baseColor, style: st)
        }
        let chars = view === menuSurface ? menuBarCols(dot: d) : barCols(dot: d)
        return renderStandbyFrame(text: msg.text, displayWidth: chars, defaultColor: baseColor,
                                  customChars: config.customChars, dot: d, style: st, scale: scale)
    }

    /// 状态项长度与浮动条尺寸跟随内容;固定长度免得 AppKit 反复重解内在尺寸
    private func syncSurfaceSizes() {
        if let si = statusItem, let surface = menuSurface {
            let w = max(8, surface.contentWidth.rounded(.up))
            if abs(si.length - w) > 0.5 { si.length = w }
        }
        barWindow?.fitContent()
    }

    // ── Pixeldichte / Bildschirme ──────────────────────────────────────────────

    @objc private func screensChanged() {
        board?.config = config; barWindow?.config = config
        board?.reposition(); barWindow?.reposition()
        scheduleArtRefresh()
    }

    // ── 休眠 / 锁屏:不拉行情、不滚动 ─────────────────────────────────────────

    @objc private func systemAsleep(_ notification: Notification) {
        suspensionReasons.insert(notification.name)
        guard !suspended else { return }
        suspended = true
        appLog.notice("suspend (screens asleep or session inactive)")
        engine.clearKeepingFrame()
        boardTimer?.invalidate(); boardTimer = nil
    }

    @objc private func systemAwake(_ notification: Notification) {
        suspensionReasons.remove(notification.name == NSWorkspace.screensDidWakeNotification
            ? NSWorkspace.screensDidSleepNotification : NSWorkspace.sessionDidResignActiveNotification)
        guard suspended, suspensionReasons.isEmpty else { return }
        suspended = false
        appLog.notice("resume")
        guard !userPaused, config.tickerEnabled else { return }
        quoteService.requestRefresh()
        if marqueeOn || barOn { fetchNextQuoteCycle() }
        if boardOn { startBoardTimer(); refreshBoard() }
    }

    // ── Menü ───────────────────────────────────────────────────────────────────

    @objc private func statusItemClicked() {
        guard let statusItem else { return }
        if engine.isWaitingForClick {
            engine.clickSticky()
        } else if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            nextWatchlist()   // ⌥+单击:切到下一套自选池
        } else {
            // 左键单击 = 收起/展开(收起时缩成 <w 小图标);右键才是菜单
            toggleCollapsed()
        }
    }

    @objc private func toggleCollapsed() {
        userPaused = !userPaused
        if userPaused {
            engine.stop()
            barWindow?.orderOut(nil)
            board?.orderOut(nil)
        } else {
            if barOn { barWindow?.orderFrontRegardless() }
            if boardOn { board?.orderFrontRegardless(); startBoardTimer(); refreshBoard() }
            restartMarquee()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            entry.target = self; menu.addItem(entry)
        }
        if let release = updater?.available, updater?.isSkipped(release) == false {
            let update = NSMenuItem(title: String(format: L("Whirlpool %@ is available…"), release.version),
                                    action: #selector(openUpdatePage), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
        }
        item("About Whirlpool", #selector(showAbout))
        item("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        let status = NSMenuItem(title: userPaused ? L("Paused") : L(quoteService?.status ?? "Waiting for quotes"), action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        if let date = quoteService?.lastUpdated {
            let label = NSMenuItem(title: L("Updated at") + " " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium), action: nil, keyEquivalent: "")
            label.isEnabled = false; menu.addItem(label)
        }
        item(userPaused ? "Resume" : "Pause", #selector(toggleCollapsed))
        item("Refresh Quotes", #selector(refreshQuotes))
        let lists = NSMenuItem(title: L("Watchlists"), action: nil, keyEquivalent: "")
        let listMenu = NSMenu()
        for (i, list) in config.watchlists.enumerated() {
            let entry = NSMenuItem(title: list.name, action: #selector(selectWatchlist(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            entry.state = i == config.activeWatchlist ? .on : .off
            listMenu.addItem(entry)
        }
        listMenu.addItem(.separator())
        let hint = NSMenuItem(title: L("Option-click the ticker to switch"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        listMenu.addItem(hint)
        let edit = NSMenuItem(title: L("Edit Watchlists…"), action: #selector(openConfigWindow), keyEquivalent: "")
        edit.target = self
        listMenu.addItem(edit)
        lists.submenu = listMenu; menu.addItem(lists)
        let charts = NSMenuItem(title: L("Open Chart"), action: nil, keyEquivalent: "")
        let chartMenu = NSMenu()
        for entry in config.watchlist {
            let i = NSMenuItem(title: entry.symbol, action: #selector(openChart(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [entry.symbol, entry.market]
            chartMenu.addItem(i)
        }
        charts.submenu = chartMenu; menu.addItem(charts)
        menu.addItem(.separator())
        item("Settings…", #selector(openConfigWindow), ",")
        let display = NSMenuItem(title: L("Display"), action: nil, keyEquivalent: "")
        display.submenu = buildModeMenu(); menu.addItem(display)
        if barOn || boardOn {
            let lock = NSMenuItem(title: L("Lock Floating Windows"), action: #selector(toggleLock), keyEquivalent: "")
            lock.target = self; lock.state = config.lockPosition ? .on : .off
            menu.addItem(lock)
        }
        if barOn {
            let through = NSMenuItem(title: L("Click Through Floating Ticker"), action: #selector(toggleClickThrough), keyEquivalent: "")
            through.target = self; through.state = config.barClickThrough ? .on : .off
            menu.addItem(through)
        }
        let appearance = NSMenuItem(title: L("Appearance"), action: nil, keyEquivalent: "")
        appearance.submenu = buildColorMenu(); menu.addItem(appearance)
        let advanced = NSMenuItem(title: L("Advanced"), action: nil, keyEquivalent: "")
        let advancedMenu = NSMenu()
        for (title, action) in [("Clear Messages", #selector(clearQueue)), ("Show Configuration File…", #selector(editConfigFile))] {
            let entry = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
            entry.target = self; advancedMenu.addItem(entry)
        }
        advancedMenu.addItem(.separator())
        for (title, action, enabled) in [("Enable Ticker", #selector(toggleTickerEnabled), config.tickerEnabled),
                                          ("Automatic Quotes", #selector(toggleQuoteLoop), config.quoteLoop)] {
            let entry = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
            entry.target = self; entry.state = enabled ? .on : .off; advancedMenu.addItem(entry)
        }
        advanced.submenu = advancedMenu; menu.addItem(advanced)
        item("Help", #selector(showHelp))
        menu.addItem(.separator())
        item("Quit Whirlpool", #selector(quit))
        return menu
    }

    private func applyDockIcon() {
        // 常驻行情工具默认不占程序坞;要看得见进程/随手重启的用户可打开图标
        NSApp.setActivationPolicy(config.showDockIcon ? .regular : .accessory)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Whirlpool", .applicationVersion: Self.version,
            .credits: NSAttributedString(string: L("A quiet desktop ticker for your watchlist.") + "\n\nmade by KFK with GPT-Astra, for all my lovely besties.")
        ])
    }

    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: L10n.isChinese ? "README.zh-CN" : "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else { showAbout() }
    }

    @objc private func openChart(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        openChart(for: WatchEntry(symbol: pair[0], market: pair[1]))
    }

    private func openChart(for entry: WatchEntry) {
        if let url = chartURL(for: entry) { NSWorkspace.shared.open(url) }
    }

    @objc private func refreshQuotes() {
        if userPaused { toggleCollapsed(); return }
        quoteService.requestRefresh()
        restartMarquee()
        if boardOn { refreshBoard() }
    }

    private func configureQuoteService() {
        let p = QuoteEngine.provider(for: config.provider)
        provider = p
        (p as? RealProvider)?.includeSeries = boardOn
        quoteService = QuoteService(provider: p, interval: config.boardRefresh)
        applyCadence()
        quoteService.onUpdate = { [weak self] in
            guard let self else { return }
            let text = "Whirlpool · " + L(self.quoteService.status)
            self.statusItem?.button?.toolTip = text
            self.board?.contentView?.toolTip = text
            self.barWindow?.contentView?.toolTip = text
        }
    }

    private func applyCadence() {
        quoteService.cadence = config.smartRefresh
            ? { entries, base, now, lastTrade in
                MarketClock.refreshInterval(entries, base: base, now: now, lastTrade: lastTrade) }
            : nil
    }

    private func buildColorMenu() -> NSMenu {
        let menu    = NSMenu()
        let current = config.colorScheme
        for scheme in ColorScheme.allCases {
            let item = NSMenuItem(title: scheme.label, action: #selector(setTintColor(_:)), keyEquivalent: "")
            item.target           = self
            item.representedObject = scheme.rawValue
            item.state            = (current == scheme) ? .on : .off
            menu.addItem(item)
            if scheme == .mono { menu.addItem(.separator()) }
        }
        return menu
    }

    // ── Actions ────────────────────────────────────────────────────────────────

    @objc private func setTintColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config.transparentColor = key
        saveConfig(config)
        engine.refreshArt()
    }

    @objc private func toggleLock() {
        config.lockPosition.toggle()
        persistFloatingOptions()
    }

    @objc private func toggleClickThrough() {
        config.barClickThrough.toggle()
        persistFloatingOptions()
    }

    /// Drag callbacks keep the shared configuration current, even before the debounced disk save.
    private func persistFloatingOptions() {
        saveConfig(config)
        barWindow?.config = config
        board?.config = config
    }

    @objc private func toggleTickerEnabled() {
        config.tickerEnabled.toggle()
        saveConfig(config)
        if config.tickerEnabled { restartMarquee() } else { engine.stop() }
    }

    @objc private func clearQueue() {
        restartMarquee()
    }

    /// 清掉插播与当前轮,按当前配置重开一轮(行情循环开着就立刻重拉)
    private func restartMarquee() {
        guard marqueeOn || barOn else { engine.stop(); return }
        guard config.tickerEnabled, !userPaused, !suspended else { engine.stop(); return }
        if config.quoteLoop {
            engine.clearKeepingFrame()
            cycleInFlight = false
            configRevision += 1
            fetchNextQuoteCycle()
        } else {
            engine.stop()
        }
    }

    @objc private func toggleQuoteLoop() {
        config.quoteLoop.toggle()
        saveConfig(config)
        if config.quoteLoop { restartMarquee() }
    }

    @objc private func editConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    @objc private func openConfigWindow() {
        if configWindow == nil {
            configWindow = ConfigWindowController(config: config)
            configWindow?.currentConfig = { [weak self] in self?.config }
            configWindow?.onApplied = { [weak self] c in
                guard let self else { return }
                let resetSource = self.config.provider != c.provider
                self.config = c
                L10n.language = c.language
                self.installMainMenu()
                self.applyDockIcon()
                if resetSource { self.configureQuoteService(); self.lastTicks = [:]; self.board?.resetPriceHistory() }
                self.quoteService.interval = c.boardRefresh
                self.applyCadence()
                self.applyDisplayMode()
                self.configureUpdater()
            }
        }
        configWindow?.reload(config: config)
        configWindow?.show()
    }

    @objc private func quit() {
        quitReason = "menu"
        NSApp.terminate(nil)
    }

    // ── Empfang ────────────────────────────────────────────────────────────────

    @discardableResult
    private func receive(_ msg: TickerMessage) -> String {
        // getStatus und quit funktionieren auch bei deaktiviertem Ticker
        switch msg.kind {
        case .getStatus:
            return statusJSON()
        case .openSettings:
            DispatchQueue.main.async { self.openConfigWindow() }
            return "ok"
        case .setMode:
            // 模式切换:与设置页/菜单同源,和 tickerEnabled 无关
            let wanted = msg.text
            let key = TickerConfig.displayModes.first { $0.key == wanted }?.key
                ?? (wanted == "both" ? "marquee,board" : nil)
            guard let key else { return "error" }
            config.displayMode = key
            saveConfig(config)
            DispatchQueue.main.async { self.applyDisplayMode() }
            return "ok"
        case .setList:
            guard let index = watchlistIndex(for: msg.text) else { return "error: unknown watchlist" }
            DispatchQueue.main.async { self.switchWatchlist(to: index) }
            return "ok"
        case .quit:
            quitReason = "CLI --quit/--restart"
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok"
        default:
            break
        }

        guard config.tickerEnabled else { return "disabled" }

        switch msg.kind {
        case .setWidth:
            // 运行时覆盖宽度(不落盘);物理锚定下只改基准值,各面自行换算,下一轮生效
            if let w = msg.width, w >= 5 { config.defaultWidth = min(TickerConfig.maxWidth, max(8, w)) }
            return "ok"
        case .clearQueue:
            restartMarquee()
            return "ok"
        case .scroll, .standby:
            break
        case .getStatus, .quit, .openSettings, .setMode, .setList:
            return "ok"   // bereits oben behandelt
        }

        switch msg.priority {
        case .normal:     engine.enqueue(msg)
        case .urgent:     engine.prepend(msg)
        case .veryUrgent: engine.interrupt(with: msg)   // 被打断的消息之后从头重播
        }
        return "ok"
    }

    private func statusJSON() -> String {
        // menubar:状态项窗口是否真的在屏上(菜单栏挤不下时 macOS 会整个藏掉它)
        var menubar = "null"
        if marqueeOn || statusItem != nil, let window = statusItem?.button?.window {
            let f = window.frame
            menubar = "{\"visible\":\(window.occlusionState.contains(.visible)),\"x\":\(Int(f.minX)),\"y\":\(Int(f.minY)),\"w\":\(Int(f.width)),\"h\":\(Int(f.height)),\"length\":\(Int(statusItem?.length ?? 0))}"
        }
        // cols:各显示面图层实际滚到的列(连查两次在变 = 动画在 GPU 上推进)
        let cols = engine.surfaces().map { $0.presentationCol.map { String(format: "%.1f", $0) } ?? "null" }
        if let window = statusItem?.button?.window, menubar != "null" {
            let screen = (try? JSONEncoder().encode(window.screen?.localizedName ?? "")).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            menubar = String(menubar.dropLast()) + ",\"screen\":\(screen)}"
        }
        let listName = config.watchlists.indices.contains(config.activeWatchlist) ? config.watchlists[config.activeWatchlist].name : ""
        let list = (try? JSONEncoder().encode(listName)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "{\"phase\":\"\(engine.phaseName)\",\"queue\":\(engine.queueCount),\"pid\":\(getpid()),\"version\":\"\(Self.version)\",\"list\":\(list),\"menubar\":\(menubar),\"cols\":[\(cols.joined(separator: ","))]}"
    }

    // ── Quote-Loop ───────────────────────────────────────────────────────────────
    //
    // 一轮将尽 → 拉一次行情(共享缓存,未到间隔直接给缓存)→ 拼串入队,轮尾无缝接上。
    // 拉取失败保留最后一帧,15s 后重试。

    private func fetchNextQuoteCycle() {
        guard !cycleInFlight, !suspended, !userPaused, config.tickerEnabled, config.quoteLoop,
              marqueeOn || barOn else { return }
        cycleInFlight = true
        let revision = configRevision
        let entries   = config.watchlist
        let redUp     = config.redUpMarkets
        let pause     = config.pausePerSymbol

        quoteService.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self, self.configRevision == revision else { return }
                self.cycleInFlight = false
                guard self.config.quoteLoop, self.config.tickerEnabled, !self.userPaused, !self.suspended,
                      !quotes.isEmpty, !entries.isEmpty
                else {
                    if self.engine.phase == .idle, self.engine.current == nil, quotes.isEmpty { self.engine.showIdle() }
                    self.scheduleRetry()
                    return
                }
                let built = QuoteEngine.marqueeText(entries: entries, quotes: quotes,
                                                    redUpMarkets: redUp, pausePerSymbol: pause,
                                                    separator: self.config.marqueeSeparator,
                                                    changeArrows: self.config.changeArrows,
                                                    blinkChanged: self.config.marqueeBlink,
                                                    previousTicks: self.lastTicks)
                // A missing symbol in one response must not erase its last known tick.
                self.lastTicks = self.lastTicks.filter { key, _ in entries.contains { $0.symbol == key } }
                for e in entries {
                    if let q = quotes[e.symbol] { self.lastTicks[e.symbol] = q.price }
                }
                var msg = TickerMessage(kind: .scroll, text: built, priority: .normal,
                                        duration: 0, onClickCommand: nil, width: nil)
                msg.isQuoteCycle = true
                self.engine.enqueue(msg)
            }
        }
    }

    private func scheduleRetry() {
        guard !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            if self.engine.phase == .idle { self.fetchNextQuoteCycle() }
        }
    }

    // ── 多自选池 ───────────────────────────────────────────────────────────────

    /// CLI/菜单参数 → 池序号:名称(不分大小写)、1 起的序号、next / prev
    private func watchlistIndex(for text: String) -> Int? {
        let lists = config.watchlists
        let t = text.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "next": return (config.activeWatchlist + 1) % lists.count
        case "prev", "previous": return (config.activeWatchlist - 1 + lists.count) % lists.count
        default:
            if let n = Int(t), (1...lists.count).contains(n) { return n - 1 }
            return lists.firstIndex { $0.name.caseInsensitiveCompare(t) == .orderedSame }
        }
    }

    @objc private func selectWatchlist(_ sender: NSMenuItem) {
        switchWatchlist(to: sender.tag)
    }

    private func nextWatchlist() {
        guard config.watchlists.count > 1 else { return }
        switchWatchlist(to: (config.activeWatchlist + 1) % config.watchlists.count)
    }

    private func switchWatchlist(to index: Int) {
        guard config.watchlists.indices.contains(index) else { return }
        // 只改当前池,别的字段以磁盘为准(浮窗位置可能刚被拖动写过)
        var saved = (try? readConfig(at: configURL)) ?? config!
        saved.activeWatchlist = index
        saved.barOrigin = config.barOrigin; saved.boardOrigin = config.boardOrigin
        config.activeWatchlist = index
        if configReadError == nil { saveConfig(saved) }
        appLog.notice("watchlist → \(self.config.watchlists[index].name, privacy: .public)")
        applyDisplayMode()
        // 切换提示:先亮一下池名,行情到了接着滚(LED 字库只有 ASCII,中文名用序号)
        guard (marqueeOn || barOn), config.watchlists.count > 1,
              config.tickerEnabled, !userPaused, !suspended else { return }
        let name = config.watchlists[index].name
        let ledSafe = name.uppercased().allSatisfy { FONT[$0] != nil }
        let label = isTextMarquee || ledSafe ? name : "LIST \(index + 1)"
        engine.interrupt(with: TickerMessage(kind: .standby, text: "> " + label, priority: .normal,
                                             duration: 1.2, onClickCommand: nil, width: nil))
    }

    // ── 新版本提示 ─────────────────────────────────────────────────────────────

    private func configureUpdater() {
        if updater == nil {
            let u = UpdateChecker(current: Self.version)
            u.onAvailable = { [weak self] release in self?.announce(release) }
            updater = u
        }
        if config.checkUpdates { updater?.start() } else { updater?.stop() }
    }

    /// 自动发现新版本:跑马灯插播一次(琥珀色),菜单顶部常驻入口
    private func announce(_ release: UpdateChecker.Release) {
        appLog.notice("update available: \(release.version, privacy: .public)")
        // 先看此刻能不能播,再记"已播":行情条关着时不该把这次提示白白记掉
        guard let updater, marqueeOn || barOn, config.tickerEnabled, !userPaused,
              updater.shouldAnnounce(release) else { return }
        let text = isTextMarquee
            ? String(format: L("Whirlpool %@ is available — right-click to update"), release.version)
            : "WHIRLPOOL \(release.version) AVAILABLE - RIGHT-CLICK TO UPDATE"
        engine.enqueue(TickerMessage(kind: .scroll, text: "\\c[amber]\(text)\\c[]   ", priority: .normal,
                                     duration: 0, onClickCommand: nil, width: nil))
    }

    @objc private func openUpdatePage() {
        NSWorkspace.shared.open(updater?.available?.page ?? UpdateChecker.releasesPage)
    }

    @objc private func checkForUpdates() {
        let u = updater ?? UpdateChecker(current: Self.version)
        updater = u
        u.check { result in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .success(let release?):
                alert.messageText = String(format: L("Whirlpool %@ is available"), release.version)
                alert.informativeText = String(format: L("You have %@. Download the new version from GitHub?"), Self.version)
                alert.addButton(withTitle: L("Download"))
                alert.addButton(withTitle: L("Later"))
                alert.addButton(withTitle: L("Skip This Version"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: NSWorkspace.shared.open(release.page)
                case .alertThirdButtonReturn: u.skip(release)
                default: break
                }
            case .success(nil):
                alert.messageText = L("Whirlpool is up to date")
                alert.informativeText = String(format: L("Version %@ is the latest release."), Self.version)
                alert.runModal()
            case .failure(let error):
                alert.messageText = L("Could Not Check for Updates")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // ── Display-Mode ─────────────────────────────────────────────────────────────
    //
    // 可组合 displayMode(逗号分隔):marquee=状态栏跑马灯,board=程序坞旁报价卡,
    // bar=屏幕下缘置顶跑马灯条(给竖屏/放不下宽 bar 的屏幕)。"both"=旧别名(marquee+board)。

    private func applyDisplayMode() {
        configRevision += 1
        cycleInFlight = false
        boardTimer?.invalidate(); boardTimer = nil
        renderTransparent = config.transparent
        renderColoredTransparent = config.transparent && config.colorScheme != .mono
        applyEngineTiming()

        ensureStatusItem()
        engine.stop()
        if !marqueeOn, let surface = menuSurface {
            // 只开报价卡/浮动条时,菜单栏留一个 <w 小图标作抓手
            surface.showStill(stillImage(nil, surface))
            syncSurfaceSizes()
        }

        if barOn {
            if barWindow == nil {
                let bar = BarWindow(config: config)
                bar.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
                bar.onHover = { [weak self] inside in self?.hover(inside) }
                bar.onOptionClick = { [weak self] in self?.nextWatchlist() }
                bar.onOriginChange = { [weak self] origin in self?.config.barOrigin = origin }
                hook(bar.surface)
                bar.surface.onHover = nil
                barWindow = bar
            }
            barWindow?.config = config
            if !userPaused { barWindow?.orderFrontRegardless() }
        } else {
            barWindow?.orderOut(nil)
        }

        let wantsSeries = boardOn
        if let real = provider as? RealProvider, real.includeSeries != wantsSeries {
            real.includeSeries = wantsSeries
            if wantsSeries { quoteService.invalidate() }
        }

        if boardOn {
            if board == nil {
                board = BoardWindow(config: config)
                board?.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
                board?.onOpenChart = { [weak self] entry in self?.openChart(for: entry) }
                board?.onOriginChange = { [weak self] origin in self?.config.boardOrigin = origin }
            }
            board?.config = config
            if !userPaused { board?.orderFrontRegardless() }
            startBoardTimer()
            refreshBoard()
        } else {
            board?.orderOut(nil)
        }

        // 跑马灯引擎(marquee/bar 共用同一时间线):清旧一轮、按新配置立即重拉
        engine.showIdle()
        restartMarquee()
    }

    private func startBoardTimer() {
        guard boardTimer == nil, !suspended else { return }
        let t = Timer(timeInterval: max(5, config.boardRefresh), repeats: true) { [weak self] _ in
            self?.refreshBoard()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        boardTimer = t
    }

    private func refreshBoard() {
        guard !userPaused, !suspended, config.tickerEnabled else { return }
        let revision = configRevision
        let entries = config.watchlist
        let redUp   = config.redUpMarkets
        let arrows  = config.changeArrows
        quoteService.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self, self.configRevision == revision, !self.userPaused, !self.suspended,
                      self.config.tickerEnabled else { return }
                self.board?.update(entries: entries, quotes: quotes,
                                   redUpMarkets: redUp, at: self.quoteService.lastUpdated ?? Date(), changeArrows: arrows,
                                   status: self.quoteService.status)
            }
        }
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config.displayMode = key
        saveConfig(config)
        applyDisplayMode()
    }

    private func buildModeMenu() -> NSMenu {
        let menu = NSMenu()
        let modes = TickerConfig.displayModes.map { ($0.label, $0.key) }
        for (title, key) in modes {
            let i = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = (config.displayMode == key) ? .on : .off
            menu.addItem(i)
        }
        return menu
    }
}
