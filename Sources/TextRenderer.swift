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
        let width: CGFloat
        let cols: Range<Int>              // 覆盖的虚拟列
        let range: NSRange                // 在整串中的字符范围
        let color: LEDColor               // 闪现色
    }

    let attributed: NSAttributedString    // 整串(已按风格着色)
    let style: LEDStyle
    let widthPt: CGFloat
    let heightPt: Int                     // 含上下 3pt 松量,画帧时即帧高
    let textY: CGFloat                    // draw(at:) 的基线定位 y
    let totalCols: Int                    // 虚拟列数(3pt/列)
    let pauses: [PauseMarker]             // at 已换算为虚拟列
    let blinkCols: [Int: LEDColor]        // 虚拟列 → 闪现色(跳动方向色)
    let runs: [BlinkRun]
    private var cachedImage: NSImage?

    init(stream: TextStream, font: NSFont, defaultColor: LEDColor, style: LEDStyle = legacyStyle) {
        self.style = style
        let attr = NSMutableAttributedString()
        var blinkRanges: [(NSRange, LEDColor)] = []
        for run in stream.runs where !run.text.isEmpty {
            let location = attr.length
            attr.append(NSAttributedString(string: run.text, attributes: [
                .font: font, .foregroundColor: style.nsColor(run.color),
            ]))
            if let b = run.blink {
                blinkRanges.append((NSRange(location: location, length: (run.text as NSString).length), b))
            }
        }
        attributed = attr

        // 布局量测:单行,零 fragment padding,字符位 → x 坐标
        let storage = NSTextStorage(attributedString: attr)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 500))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: attr.length))
        let used = manager.usedRect(for: container)

        let n = attr.length
        var charX = [CGFloat](repeating: 0, count: n + 1)
        for ci in 0...n where n > 0 {
            let glyph = manager.glyphIndexForCharacter(at: min(ci, n - 1))
            var loc = manager.location(forGlyphAt: glyph)
            if ci == n {   // 末字符右缘 = 末字符 x + 自身advance
                let lineFragment = manager.lineFragmentUsedRect(
                    forGlyphAt: max(0, manager.numberOfGlyphs - 1), effectiveRange: nil)
                loc = NSPoint(x: max(loc.x, lineFragment.maxX), y: loc.y)
            }
            charX[ci] = loc.x
        }

        let bounds = attr.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        heightPt = Int(ceil(used.height)) + 6
        textY = (CGFloat(heightPt) - bounds.height) / 2 - bounds.minY
        // 宽度取整到 3pt 虚拟列:条带单份宽 = totalCols × 3,环绕接缝与引擎列严格对齐
        totalCols = max(1, Int(ceil(max(6, ceil(used.width)) / 3.0)))
        widthPt = CGFloat(totalCols) * 3

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
            runs.append(BlinkRun(x: start, width: max(1, end - start), cols: cols, range: range, color: color))
        }
        blinkCols = blinks
        self.runs = runs
    }

    convenience init(stream: TextStream, font: NSFont, defaultColor: LEDColor) {
        self.init(stream: stream, font: font, defaultColor: defaultColor, style: legacyStyle)
    }

    /// 把整串(或只把某个闪变段)画进 [x, x+width) 这一片。
    /// highlight 非 nil:只画该段、用闪现色,其余字透明——字形与底图逐像素重合。
    private func renderSlice(x: CGFloat, width: CGFloat, scale: Int, highlight: BlinkRun? = nil) -> CGImage? {
        let s = CGFloat(max(1, scale))
        let pw = Int(ceil(width * s)), ph = Int(CGFloat(heightPt) * s)
        guard let ctx = makeBitmapContext(pixelsWide: pw, pixelsHigh: ph) else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -x, y: 0)
        let text: NSAttributedString
        if let run = highlight {
            let tinted = NSMutableAttributedString(attributedString: attributed)
            tinted.addAttribute(.foregroundColor, value: NSColor.clear,
                                range: NSRange(location: 0, length: tinted.length))
            tinted.addAttribute(.foregroundColor, value: style.nsColor(run.color), range: run.range)
            text = tinted
        } else {
            text = attributed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: 0, y: textY))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// GPU 条带:整串分片成纹理 + 每个闪变段一张叠层。
    func makeArt(scale: Int) -> StripArt {
        let maxWidth = CGFloat(8192 / max(1, scale))
        var tiles: [StripTile] = []
        var x: CGFloat = 0
        while x < widthPt {
            let w = min(maxWidth, widthPt - x)
            if let img = renderSlice(x: x, width: w, scale: scale) {
                tiles.append(StripTile(image: img, x: x, width: w))
            }
            x += w
        }
        var flashes: [FlashArt] = []
        if !style.mono {
            for run in runs {
                // 叠层左右各放 2pt,容纳斜体/抗锯齿外溢
                let x0 = max(0, run.x - 2), w = min(widthPt - x0, run.width + 4)
                if w > 0, let img = renderSlice(x: x0, width: w, scale: scale, highlight: run) {
                    flashes.append(FlashArt(tile: StripTile(image: img, x: x0, width: w),
                                            cols: run.cols, color: run.color))
                }
            }
        }
        return StripArt(tiles: tiles, width: widthPt, height: CGFloat(heightPt), pitch: 3,
                        totalCols: totalCols, flashes: flashes, nearest: false, panel: style.panel,
                        inset: 0, fadeWidth: CGFloat(edgeFadeCols * 3))
    }

    /// 整串单份 NSImage(standby 静态帧用)
    var image: NSImage {
        if let cachedImage { return cachedImage }
        let scale = max(1, renderScale)
        let img = NSImage(size: NSSize(width: widthPt, height: CGFloat(heightPt)))
        if let cg = renderSlice(x: 0, width: widthPt, scale: scale) {
            img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        cachedImage = img
        return img
    }
}

