import AppKit

// 持仓板(positions):贴在屏幕角落的 IBKR 账户悬浮小板,内容对齐 IBKR 手机端默认页。
// 数据来自本机喂料服务(~/tools/ib_live/server.py,只读连 IB Gateway 4001,客户端 ID 93),
// 这里只拉 JSON 画卡片,绝不下单。交互与报价卡一致:整卡拖动(位置落配置)、右键弹菜单。
// 字体用独立的 positionsFont(等宽数字/系统字体)——点阵对密集数字墙不适用,不提供。
final class PortfolioWindow: NSPanel, NSWindowDelegate {

    // ── 喂料数据结构(与 server.py 的 /api/snapshot.json 对应) ─────────────────

    struct Snapshot: Codable {
        let connected: Bool
        let time: String?
        let error: String?
        let account: String?
        let pnl: PnL?
        let summary: [String: Double]?
        let positions: [Position]?
        struct PnL: Codable {
            let daily: Double?
            let unrealized: Double?
            let realized: Double?
        }
        struct Position: Codable {
            let label: String
            let kind: String?          // STK | OPT | SPREAD
            let secType: String?
            let qty: Double
            let last: Double?
            let mktValue: Double?
            let costBasis: Double?
            let unrealized: Double?
            let unrealizedPct: Double?
            let dayPnl: Double?
            let legCount: Int?
            let netCost: Double?       // SPREAD:两腿成本basis合计(含乘数,借方为正)
            let netMark: Double?       // SPREAD:两腿市值合计
        }
    }

    private static let decoder = JSONDecoder()
    static let feederURL = URL(string: "http://127.0.0.1:8899/api/snapshot.json")!

    private let container = NSVisualEffectView()
    private var programmaticMove = false
    private var saveWork: DispatchWorkItem?
    private var lastSnapshot: Snapshot?
    private var lastError: String?

    var config: TickerConfig {
        didSet {
            if oldValue.positionsOrigin != config.positionsOrigin { saveWork?.cancel() }
            isMovableByWindowBackground = !config.lockPosition
            if oldValue.positionsPrivacy != config.positionsPrivacy
                || oldValue.positionsFont != config.positionsFont
                || oldValue.transparentColor != config.transparentColor
                || oldValue.positionsRefresh != config.positionsRefresh {
                rebuild()
            }
        }
    }
    var menuProvider: (() -> NSMenu)?
    var onOriginChange: (([Double]) -> Void)?
    var onTogglePrivacy: (() -> Void)?   // 小眼睛按钮:切换资金金额打码
    /// 默认落点参照(通常是报价卡的 frame):持仓板默认叠在它上方,不重叠
    var referenceFrame: (() -> NSRect)?

