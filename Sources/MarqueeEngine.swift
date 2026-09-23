import AppKit
import QuartzCore

// ── 跑马灯调度(时间线驱动)────────────────────────────────────────────────────
//
// 旧引擎每列一个 tick(30Hz 持续唤醒 + 每帧 CPU 出图);新引擎按时间线走:
// 一段匀速运动交给 Core Animation,只在事件点(轮内暂停、换数闪色、预取、轮尾)
// 用零容差 Timer 醒来。位置单位仍是"引擎列"(LED 一列 / 文本 3pt 一虚拟列),
// 暂停标记、闪变列、预取时机的语义与旧引擎一致。

/// 一轮滚动的几何(与显示面无关)+ 各显示面出图方法。
struct MarqueeRound {
    let totalCols: Int
    let pauses: [PauseMarker]
    let flashes: [(cols: Range<Int>, color: LEDColor)]
    let makeArt: (MarqueeView) -> StripArt
}

/// 单个待办事件的轻量定时器。零容差、.common 模式(菜单打开时照常走)。
private final class EventClock {
    private var timers: [Timer] = []
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: max(0, delay), repeats: false) { _ in block() }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
        if timers.count > 64 { timers.removeAll { !$0.isValid } }
    }
    func cancelAll() { timers.forEach { $0.invalidate() }; timers = [] }
}

final class MarqueeEngine {

    enum Phase: Equatable { case idle, scrolling, paused, sticky, standby }

    // ── 宿主注入 ──
    var surfaces: () -> [MarqueeView] = { [] }
    var viewportCols: (MarqueeView) -> Int = { _ in 60 }
    var viewportWidth: (MarqueeView) -> CGFloat = { _ in 180 }
    var buildRound: (TickerMessage) -> MarqueeRound? = { _ in nil }
    var stillImage: (TickerMessage?, MarqueeView) -> NSImage? = { _, _ in nil }
    var colsPerSecond: Double = 30
    var defaultPause: Double = 0
    var flashesEnabled = true
    /// 一轮将尽/队列见底:宿主去拉下一轮行情(行情循环开时)
    var onNeedsQuotes: (() -> Void)?
    var loopsQuotes: () -> Bool = { false }
    /// 显示面内容尺寸变化(状态项长度、浮动条宽度要跟)
    var onContentSizeChange: (() -> Void)?

    // ── 状态 ──
    private(set) var phase: Phase = .idle
    private(set) var current: TickerMessage?
    private var queue: [TickerMessage] = []
    private var interrupted: TickerMessage?
    private var round: MarqueeRound?
    private var position: Double = 0            // 运动段起点 / 停驻点(引擎列)
    private var motionStart: CFTimeInterval?    // 非 nil = 正在运动
    private var motionTarget: Double = 0
    private var pauses: [PauseMarker] = []
    private var pauseIndex = 0
    private var firedFlashes = Set<String>()
    private var prefetched = false
    private var held = false
    private var pauseDeadline: CFTimeInterval?
    private var remainingPause: TimeInterval = 0
    private var stickyCommand: String?
    private var stickyWaiting = false
    private let clock = EventClock()
    private var activity: NSObjectProtocol?
    private let maxPending = 3

    var queueCount: Int { queue.count }
    var isWaitingForClick: Bool { phase == .sticky && stickyWaiting }

    // ── 队列 ────────────────────────────────────────────────────────────────

    func enqueue(_ msg: TickerMessage) {
        if queue.count >= maxPending { queue.removeFirst() }
        queue.append(msg)
        startIfIdle()
    }

    func prepend(_ msg: TickerMessage) {
        queue.insert(msg, at: 0)
        startIfIdle()
    }

    /// very-urgent:立刻插播,被打断的消息之后从头重播
    func interrupt(with msg: TickerMessage) {
        if phase == .scrolling || phase == .paused, let current { interrupted = current }
        start(msg)
    }

    func startIfIdle() {
        if phase == .idle { advance() }
    }

    /// 清空一切,回 idle(显示 idle 图标)
    func stop() {
        clock.cancelAll()
        queue.removeAll(); interrupted = nil
        current = nil; round = nil
        motionStart = nil; held = false
        phase = .idle
        endActivity()
        showIdle()
    }

    /// 清掉排队与当前轮,但保留最后一帧(重拉行情期间不闪 idle 图标)
    func clearKeepingFrame() {
        clock.cancelAll()
        queue.removeAll(); interrupted = nil
        if motionStart != nil { position = currentCol }
        motionStart = nil
        for view in surfaces() { view.hold(atCol: position) }
        current = nil; round = nil
        phase = .idle
        endActivity()
    }

    // ── 轮次推进 ────────────────────────────────────────────────────────────

