import AppKit

// 浮动行情条(bar):置顶浮层,默认贴屏幕下缘,承载一个 GPU 跑马灯显示面。
// 背板可选毛玻璃胶囊(随系统亮/暗切换,亮色桌面上文字不再隐形)或全透明。
// 为竖屏/放不下宽 bar 的屏幕准备:拖到哪块屏就常驻哪块屏。
// 左键整条拖动(位置落配置),右键弹菜单(与状态栏菜单同源),悬停暂停滚动。
final class BarWindow: NSPanel, NSWindowDelegate {

    let surface = MarqueeView(frame: .zero)
    private let root = BarRootView()
    private let resizeHandles = BarResizeHandles()
    private var backdrop: NSView?
    private var programmaticMove = false
    private var saveWork: DispatchWorkItem?
    private var dragging = false
    private var dragStartOrigin: NSPoint = .zero
    private var resizing = false
    private var resizeStartWidth: CGFloat = 0
    private var resizeStartPoint: CGFloat = 0
    private var resizeLeftEdge = false
    private var restoreSavedOrigin = true

    /// 胶囊内边距:左右留出圆角,上下让字不贴边
    private var padH: CGFloat { config.barBackground == "glass" ? 10 : 0 }
    private var padV: CGFloat { config.barBackground == "glass" ? 5 : 3 }

    var config: TickerConfig {
        didSet {
            if oldValue.barOrigin != config.barOrigin || oldValue.barPlacement != config.barPlacement || oldValue.barWidthFraction != config.barWidthFraction {
                saveWork?.cancel()
            }
            if oldValue.barBackground != config.barBackground { installBackdrop() }
            applyLock()
            guard !dragging, !resizing else { return }
            if oldValue.barOrigin != config.barOrigin || oldValue.displayScreen != config.displayScreen {
                restoreSavedOrigin = true
            }
            fitContent()
        }
    }
    var onOriginChange: (([Double]) -> Void)?
    var onLayoutChange: ((TickerConfig) -> Void)?
    var onScreenChange: (() -> Void)?
    var menuProvider: (() -> NSMenu)? {
        didSet { root.menuProvider = menuProvider }
    }
    var onHover: ((Bool) -> Void)? {
        didSet { root.onHover = onHover }
    }
    var onOptionClick: (() -> Void)? {
        didSet { root.onOptionClick = onOptionClick }
    }

