# Changelog

## 1.9.1

- Screen choice: **Display → Screen** puts the floating ticker and board on a chosen display (stored by display UUID, so it survives reboots; a disconnected choice is kept and falls back to the main display). macOS mirrors a status item to every screen's menu bar (`NSStatusItemReplicantView`) with one shared width, so the menu bar ticker cannot be limited to one screen; its width is now sized for the chosen (or main) screen instead of whichever screen had keyboard focus, which made it jump between 810 and 450 pt.
- Floating windows: **Lock Floating Windows** (no dragging; menus and hover pause still work) and **Click Through Floating Ticker** (clicks reach the windows below; turn it off from the menu bar icon). Same options on Windows (tray menu).
- Settings: watchlist rows are vertically centered with more row height and column spacing, and the Decimals column no longer overflows the table; the window grows to fit the new options.
- Defaults stay menu-bar-only (`displayMode = marquee`), now covered by tests on both platforms.
- README demo GIF rendered by the app's own renderers (`tools/make-demo-gif.sh`).

中文：新增「显示器」设置——浮动行情条与报价卡显示在所选屏幕（按显示器 UUID 记忆，重启不变；未连接时回落主屏）。macOS 会把状态项镜像到每块屏幕的菜单栏且共用宽度，无法只在一块屏显示菜单栏跑马灯；其宽度改为按所选屏（或主屏）固定计算，不再随键盘焦点在 810/450pt 间跳动。新增「锁定浮窗位置」与「浮动行情条点击穿透」（Windows 同步，在托盘菜单）。设置页自选表格行内垂直居中、加大行高与列距，小数位列不再溢出。默认仍只开菜单栏跑马灯，两端均有测试覆盖。README 新增由 app 渲染代码生成的演示动图。

## 1.9.0

