# Architecture

## macOS

`AppDelegate` coordinates the menu-bar renderer, `BarWindow`, and `BoardWindow`. All displays access one `QuoteService`, which coalesces concurrent requests, caches the last successful quote per symbol, and enforces freshness/backoff. `RealProvider` parses Yahoo/Tencent responses through a bounded `QuoteHTTPClient`. `DemoProvider` produces explicitly labeled local simulated data.

The scroll stream is precompiled into LED columns. `PriceFlash` finds the highest changed digit and retains the entire suffix. `ScrollFlashes` owns one monotonic pulse clock per changed range, starting when the range is readable. No frames are blanked by quote animation. Board rendering shares the same price rule.

The LED dot size is a runtime setting (`ledDotSize` 1–3 in `TickerConfig`, geometry in `LEDLayout`). The menu bar clamps Large to Medium — the status item's host window is about 30 pt tall — while the floating bar uses the full tier; in that case frames are rendered per surface, otherwise one frame is shared. The scroll timer is normalized to physical speed, so changing the dot size does not change how fast quotes scroll. Display width counts characters at the M reference (18 pt per character) and each surface converts its own tier, so the strip's physical width is constant across sizes.

`marqueeFont` switches the scrolling ticker between LED dots, the system font, and a monospaced font (`TextRenderer.swift`). Text mode measures the whole message once into a `TextStrip` image and blits the visible region per frame; it reuses the column-based scroll engine by measuring text at 3 pt per virtual column (the M-tier LED pitch), so pauses, prefetch, wrap, and changed-digit flashes behave identically. Text at the Large tier fits the menu bar, so the per-surface clamp only applies to LED dots. In the monochrome "auto" appearance the frame is a template image and follows light/dark like native menu bar text.

`ConfigWindowController` edits a draft. Validation runs before atomic persistence and hot application. `TickerConfig` defaults missing fields instead of discarding the user's watchlist. `Localization.swift` is generated from the shared JSON catalog. macOS keeps its historical configuration path.

## Windows

The preview uses .NET 10 with a platform-independent `Whirlpool.Core` project and a Windows Forms shell. The application context owns the tray icon, one `QuoteFeed`, and the ticker/board/settings windows. Core logic can be exercised on macOS; window execution requires Windows.

The Windows ticker reuses the bitmap glyphs but has a native rendering/timer implementation. The board is a native read-only table with suffix-only price painting. HTTP requests run asynchronously and serially with spacing, caching, Retry-After, and backoff. No UI thread waits on network I/O.

Two native UIs intentionally follow their host OS conventions. Shared localization and equivalent regression fixtures keep price behavior consistent. Windows does not attempt to inject content into the taskbar and currently omits the macOS CLI and board mini charts.

## Known limits

The public quote endpoints have no availability or freshness guarantee. Each Yahoo symbol is a separate chart request. The configured refresh interval is a lower bound between fetch cycles. All prices currently use two decimals; instruments requiring finer precision need an explicit precision model in a future version.

Future work: exchange-calendar-aware refresh cadence, instrument precision metadata, independently signed releases, and Windows on-device accessibility/multi-monitor validation.
