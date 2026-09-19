import Foundation

/// WHIRLPOOL_SOCKET 仅供开发:让调试实例与已安装实例并存
let socketPath = ProcessInfo.processInfo.environment["WHIRLPOOL_SOCKET"] ?? "/tmp/whirlpool-\(getuid()).sock"

/// 给套接字设收发超时,避免对端卡死时把本进程也拖住
func setSocketTimeouts(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
}

/// 读一条请求:读到换行或对端关闭为止,上限 64KB
func readRequest(_ fd: Int32) -> String? {
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < 65_536 {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<n])
        if buffer[0..<n].contains(0x0A) { break }
    }
    guard !data.isEmpty else { return nil }
    return String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runSocketServer(onMessage: @escaping (TickerMessage) -> String) {
    DispatchQueue.global(qos: .background).async {
        unlink(socketPath)

        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(serverFd); return }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        listen(serverFd, 8)

        // No accept() timeout: the loop has no exit condition, so a timeout would
        // only wake the thread once per second to continue. Blocking accept() lets
        // it sleep until a client actually connects.
        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &len)
                }
            }
            guard clientFd >= 0 else {
                // EINTR 直接重试;其余错误(如 EMFILE)歇 100ms,别空转吃满一个核
                if errno != EINTR { usleep(100_000) }
                continue
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(clientFd, &uid, &gid) == 0, uid == getuid() else { close(clientFd); continue }
            setSocketTimeouts(clientFd, seconds: 5)

            if let raw = readRequest(clientFd), let msg = decodeSocketMessage(raw) {
                let reply = onMessage(msg)
                reply.withCString { _ = send(clientFd, $0, strlen($0), 0) }
            } else {
                _ = "error".withCString { send(clientFd, $0, 5, 0) }
            }
            close(clientFd)
        }
    }
}

// ── CLI send ───────────────────────────────────────────────────────────────────

/// 发一条消息,失败返回 false(不退出进程)
@discardableResult
func cliTrySend(_ msg: TickerMessage) -> Bool {
    guard FileManager.default.fileExists(atPath: socketPath) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
    guard connected else { return false }
    setSocketTimeouts(fd, seconds: 5)
    (encodeSocketMessage(msg) + "\n").withCString { _ = send(fd, $0, strlen($0), 0) }
    shutdown(fd, SHUT_WR)
    _ = readRequest(fd)
    return true
}

func cliSend(_ msg: TickerMessage) {
    guard FileManager.default.fileExists(atPath: socketPath) else {
        fputs("Error: whirlpool is not running.\n", stderr)
        exit(1)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
    guard connected else {
        close(fd)
        fputs("Error: whirlpool is not running.\n", stderr)
        exit(1)
    }
    setSocketTimeouts(fd, seconds: 5)
    let payload = encodeSocketMessage(msg) + "\n"
    payload.withCString { _ = send(fd, $0, strlen($0), 0) }
    shutdown(fd, SHUT_WR)
    if let resp = readRequest(fd) { print(resp) }
    close(fd)
}

/// 询问运行实例的 pid(旧版本不回 pid 时返回 nil)
func runningInstancePID() -> pid_t? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    socketPath.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
    guard ok else { return nil }
    setSocketTimeouts(fd, seconds: 2)
    "{\"type\":\"get_status\"}\n".withCString { _ = send(fd, $0, strlen($0), 0) }
    shutdown(fd, SHUT_WR)
    guard let reply = readRequest(fd), let data = reply.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pid = obj["pid"] as? Int else { return nil }
    return pid_t(pid)
}