- Exchange holidays in smart refresh: NYSE holidays and 1:00 p.m. early closes are computed from the exchange rules (Easter, weekend observance) and match the official 2026–2027 calendar; China A-share closures (2026, State Council notice, cross-checked day by day against the SZSE trading calendar) and HKEX holidays and half days (2026–2027, HKEX schedule updated 2026-07-31) are built in. HKEX's extended morning session means Hong Kong now counts as open continuously 9:30–16:00. Years without a published calendar fall back to "weekdays are open", and a live safety net treats a market as open whenever its latest trade timestamp is under five minutes old.
- Per-instrument price precision: Auto follows the data source (Yahoo `priceHint`: FX 4, low-priced crypto 5+; A-share ETFs/funds 3 from Tencent's quote), Hong Kong stocks under HK$0.50 get 3 decimals from the tick table, everything else 2. Each watchlist row can override it (Settings → Watchlist → Decimals). Changed-digit flashes compare prices at the same precision, so 4.580 → 4.582 now flashes instead of being rounded away.
- Multiple watchlists: create, rename and delete named lists in Settings; switch from the menu (Watchlists ›), by Option-clicking the menu bar ticker or the floating ticker, or with `whirlpool --list NAME|N|next|prev`. The ticker briefly shows the list name. Old configurations migrate into the first list, and saves keep writing the legacy `watchlist` key so older versions still read the active list.
- Update notices: once a day (and from "Check for Updates…") Whirlpool asks GitHub for the latest release — one anonymous request, can be turned off in General. A newer version appears at the top of the menu and scrolls by once in amber; the manual check offers Download / Later / Skip This Version. Nothing is downloaded or replaced automatically.
- `--status` also reports the active watchlist.
- Windows preview brought to 1.9: renamed to Whirlpool (`Whirlpool.exe`, `%APPDATA%\Whirlpool`, settings copied once from `%APPDATA%\Pinwheel`), light/dark palette following the Windows app mode, multiple watchlists (tray menu, Ctrl-click), per-instrument precision, holiday-aware smart refresh, update notifications, chart links, hover pause, launch at login, pause while asleep/locked, batched Tencent requests, and a ticker that blits a pre-rendered strip instead of filling every dot each frame. Self-contained single-file x64 build; UI acceptance still needs a Windows machine (docs/WINDOWS-TESTING.md).
- Rename leftovers fixed: macOS now really migrates `~/.config/pinwheel/config.json` on first launch (the rebrand commit described this but never implemented it, so upgrading users lost their watchlist); translation keys, the Windows icon generator (pointed at a deleted iconset) and `icons/pinwheel.ico` now use Whirlpool; README/About no longer claim an MIT license (the project is GPL-3.0); `Shared/font.json` regenerated (it lagged behind the macOS glyphs).
- Fixes: `--restart` launches the app when it is not running instead of doing nothing; clicking the Dock icon always opens Settings; the update notice is not marked as shown while the ticker is hidden; a success resets the HTTP 429 backoff counter.

中文补充：Windows 预览版同步到 1.9——改名 Whirlpool（自动迁移 `%APPDATA%\Pinwheel` 配置）、跟随 Windows 亮/暗模式、多自选池（托盘菜单与 Ctrl + 单击）、按品种小数位、节假日智能刷新、更新通知、打开图表、悬停暂停、开机自启、休眠/锁屏暂停、腾讯批量请求、行情条改为贴预渲染位图；自包含单文件 x64，界面仍需在 Windows 上验收。改名遗留修复：macOS 首次启动真正迁移 `~/.config/pinwheel` 配置（改名提交写了但没实现，升级用户会丢自选）、翻译键/图标生成脚本/`pinwheel.ico` 改为 Whirlpool、文档与关于页不再误写 MIT 协议（实为 GPL-3.0）、`font.json` 与 macOS 字库对齐。其他修复：未运行时 `--restart` 直接启动、点 Dock 图标总是打开设置、行情条隐藏时不把更新提示记为已播、请求成功后 429 退避计数归零。

中文：智能刷新加入交易所节假日——美股按 NYSE 规则推算（含复活节、周末顺延、13:00 提前收盘），与官网 2026–2027 日历逐日一致；A 股 2026 休市表（国务院通知，已与深交所交易日历逐日核对）、港股 2026–2027 假期与半日市（港交所 2026-07-31 版）内置；港股延长早市后按 9:30–16:00 连续交易处理；未公布年份按工作日开市兜底，另有实时兜底（最近成交 5 分钟内即视为开市）。按品种设置价格小数位：自动跟随行情源（外汇 4 位、低价币 5 位以上、A 股 ETF 3 位），港股 0.5 元以下按价位表 3 位，自选每行可手动指定；换数闪变按同一精度比较。多套自选池：设置里新建/重命名/删除，菜单、⌥ 单击行情条或 `--list` 快速切换，切换时行情条先亮池名；旧配置自动迁移且仍写旧字段供老版本读取。新版本提示：每天匿名查询一次 GitHub Release（可关闭），有新版时菜单顶部常驻入口、行情条琥珀色滚动提示一次，手动检查可下载/稍后/跳过此版本，不会自动下载或替换。

## 1.8.0

- GPU scrolling: each quote round is rendered once into textures and moved by Core Animation, so the render server composites the ticker at the display refresh rate (120 Hz on ProMotion/120 Hz displays) while the app sleeps between a handful of events per round (in-stream pauses, changed-digit flashes, prefetch, round end). Measured with the same wide dual-surface configuration: app CPU 10.7% → 0.05% of one core, idle wakeups ~40,000 → single digits; WindowServer cost unchanged. No more smoothness-vs-CPU trade-off (see 1.7.1/1.7.2).
- Light and dark: colors are semantic and resolved per surface. The neutral color (symbols and prices) is white on dark menu bars and near-black on light ones; up/down and flash colors switch to contrast-checked darker variants on light backgrounds. New "Colors" setting: Adaptive (default; old "white" configs migrate here), Monochrome (old "Adaptive (monochrome)"), Amber, Green. The quote board redraws its pixel text when the appearance changes.
- Floating ticker: optional glass capsule background (Liquid Glass on macOS 26+, adaptive material before), so it stays readable over light windows; "Transparent" keeps the old look.
- New: hover to pause scrolling; "Open Chart" (TradingView / Yahoo) from the menu, board row double-click or row right-click; Launch at login; smart refresh that backs off while every watched market is closed and resumes at the next open; screens asleep / session switched pauses fetching and scrolling.
- Lighter network use: without the quote board, Yahoo requests use the 1-day summary (≈1.3 KB instead of ≈35 KB per symbol) and Tencent minute bars are skipped.
- Stability: `--restart` waits for the old process to exit before relaunching the same bundle (previously a slow quit could leave nothing running); the single-instance check and CLI use socket timeouts; the socket server no longer spins on accept errors and reads whole requests; the socket file is removed on every exit path. Every launch and exit is logged with its reason (`log show --predicate 'subsystem == "local.whirlpool"'`), including which app sent a Quit event. Closing Settings/About hands focus back so ⌘Q no longer quits the ticker by surprise. `--status` reports pid, version, whether the menu bar item is actually on screen, and the live scroll positions.
- Fixes: menu titles "About/Quit/Settings" were untranslated after the rename; window drags wrote the config file on every move event (now once, 0.5 s after the drag).

中文：跑马灯改为 GPU 合成——一轮行情只在 CPU 上画一次纹理，滚动交给 Core Animation 按屏幕刷新率（120Hz）推进，app 只在暂停、换数闪色、预取、轮尾几个时刻醒来；同配置实测 app CPU 从 10.7% 降到 0.05%，唤醒从约 4 万次降到个位数，滚动更顺。配色改为语义色按显示面明暗解析：代码/价格暗底白、亮底近黑，红绿与闪色在亮底换成对比度达标的深色版；新增「配色」设置（自适应/单色/琥珀/绿色，旧「白色」自动迁移为自适应）。浮动条可选毛玻璃胶囊背板，亮色桌面上也看得清。新增悬停暂停、打开图表、登录时启动、休市放慢刷新、屏幕休眠暂停；纯跑马灯时行情请求瘦身约 26 倍。稳定性：修复 `--restart` 竞态导致两个进程都没了、单实例检测与 CLI 加超时、socket 出错不再空转、所有退出路径清理 socket；每次启动/退出都记录原因（含哪个 app 发来的退出事件）；关闭设置/关于后交还前台，避免 ⌘Q 误退行情。

## 1.7.2

- Restore full-frame-rate scrolling on every surface: 1.7.1's half-rate status-item painting caused visible stutter (2-column jumps). Scrolling smoothness is the contract; the status item instead gets a fixed length synced to its image, avoiding AppKit's per-frame intrinsic-size resolution.
- Honest costs: at very wide settings (55 characters, dual surfaces) full-rate scrolling sustains ~25-30% of one core; it scales down roughly linearly with the width and speed sliders (lower speed = lower frame rate at the same per-frame distance).

中文：恢复所有显示面的全帧率滚动——1.7.1 的状态栏半帧率会带来两列一跳的可见卡顿。滚动流畅度是硬约定；状态项改为固定长度（与图同宽），免去 AppKit 每帧重解内在尺寸。如实说明成本：极宽设置（55 字符、双面同开）下全帧率常驻约 25-30% 单核，随宽度与速度滑块近似线性下降（调慢速度=帧率降低但每帧位移不变，流畅度不变）。

## 1.7.1

- Menu bar load fixes: the status-item surface is capped at 40% of the screen width (the full quote stream belongs to the floating bar) and the per-frame title reset is gone.
- New CLI/socket commands: `--mode` switches display layouts, `--restart` quits and relaunches the resident process.
- New General setting "Show Dock icon" for a visible handle on the running app (right-click to quit); README documents terminal restart paths.

中文：状态栏负载修复——菜单栏面宽度封顶为屏宽 40%（整条行情流属于浮动行情条），去掉每帧 title 重设。新增 `--mode`（切换显示布局）与 `--restart`（退出并重启常驻进程）命令；通用设置新增「在程序坞显示图标」，README 补充终端重启路径。

## 1.7.0

- System-font ticker: the scrolling ticker and the floating bar can now switch from LED dots to the system font or a monospaced font (three sizes apply to both). Colors, pauses, seamless wrap, and changed-digit flashes carry over; in the monochrome "auto" appearance the ticker becomes a template and follows light/dark like native menu bar text.
- Display width is anchored to physical size: switching font sizes no longer changes how wide the strip is; the settings label shows the approximate width in points.

中文：跑马灯与浮动行情条新增系统字体/等宽字体选项（字号三档通用），颜色、暂停、无缝环绕与换数闪变全量保留，单色外观下跟随系统明暗着色；显示宽度改为按物理宽度锚定，切换字号不再改变行情条的实际宽度，设置页标签同时显示近似像素宽度。

## 1.6.1

- LED dot size setting (Small / Medium / Large) for the menu bar ticker and the floating ticker bar; scroll speed now follows physical speed, so changing the size does not change how fast quotes scroll.
- Display width follows physical size across tiers (detailed in 1.7.0).
- The menu bar clamps Large to Medium (the status item window cannot fit it); the floating bar uses the full size in all three tiers.
- Repaired the price regression suite: tests referenced the pre-rename `TickFlash` API and could not compile.

中文：菜单栏跑马灯与浮动行情条新增点阵字号（小 / 中 / 大）；滚动速度按物理速度归一，切换字号不再改变滚动快慢；菜单栏放不下「大」档时自动按「中」档渲染，浮动行情条三档全可用；修复回归测试套件中的旧 API 名称引用。

## 1.6.0

- Native settings organized into Watchlist, Display, and General, with validation and ordering.
- Shared English / Simplified Chinese translations and a persistent system-menu entry.
- Backward-compatible configuration defaults and atomic saves; malformed configurations are preserved.
- Shared quote cache and in-flight requests, bounded HTTP concurrency, Retry-After, exponential failure backoff, and visible quote status.
- Correct left-padding of short Hong Kong symbols and validation of duplicate/invalid symbols.
- Per-user macOS local control socket with owner-only access.
- Windows x64 preview: system tray, LED ticker, native quote board, bilingual settings, and self-contained packaging.
- Dual-platform build workflow, regression checks, open-source documentation and release checklist.

中文：规范双语菜单和分区设置；兼容旧配置并原子保存；合并行情请求、共享缓存、限流退避及状态提示；修复港股补零；增加 Windows x64 预览版与开源构建文档。

## 1.5.2

- Flash the complete suffix from the highest changed price digit, including unchanged lower places.
- Use the direction of the previous quote, independent of daily change.
- Start each scrolling flash when visible, with no blank frames or repeated wrapping pulses.
- Match the quote board behavior and preserve cents above 1,000.

## 1.0.0

- Initial macOS release, derived from the MIT-licensed rhsev/ticker renderer.
