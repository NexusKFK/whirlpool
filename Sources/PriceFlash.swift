import Foundation

/// A price tick colors the entire suffix from the highest changed place.
/// For 81.20 → 81.30, both digits in "30" belong to the flash.
struct PriceFlash {
    static let duration: TimeInterval = 0.55

    let prefix: String
    let suffix: String
    let color: LEDColor

    static func priceText(_ price: Double, decimals: Int = 2) -> String {
        // 同一品种精度固定(自选设置/行情源提示),不随价格大小变化,否则会藏掉真实跳动
        String(format: "%.\(min(8, max(0, decimals)))f", locale: Locale(identifier: "en_US_POSIX"), price)
    }

    static func between(_ previous: Double?, and current: Double,
                        redUp: Bool, decimals: Int = 2) -> PriceFlash? {
        guard let previous, previous.isFinite, current.isFinite,
              previous != current else { return nil }
        let old = priceText(previous, decimals: decimals)
        let new = priceText(current, decimals: decimals)
        guard old != new else { return nil } // No visible change after rounding.

        let oldChars = Array(old), newChars = Array(new)
        // A carry across the decimal-aligned integer width changes the whole price.
        let start = oldChars.count == newChars.count
            ? zip(oldChars, newChars).prefix(while: { $0.0 == $0.1 }).count
            : 0
        return PriceFlash(prefix: String(newChars.prefix(start)),
                          suffix: String(newChars.dropFirst(start)),
                          color: (current > previous) == redUp ? .red : .green)
    }
}

/// Each changed price gets one pulse when it becomes readable, even when it
/// scrolls into view seconds after the beginning of the quote cycle.
struct ScrollFlashes {
    private struct Group {
        var range: Range<Int>
        let color: LEDColor
        var startedAt: TimeInterval?
    }
    private var groups: [Group] = []

    init(columns: [Int: LEDColor] = [:]) {
        for index in columns.keys.sorted() {
            let color = columns[index]!
            if let last = groups.last, last.range.upperBound == index, last.color == color {
                groups[groups.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                groups.append(Group(range: index..<(index + 1), color: color))
            }
        }
    }

    mutating func colors(offset: Int, visibleColumns: Int, roundLength: Int,
                         now: TimeInterval, edgeInset: Int = edgeFadeCols) -> [Int: LEDColor] {
        guard roundLength > 0, visibleColumns > 0 else { return [:] }
        let visible = offset..<(offset + visibleColumns)
        let inset = min(max(0, edgeInset), (visibleColumns - 1) / 2)
        let readable = (visible.lowerBound + inset)..<(visible.upperBound - inset)
        let copies = max(0, offset / roundLength - 1)...((visible.upperBound - 1) / roundLength)
        var result: [Int: LEDColor] = [:]

        for i in groups.indices {
            let group = groups[i]
            let ranges = copies.map { copy in
                (group.range.lowerBound + copy * roundLength)..<(group.range.upperBound + copy * roundLength)
            }
            if group.startedAt == nil, ranges.contains(where: { range in
                range.overlaps(readable) &&
                    (range.upperBound <= readable.upperBound || range.count > readable.count)
            }) {
                groups[i].startedAt = now
            }
            guard let start = groups[i].startedAt, now - start < PriceFlash.duration else { continue }
            for range in ranges where range.overlaps(visible) {
                for column in max(range.lowerBound, visible.lowerBound)..<min(range.upperBound, visible.upperBound) {
                    result[column] = group.color
                }
            }
        }
        return result
    }
}
