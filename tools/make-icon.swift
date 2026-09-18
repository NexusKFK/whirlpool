// 画 Whirlpool 图标:深色 squircle 底 + 白色两行点阵 "<Whirl" / "Pool.>"
// 用法: swift tools/make-icon.swift [输出目录 icons]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons"
let S: CGFloat = 1024
let white = NSColor.white

let glyphs: [Character: [UInt8]] = [
    "<": [0x08, 0x14, 0x22, 0x41, 0x00, 0x00],
    "W": [0x3F, 0x40, 0x38, 0x40, 0x3F, 0x00],
    "H": [0x7F, 0x08, 0x08, 0x08, 0x7F, 0x00],
    "I": [0x00, 0x41, 0x7F, 0x41, 0x00, 0x00],
    "R": [0x7F, 0x09, 0x19, 0x29, 0x46, 0x00],
    "L": [0x7F, 0x40, 0x40, 0x40, 0x40, 0x00],
    "P": [0x7F, 0x09, 0x09, 0x09, 0x06, 0x00],
    "O": [0x3E, 0x41, 0x41, 0x41, 0x3E, 0x00],
    ".": [0x00, 0x60, 0x60, 0x00, 0x00, 0x00],
    ">": [0x00, 0x41, 0x22, 0x14, 0x08, 0x00],
]

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 深色 squircle 底 + 细描边
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                      xRadius: 229, yRadius: 229)
NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); bg.fill()
NSColor(calibratedWhite: 0.30, alpha: 1).setStroke(); bg.lineWidth = 5; bg.stroke()

let dot: CGFloat = 18, gap: CGFloat = 7
let unit = dot + gap
let rows = 8, cols = 6   // 每字符 8 行 6 列(5 列字面 + 1 空隙)

func putDot(_ x: CGFloat, _ y: CGFloat) {
    let p = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: dot, height: dot),
                         xRadius: 4, yRadius: 4)
    white.setFill(); p.fill()
}

func drawText(_ text: String, at origin: NSPoint) {
    for (gi, ch) in text.uppercased().enumerated() {
        guard let g = glyphs[ch] else { continue }
        for c in 0..<6 {
            for r in 0..<8 where g[c] & (1 << UInt8(r)) != 0 {
                putDot(origin.x + CGFloat(gi * cols + c) * unit + gap / 2,
                       origin.y + CGFloat(7 - r) * unit + gap / 2)
            }
        }
    }
}

let lineW = CGFloat(6 * cols) * unit   // 每行 6 字符
let lineH = 8 * unit
let lineGap: CGFloat = unit            // 两行之间的空隙
let totalH = lineH * 2 + lineGap
let tx = (S - lineW) / 2
let ty = (S - totalH) / 2

drawText("<Whirl", at: NSPoint(x: tx, y: ty + lineH + lineGap))
drawText(" Pool.", at: NSPoint(x: tx, y: ty))
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("png encode failed") }
let out = URL(fileURLWithPath: outDir).appendingPathComponent("whirlpool_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
