# Changelog

## 1.6.1

- LED dot size setting (Small / Medium / Large) for the menu bar ticker and the floating ticker bar; scroll speed now follows physical speed, so changing the size does not change how fast quotes scroll.
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
