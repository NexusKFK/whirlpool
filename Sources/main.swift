import AppKit
import Foundation

// ── CLI-Modus ──────────────────────────────────────────────────────────────────

if CommandLine.arguments.count > 1 {
    let args = Array(CommandLine.arguments.dropFirst())

    func value(for flags: [String]) -> String? {
        for f in flags {
            if let i = args.firstIndex(of: f), i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }
    func has(_ flags: [String]) -> Bool { flags.contains { args.contains($0) } }

    let text      = value(for: ["--send", "-s",
                                "--urgent", "-u",
                                "--very-urgent", "-vu",
                                "--standby",
                                "--standby-urgent",
                                "--standby-very-urgent"])
    let onClickCmd = value(for: ["--on-click"])
    let duration  = value(for: ["--duration"]).flatMap(Double.init) ?? 5.0
    let width     = value(for: ["--width"]).flatMap(Int.init)

    // --clear
    if has(["--clear"]) {
        let msg = TickerMessage(kind: .clearQueue, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --quit
    if has(["--quit"]) {
        let msg = TickerMessage(kind: .quit, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --status
    if has(["--status"]) {
        let msg = TickerMessage(kind: .getStatus, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --settings — 唤起运行实例的配置窗
    if has(["--settings"]) {
        let msg = TickerMessage(kind: .openSettings, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --width
    if let w = width, text == nil {
        let msg = TickerMessage(kind: .setWidth, text: "", priority: .normal,
                                duration: 0, onClickCommand: nil, width: w)
        cliSend(msg); exit(0)
    }

    // --mode accepts any nonempty comma-separated combination of marquee, bar and board.
    if let mode = value(for: ["--mode"]) {
        let msg = TickerMessage(kind: .setMode, text: mode, priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --list 名称|序号|next|prev — 切换自选池
    if let list = value(for: ["--list"]) {
        let msg = TickerMessage(kind: .setList, text: list, priority: .normal,
                                duration: 0, onClickCommand: nil, width: nil)
        cliSend(msg); exit(0)
    }

    // --restart — 退出运行中的实例并重新拉起(常驻进程不可见时的抓手)。
    // 等旧进程真正退出再拉新的:否则新实例看到旧 socket 还活着会判定"已在运行"而自退,
    // 结果两个都没了。拉起的是本二进制所在的 app 包,不靠 LaunchServices 猜同名 app。
    if has(["--restart"]) {
        let oldPID = runningInstancePID()
        let quitMsg = TickerMessage(kind: .quit, text: "", priority: .normal,
                                    duration: 0, onClickCommand: nil, width: nil)
        // 没在运行就直接启动;在运行则先请它退出
        if cliTrySend(quitMsg) { print("ok") }
        for _ in 0..<100 {   // 最多 10 秒
            let gone = oldPID.map { kill($0, 0) != 0 && errno == ESRCH }
                ?? !instanceAcceptsConnections()
            if gone { break }
            usleep(100_000)
        }
        let bundle = Bundle.main.bundleURL
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = bundle.pathExtension == "app" ? ["-n", bundle.path] : ["-a", "Whirlpool"]
        try? launcher.run()
        launcher.waitUntilExit()
        exit(0)
    }

    guard let txt = text else {
        fputs("""
        Usage:
          whirlpool --send TEXT [--on-click CMD]
          whirlpool --urgent TEXT [--on-click CMD]
          whirlpool --very-urgent TEXT [--on-click CMD]
          whirlpool --standby TEXT --duration N
          whirlpool --standby-urgent TEXT --duration N
          whirlpool --standby-very-urgent TEXT --duration N
          whirlpool --width N
          whirlpool --mode marquee|bar|board|marquee,bar|marquee,board|bar,board|marquee,bar,board
          whirlpool --list NAME|N|next|prev
          whirlpool --settings
          whirlpool --restart
          whirlpool --clear
          whirlpool --status
          whirlpool --quit
        """, stderr)
        exit(1)
    }

    let kind: MessageKind = has(["--standby", "--standby-urgent", "--standby-very-urgent"])
        ? .standby : .scroll

    let priority: Priority
    if      has(["--very-urgent", "-vu", "--standby-very-urgent"]) { priority = .veryUrgent }
    else if has(["--urgent",      "-u",  "--standby-urgent"])      { priority = .urgent }
    else                                                            { priority = .normal }

    let msg = TickerMessage(kind: kind, text: txt, priority: priority,
                            duration: duration, onClickCommand: onClickCmd, width: nil)
    cliSend(msg)
    exit(0)
}

// ── App-Modus ──────────────────────────────────────────────────────────────────

// 已有实例(当前路径,或升级期间旧版的 /tmp 路径;同一用户)在监听 → 退出。
// 当前路径上的残留 socket 文件由 runSocketServer 绑定前清掉;旧路径上自己的残留也顺手删除。
if let owner = runningInstancePath() {
    fputs("whirlpool: already running\n", stderr)
    appLog.notice("second launch exited: another instance owns \(owner, privacy: .public)")
    exit(0)
}
if instanceSocketPaths.contains(legacySocketPath) { unlink(legacySocketPath) }


let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

app.run()
