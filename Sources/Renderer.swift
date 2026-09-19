import AppKit

// ── Layout ────────────────────────────────────────────────────────────────────
let ledRows     = 8
let paddingH    = 4
let paddingV    = 0
let colsPerChar = 6   // 5 Pixel + 1 Abstandsspalte
let edgeFadeCols = 8   // 两缘渐隐列数:文字出图不生硬
private let paddingTop  = 3

// ── 点阵字号 S/M/L ─────────────────────────────────────────────────────────────
// 点距恒为 1px:字高 = 8·(dot+1)−1,点愈大字愈大。M=2 是 1.6.x 的历史默认档。
// 菜单栏状态项的宿主窗口实测高约 30pt,L 档(34pt)放不下,界面层把菜单栏
// 一侧钳回 M(见 AppDelegate.renderSurfaces);浮动 bar 窗口自适应宽高,三档全可用。
var renderDotSize = 2

struct LEDLayout {
    let dot: Int
    var colW: Int { dot + 1 }
    var rowH: Int { dot + 1 }
    var imgH: Int { ledRows * rowH - 1 + paddingV * 2 }
    var imgHTransparent: Int { ledRows * rowH - 1 + paddingTop }
    func imgWidth(_ displayWidth: Int) -> Int { displayWidth * colsPerChar * colW + paddingH * 2 }
}

// 旧引用点(测试解码、bar 初始宽度)按当前全局档位取值
var colW: Int { LEDLayout(dot: renderDotSize).colW }
var rowH: Int { LEDLayout(dot: renderDotSize).rowH }

// ── Farben ─────────────────────────────────────────────────────────────────────
// 具体 RGB 由 Theme.swift 的 LEDStyle 按显示面明暗解析;这里只留旧全局开关,
// 供逐帧渲染函数(静态图标、standby、回归测试)推导默认风格。

func nsColor(_ c: LEDColor) -> NSColor { LEDStyle().nsColor(c) }

// Transparenter Modus — gesetzt aus Config beim Start
var renderTransparent = false

// Backing-Scale des Bildschirms mit der Menüleiste — gesetzt aus AppDelegate,
// aktualisiert bei Bildschirmwechsel. Ganzzahlig, damit das Punktraster scharf bleibt.
var renderScale = 2

// Transparentmodus: false = einfarbig (neutral, folgt Hell/Dunkel), true = die Punkte
// werden in ihrer eigenen Farbe gezeichnet, also in der eingestellten Grundfarbe,
// die \c[…] pro Nachricht überschreiben darf.
var renderColoredTransparent = false

/// 旧全局开关对应的风格(暗底)。新代码按显示面显式传 LEDStyle。
var legacyStyle: LEDStyle {
    LEDStyle(tone: .dark, mono: renderTransparent && !renderColoredTransparent, panel: !renderTransparent)
}

private let packedOffDots: UInt32 = 0xFF00_1C26   // (0.15, 0.11, 0.0) 灭灯暗琥珀
private let packedBlack:   UInt32 = 0xFF00_0000

// ── Hilfsfunktionen ────────────────────────────────────────────────────────────

func visCols(displayWidth: Int) -> Int {
    displayWidth * colsPerChar
}

// ── Frame-Rendering ────────────────────────────────────────────────────────────
//
// Die Punkte werden direkt in einen RGBA-Puffer geschrieben statt als einzelne
// NSBezierPath-Rechtecke in einen lockFocus-Kontext. Bei Breite 20 sind das 960
// Rasterpunkte pro Frame, 20×/s — der Kontextaufbau und die Core-Graphics-Aufrufe
// dominierten die CPU-Last. Der Puffer ist klein (bei Breite 20 und 2× rund
// 34.000 Pixel), das Füllen ist ein reiner Speicher-Loop.
//
// Bit 0 eines Font-Bytes ist die oberste Zeile; im Bitmap läuft y von oben,
// darum y = yPad + bit * rowH (in der alten Zeichnung von unten gerechnet).

