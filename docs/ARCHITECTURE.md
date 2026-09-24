# Architecture

## macOS

`AppDelegate` coordinates the menu-bar renderer, `BarWindow`, and `BoardWindow`. All displays access one `QuoteService`, which coalesces concurrent requests, caches the last successful quote per symbol, and enforces freshness/backoff. `RealProvider` parses Yahoo/Tencent responses through a bounded `QuoteHTTPClient`. `DemoProvider` produces explicitly labeled local simulated data.

The scroll stream is precompiled into LED columns (or measured text at 3 pt per virtual column). `MarqueeEngine` drives a timeline instead of a per-column tick: each motion segment (to the next in-stream pause or the end of the round) is a linear Core Animation on the `track` layer of every `MarqueeView`, and zero-tolerance timers fire only at events — pauses, changed-digit flashes, prefetch and round end. `MarqueeView` holds a clipped viewport with a gradient fade mask, a `CAReplicatorLayer` that repeats one copy of the round for seamless wrap, texture tiles (≤ 8192 px each) and one overlay per changed-digit group whose opacity pulses once. The app process therefore does no per-frame drawing; the render server composites at the display refresh rate.

`PriceFlash` finds the highest changed digit and retains the entire suffix. `MarqueeEngine.flashStartCol` reproduces the per-column readability rule of `ScrollFlashes` (a group flashes once, when it is fully inside the viewport minus the fade insets), and the regression suite checks both agree.

Colors are semantic (`LEDColor`) and resolved per surface by `LEDStyle` in `Theme.swift`: tone from the surface's effective appearance (the menu bar follows its own light/dark appearance, the floating bar follows the system), monochrome for the "Monochrome" scheme, and a fixed dark palette for the black LED panel. Strips are rendered in sRGB so the compositor never color-converts per frame. The LED dot size is a runtime setting (`ledDotSize` 1–3 in `TickerConfig`, geometry in `LEDLayout`); the menu bar clamps Large to Medium, the floating bar uses the full tier, and the engine keeps both surfaces column-synchronized.

`MarketClock` models exchange calendars for the optional smart refresh: NYSE holidays and early closes from the exchange rules, China A-share and HKEX closures/half days from the official tables (one entry per published year; unpublished years fall back to weekdays open), plus a live override from quote timestamps. Yahoo symbols map to a calendar by suffix (none = NYSE, `.HK`, `.SS`/`.SZ`); other venues have no modeled calendar and never count as closed. It also builds chart links. Price precision is resolved per instrument (`QuoteEngine.decimals`: row override → provider hint → market tick rule → 2). Watchlists are named lists with an active index; the legacy `watchlist` key is still written for older versions. `UpdateChecker` polls GitHub's latest release at most once a day.

`ConfigWindowController` edits a draft. Validation runs before atomic persistence and hot application. `TickerConfig` defaults missing fields instead of discarding the user's watchlist. `Localization.swift` is generated from the shared JSON catalog. macOS keeps its historical configuration path.

## Windows

The preview uses .NET 10 with a platform-independent `Whirlpool.Core` project and a Windows Forms shell. The application context owns the notification-area icon, one `QuoteFeed`, and the ticker/board/settings windows. Core logic (settings and migration, `MarketClock`, precision, `UpdateChecker`, provider parsing) is exercised on macOS by `Whirlpool.Core.Tests`; window execution requires Windows.

The Windows ticker reuses the bitmap glyphs (`Shared/font.json`, generated from `FontData.swift`). Each round is rendered once into a strip bitmap and a frame only blits the visible slice, the changed-digit overlays and the edge fades. The board is a native read-only table with suffix-only price painting. Colors come from the same semantic palette as macOS, resolved from the Windows app mode (or a fixed light/dark choice); the board gets a dark title bar and the ticker Windows 11 rounded corners. China/Hong Kong quotes are one batched Tencent request; Yahoo uses the 1-day summary. Polling and animation stop while the machine sleeps or the session is locked. No UI thread waits on network I/O.

Two native UIs intentionally follow their host OS conventions. Shared localization and equivalent regression fixtures keep price behavior consistent. Windows does not attempt to inject content into the taskbar and currently omits the macOS CLI and board mini charts.

## Known limits

The public quote endpoints have no availability or freshness guarantee. Each Yahoo symbol is a separate chart request. The configured refresh interval is a lower bound between fetch cycles. Exchange tables for China A-shares and HKEX must be extended each year when the exchanges publish them.

Future work: independently signed releases, and Windows on-device accessibility/multi-monitor validation.
