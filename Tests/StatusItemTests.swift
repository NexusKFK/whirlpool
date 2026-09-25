import AppKit

/// Exercise the real status button, including the AppDelegate/engine size callbacks.
func runStatusItemTests() throws {
    precondition(ProcessInfo.processInfo.environment["WHIRLPOOL_SOCKET"] != nil,
                 "status item tests require a separate socket from the installed app")
    var config = TickerConfig()
    config.provider = "demo"; config.checkUpdates = false; config.smartRefresh = false
    config.displayMode = "marquee"; config.menuWidthPoints = 1200; config.marqueeFont = "system"
    try writeConfig(config, to: configURL)
    let delegate = AppDelegate()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let button = NSApp.windows.compactMap(\.contentView).flatMap(descendants)
        .first { $0.identifier?.rawValue == "whirlpool-status-button" } as! NSButton
    let surface = button.subviews.compactMap { $0 as? MarqueeView }.first!
    func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(predicate(), "status item did not reach the expected geometry")
    }
    func expectClickableStatusButton() {
        for x in [CGFloat(0.05), 0.5, 0.95] {
            let point = NSPoint(x: button.bounds.width * x, y: button.bounds.midY)
            let target: NSView = surface.isHidden ? button : surface
            precondition(button.hitTest(button.convert(point, to: button.superview)) === target,
                         "mouse events must reach the visible ticker or native restore button")
        }
        if surface.isHidden {
            precondition(button.image?.isTemplate == true && button.image?.isValid == true,
                         "the restore handle must be a real native template image")
            precondition(button.image!.size.width <= button.bounds.width && button.image!.size.height <= button.bounds.height,
                         "the native restore icon must fit without clipping")
        }
    }
    func mouseClick() {
        let local = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let point = button.convert(local, to: nil)
        let target = button.hitTest(button.convert(local, to: button.superview))!
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: button.window!.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // Native buttons consume mouse-up in their tracking loop. A custom view returns
        // immediately, so deliver any remaining release to the hit-tested view.
        NSApp.postEvent(event(.leftMouseUp), atStart: true)
        target.mouseDown(with: event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp,
                                         until: Date(), inMode: .default, dequeue: true) {
            target.mouseUp(with: release)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    waitUntil { surface.art != nil && button.frame.width > 300 }
    expectClickableStatusButton()
    let expandedWidth = button.frame.width
    func popupWidth(language: String) -> CGFloat {
        let previousLanguage = L10n.language
        L10n.language = language
        defer { L10n.language = previousLanguage }
        let tickerWidth = button.frame.width
        var trackingMenu: NSMenu?
        var width: CGFloat?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: nil) { notification in
            trackingMenu = notification.object as? NSMenu
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let menu = trackingMenu else { return }
            width = menu.size.width
            precondition(abs(button.frame.width - tickerWidth) < 1,
                         "opening a menu must not resize the ticker")
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
        }
        let event = NSEvent.mouseEvent(with: .rightMouseUp,
                                      location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: button.window!.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 0)!
        if surface.isHidden { delegate.handleStatusItemClick(event) }
        else { surface.rightMouseUp(with: event) }
        precondition(width != nil, "the native context menu must enter tracking")
        precondition(width! > 100 && width! < 350, "menu width must follow its content, not the wide ticker")
        precondition(abs(button.frame.width - tickerWidth) < 1, "closing a menu must preserve ticker width")
        return width!
    }
    let expandedMenuWidths = ["en", "zh-Hans"].map { popupWidth(language: $0) }
    for _ in 0..<3 {
        mouseClick()
        waitUntil { surface.art == nil && button.frame.width < 80 }
        expectClickableStatusButton()
        surface.viewDidChangeEffectiveAppearance()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(button.frame.width < 80, "appearance refresh must keep the collapsed button compact")
        mouseClick()
        waitUntil { surface.art != nil && abs(button.frame.width - expandedWidth) < 1 }
    }
    mouseClick()
    waitUntil { surface.art == nil && button.frame.width < 80 }
    let collapsedMenuWidths = ["en", "zh-Hans"].map { popupWidth(language: $0) }
    print("PASS: English/Chinese native status menus stay compact (expanded: \(expandedMenuWidths), collapsed: \(collapsedMenuWidths)) without resizing the ticker")
    print("PASS: real status item collapses to icon width and restores its independent ticker width")

    // Use the same actions as the context menu, with the real settings window open.
    func menuAction(_ selector: String, sender: Any? = nil) {
        precondition(NSApp.sendAction(NSSelectorFromString(selector), to: delegate, from: sender))
    }
    func selectMode(_ mode: String) {
        let item = NSMenuItem(); item.representedObject = mode
        menuAction("setDisplayMode:", sender: item)
    }
    menuAction("openConfigWindow")
    let settings = NSApp.windows.first { $0.isVisible && $0.delegate is ConfigWindowController }!
    defer { settings.close() }
    func control<T: NSView>(_ id: String, as type: T.Type) -> T {
        guard let result = descendants(settings.contentView!).first(where: { $0.identifier?.rawValue == id }) as? T
        else { fatalError("Missing settings control: \(id)") }
        return result
    }
    func click(_ id: String) { control(id, as: NSButton.self).performClick(nil) }
    func expectMode(_ mode: String) {
        let keys = ["marquee", "bar", "board"]
        let selected = keys.map { mode.split(separator: ",").contains(Substring($0)) }
        for (key, on) in zip(keys, selected) {
            precondition((control("surface-" + key, as: NSButton.self).state == .on) == on,
                         "open settings must reflect context-menu display changes")
        }
        let preview = control("layout-preview", as: LayoutPreviewView.self)
        precondition([preview.menuOn, preview.barOn, preview.boardOn] == selected,
                     "the preview must follow the live display mode")
        precondition(control("menu-controls", as: NSView.self).isHidden == !selected[0])
        precondition(control("floating-controls", as: NSView.self).isHidden == !selected[1])
    }
    let width = control("menu-width", as: NSSlider.self)
    width.doubleValue = 280; _ = width.sendAction(width.action, to: width.target)
    click("settings-page-appearance")
    let mono = control("choice-font-mono", as: NSButton.self)
    mono.performClick(nil)
    click("settings-page-layout")
    for mode in TickerConfig.displayModes.map(\.key) {
        selectMode(mode)
        expectMode(mode)
        precondition(width.doubleValue == 280 && mono.state == .on,
                     "live mode changes must preserve unrelated unsaved settings")
    }
    click("settings-save")
    let saved = try readConfig(at: configURL)
    precondition(saved.displayMode == "marquee,bar,board" && saved.menuWidthPoints == 280 && saved.marqueeFont == "mono",
                 "saving other edits must not restore the display mode from when settings opened")

    menuAction("openConfigWindow")
    click("surface-marquee")
    menuAction("openConfigWindow")
    expectMode("bar,board")
    click("settings-save")
    let edited = try readConfig(at: configURL)
    precondition(edited.displayMode == "bar,board", "later GUI mode edits must still save")

    menuAction("openConfigWindow")
    click("surface-marquee")
    selectMode("board")
    expectMode("board")
    click("settings-cancel")
    let cancelled = try readConfig(at: configURL)
    precondition(cancelled.displayMode == "board", "Cancel must retain a mode applied from the menu")
    selectMode("bar")
    menuAction("openConfigWindow")
    expectMode("bar")
    DispatchQueue.global().async {
        precondition(cliTrySend(TickerMessage(kind: .setMode, text: "both", priority: .normal,
                                             duration: 0, onClickCommand: nil, width: nil)))
    }
    waitUntil { control("surface-marquee", as: NSButton.self).state == .on }
    expectMode("marquee,board")
    click("settings-cancel")
    print("PASS: menu/CLI modes sync open/reopened settings, previews and controls while preserving drafts, Save and Cancel")

    // Every display combination must leave a clickable menu-bar handle when collapsed.
    selectMode("marquee,bar,board")
    mouseClick()
    waitUntil { surface.art != nil }
    let floating = NSApp.windows.first { $0 is BarWindow && $0.isVisible } as! BarWindow
    let board = NSApp.windows.first { $0 is BoardWindow && $0.isVisible } as! BoardWindow
    for mode in TickerConfig.displayModes.map(\.key) {
        selectMode(mode)
        let keys = mode.split(separator: ",")
        waitUntil { !keys.contains("marquee") || surface.art != nil }
        expectClickableStatusButton()
        mouseClick()
        waitUntil { !floating.isVisible && !board.isVisible && button.frame.width < 80 }
        expectClickableStatusButton()
        precondition(button.image != nil, "collapse must retain a native restore icon even without the menu ticker")
        mouseClick()
        waitUntil { floating.isVisible == keys.contains("bar") && board.isVisible == keys.contains("board")
            && (!keys.contains("marquee") || surface.art != nil)
            && (!keys.contains("bar") || floating.surface.art != nil) }
        expectClickableStatusButton()
    }
    print("PASS: full mouse down/up dispatch and native restore icons work across all 7 display modes")
}