private func renderFrame(columns: [ColoredColumn], offset: Int, visibleCols: Int,
                         width: Int, height: Int, yPad: Int,
                         fadeEdges: Bool = false, flash: [Int: LEDColor] = [:],
                         layout: LEDLayout, style: LEDStyle = legacyStyle,
                         scale: Int = renderScale) -> NSImage {
    let s    = max(1, scale)
    let pw   = width  * s
    let ph   = height * s
    let size = NSSize(width: Double(width), height: Double(height))

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pw, pixelsHigh: ph,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: pw * 4, bitsPerPixel: 32),
          let base = rep.bitmapData
    else { return NSImage(size: size) }

    let px = UnsafeMutableRawPointer(base).bindMemory(to: UInt32.self, capacity: pw * ph)

    // Hintergrund
    let bg: UInt32 = style.panel ? packedBlack : 0
    if bg == 0 {
        memset(base, 0, pw * ph * 4)
    } else {
        for i in 0..<(pw * ph) { px[i] = bg }
    }

    // Punkte
    let dot = layout.dot * s
    for ci in 0..<visibleCols {
        let si = offset + ci
        guard si >= 0, si < columns.count else { continue }
        let flashColor = flash[si]
        let col = columns[si]
        let x0  = (paddingH + ci * layout.colW) * s
        for bit in 0..<ledRows {
            let on = (col.value & (1 << bit)) != 0
            var v: UInt32
            if !style.panel {
                guard on else { continue }          // unbeleuchtete Punkte bleiben transparent
            }
            // 换数提示=跳动方向色单次闪:命中列闪现色→回原色,无空帧(单色模式不闪)
            let c = style.mono ? col.color : (flashColor ?? col.color)
            v = on ? style.packed(c) : packedOffDots
            // 两缘渐隐仅用于滚动帧;idle/standby 小图标不吃,否则 5 列宽的
            // "<" 会被 8 列渐隐区整颗压暗
            if fadeEdges {
                let edgeDist: Double = min(Double(ci), Double(visibleCols - 1 - ci))
                let fade: Double = min(1.0, edgeDist / Double(edgeFadeCols))
                let alpha: UInt32 = UInt32(UInt8(max(0, fade * 255.0)))
                v = (v & 0x00FF_FFFF) | (alpha << 24)
            }
            let y0 = (yPad + bit * layout.rowH) * s
            for dy in 0..<dot {
                let row = (y0 + dy) * pw + x0
                for dx in 0..<dot { px[row + dx] = v }
            }
        }
    }

    // 像素值按 sRGB 解释(与 GPU 条带同一色彩空间),免得合成时每帧做色彩转换
    let tagged = rep.retagging(with: .sRGB) ?? rep
    tagged.size = size
    let img = NSImage(size: size)
    img.addRepresentation(tagged)
    return img
}

// ── Scroll-Frame ───────────────────────────────────────────────────────────────

func renderScrollFrame(columns: [ColoredColumn], offset: Int,
                       displayWidth: Int, blank: Bool = false, flash: [Int: LEDColor] = [:],
                       dot: Int = renderDotSize, style: LEDStyle = legacyStyle,
                       scale: Int = renderScale) -> NSImage {
    let lay = LEDLayout(dot: dot)
    return renderFrame(columns:    columns,
                offset:     offset,
                visibleCols: blank ? 0 : visCols(displayWidth: displayWidth),
                width:      lay.imgWidth(displayWidth),
                height:     style.panel ? lay.imgH : lay.imgHTransparent,
                yPad:       style.panel ? paddingV : paddingTop,
                fadeEdges:  true,
                flash:      flash,
                layout:     lay, style: style, scale: scale)
}

// ── Idle-Icon (< aus LED-Punkten) ─────────────────────────────────────────────

func renderIdleIcon(color: LEDColor, dot: Int = renderDotSize,
                    style: LEDStyle = legacyStyle, scale: Int = renderScale) -> NSImage {
    // 收起态:<W — 每字符 5 列字面 + 1 空隙列
    let lay = LEDLayout(dot: dot)
    let glyphs = ["<", "w"].map { FONT[$0] ?? Array(repeating: 0, count: 5) }
    var cols: [UInt8] = []
    for g in glyphs { cols += g }
    return renderFrame(columns:     cols.map { ColoredColumn(value: $0, color: color) },
                       offset:      0,
                       visibleCols: cols.count,
                       width:       paddingH * 2 + cols.count * lay.colW - 1,
                       height:      style.panel ? lay.imgH : lay.imgHTransparent,
                       yPad:        style.panel ? paddingV : paddingTop,
                       layout:      lay, style: style, scale: scale)
}

// ── Standby-Frame (links-ausgerichtet, geclippt) ───────────────────────────────

