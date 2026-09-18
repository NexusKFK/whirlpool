// 画 Pinwheel 图标:深色 squircle 底 + 白色 "<SPX" LED 点阵 + 四角 L 形点阵角括号
// 用法: swift tools/make-pinwheel-icon.swift [输出目录 icons]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons"
let S: CGFloat = 1024
let white = NSColor.white

let glyphs: [Character: [UInt8]] = [
    "<": [0x08, 0x14, 0x22, 0x41, 0x00, 0x00],
    "S": [0x46, 0x49, 0x49, 0x49, 0x31, 0x00],
    "P": [0x7F, 0x09, 0x09, 0x09, 0x06, 0x00],
    "X": [0x63, 0x14, 0x08, 0x14, 0x63, 0x00],
]

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 深色 squircle 底 + 细描边
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                      xRadius: 229, yRadius: 229)
NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); bg.fill()
NSColor(calibratedWhite: 0.30, alpha: 1).setStroke(); bg.lineWidth = 5; bg.stroke()

// 点阵尺寸:4 字 × 6 列 = 24 列,8 行
let dot: CGFloat = 20, gap: CGFloat = 8
let unit = dot + gap
let totalW = 24 * unit, totalH = 8 * unit

func putDot(_ x: CGFloat, _ y: CGFloat) {
    let p = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: dot, height: dot),
                         xRadius: 4, yRadius: 4)
    white.setFill(); p.fill()
}

// 画点(bit 0 = 顶行)
let text = Array("<SPX")
let tx = (S - totalW) / 2, ty = (S - totalH) / 2
for (gi, ch) in text.enumerated() {
    guard let g = glyphs[ch] else { continue }
    for c in 0..<6 {
        for r in 0..<8 where g[c] & (1 << UInt8(r)) != 0 {
            putDot(tx + CGFloat(gi * 6 + c) * unit + gap / 2,
                   ty + CGFloat(7 - r) * unit + gap / 2)
        }
    }
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("png encode failed") }
let out = URL(fileURLWithPath: outDir).appendingPathComponent("pinwheel_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
