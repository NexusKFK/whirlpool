import Foundation

/// 控制 socket 放在每用户私有的临时目录(DARWIN_USER_TEMP_DIR,0700):
/// 其他本地用户既连不上,也不能事先占住这个路径让本 app 起不来。
/// WHIRLPOOL_SOCKET 仅供开发:让调试实例与已安装实例并存
let socketPath = ProcessInfo.processInfo.environment["WHIRLPOOL_SOCKET"] ?? defaultSocketPath()

/// 2.0.4 及更早放在全局可写的 /tmp。升级时旧实例可能还在那里监听:启动时据此判断"已在运行",
/// CLI 在新路径找不到实例时也回退到这里(--restart 才能退掉旧实例)。只认同一用户开的实例。
let legacySocketPath = "/tmp/whirlpool-\(getuid()).sock"

/// 客户端依次尝试的路径;开发实例只用自己的 socket
var instanceSocketPaths: [String] {
    ProcessInfo.processInfo.environment["WHIRLPOOL_SOCKET"] != nil || socketPath == legacySocketPath
        ? [socketPath] : [socketPath, legacySocketPath]
}

private func defaultSocketPath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let directory = length > 0 && length <= buffer.count
        ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        : NSTemporaryDirectory()
    let path = (directory as NSString).appendingPathComponent("whirlpool.sock")
    // sun_path 只有 104 字节,放不下就退回旧路径
    return path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) ? path : legacySocketPath
}

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

/// 连上 path 上的实例。对端必须是同一用户的进程:旧 /tmp 路径可能被别的用户抢先占住。
func connectSocket(_ path: String, timeout: Int) -> Int32? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
    path.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strlcpy($0, src, pathSize) }
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
    var uid: uid_t = 0, gid: gid_t = 0
    guard connected, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return nil }
    setSocketTimeouts(fd, seconds: timeout)
    return fd
}

/// 运行中的实例:先找当前路径,再找旧版路径。返回已连上的描述符与路径。
func connectInstance(timeout: Int = 5) -> (fd: Int32, path: String)? {
    for path in instanceSocketPaths {
        if let fd = connectSocket(path, timeout: timeout) { return (fd, path) }
    }
    return nil
}

/// 还有实例接受连接(不发请求;--restart 等旧实例退出时用)
func instanceAcceptsConnections() -> Bool {
    guard let instance = connectInstance(timeout: 1) else { return false }
    close(instance.fd)
    return true
}

/// 发一条请求(补换行)并读回复
func roundTrip(_ fd: Int32, _ payload: String) -> String? {
    (payload + "\n").withCString { _ = send(fd, $0, strlen($0), 0) }
    shutdown(fd, SHUT_WR)
    return readRequest(fd)
}

/// 已有实例在监听时返回它的 socket 路径(发一条合法请求,让对端正常收尾)
func runningInstancePath() -> String? {
    guard let instance = connectInstance(timeout: 2) else { return nil }
    defer { close(instance.fd) }
    _ = roundTrip(instance.fd, "{\"type\":\"get_status\"}")
    return instance.path
}

/// 发一条消息,失败返回 false(不退出进程)
@discardableResult
func cliTrySend(_ msg: TickerMessage) -> Bool {
    guard let instance = connectInstance() else { return false }
    defer { close(instance.fd) }
    _ = roundTrip(instance.fd, encodeSocketMessage(msg))
    return true
}

func cliSend(_ msg: TickerMessage) {
    guard let instance = connectInstance() else {
        fputs("Error: whirlpool is not running.\n", stderr)
        exit(1)
    }
    if let resp = roundTrip(instance.fd, encodeSocketMessage(msg)) { print(resp) }
    close(instance.fd)
}

/// 询问运行实例的 pid(旧版本不回 pid 时返回 nil)
func runningInstancePID() -> pid_t? {
    guard let instance = connectInstance(timeout: 2) else { return nil }
    defer { close(instance.fd) }
    guard let reply = roundTrip(instance.fd, "{\"type\":\"get_status\"}"), let data = reply.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pid = obj["pid"] as? Int else { return nil }
    return pid_t(pid)
}
