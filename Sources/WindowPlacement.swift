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
