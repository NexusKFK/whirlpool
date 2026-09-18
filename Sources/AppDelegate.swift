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
    private var quoteProvider: QuoteProvider = DemoProvider()
    private var cycleInFlight = false
    private var board: BoardWindow?
    private var boardTimer: Timer?

    // Zustand
    private var displayWidth: Int = 20
    private var tintColor: LEDColor?   // im Menü gewählte Grundfarbe, nil = Menüleiste
    private var phase: Phase = .idle
    private var userPaused = false
    private var idleRendered = false

    // Aktuelle Scroll-Animation
    private var canvas:      [ColoredColumn] = []
    private var scrollOffset = 0
    private var pendingPauses: [PauseMarker] = []   // noch nicht getriggert
    private var currentMsg:  TickerMessage?          // für very-urgent Replay

    // Queue
    private var queue:     [TickerMessage] = []
    private let queueLock = NSLock()
    private var interrupted: TickerMessage? = nil    // sehr-dringend unterbrochene Msg

    // ── Setup ──────────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        config           = loadConfig()
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

        quoteProvider = QuoteEngine.provider(for: config.provider)
        applyDisplayMode()
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp])
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
        } else {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Ticker-Steuerung (nur wenn aktiv)
        if config.tickerEnabled {
            let ci = NSMenuItem(title: "Clear queue", action: #selector(clearQueue), keyEquivalent: "")
            ci.target = self
            menu.addItem(ci)
            menu.addItem(.separator())
            let pi = NSMenuItem(title: userPaused ? "Resume" : "Pause",
                                action: #selector(togglePause), keyEquivalent: "")
            pi.target = self
            pauseItem = pi
            menu.addItem(pi)
            menu.addItem(.separator())
        }

        // Farbe (nur im Transparentmodus — opak gilt defaultColor aus der Config)
        if config.transparent {
            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colorItem.submenu = buildColorMenu()
            menu.addItem(colorItem)
            menu.addItem(.separator())
        }

        // Ticker-Toggle
        let tickerItem = NSMenuItem(title: "Ticker", action: #selector(toggleTickerEnabled),
                                    keyEquivalent: "")
        tickerItem.target = self
        tickerItem.state  = config.tickerEnabled ? .on : .off
        menu.addItem(tickerItem)

        let loopItem = NSMenuItem(title: "Quote loop", action: #selector(toggleQuoteLoop),
                                  keyEquivalent: "")
        loopItem.target = self
        loopItem.state  = config.quoteLoop ? .on : .off
        menu.addItem(loopItem)

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = buildModeMenu()
        menu.addItem(modeItem)

        let editItem = NSMenuItem(title: "Edit config…", action: #selector(editConfigFile),
                                  keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
        menu.addItem(.separator())

        let qi = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        qi.target = self
        menu.addItem(qi)

        return menu
    }

    private func buildColorMenu() -> NSMenu {
        let menu    = NSMenu()
        let current = config.transparentColor.lowercased()
        // Nur die gängigen Grundfarben — \c[red] und \c[yellow] bleiben im Text
        // natürlich weiter möglich, sie brauchen nur keinen Menüeintrag.
        let entries = [("Adaptive (no colors)", "auto"),
                       ("Amber", "amber"),
                       ("Green", "green"),
                       ("White", "white"),
                       ("Black", "black")]
        for (title, key) in entries {
            let item = NSMenuItem(title: title, action: #selector(setTintColor(_:)), keyEquivalent: "")
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
            let vc  = visCols(displayWidth: displayWidth)
            let pad = [ColoredColumn](repeating: ColoredColumn(value: 0, color: baseColor()), count: vc)
            let rebuilt = pad + stream.columns + pad
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
        setIdle()
        stopTimer()
    }

    @objc private func togglePause() {
        userPaused = !userPaused
        pauseItem?.title = userPaused ? "Resume" : "Pause"
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments     = ["-t", configPath()]
        try? proc.run()
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
        case .getStatus, .quit:
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
            let vc = visCols(displayWidth: displayWidth)

            if let p = pendingPauses.first, p.at == scrollOffset {
                pendingPauses.removeFirst()
                triggerPause(p.kind)
                return
            }

            // Ende erst nach dem Pause-Check prüfen, sonst geht ein Marker
            // am Nachrichtenende verloren
            if canvas.count <= vc || scrollOffset >= canvas.count - vc {
                phase = .idle
                // 行情循环:保留最后一帧直接拉下一轮,避免每轮之间闪 idle 图标
                if config.quoteLoop, config.tickerEnabled, !userPaused, !cycleInFlight {
                    fetchNextQuoteCycle()
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
            let stream   = buildScrollStream(text: msg.text, defaultColor: defColor,
                                              onClickCommand: msg.onClickCommand,
                                              customChars: config.customChars)
            let vc       = visCols(displayWidth: displayWidth)
            let pad      = [ColoredColumn](repeating: ColoredColumn(value: 0, color: defColor), count: vc)
            canvas       = pad + stream.columns + pad
            scrollOffset = 0

            var pauses   = stream.pauses.map { PauseMarker(at: $0.at + vc, kind: $0.kind) }
            let hasEarlyPause = pauses.contains { $0.at == vc }
            if !hasEarlyPause {
                pauses.insert(PauseMarker(at: vc, kind: .timed(seconds: config.defaultPause)), at: 0)
            }
            pendingPauses = pauses.sorted { $0.at < $1.at }
            phase         = .scrolling
            showScrollFrame()

        case .standby:
            let img = renderStandbyFrame(text: msg.text, displayWidth: displayWidth,
                                         defaultColor: defColor, customChars: config.customChars)
            setImage(img)
            phase = .standby(until: Date().addingTimeInterval(msg.duration))

        case .setWidth, .clearQueue, .getStatus, .quit:
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
        let img = renderScrollFrame(columns: canvas, offset: scrollOffset,
                                     displayWidth: displayWidth, blank: blank)
        setImage(img)
    }

    private func setImage(_ img: NSImage) {
        statusItem?.button?.image = img
        statusItem?.button?.title = ""
    }

    private func setIdle() {
        guard !idleRendered else { return }
        idleRendered = true
        setImage(renderIdleIcon(color: currentIdleColor()))
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
        cycleInFlight = true
        let entries   = config.watchlist
        let redUp     = config.redUpMarkets
        let pause     = config.pausePerSymbol

        quoteProvider.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cycleInFlight = false
                guard self.config.quoteLoop, self.config.tickerEnabled, !self.userPaused,
                      !quotes.isEmpty, !entries.isEmpty
                else {
                    // 拉取失败/循环已关:回 idle;循环仍开着则 15s 后重试
                    self.setIdle()
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
                let text = QuoteEngine.marqueeText(entries: entries, quotes: quotes,
                                                   redUpMarkets: redUp, pausePerSymbol: pause)
                self.enqueue(TickerMessage(kind: .scroll, text: text, priority: .normal,
                                           duration: 0, onClickCommand: nil, width: nil))
                self.startTimer()
            }
        }
    }

    // ── Display-Mode ─────────────────────────────────────────────────────────────
    //
    // marquee = 跑马灯(状态栏);board = 报价卡(程序坞旁);both = 两个都要。
    // board 模式下状态栏图标整个让位,控制菜单移到报价卡右键。

    private func applyDisplayMode() {
        let m = config.displayMode

        if m == "marquee" || m == "both" {
            ensureStatusItem()
            if config.quoteLoop { fetchNextQuoteCycle() }
        } else if let si = statusItem {
            NSStatusBar.system.removeStatusItem(si)
            statusItem = nil
            stopTimer()
        }

        if m == "board" || m == "both" {
            if board == nil {
                board = BoardWindow(config: config)
                board?.menuProvider = { [weak self] in self?.buildBoardMenu() ?? NSMenu() }
            }
            board?.config = config
            board?.orderFrontRegardless()
            startBoardTimer()
            refreshBoard()
        } else {
            boardTimer?.invalidate()
            boardTimer = nil
            board?.orderOut(nil)
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
        let entries = config.watchlist
        let redUp   = config.redUpMarkets
        quoteProvider.quotes(for: entries) { [weak self] quotes in
            DispatchQueue.main.async {
                guard let self, !quotes.isEmpty else { return }
                self.board?.update(entries: entries, quotes: quotes,
                                   redUpMarkets: redUp, at: Date())
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
        for (title, key) in [("Marquee", "marquee"), ("Board", "board"), ("Both", "both")] {
            let i = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = (config.displayMode == key) ? .on : .off
            menu.addItem(i)
        }
        return menu
    }

    private func buildBoardMenu() -> NSMenu {
        let menu = NSMenu()
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = buildModeMenu()
        menu.addItem(modeItem)
        menu.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit config…", action: #selector(editConfigFile),
                                  keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
        let qi = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        qi.target = self
        menu.addItem(qi)
        return menu
    }
}
