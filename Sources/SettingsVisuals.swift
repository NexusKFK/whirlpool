import AppKit

/// Native vector controls: no web view or raster assets, and the system palette follows appearance.
final class SettingsChoiceButton: NSButton {
    enum Artwork { case text, surface, anchor, font, background, color }
    var artwork: Artwork = .text
    var key = ""
    var subtitle = ""
    var onChoose: (() -> Void)?

    init(_ title: String, key: String = "", artwork: Artwork = .text) {
        super.init(frame: .zero)
        self.title = title; self.key = key; self.artwork = artwork
        setButtonType(.momentaryChange); isBordered = false
        target = self; action = #selector(choose)
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }
    @objc private func choose() { onChoose?() }
    override var intrinsicContentSize: NSSize { NSSize(width: 100, height: artwork == .surface ? 78 : artwork == .anchor ? 32 : 48) }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let card = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).setFill(); card.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); card.lineWidth = selected ? 1.5 : 0.8; card.stroke()
        let ink = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let accent = isEnabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor
        func label(_ string: String, _ at: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
            let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
            (string as NSString).draw(in: at, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        }
        switch artwork {
        case .surface:
            let screen = NSRect(x: 13, y: bounds.height - 43, width: 53, height: 31)
            NSColor.secondaryLabelColor.setStroke(); NSBezierPath(roundedRect: screen, xRadius: 4, yRadius: 4).stroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: screen.minX, y: screen.maxY - 7)); line.line(to: NSPoint(x: screen.maxX, y: screen.maxY - 7)); line.stroke()
            let mark: NSRect
            switch key {
            case "marquee": mark = NSRect(x: screen.maxX - 23, y: screen.maxY - 5, width: 19, height: 3)
            case "board": mark = NSRect(x: screen.maxX - 20, y: screen.minY + 4, width: 16, height: 18)
            default: mark = NSRect(x: screen.minX + 7, y: screen.minY + 4, width: 39, height: 5)
            }
            accent.setFill(); NSBezierPath(roundedRect: mark, xRadius: 2, yRadius: 2).fill()
            label(title, NSRect(x: 13, y: 9, width: bounds.width - 25, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: ink)
            if selected { NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.draw(in: NSRect(x: bounds.width - 25, y: bounds.height - 26, width: 14, height: 14)) }
        case .anchor:
            let x: CGFloat = key.hasSuffix("left") ? 12 : key.hasSuffix("right") ? bounds.width - 29 : (bounds.width - 17) / 2
            let y: CGFloat = key.hasPrefix("top") ? bounds.height - 12 : 8
            (selected ? accent : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 17, height: 4), xRadius: 2, yRadius: 2).fill()
        case .font:
            let font: NSFont = key == "system" ? .systemFont(ofSize: 16) : .monospacedSystemFont(ofSize: 16, weight: .medium)
            if key == "led" {
                let stream = buildScrollStream(text: "81.30", defaultColor: .white, onClickCommand: nil)
                let art = makeLEDArt(stream: stream, dot: 1, style: LEDStyle(tone: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light), scale: Int(window?.backingScaleFactor ?? 2))
                if let tile = art.tiles.first {
                    NSImage(cgImage: tile.image, size: NSSize(width: tile.width, height: art.height)).draw(in: NSRect(x: 12, y: bounds.height - 30, width: tile.width, height: art.height))
                }
            } else { label("81.30", NSRect(x: 12, y: bounds.height - 34, width: bounds.width - 24, height: 22), font: font, color: ink) }
            label(title, NSRect(x: 12, y: 8, width: bounds.width - 24, height: 18), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .background:
            let pill = NSRect(x: 12, y: bounds.height - 36, width: max(30, bounds.width - 24), height: 23)
            if key == "glass" { NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill() }
            label("SPY 759.72", pill.insetBy(dx: 9, dy: 3), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: ink)
            label(title, NSRect(x: 12, y: 8, width: bounds.width - 24, height: 18), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .color:
            let colors: [NSColor] = key == "adaptive" ? [.labelColor, .systemGreen, .systemRed] : key == "amber" ? [.systemOrange] : key == "green" ? [.systemGreen] : [.labelColor]
            for (i, c) in colors.enumerated() { c.setFill(); NSBezierPath(ovalIn: NSRect(x: 13 + CGFloat(i) * 15, y: bounds.height - 27, width: 9, height: 9)).fill() }
            label(title, NSRect(x: 12, y: 8, width: bounds.width - 24, height: 18), font: .systemFont(ofSize: 11), color: ink)
        case .text:
            label(title, NSRect(x: 8, y: (bounds.height - 18) / 2, width: bounds.width - 16, height: 18), font: .systemFont(ofSize: 12, weight: selected ? .medium : .regular), color: selected ? accent : ink, align: .center)
        }
    }
}

