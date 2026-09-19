import AppKit

// ── 系统字体跑马灯(flat-text)──────────────────────────────────────────────────
//
// 与 LED 点阵共用同一套滚动引擎(列推进/暂停/预取/换数闪变),差别只在帧渲染:
// 文本按 3pt 一"虚拟列"计量(与 M 档 LED 点距一致,滚速语义不变),整条消息
// 预渲染成一张宽图(TextStrip),每帧把可视区 blit 进帧缓冲,再到右缘复制一份
// 实现无缝环绕。\c 着色、\p 暂停、\b 闪变与 LED 同一套标记语言,位置按字符
// 量测后换算到虚拟列。
// 单色模板模式(transparentColor=auto)与 LED 行为一致:整体黑字交给系统着色,
// \c 与 \b 的彩色在这档无效。

struct TextRun {
    var text: String
    var color: LEDColor
    var blink: LEDColor?   // 非 nil = 处于 \b[1:…] 闪变组,覆绘用闪现色
}

struct TextStream {
    var runs: [TextRun] = []
    var pauses: [(charIndex: Int, kind: PauseKind)] = []   // charIndex = 字符位(非虚拟列)
}

/// 与 buildScrollStream 同一套标记机(\c \p \b \g),输出改为带颜色的文本段。
/// \g 自定义字形是 LED 专属,文本模式静默跳过。
func buildTextScrollStream(text: String, defaultColor: LEDColor,
                           onClickCommand: String?) -> TextStream {
    var stream = TextStream()
    var color = defaultColor
    var blinking = false
    var blinkColor: LEDColor? = nil
    var chars = 0
    var i = text.startIndex

    func append(_ s: String) {
        if let last = stream.runs.last, last.color == color, last.blink == (blinking ? blinkColor : nil) {
            stream.runs[stream.runs.count - 1].text += s
        } else {
            stream.runs.append(TextRun(text: s, color: color,
                                       blink: blinking ? (blinkColor ?? color) : nil))
        }
        chars += s.count
    }

    while i < text.endIndex {
        if text[i] == "\\", text.index(after: i) < text.endIndex {
            let ni = text.index(after: i)
            if text[ni] == "c" || text[ni] == "p" || text[ni] == "g" || text[ni] == "b" {
                if let (code, end) = parseCode(text, from: i) {
                    switch code {
                    case .color(let c):
                        color = c ?? defaultColor
                    case .blink(let on, let c):
                        blinking = on
                        blinkColor = on ? c : nil
                    case .pause(var k):
                        if case .sticky(nil, let b) = k, let cmd = onClickCommand {
                            k = .sticky(onClickCommand: cmd, blinks: b)
                        }
                        stream.pauses.append((charIndex: chars, kind: k))
                    case .glyph:
                        break   // LED 专属自定义字形
                    }
                    i = end
                    continue
                }
            }
        }
        append(String(text[i]))
        i = text.index(after: i)
    }
    return stream
}

// ── 整条预渲染 ─────────────────────────────────────────────────────────────────
//
// 一轮一条。宽度、字符 x 坐标、暂停/闪变的虚拟列换算都只算一次;
// 帧渲染只做 blit 与闪变覆绘。

final class TextStrip {

    struct BlinkRun {
        let x: CGFloat                    // 串内起点(pt)
        let cols: Range<Int>              // 覆盖的虚拟列
        let substring: NSString
        let baseAttrs: [NSAttributedString.Key: Any]
    }

    let image: NSImage                    // 整条串,单份(环绕在帧渲染里拼)
    let widthPt: CGFloat
    let heightPt: Int                     // 含上下 3pt 松量,画帧时即帧高
    let textY: CGFloat                    // draw(at:) 的基线定位 y
    let totalCols: Int                    // 虚拟列数(3pt/列)
    let pauses: [PauseMarker]             // at 已换算为虚拟列
    let blinkCols: [Int: LEDColor]        // 虚拟列 → 闪现色(跳动方向色)
    private let blinkRuns: [BlinkRun]
    private var tintedCache: [String: NSAttributedString] = [:]