func renderStandbyFrame(text: String, displayWidth: Int,
                        defaultColor: LEDColor,
                        customChars: [String: [UInt8]],
                        dot: Int = renderDotSize, style: LEDStyle = legacyStyle,
                        scale: Int = renderScale) -> NSImage {
    let stream  = buildScrollStream(text: text, defaultColor: defaultColor,
                                    onClickCommand: nil, customChars: customChars)
    let clipped = Array(stream.columns.prefix(visCols(displayWidth: displayWidth)))
    return renderScrollFrame(columns: clipped, offset: 0, displayWidth: displayWidth,
                             dot: dot, style: style, scale: scale)
}

// ── 像素文本(board 卡等非跑马灯场景) ─────────────────────────────────────────
// 用同一张 LED 位图字体表渲染任意分段着色文本,直写 RGBA,透明底。

func renderPixelText(_ segments: [(text: String, color: NSColor)], dot: Int = 2, gap: Int = 0) -> NSImage {
    var cols: [(UInt8, NSColor)] = []
    for seg in segments {
        for ch in seg.text.uppercased() {
            guard let g = FONT[ch] else { continue }
            for b in g { cols.append((b, seg.color)) }
        }
    }
    let cw = dot + gap, rh = dot + gap
    let w = max(1, cols.count * cw + 2)
    let h = 8 * rh + 2

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: w * 4, bitsPerPixel: 32),
          let base = rep.bitmapData
    else { return NSImage(size: NSSize(width: w, height: h)) }
    let px = UnsafeMutableRawPointer(base).bindMemory(to: UInt32.self, capacity: w * h)
    memset(base, 0, w * h * 4)

    func pack(_ c: NSColor) -> UInt32 {
        let rgb = c.usingColorSpace(.deviceRGB) ?? c
        let r = UInt32(rgb.redComponent * 255.0 + 0.5)
        let g = UInt32(rgb.greenComponent * 255.0 + 0.5)
        let b = UInt32(rgb.blueComponent * 255.0 + 0.5)
        return r | (g << 8) | (b << 16) | (0xFF << 24)
    }

    for (ci, col) in cols.enumerated() {
        for bit in 0..<8 where col.0 & (1 << UInt8(bit)) != 0 {
            let x0 = 1 + ci * cw
            let y0 = 1 + bit * rh   // bit 0 = 顶行;位图 y 向下,直接对应
            let v = pack(col.1)
            for dy in 0..<dot {
                let row = (y0 + dy) * w + x0
                for dx in 0..<dot { px[row + dx] = v }
            }
        }
    }

    rep.size = NSSize(width: w, height: h)
    let img = NSImage(size: NSSize(width: w, height: h))
    img.addRepresentation(rep)
    return img
}

// ── GPU 条带 ───────────────────────────────────────────────────────────────────
//
// 一轮消息只在 CPU 上画一次:整串画成若干张纹理(单张 ≤ 8192px,避开 GPU 纹理上限),
// 滚动交给 Core Animation 平移图层,app 进程每帧零绘制。
// 条带不含左右留白与两缘渐隐——留白由视口、渐隐由遮罩层负责。

struct StripTile {
    let image: CGImage
    let x: CGFloat          // 串内起点(pt)
    let width: CGFloat      // pt
}

/// 换数闪色叠层:只含闪变列/字,盖在底图原位,由不透明度脉冲点亮。
struct FlashArt {
    let tile: StripTile
    let cols: Range<Int>    // 引擎列
    let color: LEDColor
}

/// 一个显示面一轮的全部纹理与几何。
struct StripArt {
    var tiles: [StripTile]
    var width: CGFloat       // 单份宽(pt)= totalCols × pitch
    var height: CGFloat
    var pitch: CGFloat       // 引擎一列 = 多少 pt
    var totalCols: Int
    var flashes: [FlashArt]
    var nearest: Bool        // LED:最近邻采样,点阵锐利不糊
    var panel: Bool          // 黑底面板
    var inset: CGFloat       // 视口左右留白(LED 4pt,文本 0)
    var fadeWidth: CGFloat   // 两缘渐隐宽(pt)
}

