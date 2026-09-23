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
    print("PASS: real status item collapses to icon width and restores its independent ticker width")
}