// ── 帧渲染 ─────────────────────────────────────────────────────────────────────

/// 可视区帧(standby 等静态场景):把整条 strip 平移 blit,右缘补一份实现环绕;两缘渐隐。
func renderTextFrame(strip: TextStrip, offset: Int, viewportCols: Int, blank: Bool,
                     flash: [Int: LEDColor] = [:]) -> NSImage {
    let s = max(1, renderScale)
    let w = max(6, viewportCols * 3)
    let h = strip.heightPt
    let size = NSSize(width: Double(w), height: Double(h))
    guard let ctx = makeBitmapContext(pixelsWide: w * s, pixelsHigh: h * s) else { return NSImage(size: size) }
    ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = gc

    if strip.style.panel {
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

        // 两缘渐隐:擦 alpha,透明/黑底通用
        let fade = CGFloat(edgeFadeCols * 3)
        gc.compositingOperation = .destinationOut
        if fade > 0, fade * 2 < CGFloat(w) {
            NSGradient(colors: [NSColor.black, NSColor.black.withAlphaComponent(0)])?
                .draw(in: NSRect(x: 0, y: 0, width: fade, height: CGFloat(h)), angle: 0)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black])?
                .draw(in: NSRect(x: CGFloat(w) - fade, y: 0, width: fade, height: CGFloat(h)), angle: 0)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: size)
    if let cg = ctx.makeImage() { img.addRepresentation(NSBitmapImageRep(cgImage: cg)) }
    return img
}

/// 系统字体 standby(左对齐,超出可视宽即裁,不滚动)
func renderTextStandbyFrame(text: String, viewportCols: Int,
                            font: NSFont, defaultColor: LEDColor, style: LEDStyle = legacyStyle) -> NSImage {
    let stream = buildTextScrollStream(text: text, defaultColor: defaultColor, onClickCommand: nil)
    let strip = TextStrip(stream: stream, font: font, defaultColor: defaultColor, style: style)
    return renderTextFrame(strip: strip, offset: 0, viewportCols: viewportCols, blank: false)
}
