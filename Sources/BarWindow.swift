import AppKit

// 浮动行情条(bar):置顶浮层,默认贴屏幕下缘,承载一个 GPU 跑马灯显示面。
// 背板可选毛玻璃胶囊(随系统亮/暗切换,亮色桌面上文字不再隐形)或全透明。
// 为竖屏/放不下宽 bar 的屏幕准备:拖到哪块屏就常驻哪块屏。
// 左键整条拖动(位置落配置),右键弹菜单(与状态栏菜单同源),悬停暂停滚动。
final class BarWindow: NSPanel, NSWindowDelegate {

    let surface = MarqueeView(frame: .zero)
    private let root = BarRootView()
    private var backdrop: NSView?
    private var programmaticMove = false
    private var saveWork: DispatchWorkItem?

    /// 胶囊内边距:左右留出圆角,上下让字不贴边
    private var padH: CGFloat { config.barBackground == "glass" ? 10 : 0 }
    private var padV: CGFloat { config.barBackground == "glass" ? 5 : 3 }

    var config: TickerConfig {
        didSet {
            if oldValue.barOrigin != config.barOrigin { saveWork?.cancel() }
            if oldValue.barBackground != config.barBackground { installBackdrop() }
            applyLock()
            if oldValue.barOrigin != config.barOrigin || oldValue.displayScreen != config.displayScreen { reposition() }
        }
    }
    var onOriginChange: (([Double]) -> Void)?
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
        installBackdrop()
        applyLock()
        reposition()
    }

    /// 锁定:不能拖;点击穿透:整条不接鼠标,点击直接落到下面的窗口
    private func applyLock() {
        root.locked = config.lockPosition
        ignoresMouseEvents = config.barClickThrough
    }

    private func installBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        surface.removeFromSuperview()
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
        layoutContent()
    }

    /// 显示面内容尺寸变了(换轮/换字号/改宽度):窗口跟着变,底缘与水平中心不动
    func fitContent() {
        let w = surface.contentWidth, h = surface.contentHeight
        guard w > 0, h > 0 else { return }
        let target = NSSize(width: ceil(w + padH * 2), height: max(ceil(h + padV * 2), 24))
        if abs(target.width - frame.width) > 0.5 || abs(target.height - frame.height) > 0.5 {
            let cx = frame.midX
            programmaticMove = true
            setFrame(keptOnScreen(NSRect(x: (cx - target.width / 2).rounded(), y: frame.origin.y,
                                         width: target.width, height: target.height)), display: true)
            programmaticMove = false
        }
        layoutContent()
    }

    /// 变宽后保持水平中心,但不许伸出所在屏(靠边放置时会被推回屏内)
    private func keptOnScreen(_ rect: NSRect) -> NSRect {
        guard let area = (screen ?? placementScreen(config.displayScreen))?.frame else { return rect }
        var r = rect
        let margin: CGFloat = 8
        r.origin.x = min(max(r.origin.x, area.minX + margin), max(area.minX + margin, area.maxX - r.width - margin))
        return r
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
        if let origin = reachableOrigin(config.barOrigin, size: frame.size) {
            programmaticMove = true
            setFrameOrigin(origin)
            programmaticMove = false
            return
        }
        guard let screen = placementScreen(config.displayScreen) else { return }
        let f = screen.frame
        programmaticMove = true
        setFrameOrigin(NSPoint(x: (f.midX - frame.width / 2).rounded(), y: f.minY + 10))
        programmaticMove = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        config.barOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if let origin = config.barOrigin { onOriginChange?(origin) }
        // 拖动过程中会连发;停手 0.5 秒后再落盘一次
        saveWork?.cancel()
        let origin = config.barOrigin
        let work = DispatchWorkItem {
            if configReadError == nil, var current = try? readConfig(at: configURL) {
                current.barOrigin = origin
                saveConfig(current)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// 浮动条根视图:吃下全部鼠标事件——左键拖窗、右键菜单、悬停暂停
private final class BarRootView: NSView {
    var menuProvider: (() -> NSMenu)?
    var onHover: ((Bool) -> Void)?
    var onOptionClick: (() -> Void)?
    var locked = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override var mouseDownCanMoveWindow: Bool { !locked }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { onOptionClick?(); return }   // ⌥+单击切自选池
        if !locked { window?.performDrag(with: event) }
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
