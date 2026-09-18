# Changelog

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