    init(stream: TextStream, font: NSFont, defaultColor: LEDColor) {
        let template = renderTransparent && !renderColoredTransparent
        let attr = NSMutableAttributedString()
        var blinkRanges: [(NSRange, LEDColor)] = []
        for run in stream.runs where !run.text.isEmpty {
            let foreground: NSColor = template ? .black : nsColor(run.color)
            let location = attr.length
            attr.append(NSAttributedString(string: run.text, attributes: [
                .font: font, .foregroundColor: foreground,
            ]))
            if let b = run.blink {
                blinkRanges.append((NSRange(location: location, length: (run.text as NSString).length), b))
            }
        }

        // 布局量测:单行,零 fragment padding,字符位 → x 坐标
        let storage = NSTextStorage(attributedString: attr)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 100_000, height: 500))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: attr.length))
        let used = manager.usedRect(for: container)

        let n = attr.length
        var charX = [CGFloat](repeating: 0, count: n + 1)
        for ci in 0...n {
            let glyph = manager.glyphIndexForCharacter(at: min(ci, max(0, n - 1)))
            var loc = manager.location(forGlyphAt: glyph)
            if ci == n {   // 末字符右缘 = 末字符 x + 自身advance
                let lineFragment = manager.lineFragmentUsedRect(
                    forGlyphAt: max(0, manager.numberOfGlyphs - 1), effectiveRange: nil)
                loc = NSPoint(x: max(loc.x, lineFragment.maxX), y: loc.y)
            }
            charX[ci] = loc.x
        }

        widthPt = max(6, ceil(used.width))
        let bounds = attr.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        heightPt = Int(ceil(used.height)) + 6
        textY = (CGFloat(heightPt) - bounds.height) / 2 - bounds.minY
        totalCols = max(1, Int(ceil(widthPt / 3.0)))

        func col(_ x: CGFloat) -> Int { max(0, Int((x / 3.0).rounded())) }

        pauses = stream.pauses.map { pause in
            let idx = min(pause.charIndex, n)
            return PauseMarker(at: col(charX[idx]), kind: pause.kind)
        }

        var blinks: [Int: LEDColor] = [:]
        var runs: [BlinkRun] = []
        for (range, color) in blinkRanges {
            let start = charX[min(range.location, n)]
            let end = charX[min(range.location + range.length, n)]
            let cols = col(start)..<max(col(start) + 1, col(end))
            for c in cols { blinks[c] = color }
            let substring = attr.attributedSubstring(from: range).string as NSString
            runs.append(BlinkRun(x: start, cols: cols, substring: substring,
                                 baseAttrs: [.font: font, .foregroundColor: NSColor.black]))
        }
        blinkCols = blinks
        blinkRuns = runs

        // 整条渲染一次
        let s = max(1, renderScale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(widthPt) * s, pixelsHigh: heightPt * s,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: Int(widthPt) * s * 4, bitsPerPixel: 32)
        if let rep {
            rep.size = NSSize(width: widthPt, height: CGFloat(heightPt))   // 先设:上下文按比例出 2x 清晰文本
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                attr.draw(at: NSPoint(x: 0, y: textY))
                NSGraphicsContext.current = nil
            }
            NSGraphicsContext.restoreGraphicsState()
            image = NSImage(size: rep.size)
            image.addRepresentation(rep)
        } else {
            image = NSImage(size: NSSize(width: widthPt, height: CGFloat(heightPt)))
        }
    }

    /// 闪变覆绘:同一串字形按闪现色重画一遍盖在原位(仅彩色模式被调用)
    func tinted(for run: BlinkRun, color: LEDColor, at index: Int) -> NSAttributedString {
        let key = "\(index):\(color.rawValue)"
        if let cached = tintedCache[key] { return cached }
        var attrs = run.baseAttrs
        attrs[.foregroundColor] = nsColor(color)
        let result = NSAttributedString(string: run.substring as String, attributes: attrs)
        tintedCache[key] = result
        return result
    }

    var runs: [BlinkRun] { blinkRuns }
}

// ── 帧渲染 ─────────────────────────────────────────────────────────────────────

/// 可视区帧:把整条 strip 平移 blit,右缘补一份实现无缝环绕;
/// 闪变列命中的 blink 段整段按闪现色覆绘;两缘 24pt 渐隐(与 LED edgeFadeCols 同宽)。
func renderTextFrame(strip: TextStrip, offset: Int, viewportCols: Int, blank: Bool,
                     flash: [Int: LEDColor] = [:]) -> NSImage {
    let s = max(1, renderScale)
    let w = max(6, viewportCols * 3)
    let h = strip.heightPt
    let size = NSSize(width: Double(w), height: Double(h))

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: w * s, pixelsHigh: h * s,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: w * s * 4, bitsPerPixel: 32)
    guard let rep else { return NSImage(size: size) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(size: size)
    }
    NSGraphicsContext.current = ctx

    if !renderTransparent {
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)).fill()
    }

    if !blank {
        let xOff = CGFloat(offset) * 3.0
        var dx = -xOff.truncatingRemainder(dividingBy: strip.widthPt)
        if dx > 0 { dx -= strip.widthPt }
        while dx < CGFloat(w) {
            strip.image.draw(in: NSRect(x: dx, y: 0, width: strip.widthPt, height: CGFloat(h)))
            dx += strip.widthPt
        }

        // 换数闪变:彩色模式才有效(模板模式闪色无效,与 LED 一致)
        if renderColoredTransparent || !renderTransparent {
            for (idx, run) in strip.runs.enumerated() where !flash.isEmpty {
                guard flash.keys.contains(where: { run.cols.contains($0) }) else { continue }
                let color = flash[run.cols.lowerBound] ?? .green
                strip.tinted(for: run, color: color, at: idx)
                    .draw(at: NSPoint(x: run.x - xOff, y: strip.textY))
            }
        }

        // 两缘渐隐:擦 alpha,模板/透明/黑底三档通用
        let fade = CGFloat(edgeFadeCols * 3)
        ctx.compositingOperation = .destinationOut
        if fade > 0, fade * 2 < CGFloat(w) {
            NSGradient(colors: [NSColor.black, NSColor.black.withAlphaComponent(0)])?
                .draw(in: NSRect(x: 0, y: 0, width: fade, height: CGFloat(h)), angle: 0)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black])?
                .draw(in: NSRect(x: CGFloat(w) - fade, y: 0, width: fade, height: CGFloat(h)), angle: 0)
        }
    }

    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: size)
    img.addRepresentation(rep)
    img.isTemplate = renderTransparent && !renderColoredTransparent
    return img
}

/// 系统字体 standby(左对齐,超出可视宽即裁,不滚动)
func renderTextStandbyFrame(text: String, viewportCols: Int,
                            font: NSFont, defaultColor: LEDColor) -> NSImage {
    let stream = buildTextScrollStream(text: text, defaultColor: defaultColor, onClickCommand: nil)
    let strip = TextStrip(stream: stream, font: font, defaultColor: defaultColor)
    return renderTextFrame(strip: strip, offset: 0, viewportCols: viewportCols, blank: false)
}
