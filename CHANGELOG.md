# Changelog

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
