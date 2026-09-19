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

    // --mode marquee|board|bar|marquee,board|marquee,bar
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
                ?? !FileManager.default.fileExists(atPath: socketPath)
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
          whirlpool --mode marquee|board|bar|marquee,board|marquee,bar
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

// Bereits laufende Instanz erkennen: Socket-Datei vorhanden + connect erfolgreich → exit
if FileManager.default.fileExists(atPath: socketPath) {
    let checkFd = socket(AF_UNIX, SOCK_STREAM, 0)
    if checkFd >= 0 {
        var checkAddr = sockaddr_un()
        checkAddr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: checkAddr.sun_path)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &checkAddr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
        }
        let connected = withUnsafePointer(to: &checkAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(checkFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
        if connected {
            // Gültigen Request senden damit der Server sauber abhandelt;超时防对端卡死
            setSocketTimeouts(checkFd, seconds: 2)
            let ping = "{\"type\":\"get_status\"}\n"
            ping.withCString { _ = send(checkFd, $0, strlen($0), 0) }
            var buf = [UInt8](repeating: 0, count: 256)
            _ = recv(checkFd, &buf, buf.count, 0)
            close(checkFd)
            fputs("whirlpool: already running\n", stderr)
            appLog.notice("second launch exited: another instance owns \(socketPath, privacy: .public)")
            exit(0)
        } else {
            // Veraltete Socket-Datei entfernen
            close(checkFd)
            unlink(socketPath)
        }
    }
}


let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

app.run()