/// 连续同色闪变列归成组(与 ScrollFlashes 同一规则)。
func flashGroups(_ columns: [Int: LEDColor]) -> [(cols: Range<Int>, color: LEDColor)] {
    var groups: [(cols: Range<Int>, color: LEDColor)] = []
    for index in columns.keys.sorted() {
        let color = columns[index]!
        if let last = groups.last, last.cols.upperBound == index, last.color == color {
            groups[groups.count - 1].cols = last.cols.lowerBound..<(index + 1)
        } else {
            groups.append((index..<(index + 1), color))
        }
    }
    return groups
}

func makeBitmapContext(pixelsWide: Int, pixelsHigh: Int) -> CGContext? {
    guard pixelsWide > 0, pixelsHigh > 0 else { return nil }
    return CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                     bytesPerRow: pixelsWide * 4, space: sRGBSpace,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// LED 列 [range] 画成一张纹理。only 非 nil 时只画这些列、用给定闪现色(叠层)。
private func renderLEDTile(columns: [ColoredColumn], range: Range<Int>, layout: LEDLayout,
                           style: LEDStyle, scale: Int, only: [Int: LEDColor]? = nil) -> CGImage? {
    let s = max(1, scale)
    let height = style.panel ? layout.imgH : layout.imgHTransparent
    let yPad = style.panel ? paddingV : paddingTop
    let pw = range.count * layout.colW * s, ph = height * s
    guard let ctx = makeBitmapContext(pixelsWide: pw, pixelsHigh: ph), let base = ctx.data else { return nil }
    let px = base.bindMemory(to: UInt32.self, capacity: pw * ph)
    let fillPanel = style.panel && only == nil
    if fillPanel { for i in 0..<(pw * ph) { px[i] = packedBlack } }
    let dot = layout.dot * s
    for si in range {
        let col = columns[si]
        let flash = only?[si]
        if only != nil, flash == nil { continue }
        let x0 = (si - range.lowerBound) * layout.colW * s
        for bit in 0..<ledRows {
            let on = (col.value & (1 << bit)) != 0
            let v: UInt32
            if on { v = style.packed(flash ?? col.color) }
            else if fillPanel { v = packedOffDots }
            else { continue }
            let y0 = (yPad + bit * layout.rowH) * s
            for dy in 0..<dot {
                let row = (y0 + dy) * pw + x0
                for dx in 0..<dot { px[row + dx] = v }
            }
        }
    }
    return ctx.makeImage()
}

/// LED 整轮条带 + 换数叠层。
func makeLEDArt(stream: ScrollStream, dot: Int, style: LEDStyle, scale: Int) -> StripArt {
    let layout = LEDLayout(dot: dot)
    let columns = stream.columns
    let pitch = CGFloat(layout.colW)
    let maxCols = max(1, 8192 / max(1, layout.colW * max(1, scale)))
    var tiles: [StripTile] = []
    var start = 0
    while start < columns.count {
        let end = min(columns.count, start + maxCols)
        if let img = renderLEDTile(columns: columns, range: start..<end, layout: layout, style: style, scale: scale) {
            tiles.append(StripTile(image: img, x: CGFloat(start) * pitch, width: CGFloat(end - start) * pitch))
        }
        start = end
    }
    var flashes: [FlashArt] = []
    if !style.mono {
        for group in flashGroups(stream.blinkCols) where group.cols.upperBound <= columns.count {
            let only = Dictionary(uniqueKeysWithValues: group.cols.map { ($0, group.color) })
            if let img = renderLEDTile(columns: columns, range: group.cols, layout: layout,
                                       style: style, scale: scale, only: only) {
                flashes.append(FlashArt(tile: StripTile(image: img, x: CGFloat(group.cols.lowerBound) * pitch,
                                                        width: CGFloat(group.cols.count) * pitch),
                                        cols: group.cols, color: group.color))
            }
        }
    }
    return StripArt(tiles: tiles, width: CGFloat(columns.count) * pitch,
                    height: CGFloat(style.panel ? layout.imgH : layout.imgHTransparent),
                    pitch: pitch, totalCols: columns.count, flashes: flashes,
                    nearest: true, panel: style.panel, inset: CGFloat(paddingH),
                    fadeWidth: CGFloat(edgeFadeCols) * pitch)
}

extension NSImage {
    /// 静态图(idle/standby)转纹理;按图的点尺寸取对应倍率像素
    func cgImageForLayer(scale: CGFloat) -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil,
                       hints: [.ctm: AffineTransform(scale: scale)])
    }
}