    private func advance(lead: Double = 0) {
        if let saved = interrupted { interrupted = nil; start(saved); return }
        if !queue.isEmpty { start(queue.removeFirst(), lead: lead); return }
        // 行情循环:新数据还没到就把上一轮接着滚(不冻结、不停顿),数据到了下一轮换上
        if let last = current, last.isQuoteCycle, loopsQuotes() {
            start(last, replay: true, lead: lead)
            onNeedsQuotes?()
            return
        }
        phase = .idle
        current = nil; round = nil
        endActivity()
        // 行情循环开着:保留最后一帧等新一轮(不闪 idle 图标);否则回 idle
        if loopsQuotes() { onNeedsQuotes?() } else { showIdle() }
    }

    private func start(_ msg: TickerMessage, replay: Bool = false, lead: Double = 0) {
        clock.cancelAll()
        current = msg
        motionStart = nil
        pauseDeadline = nil; remainingPause = 0
        stickyWaiting = false
        switch msg.kind {
        case .standby:
            round = nil
            phase = .standby
            endActivity()
            for view in surfaces() { view.showStill(stillImage(msg, view)) }
            onContentSizeChange?()
            clock.after(msg.duration) { [weak self] in
                guard let self, self.phase == .standby else { return }
                self.advance()
            }
        case .scroll:
            guard let built = buildRound(msg), built.totalCols > 0 else {
                phase = .idle; current = nil; round = nil
                advance()
                return
            }
            round = built
            var markers = built.pauses.filter { $0.at < built.totalCols }.sorted { $0.at < $1.at }
            if defaultPause > 0, !markers.contains(where: { $0.at == 0 }) {
                markers.insert(PauseMarker(at: 0, kind: .timed(seconds: defaultPause)), at: 0)
            }
            pauses = markers
            pauseIndex = 0
            firedFlashes = []
            if replay || !flashesEnabled {   // 重播轮不重复闪
                for (i, _) in surfaces().enumerated() {
                    for g in built.flashes.indices { firedFlashes.insert("\(i):\(g)") }
                }
            }
            prefetched = !msg.isQuoteCycle
            // 轮尾事件晚到的几毫秒折算成起步位移,轮与轮之间位置连续
            let startAt = markers.first?.at == 0 ? 0 : min(max(0, lead), 3)
            position = startAt
            for view in surfaces() {
                view.load(built.makeArt(view), viewportWidth: viewportWidth(view), atCol: startAt)
            }
            onContentSizeChange?()
            phase = .scrolling
            run()
        default:
            advance()
        }
    }

    /// 从 position 起滚到下一个暂停标记或轮尾
    private func run() {
        guard let round, !held else { return }
        beginActivity()
        phase = .scrolling
        while pauseIndex < pauses.count, Double(pauses[pauseIndex].at) < position { pauseIndex += 1 }
        let target = pauseIndex < pauses.count ? Double(pauses[pauseIndex].at) : Double(round.totalCols)
        fireDueEvents(upTo: position)
        if target <= position { arrive(at: target, expected: CACurrentMediaTime()); return }

        let cps = max(1, colsPerSecond)
        let duration = (target - position) / cps
        let now = CACurrentMediaTime()
        motionStart = now
        motionTarget = target
        for view in surfaces() { view.animate(fromCol: position, toCol: target, duration: duration, beginTime: now) }

        // 段内事件:预取、各显示面的换数闪色
        for (col, action) in pendingEvents() where col > position && col <= target {
            clock.after((col - position) / cps, action)
        }
        let from = position
        clock.after(duration) { [weak self] in
            self?.arrive(at: target, expected: now + (target - from) / cps)
        }
    }

    private func arrive(at col: Double, expected: CFTimeInterval) {
        guard let round else { return }
        position = col
        motionStart = nil
        fireDueEvents(upTo: col)
        if col >= Double(round.totalCols) {
            let late = max(0, CACurrentMediaTime() - expected) * colsPerSecond
            advance(lead: late)
            return
        }
        guard pauseIndex < pauses.count else { run(); return }
        let marker = pauses[pauseIndex]
        pauseIndex += 1
        switch marker.kind {
        case .timed(let seconds):
            pause(for: seconds)
        case .sticky(let cmd, let blinks):
            phase = .sticky
            stickyCommand = cmd
            blink(step: 0, total: blinks * 2)
        }
    }

    private func pause(for seconds: TimeInterval) {
        phase = .paused
        remainingPause = seconds
        guard !held else { return }
        pauseDeadline = CACurrentMediaTime() + seconds
        clock.after(seconds) { [weak self] in
            guard let self else { return }
            self.pauseDeadline = nil; self.remainingPause = 0
            self.run()
        }
    }

    private func blink(step: Int, total: Int) {
        guard step < total else {
            for view in surfaces() { view.setBlank(false) }
            stickyWaiting = true
            endActivity()
            return
        }
        for view in surfaces() { view.setBlank(step % 2 == 0) }
        clock.after(0.4) { [weak self] in self?.blink(step: step + 1, total: total) }
    }

