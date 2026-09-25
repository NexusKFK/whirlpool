import AppKit
import QuartzCore

// ── 跑马灯显示面(GPU 合成)────────────────────────────────────────────────────
//
// 菜单栏状态项与浮动条各持一个。一轮行情预渲染成纹理挂在图层上,
// 滚动 = Core Animation 线性平移图层,由系统渲染服务按屏幕刷新率(120Hz)合成;
// app 进程在一轮里只在少数事件点(暂停、换数闪色、预取、轮尾)醒来。
//
// 图层树:
//   root
//   ├─ panel          LED 黑底面板(非透明模式)
//   ├─ viewport       裁剪窗口,两缘渐隐遮罩
//   │   └─ track      CAReplicatorLayer:单份串横向复制 N 份 → 无缝环绕
//   │       └─ strip  单份:底图分片 + 换数闪色叠层(不透明度脉冲)
//   └─ still          idle 图标 / standby 静态帧

final class MarqueeView: NSView {

    var onAppearanceChange: (() -> Void)?
    var onBackingChange: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onClick: ((NSEvent) -> Void)?

    private let panel = CALayer()
    private let viewport = CALayer()
    private let fade = CAGradientLayer()
    private let track = CAReplicatorLayer()
    private let strip = CALayer()
    private let still = CALayer()
    private var flashLayers: [CALayer] = []
    private(set) var art: StripArt?
    private(set) var viewportWidth: CGFloat = 0
    private var stillSize: CGSize = .zero

