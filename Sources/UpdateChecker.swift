import Foundation

// ── 新版本检查 ─────────────────────────────────────────────────────────────────
//
// 每天最多一次匿名 GET GitHub Releases latest(只带 User-Agent 里的版本号,不带任何标识),
// 发现更高版本:菜单顶部出现"新版本可用",跑马灯插播一次(每个版本只播一次)。
// 手动"检查更新…"才弹对话框。不自动下载、不替换 app——下载页交给浏览器,装不装由用户定。

final class UpdateChecker {

    struct Release: Equatable {
        let version: String
        let name: String
        let page: URL
    }

    static let endpoint = URL(string: "https://api.github.com/repos/NexusKFK/whirlpool/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/NexusKFK/whirlpool/releases")!

    private static let lastCheckKey = "WhirlpoolLastUpdateCheck"
    private static let skippedKey = "WhirlpoolSkippedVersion"
    private static let announcedKey = "WhirlpoolAnnouncedVersion"
    private static let checkEvery: TimeInterval = 24 * 3600

    let current: String
    private(set) var available: Release?
    /// 自动检查发现新版本(未被跳过)时回调,主线程
    var onAvailable: ((Release) -> Void)?
    private var timer: Timer?
    private let session: URLSession
    private let defaults: UserDefaults

    init(current: String, defaults: UserDefaults = .standard) {
        self.current = current
        self.defaults = defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    // ── 版本号 ──

    /// 取字符串里第一个 x.y[.z](兼容 "v1.6.0-main"、"Whirlpool v1.6.0")
    static func parseVersion(_ text: String) -> [Int]? {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parseVersion(candidate), let b = parseVersion(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parseRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true else { return nil }
        let tag = obj["tag_name"] as? String ?? ""
        let name = obj["name"] as? String ?? tag
        guard let numbers = parseVersion(tag) ?? parseVersion(name) else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: numbers.map(String.init).joined(separator: "."), name: name, page: page)
    }

    // ── 调度 ──

    /// 启动 1 分钟后查一次(若距上次超过一天),之后每 6 小时看一眼是否到期
    func start() {
        guard timer == nil, Self.parseVersion(current) != nil else { return }   // 开发版不查
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func checkIfDue() {
        guard timer != nil else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkEvery else { return }
        check { _ in }
    }

    /// 查一次;completion 在主线程拿到最新 release(没有更新时为 nil)或错误
    func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Whirlpool/\(current)", forHTTPHeaderField: "User-Agent")
        // 请求期间强持有 self(请求结束即释放):调用方没留引用时结果也不会被静默丢掉
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let release = Self.parseRelease(data) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    completion(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])))
                    return
                }
                self.defaults.set(Date(), forKey: Self.lastCheckKey)
                guard Self.isNewer(release.version, than: self.current) else {
                    self.available = nil
                    completion(.success(nil))
                    return
                }
                self.available = release
                completion(.success(release))
                if self.defaults.string(forKey: Self.skippedKey) != release.version {
                    self.onAvailable?(release)
                }
            }
        }.resume()
    }

    func isSkipped(_ release: Release) -> Bool {
        defaults.string(forKey: Self.skippedKey) == release.version
    }

    func skip(_ release: Release) {
        defaults.set(release.version, forKey: Self.skippedKey)
    }

    /// 跑马灯里每个版本只插播一次
    func shouldAnnounce(_ release: Release) -> Bool {
        guard defaults.string(forKey: Self.announcedKey) != release.version else { return false }
        defaults.set(release.version, forKey: Self.announcedKey)
        return true
    }
}
