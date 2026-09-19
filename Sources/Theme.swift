import AppKit

// ── 明暗自适应配色 ─────────────────────────────────────────────────────────────
//
// 行情色是语义色:white=中性(代码/价格)、green/red=涨跌与换数闪色。
// 每个显示面按自己的实际明暗(菜单栏跟壁纸、浮动条跟系统外观、LED 面板恒暗)
// 解析成具体 RGB:暗底沿用 LED 霓虹原色,亮底换成对白底有足够对比度的深色版本。
// "中性"在暗底是白、亮底是近黑——所以"默认白"在亮色系统里不会再隐形。

enum Tone: Equatable {
    case dark, light

    static func of(_ appearance: NSAppearance) -> Tone {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        return (match == .aqua || match == .vibrantLight) ? .light : .dark
    }
}

/// 外观方案(菜单"外观"与设置页共用)。
enum ColorScheme: String, CaseIterable {
    case adaptive   // 中性色随明暗切换,涨跌保留红绿(默认)
    case mono       // 单色随明暗切换,不着红绿(原"自适应(单色)")
    case amber      // 代码/价格固定琥珀色(经典 LED)
    case green      // 代码/价格固定绿色

    /// 兼容旧配置:auto=旧单色模板;white/black 在新方案里就是自适应中性色
    init(configKey: String) {
        switch configKey.lowercased() {
        case "auto", "mono": self = .mono
        case "amber": self = .amber
        case "green": self = .green
        default: self = .adaptive
        }
    }

    var baseColor: LEDColor {
        switch self {
        case .adaptive, .mono: return .white
        case .amber: return .amber
        case .green: return .green
        }
    }

    var label: String {
        switch self {
        case .adaptive: return L("Adaptive")
        case .mono: return L("Monochrome")
        case .amber: return L("Amber")
        case .green: return L("Green")
        }
    }
}

/// 一个显示面的绘制风格:明暗、是否单色、是否黑底 LED 面板。
struct LEDStyle: Equatable {
    var tone: Tone = .dark
    var mono = false      // 单色:所有点/字统一用中性色,换数闪色无效
    var panel = false     // 黑底面板 + 暗琥珀灭灯点(非透明模式),恒按暗底配色

    var effectiveTone: Tone { panel ? .dark : tone }

    func rgb(_ c: LEDColor) -> (r: Double, g: Double, b: Double) {
        let color = mono ? LEDColor.white : c
        switch (effectiveTone, color) {
        case (.dark, .amber):  return (1.0, 0.55, 0.0)
        case (.dark, .green):  return (0.0, 1.0, 0.25)
        case (.dark, .red):    return (1.0, 0.1, 0.0)
        case (.dark, .white):  return (1.0, 1.0, 1.0)
        case (.dark, .yellow): return (1.0, 0.9, 0.0)
        case (.dark, .black):  return (0.0, 0.0, 0.0)
        // 亮底:对白/浅灰底 ≥3:1 的深色版本,点阵小字也读得清
        case (.light, .amber):  return (0.80, 0.40, 0.0)
        case (.light, .green):  return (0.0, 0.56, 0.20)
        case (.light, .red):    return (0.84, 0.08, 0.04)
        case (.light, .white):  return (0.08, 0.08, 0.09)
        case (.light, .yellow): return (0.62, 0.48, 0.0)
        case (.light, .black):  return (0.0, 0.0, 0.0)
        }
    }

    func nsColor(_ c: LEDColor) -> NSColor {
        let v = rgb(c)
        return NSColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1)
    }

    /// 小端 RGBA 打包(R | G<<8 | B<<16 | A<<24),与位图字节序 R,G,B,A 一致
    func packed(_ c: LEDColor) -> UInt32 {
        let v = rgb(c)
        let r = UInt32(v.r * 255 + 0.5), g = UInt32(v.g * 255 + 0.5), b = UInt32(v.b * 255 + 0.5)
        return r | (g << 8) | (b << 16) | (0xFF << 24)
    }
}

let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
