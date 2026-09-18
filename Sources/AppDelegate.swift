import AppKit

private let maxPending = 3
private let blinkDuration = 0.4   // Sekunden pro Blink-Phase

// ── Animations-Phase ───────────────────────────────────────────────────────────

private enum Phase {
    case idle
    case scrolling                              // scrollIn + scrollOut in einem
    case pauseInStream(until: Date)             // \p[N] getriggert
    case stickyBlink(phase: Int, until: Date, cmd: String?, blinks: Int)
    case stickyWait(cmd: String?)               // wartet auf Klick
    case defaultPause(until: Date)              // End-of-message Pause
    case standby(until: Date)                   // Standby-Text
}

// ── App Delegate ───────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var animTimer:  Timer?
    private var pauseItem:  NSMenuItem?
    private var config:     TickerConfig!
    private var quoteService: QuoteService!
    private var configRevision = 0
    private var cycleInFlight = false
    private var prefetchArmed = true   // 每轮只预取一次;预取窗口比轮尾长,不设闸会连环重拉
    private var lastTicks: [String: Double] = [:]   // symbol → 上轮价格(判跳动方向)
    private var priceFlashes = ScrollFlashes()
    private var board: BoardWindow?
    private var boardTimer: Timer?
    private var barWindow: BarWindow?
    private var configWindow: ConfigWindowController?

    // Zustand
    private var displayWidth: Int = 20
    private var tintColor: LEDColor?   // im Menü gewählte Grundfarbe, nil = Menüleiste
    private var phase: Phase = .idle
    private var userPaused = false
    private var idleRendered = false

    // Aktuelle Scroll-Animation
    private var canvas:      [ColoredColumn] = []
    private var scrollOffset = 0
    private var roundLen     = 0             // 一轮 = 一份完整串(环绕画布的一半)
    private var pendingPauses: [PauseMarker] = []   // noch nicht getriggert
    private var currentMsg:  TickerMessage?          // für very-urgent Replay

    // Queue
    private var queue:     [TickerMessage] = []
    private let queueLock = NSLock()
    private var interrupted: TickerMessage? = nil    // sehr-dringend unterbrochene Msg

    // ── Setup ──────────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        config           = loadConfig()
        L10n.language = config.language
        installMainMenu()
        displayWidth     = config.defaultWidth
        renderTransparent = config.transparent
        applyTint()

        updateRenderScale()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Idle-Icon sofort zeigen — der Timer läuft erst, wenn es etwas zu
        // animieren gibt (siehe startTimer/stopTimer)
        setIdle()

        runSocketServer { [weak self] msg -> String in
            guard let self else { return "error" }
            var reply = "ok"
            DispatchQueue.main.sync { reply = self.receive(msg) }
            return reply
        }

        configureQuoteService()
        applyDisplayMode()
        if let error = configReadError {
            let alert = NSAlert()
            alert.messageText = L("Configuration Could Not Be Read")
            alert.informativeText = L("The original file has been preserved. Check its format before saving new settings.") + "\n\n" + error
            alert.runModal()
        }
    }

    private func installMainMenu() {
        let root = NSMenu()
        let application = NSMenuItem(title: "Pinwheel", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Pinwheel")
        for (title, action, key) in [("About Pinwheel", #selector(showAbout), ""),
                                      ("Settings…", #selector(openConfigWindow), ","),
                                      ("Quit Pinwheel", #selector(quit), "q")] {
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// Grundfarbe einer Nachricht. Im gefärbten Transparentmodus gilt die im Menü
    /// gewählte Farbe; \c[…] im Text überschreibt sie danach spaltenweise.
    private func baseColor() -> LEDColor {
        if renderColoredTransparent, let tint = tintColor { return tint }
        return LEDColor.from(config.defaultColor)
    }

    private func currentIdleColor() -> LEDColor {
        baseColor()
    }

    // ── Pixeldichte ────────────────────────────────────────────────────────────
    //
    // Der Renderer schreibt Pixel direkt und braucht dafür die Auflösung des
    // Bildschirms, auf dem die Menüleiste liegt.

    private func updateRenderScale() {
        let s = statusItem?.button?.window?.backingScaleFactor
             ?? NSScreen.main?.backingScaleFactor ?? 2
        renderScale = max(1, Int(s.rounded()))
    }

    @objc private func screensChanged() {
        if let saved = try? readConfig(at: configURL) {
            config.boardOrigin = saved.boardOrigin; config.barOrigin = saved.barOrigin
        }
        board?.config = config; barWindow?.config = config
        let previous = renderScale
        updateRenderScale()
        guard renderScale != previous else { return }
        idleRendered = false
        if case .idle = phase { setIdle() }
    }

    // ── Animations-Timer ───────────────────────────────────────────────────────
    //
    // Der Timer läuft nur, solange sich etwas bewegt. Im Leerlauf (leere Queue,
    // sticky-Wartezustand, Ticker aus, pausiert) wird er gestoppt — sonst weckt
    // er den Prozess dauerhaft 1/scrollSpeed-mal pro Sekunde für nichts.
    // Alles, was wieder etwas zu tun gibt, ruft startTimer().

    private func startTimer() {
        guard animTimer == nil, config.tickerEnabled, !userPaused else { return }
        let timer = Timer(timeInterval: config.scrollSpeed, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = config.scrollSpeed * 0.1   // erlaubt dem Kernel, Wakeups zu bündeln
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stopTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    // ── Menü ───────────────────────────────────────────────────────────────────

    @objc private func statusItemClicked() {
        guard let statusItem else { return }
        if case .stickyWait(let cmd) = phase {
            if let cmd = cmd {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments     = ["-c", cmd]
                try? proc.run()
            }
            phase = .scrolling
            startTimer()
        } else if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // 左键单击 = 收起/展开(收起时缩成 < 小图标);右键才是菜单
            toggleCollapsed()
        }
    }

    @objc private func toggleCollapsed() {
        userPaused = !userPaused
        if userPaused {
            stopTimer()
            idleRendered = false
            setIdle()
            barWindow?.orderOut(nil)
            board?.orderOut(nil)
        } else {
            if config.quoteLoop, config.tickerEnabled {
                clearAllMessages()     // 展开立即拉新行情,不吃旧轮残帧
            } else {
                startTimer()
            }
            if config.displayMode.contains("bar") { barWindow?.orderFrontRegardless() }
            if config.displayMode.contains("board") { board?.orderFrontRegardless(); refreshBoard() }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            entry.target = self; menu.addItem(entry)
        }
        item("About Pinwheel", #selector(showAbout))
        menu.addItem(.separator())
        let status = NSMenuItem(title: userPaused ? L("Paused") : L(quoteService?.status ?? "Waiting for quotes"), action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        if let date = quoteService?.lastUpdated {
            let label = NSMenuItem(title: L("Updated at") + " " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium), action: nil, keyEquivalent: "")
            label.isEnabled = false; menu.addItem(label)
        }
        item(userPaused ? "Resume" : "Pause", #selector(toggleCollapsed))
        item("Refresh Quotes", #selector(refreshQuotes))
        menu.addItem(.separator())
        item("Settings…", #selector(openConfigWindow), ",")
        let display = NSMenuItem(title: L("Display"), action: nil, keyEquivalent: "")
        display.submenu = buildModeMenu(); menu.addItem(display)
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
        item("Quit Pinwheel", #selector(quit), "q")
        return menu
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.6.0"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pinwheel", .applicationVersion: version,
            .credits: NSAttributedString(string: L("A quiet desktop ticker for your watchlist.") + "\n\n" + L("Open-source software under the MIT license. Market data remains subject to provider terms."))
        ])
    }

    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: L10n.isChinese ? "README.zh-CN" : "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else { showAbout() }
    }

    @objc private func refreshQuotes() {
        if userPaused { toggleCollapsed(); return }
        quoteService.requestRefresh()
        clearAllMessages()
        if config.displayMode.contains("board") { refreshBoard() }
    }

    private func configureQuoteService() {
        quoteService = QuoteService(provider: QuoteEngine.provider(for: config.provider), interval: config.boardRefresh)
        quoteService.onUpdate = { [weak self] in
            guard let self else { return }
            let text = "Pinwheel · " + L(self.quoteService.status)
            self.statusItem?.button?.toolTip = text
            self.board?.contentView?.toolTip = text
            self.barWindow?.contentView?.toolTip = text
        }
    }

    private func buildColorMenu() -> NSMenu {
        let menu    = NSMenu()
        let current = config.transparentColor.lowercased()
        // Nur die gängigen Grundfarben — \c[red] und \c[yellow] bleiben im Text
        // natürlich weiter möglich, sie brauchen nur keinen Menüeintrag.
        let entries = [("Adaptive (monochrome)", "auto"),
                       ("Amber", "amber"),
                       ("Green", "green"),
                       ("White", "white"),
                       ("Black", "black")]
        for (title, key) in entries {
            let item = NSMenuItem(title: L(title), action: #selector(setTintColor(_:)), keyEquivalent: "")
            item.target           = self
            item.representedObject = key
            item.state            = (current == key) ? .on : .off
            menu.addItem(item)
            if key == "auto" { menu.addItem(.separator()) }
        }
        return menu
    }

    // ── Actions ────────────────────────────────────────────────────────────────

    @objc private func setTintColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config.transparentColor = key
        saveConfig(config)
        applyTint()
        refreshDisplay()
    }

    /// "auto" (oder ein unbekannter Name) → Template, sonst gefärbt
    private func applyTint() {
        let key = config.transparentColor.lowercased()
        tintColor = key == "auto" ? nil : LEDColor(rawValue: key)
        renderColoredTransparent = renderTransparent && tintColor != nil
    }

    /// Zeichnet das aktuell Sichtbare in der neuen Farbe neu, ohne den Ablauf
    /// zu stören. Die laufende Nachricht wird neu aufgebaut, weil die Farben
    /// beim Erzeugen des Streams in die Spalten eingebacken werden.
    private func refreshDisplay() {
        idleRendered = false
        switch phase {
        case .idle:
            setIdle()

        case .standby:
            if let msg = currentMsg {
                setImage(renderStandbyFrame(text: msg.text, displayWidth: displayWidth,
                                            defaultColor: baseColor(),
                                            customChars: config.customChars))
            }

        default:
            guard let msg = currentMsg, msg.kind == .scroll, !canvas.isEmpty else { break }
            let stream = buildScrollStream(text: msg.text, defaultColor: baseColor(),
                                           onClickCommand: msg.onClickCommand,
                                           customChars: config.customChars)
            let rebuilt = wrapCanvas(stream.columns)
            // Gleicher Text, gleiche Breite → gleiche Geometrie; nur die Farben
            // ändern sich, Scrollposition und offene Pausen bleiben gültig.
            if rebuilt.count == canvas.count {
                canvas = rebuilt
                showScrollFrame()
            }
        }
    }

    @objc private func toggleTickerEnabled() {
        config.tickerEnabled.toggle()
        saveConfig(config)
        idleRendered = false
        if case .idle = phase { setIdle() }
        if config.tickerEnabled { startTimer() } else { stopTimer() }
    }

    @objc private func clearQueue() {
        clearAllMessages()
    }

    private func clearAllMessages() {
        queueLock.lock(); queue.removeAll(); queueLock.unlock()
        interrupted = nil
        currentMsg  = nil
        phase = .idle
        stopTimer()
        // 行情循环还开着就续上下一轮,否则 Clear queue 会把跑马灯清死;
        // 重拉期间保留最后一帧,不闪 idle 图标。
        if config.quoteLoop, config.tickerEnabled, !userPaused {
            fetchNextQuoteCycle()
        } else {
            setIdle()
        }
    }

    @objc private func togglePause() {
        userPaused = !userPaused
        pauseItem?.title = userPaused ? L("Resume") : L("Pause")
        if userPaused { stopTimer() } else { startTimer() }
    }

    @objc private func toggleQuoteLoop() {
        config.quoteLoop.toggle()
        saveConfig(config)
        if config.quoteLoop, config.tickerEnabled, !userPaused {
            fetchNextQuoteCycle()
            startTimer()
        }
    }

    @objc private func editConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    @objc private func openConfigWindow() {
        if let saved = try? readConfig(at: configURL) {
            config.boardOrigin = saved.boardOrigin; config.barOrigin = saved.barOrigin
        }
        if configWindow == nil {
            configWindow = ConfigWindowController(config: config)
            configWindow?.onApplied = { [weak self] c in
                guard let self else { return }
                let resetSource = self.config.provider != c.provider
                self.config = c
                L10n.language = c.language
                self.installMainMenu()
                if resetSource { self.configureQuoteService(); self.lastTicks = [:]; self.board?.resetPriceHistory() }
                self.quoteService.interval = c.boardRefresh
                self.applyDisplayMode()
            }
        }
        configWindow?.reload(config: config)
        configWindow?.show()
    }

    @objc private func quit() {
        animTimer?.invalidate()
        unlink(socketPath)
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
        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok"
        default:
            break
        }

        guard config.tickerEnabled else { return "disabled" }

        switch msg.kind {
        case .setWidth:
            if let w = msg.width, w >= 5 { displayWidth = w }
            return "ok"
        case .clearQueue:
            clearAllMessages()
            return "ok"
        case .scroll, .standby:
            break
        case .getStatus, .quit, .openSettings:
            return "ok"   // bereits oben behandelt
        }

        switch msg.priority {
        case .normal:
            enqueue(msg)
        case .urgent:
            prependQueue(msg)
        case .veryUrgent:
            // Sofort starten statt einreihen — die unterbrochene Nachricht
            // wird danach von vorn wiederholt
            switch phase {
            case .scrolling, .pauseInStream, .defaultPause:
                interrupted = currentMsg
            default:
                break
            }
            startMessage(msg)
        }
        startTimer()
        return "ok"
    }

    // ── Status ─────────────────────────────────────────────────────────────────

    private func statusJSON() -> String {
        let phaseName: String
        switch phase {
        case .idle:                    phaseName = "idle"
        case .scrolling:               phaseName = "scrolling"
        case .pauseInStream:           phaseName = "scrolling"
        case .defaultPause:            phaseName = "scrolling"
        case .stickyBlink, .stickyWait: phaseName = "sticky"
        case .standby:                 phaseName = "standby"
        }
        queueLock.lock()
        let count = queue.count
        queueLock.unlock()
        return "{\"phase\":\"\(phaseName)\",\"queue\":\(count)}"
    }

    // ── Timer-Tick (Main-Thread) ───────────────────────────────────────────────

    private func tick() {
        guard config.tickerEnabled, !userPaused else { stopTimer(); return }

        switch phase {

        case .idle:
            if let saved = interrupted {
                interrupted = nil
                startMessage(saved)
                return
            }
            guard let msg = dequeueNext() else {
                // 队列空:行情循环开着就拉下一轮(拉取期间保留当前画面,
                // 回调里 enqueue + startTimer);否则回 idle 图标并停表。
                if config.quoteLoop, config.tickerEnabled, !userPaused {
                    if !cycleInFlight { fetchNextQuoteCycle() }
                    stopTimer()
                } else {
                    setIdle(); stopTimer()
                }
                return
            }
            startMessage(msg)

        case .scrolling:
            if let p = pendingPauses.first, p.at == scrollOffset {
                pendingPauses.removeFirst()
                triggerPause(p.kind)
                return
            }

            // 预取:离本轮结束还有约一屏时提前拉下一轮(每轮只发一次),
            // 滚到头时新数据已入队,消除轮尾的冻结停顿感。
            if prefetchArmed, config.quoteLoop, config.tickerEnabled, !userPaused,
               !cycleInFlight, roundLen > 0,
               scrollOffset >= roundLen - visCols(displayWidth: displayWidth) {
                prefetchArmed = false
                fetchNextQuoteCycle()
            }

            // 一轮 = 一份完整串。画布是双拼环绕,窗口末端恰是"串尾接串头"。
            if roundLen > 0, scrollOffset >= roundLen {
                // 队列里已有下一轮:同 tick 直接接线渲染,零冻结
                if let next = dequeueNext() {
                    startMessage(next)
                    return
                }
                phase = .idle
                if config.quoteLoop, config.tickerEnabled, !userPaused, !cycleInFlight {
                    fetchNextQuoteCycle()   // 保险:预取没赶上时兜底
                } else {
                    setIdle()
                }
                return
            }

            showScrollFrame()
            scrollOffset += 1

        case .pauseInStream(let until):
            if Date() >= until {
                phase = .scrolling
            }

        case .stickyBlink(let bphase, let until, let cmd, let blinks):
            if Date() >= until {
                let next = bphase + 1
                if next >= blinks * 2 {
                    showScrollFrame()
                    phase = .stickyWait(cmd: cmd)
                } else {
                    let on = (next % 2 != 0)
                    showScrollFrame(blank: !on)
                    phase = .stickyBlink(phase: next,
                                         until: Date().addingTimeInterval(blinkDuration),
                                         cmd: cmd, blinks: blinks)
                }
            }

        case .stickyWait:
            stopTimer()   // wartet auf Klick — statusItemClicked startet neu

        case .defaultPause(let until):
            if Date() >= until {
                phase = .scrolling
            }

        case .standby(let until):
            if Date() >= until {
                phase = .idle
                setIdle()
            }
        }
    }

    // ── Nachricht starten ──────────────────────────────────────────────────────

    private func startMessage(_ msg: TickerMessage) {
        idleRendered = false
        currentMsg = msg
        let defColor = baseColor()

        switch msg.kind {
        case .scroll:
            let stream = buildScrollStream(text: msg.text, defaultColor: defColor,
                                           onClickCommand: msg.onClickCommand,
                                           customChars: config.customChars)
            guard stream.columns.count > 0 else {
                phase = .idle
                return
            }
            priceFlashes = ScrollFlashes(columns: stream.blinkCols)

            canvas       = wrapCanvas(stream.columns)
            roundLen     = stream.columns.count
            scrollOffset = 0
            prefetchArmed = config.quoteLoop   // 新一轮重新武装预取

            var pauses = stream.pauses.map { PauseMarker(at: $0.at, kind: $0.kind) }
            if config.defaultPause > 0, !pauses.contains(where: { $0.at == 0 }) {
                pauses.insert(PauseMarker(at: 0, kind: .timed(seconds: config.defaultPause)), at: 0)
            }
            pendingPauses = pauses.sorted { $0.at < $1.at }
            phase         = .scrolling
            showScrollFrame()

        case .standby:
            let img = renderStandbyFrame(text: msg.text, displayWidth: displayWidth,
                                         defaultColor: defColor, customChars: config.customChars)
            setImage(img)
            phase = .standby(until: Date().addingTimeInterval(msg.duration))

        case .setWidth, .clearQueue, .getStatus, .quit, .openSettings:
            break
        }
    }

    // ── Pause auslösen ─────────────────────────────────────────────────────────

    private func triggerPause(_ kind: PauseKind) {
        switch kind {
        case .timed(let secs):
            phase = .pauseInStream(until: Date().addingTimeInterval(secs))
        case .sticky(let cmd, let blinks):
            if blinks == 0 {
                phase = .stickyWait(cmd: cmd)
            } else {
                showScrollFrame(blank: true)
                phase = .stickyBlink(phase: 0,
                                      until: Date().addingTimeInterval(blinkDuration),
                                      cmd: cmd, blinks: blinks)
            }
        }
    }

    // ── Darstellung ────────────────────────────────────────────────────────────

    private func showScrollFrame(blank: Bool = false) {
        // 每段进入可读区域后独立闪一次;使用单调时钟,滚动不停、数字不消失。
        let flash = blank ? [:] : priceFlashes.colors(
            offset: scrollOffset, visibleColumns: visCols(displayWidth: displayWidth),
            roundLength: roundLen, now: ProcessInfo.processInfo.systemUptime)
        let img = renderScrollFrame(columns: canvas, offset: scrollOffset,
                                     displayWidth: displayWidth, blank: blank, flash: flash)
        setImage(img)
    }

    /// 无缝环绕画布:把串拼几份,保证任何窗口位置都有内容,
    /// 窗口末端恰好是"串尾接串头",轮与轮之间没有空白垫。
    private func wrapCanvas(_ columns: [ColoredColumn]) -> [ColoredColumn] {
        let vc = visCols(displayWidth: displayWidth)
        let reps = max(2, 1 + Int((Double(vc) / Double(max(1, columns.count))).rounded(.up)))
        return (0..<reps).flatMap { _ in columns }
    }

    private func setImage(_ img: NSImage) {
        if let si = statusItem, config.displayMode.contains("marquee") {
            si.button?.image = img
            si.button?.title = ""
        }
        if let bar = barWindow, bar.isVisible {
            bar.update(img)
        }
    }

    private func setIdle() {
        guard !idleRendered else { return }
        idleRendered = true
        let image = renderIdleIcon(color: currentIdleColor())
        statusItem?.button?.image = image
        barWindow?.update(image)
    }

    // ── Queue ──────────────────────────────────────────────────────────────────

    private func enqueue(_ msg: TickerMessage) {
        queueLock.lock()
        if queue.count >= maxPending { queue.removeFirst() }
        queue.append(msg)
        queueLock.unlock()
    }

    private func prependQueue(_ msg: TickerMessage) {
        queueLock.lock()
        queue.insert(msg, at: 0)
        queueLock.unlock()
    }

    private func dequeueNext() -> TickerMessage? {
        queueLock.lock()
        defer { queueLock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    // ── Quote-Loop ───────────────────────────────────────────────────────────────
    //
    // 一轮滚动结束 → 拉一次行情 → 拼串重新入队。滚动周期 = 行情刷新周期,
    // 天然同步且无闪烁;拉取失败(空回调)则保持 idle,下一 tick 再试。

    private func fetchNextQuoteCycle() {
        guard !cycleInFlight else { return }
        cycleInFlight = true
        let revision = configRevision
        let entries   = config.watchlist
        let redUp     = config.redUpMarkets
        let pause     = config.pausePerSymbol

        quoteService.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self, self.configRevision == revision else { return }
                self.cycleInFlight = false
                guard self.config.quoteLoop, self.config.tickerEnabled, !self.userPaused,
                      !quotes.isEmpty, !entries.isEmpty
                else {
                    // 拉取失败/循环已关:回 idle;循环仍开着则 15s 后重试
                    if self.canvas.isEmpty { self.setIdle() }
                    if self.config.quoteLoop, self.config.tickerEnabled,
                       !self.userPaused, !entries.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                            guard let self, self.config.quoteLoop, self.config.tickerEnabled,
                                  !self.userPaused else { return }
                            self.startTimer()
                        }
                    }
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
                self.enqueue(TickerMessage(kind: .scroll, text: built, priority: .normal,
                                           duration: 0, onClickCommand: nil, width: nil))
                self.startTimer()
            }
        }
    }

    // ── Display-Mode ─────────────────────────────────────────────────────────────
    //
    // 可组合 displayMode(逗号分隔):marquee=状态栏跑马灯,board=程序坞旁报价卡,
    // bar=屏幕下缘置顶跑马灯条(给竖屏/放不下宽 bar 的屏幕)。"both"=旧别名(marquee+board)。
    // bar/board 模式下状态栏图标让位,控制菜单移到各自右键。

    private func applyDisplayMode() {
        configRevision += 1
        cycleInFlight = false
        stopTimer()
        boardTimer?.invalidate(); boardTimer = nil
        renderTransparent = config.transparent
        applyTint()
        displayWidth = config.defaultWidth   // GUI 宽度保存后即时同步(marquee/bar 同宽)
        let m = config.displayMode
        let marqueeOn = m.contains("marquee") || m == "both"
        let boardOn   = m.contains("board")   || m == "both"
        let barOn     = m.contains("bar")

        ensureStatusItem()
        if !marqueeOn { statusItem?.button?.image = renderIdleIcon(color: currentIdleColor()) }

        if barOn {
            if barWindow == nil {
                barWindow = BarWindow(config: config)
                barWindow?.menuProvider = { [weak self] in self?.buildBoardMenu() ?? NSMenu() }
            }
            barWindow?.config = config
            if !userPaused { barWindow?.orderFrontRegardless() }
        } else {
            barWindow?.orderOut(nil)
        }

        if boardOn {
            if board == nil {
                board = BoardWindow(config: config)
                board?.menuProvider = { [weak self] in self?.buildBoardMenu() ?? NSMenu() }
            }
            board?.config = config
            if !userPaused { board?.orderFrontRegardless() }
            startBoardTimer()
            refreshBoard()
        } else {
            boardTimer?.invalidate()
            boardTimer = nil
            board?.orderOut(nil)
        }

        // 跑马灯引擎(marquee/bar 共用同一滚动循环):清旧一轮、按新配置立即重拉
        if marqueeOn || barOn {
            clearAllMessages()
        } else {
            stopTimer()
        }
    }

    private func startBoardTimer() {
        guard boardTimer == nil else { return }
        let t = Timer(timeInterval: max(5, config.boardRefresh), repeats: true) { [weak self] _ in
            self?.refreshBoard()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        boardTimer = t
    }

    private func refreshBoard() {
        guard !userPaused, config.tickerEnabled else { return }
        let revision = configRevision
        let entries = config.watchlist
        let redUp   = config.redUpMarkets
        let arrows  = config.changeArrows
        quoteService.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self, self.configRevision == revision, !self.userPaused, !quotes.isEmpty else { return }
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

    private func buildBoardMenu() -> NSMenu { buildMenu() }
}
