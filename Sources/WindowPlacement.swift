import AppKit

/// Reject saved positions that became unreachable after a display was unplugged.
func reachableOrigin(_ saved: [Double]?, size: NSSize) -> NSPoint? {
    guard let saved, saved.count == 2, saved.allSatisfy({ $0.isFinite }) else { return nil }
    let point = NSPoint(x: saved[0], y: saved[1])
    let frame = NSRect(origin: point, size: size)
    return NSScreen.screens.contains { screen in
        let visible = screen.frame.intersection(frame)
        return visible.width >= min(80, size.width) && visible.height >= min(20, size.height)
    } ? point : nil
}

// ── 显示器选择 ─────────────────────────────────────────────────────────────────
// 配置里存显示器 UUID(外接屏的编号重启后可能变,UUID 稳定);"auto" = 不指定。

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// 跨重启稳定的显示器标识
    var stableID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    /// 设置里显示的名字:型号 · 分辨率(点)· 主显示器标记
    var displayLabel: String {
        let size = "\(Int(frame.width))×\(Int(frame.height))"
        let main = self == NSScreen.screens.first ? " · " + L("Main display") : ""
        return "\(localizedName)  \(size)\(main)"
    }
}

/// 配置指定的显示器;"auto" 或当前未连接时为 nil
func chosenScreen(_ key: String) -> NSScreen? {
    key == "auto" ? nil : NSScreen.screens.first { $0.stableID == key }
}

/// 浮窗默认落在哪块屏:指定的屏,否则当前主屏
func placementScreen(_ key: String) -> NSScreen? {
    chosenScreen(key) ?? NSScreen.main ?? NSScreen.screens.first
}
