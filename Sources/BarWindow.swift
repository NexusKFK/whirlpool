import AppKit

// 底部跑马灯条(bar):置顶浮层,贴屏幕下缘,渲染同一套 LED 点阵帧。
// 为竖屏/放不下宽 bar 的屏幕准备:拖到哪块屏就常驻哪块屏。
// 左键整条拖动(位置落配置),右键弹菜单(与状态栏菜单同源)。
final class BarWindow: NSPanel, NSWindowDelegate {

    let imageView = NSImageView()
    private var programmaticMove = false

    var config: TickerConfig {
        didSet { reposition() }
    }
    var menuProvider: (() -> NSMenu)?

    init(config: TickerConfig) {
        self.config = config
        let w = CGFloat(config.defaultWidth * colsPerChar * colW + paddingH * 2)
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: 34),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        delegate = self
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        contentView = imageView

        reposition()
    }

    /// 每帧渲染回调;--width 改宽后随图调整,保持水平中心;
    /// 字号切换后高度也要跟(可收缩),底缘固定不动
    func update(_ img: NSImage) {
        imageView.image = img
        let targetH = max(34, img.size.height + 6)
        if abs(img.size.width - frame.width) > 1 || abs(targetH - frame.height) > 1 {
            let cx = frame.midX
            setFrame(NSRect(x: cx - img.size.width / 2, y: frame.origin.y,
                            width: img.size.width,
                            height: targetH),
                     display: true)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // ── 位置 ─────────────────────────────────────────────────────────────────

    private func reposition() {
        if let origin = reachableOrigin(config.barOrigin, size: frame.size) {
            programmaticMove = true
            setFrameOrigin(origin)
            programmaticMove = false
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.frame
        programmaticMove = true
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 10))
        programmaticMove = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        config.barOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if configReadError == nil, var current = try? readConfig(at: configURL) {
            current.barOrigin = config.barOrigin
            saveConfig(current)
        }
    }
}