final class SettingsChoiceGroup: NSStackView {
    private(set) var buttons: [SettingsChoiceButton] = []
    private(set) var indexOfSelectedItem = 0
    var onChange: (() -> Void)?
    init() {
        super.init(frame: .zero)
        orientation = .horizontal; distribution = .fillEqually; spacing = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ labels: [String], keys: [String] = [], artwork: SettingsChoiceButton.Artwork = .text) {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = labels.enumerated().map { i, label in
            let b = SettingsChoiceButton(label, key: keys.indices.contains(i) ? keys[i] : "", artwork: artwork)
            b.onChoose = { [weak self] in self?.selectItem(at: i); self?.onChange?() }
            addArrangedSubview(b)
            b.heightAnchor.constraint(equalToConstant: artwork == .font || artwork == .background ? 68 : artwork == .color ? 58 : 36).isActive = true
            return b
        }
        selectItem(at: min(indexOfSelectedItem, max(0, buttons.count - 1)))
    }
    func selectItem(at index: Int) {
        indexOfSelectedItem = min(max(0, index), max(0, buttons.count - 1))
        for (i, button) in buttons.enumerated() { button.state = i == indexOfSelectedItem ? .on : .off; button.needsDisplay = true; button.setAccessibilityValue(i == indexOfSelectedItem ? 1 : 0) }
    }
}

