import AppKit

/// Exercise the real status button, including the AppDelegate/engine size callbacks.
func runStatusItemTests() throws {
    precondition(ProcessInfo.processInfo.environment["WHIRLPOOL_SOCKET"] != nil,
                 "status item tests require a separate socket from the installed app")
    var config = TickerConfig()
    config.provider = "demo"; config.checkUpdates = false; config.smartRefresh = false
    config.displayMode = "marquee"; config.menuWidthPoints = 600; config.marqueeFont = "system"
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
    waitUntil { surface.art != nil && button.frame.width > 300 }
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
        delegate.handleStatusItemClick(event)
        precondition(width != nil, "the native context menu must enter tracking")
        precondition(width! > 100 && width! < 350, "menu width must follow its content, not the wide ticker")
        precondition(abs(button.frame.width - tickerWidth) < 1, "closing a menu must preserve ticker width")
        return width!
    }
    let expandedMenuWidths = ["en", "zh-Hans"].map { popupWidth(language: $0) }
    for _ in 0..<3 {
        button.performClick(nil)
        waitUntil { surface.art == nil && button.frame.width < 80 }
        precondition(button.frame.width >= surface.contentWidth, "restore icon must remain fully visible")
        surface.viewDidChangeEffectiveAppearance()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(button.frame.width < 80, "appearance refresh must keep the collapsed button compact")
        button.performClick(nil)
        waitUntil { surface.art != nil && abs(button.frame.width - expandedWidth) < 1 }
    }
    button.performClick(nil)
    waitUntil { surface.art == nil && button.frame.width < 80 }
    let collapsedMenuWidths = ["en", "zh-Hans"].map { popupWidth(language: $0) }
    print("PASS: English/Chinese native status menus stay compact (expanded: \(expandedMenuWidths), collapsed: \(collapsedMenuWidths)) without resizing the ticker")
    print("PASS: real status item collapses to icon width and restores its independent ticker width")
}