    init(config: TickerConfig) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 34),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        delegate = self
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = root
        root.onDragStart = { [weak self] in self?.beginDragging() }
        root.onDragEnd = { [weak self] in self?.finishDragging() }
        root.onResizeStart = { [weak self] left, point in self?.beginResizing(leftEdge: left, at: point) }
        root.onResize = { [weak self] point in self?.resize(to: point) }
        root.onResizeEnd = { [weak self] in self?.finishResizing() }
        installBackdrop()
        applyLock()
        fitContent()
    }

    /// 锁定:不能拖;点击穿透:整条不接鼠标,点击直接落到下面的窗口
    private func applyLock() {
        root.locked = config.lockPosition
        ignoresMouseEvents = config.barClickThrough
        resizeHandles.isHidden = config.lockPosition || config.barClickThrough
        invalidateCursorRects(for: root)
    }

    private func installBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        surface.removeFromSuperview()
        resizeHandles.removeFromSuperview()
        hasShadow = false
        if config.barBackground == "glass" {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                backdrop = glass
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.wantsLayer = true
                effect.layer?.masksToBounds = true
                backdrop = effect
            }
            hasShadow = true
        }
        if let backdrop {
            backdrop.frame = root.bounds
            backdrop.autoresizingMask = [.width, .height]
            root.addSubview(backdrop)
        }
        root.addSubview(surface)
        resizeHandles.frame = root.bounds
        resizeHandles.autoresizingMask = [.width, .height]
        root.addSubview(resizeHandles)
        layoutContent()
    }

    /// Width is a property of the surface, independent from its font or current idle/scrolling artwork.
    var layoutScreen: NSScreen? {
        if config.barPlacement != "free" { return placementScreen(config.displayScreen) }
        if restoreSavedOrigin {
            if let saved = config.barOrigin, saved.count == 2 {
                let savedRect = NSRect(x: saved[0], y: saved[1], width: frame.width, height: frame.height)
                if let match = NSScreen.screens.max(by: { $0.visibleFrame.intersection(savedRect).size.area < $1.visibleFrame.intersection(savedRect).size.area }),
                   match.visibleFrame.intersects(savedRect) { return match }
            }
            return placementScreen(config.displayScreen)
        }
        return screen ?? placementScreen(config.displayScreen)
    }

    var desiredOuterWidth: CGFloat {
        let area = layoutScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let legacy = CGFloat(config.defaultWidth * 18) + (config.marqueeFont == "led" ? 8 : 0) + padH * 2
        return floatingTickerWidth(fraction: config.barWidthFraction, legacyWidth: legacy, inside: area)
    }

    var desiredContentWidth: CGFloat { max(1, desiredOuterWidth - padH * 2) }

    func fitContent() {
        guard !dragging else { return }
        let h = surface.contentHeight > 0 ? surface.contentHeight : CGFloat(LEDLayout(dot: config.ledDotSize).imgHTransparent)
        let target = NSSize(width: desiredOuterWidth, height: max(ceil(h + padV * 2), 24))
        guard let area = layoutScreen?.visibleFrame else { return }
        let desired: NSRect
        if config.barPlacement != "free" {
            desired = anchoredTickerFrame(size: target, placement: config.barPlacement, inside: area)
        } else if restoreSavedOrigin, let origin = reachableOrigin(config.barOrigin, size: target) {
            desired = constrainedFrame(NSRect(origin: origin, size: target), inside: area, margin: 12)
        } else if restoreSavedOrigin {
            desired = anchoredTickerFrame(size: target, placement: "bottom-center", inside: area)
        } else {
            desired = constrainedFrame(NSRect(x: (frame.midX - target.width / 2).rounded(), y: frame.minY,
                                             width: target.width, height: target.height), inside: area, margin: 12)
        }
        restoreSavedOrigin = false
        if desired != frame {
            programmaticMove = true
            setFrame(desired, display: true)
            programmaticMove = false
            if config.barPlacement == "free", config.barOrigin != [Double(desired.minX), Double(desired.minY)] {
                shareLayout()
            }
        }
        layoutContent()
    }

    private func layoutContent() {
        let b = root.bounds
        surface.frame = NSRect(x: padH, y: 0, width: max(0, b.width - padH * 2), height: b.height)
        let radius = b.height / 2
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            backdrop?.layer?.cornerRadius = radius
        }
    }

    // ── 位置 ─────────────────────────────────────────────────────────────────

    func reposition() {
        restoreSavedOrigin = true
        fitContent()
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove, dragging, frame.origin != dragStartOrigin else { return }
        config.barPlacement = "free"
        shareLayout()
    }

    func beginDragging() {
        guard !config.lockPosition, !config.barClickThrough else { return }
        dragging = true
        dragStartOrigin = frame.origin
        restoreSavedOrigin = false
    }

    func finishDragging() {
        guard dragging else { return }
        let moved = frame.origin != dragStartOrigin
        if moved { config.barPlacement = "free" }
        dragging = false
        guard moved else { return }
        fitContent()
        shareLayout()
        onScreenChange?()
    }

    func beginResizing(leftEdge: Bool, at point: CGFloat) {
        guard !config.lockPosition, !config.barClickThrough else { return }
        resizing = true
        restoreSavedOrigin = false
        resizeStartWidth = frame.width
        resizeStartPoint = point
        resizeLeftEdge = leftEdge
    }

    func resize(to point: CGFloat) {
        guard resizing, !config.lockPosition, !config.barClickThrough, let area = layoutScreen?.visibleFrame else { return }
        let width = resizedTickerWidth(startWidth: resizeStartWidth, delta: point - resizeStartPoint,
                                       leftEdge: resizeLeftEdge, placement: config.barPlacement)
        config.barWidthFraction = min(1, max(0.20, Double(width / max(1, area.width - 24))))
        fitContent()
        shareLayout()
    }

    func finishResizing() {
        guard resizing else { return }
        resizing = false
        shareLayout()
    }

    private func shareLayout() {
        config.barOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if let origin = config.barOrigin { onOriginChange?(origin) }
        onLayoutChange?(config)
        // 拖动过程中会连发;停手 0.5 秒后再落盘一次
        saveWork?.cancel()
        let origin = config.barOrigin
        let placement = config.barPlacement
        let fraction = config.barWidthFraction
        let work = DispatchWorkItem {
            if configReadError == nil, var current = try? readConfig(at: configURL) {
                current.barOrigin = origin
                current.barPlacement = placement
                current.barWidthFraction = fraction
                saveConfig(current)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !dragging else { return }
        onScreenChange?()
    }
}

private extension NSSize { var area: CGFloat { max(0, width) * max(0, height) } }

private final class BarResizeHandles: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        for x in [CGFloat(4), bounds.width - 6] {
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - 4, width: 2, height: 8), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// 浮动条根视图:吃下全部鼠标事件——左键拖窗、右键菜单、悬停暂停
private final class BarRootView: NSView {
    var menuProvider: (() -> NSMenu)?
    var onHover: ((Bool) -> Void)?
    var onOptionClick: (() -> Void)?
    var locked = false
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onResizeStart: ((Bool, CGFloat) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    private var resizing = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() {
        guard !locked else { return }
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(NSRect(x: 0, y: 0, width: 12, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: max(0, bounds.width - 12), y: 0, width: 12, height: bounds.height), cursor: .resizeLeftRight)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { onOptionClick?(); return }   // ⌥+单击切自选池
        guard !locked else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.x < 12 || p.x > bounds.width - 12 {
            resizing = true
            onResizeStart?(p.x < 12, NSEvent.mouseLocation.x)
        } else {
            onDragStart?()
            window?.performDrag(with: event)
            onDragEnd?()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if resizing { onResize?(NSEvent.mouseLocation.x) }
    }
    override func mouseUp(with event: NSEvent) {
        if resizing { resizing = false; onResizeEnd?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