/// Draft-only desktop preview. Sliders and anchor buttons provide keyboard equivalents.
final class LayoutPreviewView: NSView {
    var menuOn = true { didSet { needsDisplay = true } }
    var barOn = true { didSet { needsDisplay = true } }
    var boardOn = false { didSet { needsDisplay = true } }
    var fraction = 0.6 { didSet { needsDisplay = true } }
    var placement = "bottom-center" { didSet { needsDisplay = true } }
    var freePosition = NSPoint(x: 0.5, y: 0) { didSet { needsDisplay = true } }
    var menuFraction = 0.2 { didSet { needsDisplay = true } }
    var glass = true { didSet { needsDisplay = true } }
    var locked = false
    var onEdit: ((String, Double, NSPoint) -> Void)?
    private var drag: (point: NSPoint, rect: NSRect, fraction: Double, edge: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(L("Desktop preview. Drag the ticker or its edges to adjust the layout."))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 500, height: 205) }
    private var area: NSRect { NSRect(x: 12, y: 39, width: max(1, bounds.width - 24), height: max(1, bounds.height - 74)) }
    var tickerFrame: NSRect {
        let a = area, w = a.width * min(1, max(0.01, fraction)), h: CGFloat = 26
        let x: CGFloat, y: CGFloat
        if placement == "free" { x = a.minX + (a.width - w) * freePosition.x; y = a.minY + (a.height - h) * freePosition.y }
        else {
            x = placement.hasSuffix("left") ? a.minX : placement.hasSuffix("right") ? a.maxX - w : a.midX - w / 2
            y = placement.hasPrefix("top") ? a.maxY - h : a.minY
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill(); outer.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.045).setFill(); outer.fill()
        NSColor.separatorColor.setStroke(); outer.stroke()
        NSGraphicsContext.saveGraphicsState(); outer.addClip()
        func fill(_ r: NSRect, _ color: NSColor, _ radius: CGFloat = 4) { color.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
        func text(_ s: String, _ r: NSRect, _ size: CGFloat = 11, _ color: NSColor = .secondaryLabelColor, mono: Bool = false) {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byClipping
            (s as NSString).draw(in: r, withAttributes: [.font: mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: p])
        }
        fill(NSRect(x: 0, y: bounds.height - 25, width: bounds.width, height: 25), .controlBackgroundColor, 0)
        text("WP", NSRect(x: 12, y: bounds.height - 20, width: 30, height: 16))
        text("09:41", NSRect(x: bounds.width - 40, y: bounds.height - 20, width: 35, height: 16))
        if menuOn {
            let r = NSRect(x: bounds.width - 52 - bounds.width * menuFraction, y: bounds.height - 21, width: bounds.width * menuFraction, height: 17)
            fill(r, NSColor.controlAccentColor.withAlphaComponent(0.12), 3)
            text("SPY 759.72  −0.38%   QQQ 717.37", r.insetBy(dx: 4, dy: 1), 10, .labelColor, mono: true)
        }
        let ghost = NSRect(x: bounds.width * 0.15, y: 61, width: bounds.width * 0.61, height: max(30, bounds.height - 107))
        fill(ghost, NSColor.controlBackgroundColor.withAlphaComponent(0.70), 7)
        for i in 0..<3 { fill(NSRect(x: ghost.minX + 13, y: ghost.maxY - 26 - CGFloat(i) * 16, width: ghost.width * (i == 1 ? 0.72 : 0.50), height: 4), NSColor.separatorColor.withAlphaComponent(0.6), 2) }
        let dock = NSRect(x: bounds.midX - 61, y: 8, width: 122, height: 23)
        fill(dock, .controlBackgroundColor, 7)
        for i in 0..<6 { fill(NSRect(x: dock.minX + 8 + CGFloat(i) * 18, y: 13, width: 13, height: 13), .separatorColor, 3) }
        if boardOn {
            let b = NSRect(x: bounds.width - 142, y: 69, width: 128, height: 89)
            fill(b, .controlBackgroundColor, 7)
            text(L("Watchlist"), NSRect(x: b.minX + 9, y: b.maxY - 20, width: 110, height: 15))
            for (i, s) in ["SPY    759.72", "QQQ    717.37", "TLT     81.30"].enumerated() { text(s, NSRect(x: b.minX + 9, y: b.maxY - 40 - CGFloat(i) * 18, width: 110, height: 16), 10, .labelColor, mono: true) }
        }
        if barOn {
            let r = tickerFrame
            if glass { fill(r, .controlBackgroundColor, 13) }
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r.insetBy(dx: 8, dy: 0)).addClip()
            let style = LEDStyle(tone: dark ? .dark : .light)
            let quote = NSMutableAttributedString(string: "SPY 759.72 ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
            quote.append(NSAttributedString(string: "−0.38%", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: style.nsColor(.red)]))
            quote.append(NSAttributedString(string: "    QQQ 717.37    TLT 81.30", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]))
            quote.draw(at: NSPoint(x: r.minX + 11, y: r.midY - 7))
            NSGraphicsContext.restoreGraphicsState()
            if !locked {
                for x in [r.minX + 4, r.maxX - 6] { fill(NSRect(x: x, y: r.midY - 5, width: 2, height: 10), .tertiaryLabelColor, 1) }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        guard barOn, !locked else { return }
        let p = convert(event.locationInWindow, from: nil), r = tickerFrame
        guard r.contains(p) else { return }
        let edge = p.x < r.minX + 10 ? -1 : p.x > r.maxX - 10 ? 1 : 0
        drag = (p, r, fraction, edge)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil), dx = p.x - drag.point.x, dy = p.y - drag.point.y
        let a = area
        if drag.edge == 0 {
            placement = "free"
            freePosition = NSPoint(x: min(1, max(0, (drag.rect.minX + dx - a.minX) / max(1, a.width - drag.rect.width))),
                                   y: min(1, max(0, (drag.rect.minY + dy - a.minY) / max(1, a.height - drag.rect.height))))
        } else {
            let multiplier: CGFloat = placement.hasSuffix("center") || placement == "free" ? 2 : 1
            fraction = min(1, max(0.2, drag.fraction + Double(dx * CGFloat(drag.edge) * multiplier / a.width)))
            if placement == "free" {
                let w = a.width * fraction
                freePosition.x = min(1, max(0, (drag.rect.midX - w / 2 - a.minX) / max(1, a.width - w)))
            }
        }
        onEdit?(placement, fraction, freePosition)
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
}