    /// 状态项被点:sticky 等待中则执行 on-click 并继续
    func clickSticky() {
        guard isWaitingForClick else { return }
        if let cmd = stickyCommand {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", cmd]
            try? proc.run()
        }
        stickyWaiting = false
        phase = .scrolling
        run()
    }

    // ── 事件 ────────────────────────────────────────────────────────────────

    /// 本轮所有待触发事件:(触发列, 动作)
    private func pendingEvents() -> [(Double, () -> Void)] {
        guard let round else { return [] }
        var events: [(Double, () -> Void)] = []
        if !prefetched {
            let widest = surfaces().map(viewportCols).max() ?? 0
            let col = max(0, Double(round.totalCols - widest))
            events.append((col, { [weak self] in self?.prefetch() }))
        }
        for (si, view) in surfaces().enumerated() {
            let v = viewportCols(view)
            for (gi, group) in round.flashes.enumerated() where !firedFlashes.contains("\(si):\(gi)") {
                guard let col = Self.flashStartCol(group.cols, roundLength: round.totalCols, viewport: v) else { continue }
                events.append((col, { [weak self, weak view] in
                    guard let self, let view, !self.firedFlashes.contains("\(si):\(gi)") else { return }
                    self.firedFlashes.insert("\(si):\(gi)")
                    view.pulse(flash: gi, duration: PriceFlash.duration)
                }))
            }
        }
        return events
    }

    private func fireDueEvents(upTo col: Double) {
        for (at, action) in pendingEvents() where at <= col { action() }
    }

    private func prefetch() {
        guard !prefetched else { return }
        prefetched = true
        if loopsQuotes() { onNeedsQuotes?() }
    }

    /// 换数段第一次进入可读区(视口去掉两缘渐隐)的滚动位置;与 ScrollFlashes 同一判据。
    /// 第 0 份在起步时已不可读(贴左缘)时,取下一份从右侧进场的时刻。
    static func flashStartCol(_ cols: Range<Int>, roundLength w: Int, viewport v: Int,
                              inset: Int = edgeFadeCols) -> Double? {
        guard w > 0, v > 0, !cols.isEmpty else { return nil }
        let i = min(max(0, inset), (v - 1) / 2)
        let readable = v - 2 * i
        var best: Double?
        for k in 0...1 {
            let a = cols.lowerBound + k * w, b = cols.upperBound + k * w
            let start: Int
            if cols.count > readable {
                start = max(0, a - (v - i) + 1)          // 超长段:一进可读区就闪
                guard start < b - i else { continue }
            } else {
                start = max(0, b - (v - i))              // 整段右缘进入可读区
                guard b - i > start else { continue }    // 起步时已滑出左侧可读区
            }
            guard start <= w else { continue }
            best = min(best ?? .infinity, Double(start))
        }
        return best
    }

    // ── 悬停暂停 / 外观重建 ─────────────────────────────────────────────────

    var currentCol: Double {
        guard let start = motionStart else { return position }
        return min(motionTarget, position + (CACurrentMediaTime() - start) * colsPerSecond)
    }

    func hold() {
        guard !held else { return }
        held = true
        guard phase == .scrolling || phase == .paused else { return }
        if let deadline = pauseDeadline {
            remainingPause = max(0, deadline - CACurrentMediaTime()); pauseDeadline = nil
        }
        clock.cancelAll()
        if motionStart != nil { position = currentCol; motionStart = nil }
        for view in surfaces() { view.hold(atCol: position) }
        endActivity()
    }

    func resume() {
        guard held else { return }
        held = false
        guard phase == .scrolling || phase == .paused else { return }
        beginActivity()
        if phase == .paused && remainingPause > 0 { pause(for: remainingPause) }
        else { run() }
    }

    /// 明暗 / 倍率 / 配色变了:当前轮原位重出纹理,滚动位置与事件不变
    func refreshArt() {
        switch phase {
        case .idle:
            showIdle()
        case .standby:
            for view in surfaces() { view.showStill(stillImage(current, view)) }
        case .scrolling, .paused, .sticky:
            guard let msg = current, let rebuilt = buildRound(msg), rebuilt.totalCols == round?.totalCols else { return }
            round = rebuilt
            let moving = motionStart != nil
            if moving { position = currentCol; motionStart = nil; clock.cancelAll() }
            for view in surfaces() {
                view.load(rebuilt.makeArt(view), viewportWidth: viewportWidth(view), atCol: position)
            }
            onContentSizeChange?()
            if moving { run() }
        }
    }

    func showIdle() {
        for view in surfaces() { view.showStill(stillImage(nil, view)) }
        onContentSizeChange?()
    }

    // ── App Nap:滚动期间别让系统合并定时器(否则轮尾会迟到数秒) ──

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Scrolling quotes")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    var phaseName: String {
        switch phase {
        case .idle: return "idle"
        case .scrolling, .paused: return "scrolling"
        case .sticky: return "sticky"
        case .standby: return "standby"
        }
    }
}