    init(config: TickerConfig) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 310, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        delegate = self
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = !config.lockPosition
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        container.material = .underWindowBackground   // 与报价卡同一毛玻璃
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        contentView = container
        rebuild()
    }

    // ── 数据入口(AppDelegate 定时调用) ─────────────────────────────────────────

    func fetch(completion: @escaping () -> Void) {
        var request = URLRequest(url: Self.feederURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        request.setValue("1", forHTTPHeaderField: "X-Whirlpool")   // 喂料服务的本机探针头
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return completion() }
                if let data, let snap = try? Self.decoder.decode(Snapshot.self, from: data) {
                    lastSnapshot = snap
                    lastError = nil
                } else {
                    lastError = L("Feeder starting…")
                        + (error.map { "\n\($0.localizedDescription)" } ?? "")
                }
                rebuild()
                completion()
            }
        }.resume()
    }

    /// 喂料服务不可达(连接被拒/超时)——区别于网关断开,这表示该把进程拉起来了
    var feederDown: Bool { lastError != nil }

    // ── 渲染 ────────────────────────────────────────────────────────────────────

    private func rebuild() {
        container.subviews.forEach { $0.removeFromSuperview() }
        buildContent()
        reposition()
    }

    private func buildContent() {
        let snap = lastSnapshot

        func textLabel(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                       _ color: NSColor = .labelColor, mono: Bool = true) -> NSTextField {
            let font = (mono && config.positionsFont == "mono")
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            let tf = NSTextField(labelWithAttributedString: NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color]))
            tf.maximumNumberOfLines = 1
            tf.lineBreakMode = .byClipping
            tf.sizeToFit()
            return tf
        }
        // 小字说明行:固定小号系统字(与报价卡页脚一致)
        func subLabel(_ text: String, _ size: CGFloat = 10.5, _ color: NSColor = .secondaryLabelColor) -> NSTextField {
            textLabel(text, size, .regular, color, mono: false)
        }
        func tint(_ v: Double?) -> NSColor {
            guard let v, v != 0 else { return .labelColor }
            return v > 0 ? .systemGreen : .systemRed
        }
        let hidden = config.positionsPrivacy
        func money(_ v: Double?, sign: Bool = false) -> String { Self.money(v, sign: sign) }
        func maskIfHidden(_ v: Double?) -> String {
            guard hidden else { return money(v) }
            return "****"
        }

        let inset: CGFloat = 14
        let gap: CGFloat = 10

        // ── 逐行准备内容,先量宽再定板宽 ──
        struct Line { let left: NSView; let right: NSView?; let leftSub: NSView?; let rightSub: NSView?; let h1: CGFloat }
        var lines: [Line] = []

        let positions = snap?.positions ?? []
        let unSum = positions.reduce(0.0) { $0 + ($1.unrealized ?? 0) }

        let todayValue = textLabel(money(snap?.pnl?.daily, sign: true), 17, .semibold, tint(snap?.pnl?.daily))
        let todayLine = Line(left: subLabel(L("Today's P&L"), 11), right: todayValue, leftSub: nil, rightSub: nil, h1: 20)

        // 账户区 2×2:净资产/浮盈亏 一行,可用/现金 一行;隐私开启时四格金额全部打码
        func cell(_ title: String, _ value: Double?, mask: Bool) -> (label: NSView, value: NSView) {
            let text = mask ? maskIfHidden(value) : money(value)
            return (subLabel(title), textLabel(text, 11.5, .medium))
        }
        let cNet = cell(L("Net Liq"), snap?.summary?["NetLiquidation"], mask: true)
        let cUn = cell(L("Unrealized"), unSum, mask: true)
        let cAv = cell(L("Available"), snap?.summary?["AvailableFunds"], mask: true)
        let cCa = cell(L("Cash"), snap?.summary?["TotalCashValue"], mask: true)
        func cellW(_ c: (label: NSView, value: NSView)) -> CGFloat { c.label.frame.width + 6 + c.value.frame.width }
        let col1W = max(cellW(cNet), cellW(cAv))
        let col2W = max(cellW(cUn), cellW(cCa))
        let cellGap: CGFloat = 18

        // 小字一律用开仓成本(现价盯盘交给报价卡):股票均价、期权每张成本、价差净成本
        for p in positions {
            let kind = p.kind ?? p.secType ?? "STK"
            let left = textLabel(p.label, 12, .semibold)
            let right = textLabel(money(p.unrealized, sign: true) + "  " + Self.pct(p.unrealizedPct),
                                  12, .semibold, tint(p.unrealized))
            func avgPerShare(divisor: Double) -> Double? {
                guard let cb = p.costBasis, p.qty != 0 else { return nil }
                return abs(cb / p.qty / divisor)
            }
            var subText: String
            switch kind {
            case "SPREAD":
                subText = String(format: L("Spread · %d legs"), p.legCount ?? 2) + " · "
                    + String(format: L("Net cost %@"), Self.money(p.netCost.map { $0 / 100 }))
            case "OPT":
                let tmpl = p.qty > 0 ? L("%d long") : L("%d short")
                subText = String(format: tmpl, Int(abs(p.qty))) + " · "
                    + L("avg") + " " + money(avgPerShare(divisor: 100))
            default:
                subText = String(format: L("%d shares"), Int(abs(p.qty))) + " · "
                    + L("avg") + " " + money(avgPerShare(divisor: 1))
            }
            let rightSub = p.dayPnl.map {
                subLabel(L("Today") + " " + money($0, sign: true), 10.5, tint($0))
            }
            lines.append(Line(left: left, right: right, leftSub: subLabel(subText), rightSub: rightSub, h1: 16))
        }

        // ── 量宽定板:主行与小字行都参与测宽,放不下就加宽(有上限);再放不下宁可裁小字 ──
        // 组内距小于组间距:小字紧贴自己的主行,两行明显成组,不会看丢归属
        let intraGap: CGFloat = 2
        let interGap: CGFloat = 12
        let rowGap = intraGap + interGap
        func pairWidth(_ line: Line) -> CGFloat {
            let mainW = line.left.frame.width + gap + (line.right?.frame.width ?? 0)
            let subW = (line.leftSub?.frame.width ?? 0) + gap + (line.rightSub?.frame.width ?? 0)
            return max(mainW, subW)
        }
        let maxPairWidth = lines.map(pairWidth).max() ?? 0
        let todayWidth = todayLine.left.frame.width + gap + (todayLine.right?.frame.width ?? 0)
        let gridWidth = inset * 2 + col1W + cellGap + col2W + 2
        let W = min(500, max(310, max(maxPairWidth, todayWidth, gridWidth)))
        let subH: CGFloat = 13.5
        var H: CGFloat = 0
        H += 24                          // 头部:账户名
        H += 26                          // 今日盈亏
        H += 2 * 16 + 6                  // 账户区两行
        H += 14                          // 分隔线
        H += CGFloat(lines.count) * (16 + subH + rowGap)
        H += 22                          // 页脚:开盘状态 + 更新时间
        programmaticMove = true
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: H), display: false)
        programmaticMove = false

        func place(_ v: NSView, left: CGFloat? = nil, right: CGFloat? = nil, cy: CGFloat) {
            v.frame.origin = NSPoint(x: left ?? (right.map { $0 - v.frame.width } ?? 0),
                                     y: cy - v.frame.height / 2)
            container.addSubview(v)
        }

        var cy = H - 12
        place(subLabel("IBKR " + (snap?.account.map { Self.maskAcct($0) } ?? "…"), 11, .labelColor),
              left: inset, cy: cy - 6)
        // 右上角小眼睛:当前打码时显示划线眼,点击切换;与右键菜单同一开关
        let eyeSymbol = config.positionsPrivacy ? "eye.slash" : "eye"
        if let icon = NSImage(systemSymbolName: eyeSymbol, accessibilityDescription: L("Hide Cash Amounts")) {
            let eye = NSButton(image: icon, target: self, action: #selector(eyeTapped))
            eye.isBordered = false
            eye.imageScaling = .scaleProportionallyDown
            eye.contentTintColor = .secondaryLabelColor
            eye.toolTip = L("Hide Cash Amounts")
            eye.frame = NSRect(x: W - inset - 26, y: cy - 14, width: 26, height: 17)
            container.addSubview(eye)
        }
        cy -= 24
        place(todayLine.left, left: inset, cy: cy - todayLine.h1 / 2)
        place(todayLine.right!, right: W - inset, cy: cy - todayLine.h1 / 2)
        cy -= todayLine.h1 + 6
        for row in [(cNet, cUn), (cAv, cCa)] {
            for (cellX, c) in [(inset, row.0), (inset + col1W + cellGap, row.1)] {
                place(c.label, left: cellX, cy: cy - 8)
                c.value.frame.origin = NSPoint(x: cellX + c.label.frame.width + 6,
                                               y: cy - 8 - c.value.frame.height / 2)
                container.addSubview(c.value)
            }
            cy -= 17
        }
        cy -= 3
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: inset, y: cy - 4, width: W - inset * 2, height: 4)
        container.addSubview(sep)
        cy -= 10

        if lines.isEmpty {
            let placeholder = lastError != nil ? "" : (snap == nil ? L("Loading IBKR snapshot…") : L("No positions"))
            if !placeholder.isEmpty { place(subLabel(placeholder, 11), left: inset, cy: cy - 8) }
        }
        for line in lines {
            place(line.left, left: inset, cy: cy - line.h1 / 2)
            if let r = line.right { place(r, right: W - inset, cy: cy - line.h1 / 2) }
            cy -= line.h1 + intraGap
            if let ls = line.leftSub { place(ls, left: inset, cy: cy - subH / 2) }
            if let rs = line.rightSub { place(rs, right: W - inset, cy: cy - subH / 2) }
            cy -= subH + interGap
        }

        // 页脚照报价卡的写法:开盘状态 + 最后一次数据时间,不放别的
        let footerText: String
        var footerColor = NSColor.secondaryLabelColor
        if let err = lastError {
            footerText = err
            footerColor = .systemOrange
        } else if snap?.connected == false {
            footerText = L("IB Gateway not connected")
            footerColor = .systemOrange
        } else {
            let updated = snap?.time.flatMap { $0.count >= 19 ? String($0.suffix(8)) : nil }
            footerText = Self.usMarketState() + (updated.map { " · " + String(format: L("Updated %@"), $0) } ?? "")
        }
        place(subLabel(footerText, 9.5, footerColor), left: inset, cy: 11)
    }

    /// 美股盘中状态(美东 9:30–16:00、周一至周五)。仅供页脚提示,不是交易日历,节假日照常显示开盘。
    private static func usMarketState() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let wd = c.weekday, let h = c.hour, let m = c.minute else { return L("Market closed") }
        let open = wd != 1 && wd != 7 && (h > 9 || (h == 9 && m >= 30)) && h < 16
        return open ? L("Market open") : L("Market closed")
    }

    // ── 位置 ───────────────────────────────────────────────────────────────────

    func reposition() {
        if let origin = reachableOrigin(config.positionsOrigin, size: frame.size) {
            let proposed = NSRect(origin: origin, size: frame.size)
            let screen = NSScreen.screens.max {
                let a = $0.frame.intersection(proposed), b = $1.frame.intersection(proposed)
                return a.width * a.height < b.width * b.height
            }
            programmaticMove = true
            setFrameOrigin(screen.map { constrainedFrame(proposed, inside: $0.frame, margin: 0).origin } ?? origin)
            programmaticMove = false
            return
        }
        guard let screen = placementScreen(config.displayScreen) else { return }
        let f = screen.frame
        var x = f.maxX - frame.width - 12
        var y = f.minY + 12
        // 报价卡在屏上时叠到它上方;放不下再压回屏内
        if let ref = referenceFrame?(), ref.width > 1, ref.intersects(f) {
            x = f.maxX - frame.width - 12
            y = min(ref.maxY + 12, f.maxY - frame.height - 8)
        }
        programmaticMove = true
        setFrameOrigin(NSPoint(x: x, y: y))
        programmaticMove = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        config.positionsOrigin = [Double(frame.origin.x), Double(frame.origin.y)]
        if let origin = config.positionsOrigin { onOriginChange?(origin) }
        saveWork?.cancel()
        let origin = config.positionsOrigin
        let work = DispatchWorkItem {
            if configReadError == nil, var current = try? readConfig(at: configURL) {
                current.positionsOrigin = origin
                saveConfig(current)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func eyeTapped() { onTogglePrivacy?() }

    // ── 文本工具 ───────────────────────────────────────────────────────────────

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    static func money(_ v: Double?, sign: Bool = false, plain: Bool = false) -> String {
        guard let v, v.isFinite else { return "—" }
        let body = grouping.string(from: NSNumber(value: abs(v))) ?? String(format: "%.2f", abs(v))
        let neg = v < 0 ? (plain ? "-" : "−") : (sign ? "+" : "")
        return neg + (plain ? "" : "$") + body
    }

    static func pct(_ v: Double?, plain: Bool = false) -> String {
        guard let v, v.isFinite else { return "—" }
        let sign = v > 0 ? "+" : v < 0 ? (plain ? "-" : "−") : ""
        return sign + String(format: "%.1f", abs(v)) + "%"
    }

    private static func maskAcct(_ a: String) -> String {
        a.count <= 4 ? a : String(a.prefix(1)) + "···" + String(a.suffix(4))
    }
}
