import AppKit

func runSettingsUITests() throws {
    _ = NSApplication.shared
    let originalLanguage = L10n.language
    defer { L10n.language = originalLanguage }
    L10n.language = "en"
    var fixture = TickerConfig(); fixture.provider = "demo"; fixture.language = "en"
    fixture.displayMode = "marquee,bar,board"
    try writeConfig(fixture, to: configURL)
    let originalFile = try Data(contentsOf: configURL)
    func open(_ config: TickerConfig) -> (ConfigWindowController, NSWindow) {
        let controller = ConfigWindowController(config: config); controller.show()
        let window = NSApp.windows.first { ($0.delegate as AnyObject?) === controller }!
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, window)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func control<T: NSView>(_ id: String, _ window: NSWindow, as type: T.Type) -> T {
        guard let result = descendants(window.contentView!).first(where: { $0.identifier?.rawValue == id }) as? T else { fatalError("Missing settings control: \(id)") }
        return result
    }
    func click(_ id: String, _ window: NSWindow) { control(id, window, as: NSButton.self).performClick(nil) }
    func setWidth(_ id: String, _ value: Double, _ window: NSWindow) {
        let slider = control(id, window, as: NSSlider.self)
        slider.doubleValue = value; _ = slider.sendAction(slider.action, to: slider.target)
    }
    let (cancelled, cancelWindow) = open(fixture)
    var applied = false; cancelled.onApplied = { _ in applied = true }
    click("placement-top-right", cancelWindow); setWidth("floating-width", 85, cancelWindow)
    click("settings-cancel", cancelWindow)
    let cancelledFile = try Data(contentsOf: configURL)
    precondition(!applied && cancelledFile == originalFile, "preview edits and Cancel must not write settings")

    let (preserved, preserveWindow) = open(fixture)
    var live = fixture; live.barPlacement = "free"; live.barOrigin = [250, 180]; live.barWidthFraction = 0.72
    preserved.currentConfig = { live }; preserved.syncLayout(from: live)
    var saved: TickerConfig?
    preserved.onApplied = { saved = $0 }
    setWidth("menu-width", 280, preserveWindow)
    click("settings-save", preserveWindow)
    precondition(saved?.barPlacement == "free" && saved?.barOrigin == [250, 180] && saved?.barWidthFraction == 0.72,
                 "unrelated settings preserve a live drag and resize")
    precondition(saved?.menuWidthPoints == 280, "menu width saves independently")

    let (explicit, explicitWindow) = open(fixture)
    explicit.currentConfig = { live }; explicit.onApplied = { saved = $0 }
    click("placement-bottom-right", explicitWindow)
    explicit.syncLayout(from: live)
    setWidth("floating-width", 50, explicitWindow)
    click("settings-save", explicitWindow)
    precondition(saved?.barPlacement == "bottom-right" && saved?.barOrigin == nil && saved?.barWidthFraction == 0.5,
                 "explicit draft placement wins over later live coordinates")
    precondition(saved?.displayMode == "marquee,bar,board", "all display regions can be enabled together")

    let area = placementScreen("auto")!.visibleFrame
    var free = fixture; free.barPlacement = "free"; free.barWidthFraction = 0.4
    let startWidth = floatingTickerWidth(fraction: 0.4, legacyWidth: 0, inside: area)
    free.barOrigin = [area.midX - startWidth / 2, area.midY]
    let (resized, resizeWindow) = open(free)
    resized.onApplied = { saved = $0 }
    setWidth("floating-width", 60, resizeWindow)
    click("settings-save", resizeWindow)
    let endWidth = floatingTickerWidth(fraction: saved?.barWidthFraction, legacyWidth: 0, inside: area)
    precondition(abs(saved!.barOrigin![0] + endWidth / 2 - area.midX) < 1,
                 "changing a free-position width in settings preserves its center")

    var legacy = fixture; legacy.defaultWidth = 8; legacy.barWidthFraction = nil; legacy.menuWidthPoints = 950
    let (migrated, migrateWindow) = open(legacy)
    let legacyWidth = floatingTickerWidth(fraction: nil, legacyWidth: 8 * 18 + 28, inside: area)
    precondition(abs(control("floating-width", migrateWindow, as: NSSlider.self).doubleValue / 100 - legacyWidth / (area.width - 24)) < 0.001,
                 "legacy widths below 20 percent are shown without clamping")
    precondition(control("menu-width", migrateWindow, as: NSSlider.self).doubleValue == 950,
                 "existing wide menu items are shown without clamping")
    migrated.onApplied = { saved = $0 }; click("settings-save", migrateWindow)
    precondition(saved?.barWidthFraction == nil && saved?.menuWidthPoints == 950,
                 "saving unrelated controls does not migrate a legacy width")
    print("PASS: graphical settings keep previews local, preserve live layout, and save independent widths/anchors")

    guard let snapshots = ProcessInfo.processInfo.environment["WHIRLPOOL_SETTINGS_SNAPSHOTS"] else { return }
    let directory = URL(fileURLWithPath: snapshots)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for language in ["en", "zh-Hans"] {
        for (tone, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            L10n.language = language; fixture.language = language
            let (controller, window) = open(fixture)
            window.appearance = NSAppearance(named: name)
            window.setContentSize(NSSize(width: 920, height: 740))
            for page in ["layout", "appearance", "general", "watchlist"] {
                click("settings-page-" + page, window)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                let root = window.contentView!
                let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
                let data = rep.representation(using: .png, properties: [:])!
                try data.write(to: directory.appendingPathComponent("\(language)-\(tone)-\(page).png"))
            }
            window.setContentSize(NSSize(width: 780, height: 540)); click("settings-page-layout", window)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let root = window.contentView!, rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(language)-\(tone)-small.png"))
            click("settings-page-watchlist", window)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(language)-\(tone)-small-watchlist.png"))
            withExtendedLifetime(controller) { window.close() }
        }
    }
    print("PASS: native settings rendered in English/Chinese, light/dark, and compact window sizes")
}
