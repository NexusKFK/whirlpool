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
    chosenScreen(key) ?? NSScreen.screens.first ?? NSScreen.main
}

/// Keep a resized floating window inside its display, including displays left of the primary one.
func constrainedFrame(_ frame: NSRect, inside area: NSRect, margin: CGFloat = 8) -> NSRect {
    var result = frame
    result.origin.x = min(max(frame.minX, area.minX + margin), max(area.minX + margin, area.maxX - frame.width - margin))
    result.origin.y = min(max(frame.minY, area.minY + margin), max(area.minY + margin, area.maxY - frame.height - margin))
    return result
}

/// Settings and the live status item share the same screen-width cap.
func menuTickerWidth(requested: CGFloat, screenWidth: CGFloat) -> CGFloat {
    max(120, min(requested, screenWidth * 0.40))
}

/// Percentage widths describe the complete capsule, including its background padding.
func floatingTickerWidth(fraction: Double?, legacyWidth: CGFloat, inside area: NSRect, margin: CGFloat = 12) -> CGFloat {
    let available = max(1, area.width - margin * 2)
    guard let fraction, fraction.isFinite else { return min(available, max(1, legacyWidth)) }
    return (available * min(1, max(0.20, fraction))).rounded()
}

/// Anchors are relative to usable desktop space, so neither the Dock nor menu bar covers the ticker.
func anchoredTickerFrame(size: NSSize, placement: String, inside area: NSRect, margin: CGFloat = 12) -> NSRect {
    let left = area.minX + margin, right = area.maxX - margin - size.width
    let x = placement.hasSuffix("-left") ? left
        : placement.hasSuffix("-right") ? right : area.midX - size.width / 2
    let y = placement.hasPrefix("top-") ? area.maxY - margin - size.height : area.minY + margin
    return constrainedFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), inside: area, margin: margin)
}

/// A centered (or free) ticker grows about its center. Side anchors remain fixed as width changes.
func resizedTickerWidth(startWidth: CGFloat, delta: CGFloat, leftEdge: Bool, placement: String) -> CGFloat {
    let symmetric = placement == "free" || placement.hasSuffix("-center")
    return startWidth + delta * (leftEdge ? -1 : 1) * (symmetric ? 2 : 1)
}
