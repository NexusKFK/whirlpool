import Foundation

// 真实行情源模板 — 把你的 API 接到 fetch() 里即可,其余都是现成的。
//
// 本机已验证过的两条免费链(参考,不强制):
//   A股  腾讯:  https://qt.gtimg.cn/q=sh600519,sz510300        响应为 GBK 编码文本
//   美股  Yahoo: https://query1.finance.yahoo.com/v8/finance/chart/AAPL?interval=1m&range=1d
//               (Yahoo 偶尔要求 UA 头;请求失败时保持空回调即可,跑马灯会停在 idle 等下一轮)
//
// 注意:
//  - completion 必须被调用(空字典 = 本轮放弃),否则循环会卡死;
//  - 可以在任意线程回调,AppDelegate 会切回主线程;
//  - 轮询节奏不用自己控:一轮滚动结束才会触发下一次拉取。

final class RealProvider: QuoteProvider {
    var name: String { "real" }

    func quotes(for entries: [WatchEntry], completion: @escaping ([String: Quote]) -> Void) {
        // TODO: 按 entries 分市场请求 → 解析成 [String: Quote] → completion(quotes)
        // 解析失败/超时一律 completion([:])
        completion([:])
    }
}