    /// 显示面当前明暗(菜单栏跟随壁纸/菜单栏外观,浮动条跟随系统外观)
    var tone: Tone { Tone.of(effectiveAppearance) }
    var backingScale: Int { max(1, Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded())) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer ?? CALayer()
        for l in [panel, viewport, still] { root.addSublayer(l) }
        viewport.masksToBounds = true
        viewport.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        viewport.addSublayer(track)
        track.addSublayer(strip)
        track.anchorPoint = .zero
        strip.anchorPoint = .zero
        panel.backgroundColor = CGColor(gray: 0, alpha: 1)
        panel.isHidden = true
        still.anchorPoint = .zero
        still.isHidden = true
        disableImplicitAnimations(root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The custom menu ticker owns its mouse events; floating windows keep their drag/menu host.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, !isHidden else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { clickInside(event) }
    override func rightMouseUp(with event: NSEvent) { clickInside(event) }
    private func clickInside(_ event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingChange?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func layout() {
        super.layout()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    /// 宿主据此设置状态项长度 / 浮动条宽度
    var contentWidth: CGFloat {
        if !still.isHidden { return stillSize.width }
        guard let art else { return 0 }
        return viewportWidth + art.inset * 2
    }
    var contentHeight: CGFloat {
        if !still.isHidden { return stillSize.height }
        return art?.height ?? 0
    }

    // ── 装载 ────────────────────────────────────────────────────────────────

    /// 换一轮(或同轮换色/换倍率):装纹理,停在 col
    func load(_ art: StripArt, viewportWidth: CGFloat, atCol col: Double) {
        self.art = art
        self.viewportWidth = max(1, viewportWidth)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.sublayers?.forEach { $0.removeFromSuperlayer() }
        flashLayers = []
        let scale = CGFloat(backingScale)
        let filter: CALayerContentsFilter = art.nearest ? .nearest : .linear
        for tile in art.tiles {
            let l = CALayer()
            l.anchorPoint = .zero
            l.frame = CGRect(x: tile.x, y: 0, width: tile.width, height: art.height)
            l.contents = tile.image
            l.contentsScale = scale
            l.magnificationFilter = filter
            l.minificationFilter = filter
            strip.addSublayer(l)
        }
        for flash in art.flashes {
            let l = CALayer()
            l.anchorPoint = .zero
            l.frame = CGRect(x: flash.tile.x, y: 0, width: flash.tile.width, height: art.height)
            l.contents = flash.tile.image
            l.contentsScale = scale
            l.magnificationFilter = filter
            l.minificationFilter = filter
            l.opacity = 0
            strip.addSublayer(l)
            flashLayers.append(l)
        }
        strip.frame = CGRect(x: 0, y: 0, width: art.width, height: art.height)
        // 任意位置 [0, W] 都要铺满视口:第 k 份覆盖 [kW, (k+1)W)
        track.instanceCount = 2 + Int(self.viewportWidth / max(1, art.width))
        track.instanceTransform = CATransform3DMakeTranslation(art.width, 0, 0)
        track.frame = CGRect(x: 0, y: 0, width: art.width, height: art.height)
        track.removeAllAnimations()
        track.position = CGPoint(x: -CGFloat(col) * art.pitch, y: 0)
        track.isHidden = false
        still.isHidden = true
        viewport.isHidden = false
        panel.isHidden = !art.panel
        relayout()
        CATransaction.commit()
    }

    /// 静态图(idle 图标 / standby 帧);nil = 清空
    func showStill(_ image: NSImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.removeAllAnimations()
        viewport.isHidden = true
        panel.isHidden = true
        if let image {
            still.contents = image.cgImageForLayer(scale: CGFloat(backingScale))
            still.contentsScale = CGFloat(backingScale)
            stillSize = image.size
            still.isHidden = false
        } else {
            still.contents = nil
            stillSize = .zero
            still.isHidden = false
        }
        art = nil
        relayout()
        CATransaction.commit()
    }

    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = bounds.height
        if let art {
            let y = ((h - art.height) / 2).rounded(.down)
            panel.frame = CGRect(x: 0, y: y, width: viewportWidth + art.inset * 2, height: art.height)
            viewport.frame = CGRect(x: art.inset, y: y, width: viewportWidth, height: art.height)
            fade.frame = viewport.bounds
            let f = min(0.45, art.fadeWidth / max(1, viewportWidth))
            fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1),
                           CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
            fade.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        }
        still.frame = CGRect(x: 0, y: ((h - stillSize.height) / 2).rounded(.down),
                             width: stillSize.width, height: stillSize.height)
        CATransaction.commit()
    }

    // ── 运动 ────────────────────────────────────────────────────────────────

    /// 从 fromCol 线性滚到 toCol;渲染服务按刷新率插值,app 不参与每帧。
    /// beginTime 与引擎计时同一原点(CACurrentMediaTime),图层与事件定时器严格对齐。
    func animate(fromCol: Double, toCol: Double, duration: CFTimeInterval,
                 beginTime: CFTimeInterval = CACurrentMediaTime()) {
        guard let art else { return }
        let from = -CGFloat(fromCol) * art.pitch, to = -CGFloat(toCol) * art.pitch
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.removeAnimation(forKey: "scroll")
        track.position = CGPoint(x: to, y: 0)
        if duration > 0, from != to {
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.beginTime = track.convertTime(beginTime, from: nil)
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            track.add(a, forKey: "scroll")
        }
        CATransaction.commit()
    }

    /// 图层实际所在列(Core Animation 表现层),诊断用
    var presentationCol: Double? {
        guard let art, !viewport.isHidden else { return nil }
        let x = track.presentation()?.position.x ?? track.position.x
        return Double(-x / art.pitch)
    }

    /// 停在 col(悬停暂停、轮内暂停、换色重建)
    func hold(atCol col: Double) {
        guard let art else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.removeAnimation(forKey: "scroll")
        track.position = CGPoint(x: -CGFloat(col) * art.pitch, y: 0)
        CATransaction.commit()
    }

    /// 换数闪色:叠层瞬间点亮、保持、末段快速收回——数字全程可见,不插空帧
    func pulse(flash index: Int, duration: CFTimeInterval) {
        guard flashLayers.indices.contains(index) else { return }
        let layer = flashLayers[index]
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, 0]
        a.keyTimes = [0, 0.75, 1]
        a.duration = duration
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(a, forKey: "pulse")
    }

    /// sticky 闪烁:整条隐/显
    func setBlank(_ blank: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.isHidden = blank
        CATransaction.commit()
    }

    private func disableImplicitAnimations(_ root: CALayer) {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                                        "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull(),
                                        "sublayers": NSNull(), "instanceCount": NSNull(),
                                        "instanceTransform": NSNull(), "locations": NSNull()]
        for l in [root, panel, viewport, fade, track, strip, still] { l.actions = none }
    }
}
