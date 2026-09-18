# Pinwheel 风车星系

macOS 状态栏行情跑马灯。LED 点阵风格,自选池循环滚动,一轮滚完自动拉新行情再来一轮——风车周而复始地转,和 M101 同名同构。

显示引擎 fork 自 [rhsev/ticker](https://github.com/rhsev/ticker)(MIT,致谢见 ATTRIBUTION.md);本仓新增的是行情层:QuoteEngine + QuoteProvider。

## 快速开始

```bash
swift build
.build/debug/pinwheel        # 直接跑,demo 行情源,无需网络
```

或打包成 app(可拖进应用程序、设登录项):

```bash
./build-app.sh               # → Pinwheel.app,ad-hoc 签名
```

默认 `provider = "demo"`:本地随机游走的假数据,只为了让屏幕上有东西滚。接真实行情见下文。

## 两种显示模式

日常配置走 GUI:菜单 **Configure…**(跑马灯模式点状态栏图标 / 报价卡模式右键卡片,或 CLI `pinwheel --settings`),自选池增删改、切显示模式、调刷新间隔、报价卡归位,保存即热生效。

菜单里 `Mode` 也可直接切换,三种取值:

- **marquee**(默认):状态栏 LED 点阵跑马灯,循环滚动。
- **board**:程序坞两端空位的报价小卡,`boardRefresh` 秒一刷(默认 30)。程序坞本体不容第三方塞内容,浮层小窗占在底部条两端的空白处,视觉上就是坞的延伸。左键整卡拖动(位置自动记忆),右键出菜单(模式切换/编辑配置/退出)。
- **bar**:屏幕下缘的置顶跑马灯条,与状态栏跑马灯同一引擎同一渲染——为竖屏/菜单栏放不下宽条的屏幕准备,拖到哪块屏常驻哪块屏,位置记忆。
- 组合:`displayMode` 支持逗号分隔(如 `marquee,bar` = 大屏菜单栏 + 竖屏底部条同时开),GUI/菜单给五个常用组合。

board 模式下状态栏图标让位;跑马灯模式和 board 各自独立刷新(共用同一个 provider)。

交互约定:菜单栏图标**左键单击=收起/展开**(收起时缩成 `<` 小图标),**右键=菜单**(Configure… 在里面,也可 `pinwheel --settings`);bar/board 左键拖动、右键菜单。图标 = 深底白色 `<SPX` 点阵 + 四角取景括号(tools/make-pinwheel-icon.swift 可重画)。

## 版本

**v1.0.0**(2026-09-18):首个定版——跑马灯/报价卡/底部条三显示可组合、免 key 双数据链(Yahoo+腾讯)、配置 GUI、CLI 遥控、无缝环绕滚动、▲/▼ 涨跌、两缘渐隐。v0.1→v1.0 一天内迭代,全部变更见 git log。

## 配置

`~/.config/pinwheel/config.json`(菜单里也有 "Edit config…"):

| 字段 | 说明 |
|---|---|
| `watchlist` | 自选池,`{"symbol": "AAPL", "market": "us"}`;market 决定涨跌配色习惯 |
| `redUpMarkets` | 这些市场红涨绿跌(默认 cn/hk),其余绿涨红跌 |
| `pausePerSymbol` | >0 时每个标的滚到左缘停留 N 秒(默认 0,连续滚) |
| `defaultWidth` | 跑马灯宽度(字符,8-60),GUI 有滑块;marquee 与 bar 同宽,保存即调 |
| `changeArrows` | 涨跌用 ▲/▼ 三角(默认开,交易所风格;关=+/-号) |
| `marqueeSeparator` | 标的间分隔,默认 3 个空格纯空隙 |
| `provider` | `demo` \| `real` |
| `defaultWidth` | 菜单栏显示宽度(字符数),默认 20 |
| `scrollSpeed` | 每 tick 秒数,默认 0.0222(≈45 列/秒) |
| `quoteLoop` | 行情循环开关(菜单可切) |
| `displayMode` | `marquee` \| `board` \| `both`(菜单 Mode 可切) |
| `boardCorner` | board 卡默认贴程序坞哪端:`left` \| `right` |
| `boardOrigin` | 手动拖动后自动写入的位置,不用手填 |
| `boardRefresh` | board 刷新间隔秒数,默认 30 |

## 行情源

配置 `provider` 二选一:

- **real**(推荐):内置免 key 双链——美股/指数/加密走 Yahoo 公开 chart 端点(yfinance 同源),A股/港股走腾讯 `qt.gtimg.cn` 实时链。任一腿失败不影响另一腿;全挂则空回调,显示层 15s 自动重试。A 股代码按首位自动配 sh/sz 前缀(6/5/9→sh,其余→sz),港股 symbol 自动补零到 5 位。
- **demo**:本地随机游走假数据,无网络依赖。

两条链都免费、无需注册;Yahoo 腿偶发限流(yfinance 同款坑),失败静默重试即可。

## CLI(与上游一致)

同一个二进制,带参数即客户端——外部工具可以往跑马灯推消息:

```bash
pinwheel --send "TEXT"          # 滚一条(支持 \c[green] 等颜色码、\p[3] 暂停码)
pinwheel --urgent TEXT          # 插队
pinwheel --very-urgent TEXT     # 打断当前滚动,播完回放
pinwheel --standby TEXT -d 10   # 静态显示 10 秒
pinwheel --status / --clear / --quit
```

## 设计备注

- 一轮 = 一次刷新:利用引擎现成的 end-of-message 相位,滚完拉新行情重新入队,无闪烁。
- 引擎细节(位图字体、列流预编译、.common RunLoop、直接写像素)见 TECHNICAL.md(上游原文)。
- 字体为 5×7 点阵大写 ASCII,不支持中文/小写——股票代码场景刚好。

## Roadmap

- [x] RealProvider 接真实 API(腾讯 + Yahoo 双链,2026-09-18 验证)
- [ ] 收盘时段自动降频(A股/美股休市时拉取间隔拉长)
- [ ] 与 Shepherd 联动:盯盘提醒直接 `--very-urgent` 推上跑马灯
