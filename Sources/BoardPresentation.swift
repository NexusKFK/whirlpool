import Foundation

/// Quote time and retrieval time are deliberately separate: a successful poll on
/// Sunday must not make Friday's close look like a new trade.
struct BoardStatus {
    let text: String
    let detail: String
    let closedSymbols: Set<String>

    static func make(entries: [WatchEntry], quotes: [String: Quote], provider: String,
                     status: String, checkedAt: Date, now: Date) -> BoardStatus {
        let closed = Set(entries.filter {
            provider != "demo" && !MarketClock.isActive($0, at: now, lastTrade: quotes[$0.symbol]?.marketTime)
        }.map(\.symbol))
        let lastTrade = entries.compactMap { quotes[$0.symbol]?.marketTime }.filter { $0 <= now }.max()
        let quoteTime = lastTrade.map { L("Last quote") + " " + timestamp($0, relativeTo: now) }
        let normal = status == "Updated" || status == "Markets closed · refreshing slowly"
        let allClosed = !entries.isEmpty && closed.count == entries.count
        let text: String
        if normal && allClosed {
            text = L("Markets closed") + " · " + (quoteTime ?? L("Last available quotes"))
        } else if normal {
            text = quoteTime ?? (L("Updated at") + " " + timestamp(checkedAt, relativeTo: now))
        } else {
            // Offline, rate limiting and partial failures must remain visible.
            text = L(status)
        }
        var details = [text]
        if normal && allClosed { details.append(L("Prices and daily changes are retained while markets are closed.")) }
        if status == "Markets closed · refreshing slowly" { details.append(L(status)) }
        if let quoteTime, !text.contains(quoteTime) { details.append(quoteTime) }
        if !quotes.isEmpty { details.append(L("Checked at") + " " + timestamp(checkedAt, relativeTo: now, seconds: true)) }
        return BoardStatus(text: text, detail: details.joined(separator: "\n"), closedSymbols: closed)
    }

    static func timestamp(_ date: Date, relativeTo now: Date, seconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_Hans" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, inSameDayAs: now) ? (seconds ? "HHmmss" : "HHmm") : "MMMdHHmm")
        return formatter.string(from: date)
    }
}
