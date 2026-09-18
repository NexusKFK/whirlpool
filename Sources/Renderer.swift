import AppKit

// ── Layout (compile-time constants) ───────────────────────────────────────────
let ledSize     = 2
let ledGap      = 1
let ledRows     = 8
let paddingH    = 4
let paddingV    = 0
let colsPerChar = 6   // 5 Pixel + 1 Abstandsspalte

let colW = ledSize + ledGap
let rowH = ledSize + ledGap
let imgH = ledRows * rowH - ledGap + paddingV * 2
let edgeFadeCols = 8   // 两缘渐隐列数:文字出图不生硬

// ── Farben ─────────────────────────────────────────────────────────────────────

func nsColor(_ c: LEDColor) -> NSColor {
    switch c {
    case .amber:  return NSColor(red: 1.0,  green: 0.55, blue: 0.0,  alpha: 1)
    case .green:  return NSColor(red: 0.0,  green: 1.0,  blue: 0.25, alpha: 1)
    case .red:    return NSColor(red: 1.0,  green: 0.1,  blue: 0.0,  alpha: 1)
    case .white:  return NSColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1)
    case .yellow: return NSColor(red: 1.0,  green: 0.9,  blue: 0.0,  alpha: 1)
    case .black:  return NSColor(red: 0.0,  green: 0.0,  blue: 0.0,  alpha: 1)
    }
}

let colorOff = NSColor(red: 0.15, green: 0.11, blue: 0.0, alpha: 1.0)

// Transparenter Modus — gesetzt aus Config beim Start
var renderTransparent = false
private let paddingTop  = 3
private let imgHtransparent = ledRows * rowH - ledGap + paddingTop

// Backing-Scale des Bildschirms mit der Menüleiste — gesetzt aus AppDelegate,
// aktualisiert bei Bildschirmwechsel. Ganzzahlig, damit das Punktraster scharf bleibt.
var renderScale = 2

// Transparentmodus: false = Template-Bild, die Menüleiste färbt selbst ein
// (hell/dunkel, Hervorhebung beim Klick) und Farben im Datenstrom sind wirkungslos.
// true = die Punkte werden in ihrer eigenen Farbe gezeichnet, also in der
// eingestellten Grundfarbe, die \c[…] pro Nachricht überschreiben darf.
var renderColoredTransparent = false

// ── Farben als fertige RGBA-Pixel ─────────────────────────────────────────────
//
// Little-Endian-Layout des Bitmaps: R | G<<8 | B<<16 | A<<24

private func packed(_ c: NSColor) -> UInt32 {
    let rgb = c.usingColorSpace(.deviceRGB) ?? c
    let r = UInt32(rgb.redComponent   * 255.0 + 0.5)
    let g = UInt32(rgb.greenComponent * 255.0 + 0.5)
    let b = UInt32(rgb.blueComponent  * 255.0 + 0.5)
    return r | (g << 8) | (b << 16) | (0xFF << 24)
}

private let packedOn: [LEDColor: UInt32] = {
    var t = [LEDColor: UInt32]()
    for c in [LEDColor.amber, .green, .red, .white, .yellow, .black] { t[c] = packed(nsColor(c)) }
    return t
}()

private let packedOff        = packed(colorOff)
private let packedBlack      = packed(.black)
private let packedTemplate: UInt32 = 0xFF00_0000   // Schwarz, deckend — Template nutzt nur Alpha
private let packedClear:    UInt32 = 0

// ── Hilfsfunktionen ────────────────────────────────────────────────────────────

func imgWidth(displayWidth: Int) -> Int {
    displayWidth * colsPerChar * colW + paddingH * 2
}

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
                         fadeEdges: Bool = false, flash: Set<Int> = []) -> NSImage {
    let s    = max(1, renderScale)
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
    let bg = renderTransparent ? packedClear : packedBlack
    if bg == 0 {
        memset(base, 0, pw * ph * 4)
    } else {
        for i in 0..<(pw * ph) { px[i] = bg }
    }

    // Punkte
    let dot = ledSize * s
    for ci in 0..<visibleCols {
        let si = offset + ci
        guard si >= 0, si < columns.count else { continue }
        let flashing = flash.contains(si)
        let col = columns[si]
        let x0  = (paddingH + ci * colW) * s
        for bit in 0..<ledRows {
            let on = (col.value & (1 << bit)) != 0
            var v: UInt32
            if renderTransparent {
                guard on else { continue }          // unbeleuchtete Punkte bleiben transparent
                // 换数提示=高亮闪:命中列用白色,字形不变、全程可读
                let c = flashing ? LEDColor.white : col.color
                v = renderColoredTransparent ? (packedOn[c] ?? packedTemplate)
                                             : packedTemplate
            } else {
                let c = flashing ? LEDColor.white : col.color
                v = on ? (packedOn[c] ?? packedTemplate) : packedOff
            }
            // 两缘渐隐仅用于滚动帧;idle/standby 小图标不吃,否则 5 列宽的
            // "<" 会被 8 列渐隐区整颗压暗
            if fadeEdges {
                let edgeDist: Double = min(Double(ci), Double(visibleCols - 1 - ci))
                let fade: Double = min(1.0, edgeDist / Double(edgeFadeCols))
                let alpha: UInt32 = UInt32(UInt8(max(0, fade * 255.0)))
                v = (v & 0x00FF_FFFF) | (alpha << 24)
            }
            let y0 = (yPad + bit * rowH) * s
            for dy in 0..<dot {
                let row = (y0 + dy) * pw + x0
                for dx in 0..<dot { px[row + dx] = v }
            }
        }
    }

    rep.size = size
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    // Nur ungefärbte Transparenz ist ein Template — sobald echte Farben im Bild
    // stehen, muss es so bleiben, wie es gezeichnet wurde.
    img.isTemplate = renderTransparent && !renderColoredTransparent
    return img
}

// ── Scroll-Frame ───────────────────────────────────────────────────────────────

func renderScrollFrame(columns: [ColoredColumn], offset: Int,
                       displayWidth: Int, blank: Bool = false, flash: Set<Int> = []) -> NSImage {
    renderFrame(columns:    columns,
                offset:     offset,
                visibleCols: blank ? 0 : visCols(displayWidth: displayWidth),
                width:      imgWidth(displayWidth: displayWidth),
                height:     renderTransparent ? imgHtransparent : imgH,
                yPad:       renderTransparent ? paddingTop : paddingV,
                fadeEdges:  true,
                flash:      flash)
}

// ── Idle-Icon (< aus LED-Punkten) ─────────────────────────────────────────────

func renderIdleIcon(color: LEDColor) -> NSImage {
    let cols = FONT[Character("<")] ?? Array(repeating: 0, count: 5)
    return renderFrame(columns:     cols.map { ColoredColumn(value: $0, color: color) },
                       offset:      0,
                       visibleCols: 5,
                       width:       paddingH * 2 + 5 * colW - ledGap,
                       height:      renderTransparent ? imgHtransparent : imgH,
                       yPad:        renderTransparent ? paddingTop : paddingV)
}

// ── Standby-Frame (links-ausgerichtet, geclippt) ───────────────────────────────

func renderStandbyFrame(text: String, displayWidth: Int,
                        defaultColor: LEDColor,
                        customChars: [String: [UInt8]]) -> NSImage {
    let stream  = buildScrollStream(text: text, defaultColor: defaultColor,
                                    onClickCommand: nil, customChars: customChars)
    let clipped = Array(stream.columns.prefix(visCols(displayWidth: displayWidth)))
    return renderScrollFrame(columns: clipped, offset: 0, displayWidth: displayWidth)
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
