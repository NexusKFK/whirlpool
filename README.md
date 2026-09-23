<p align="center">
  <img src="icons/whirlpool_1024.png" width="128" alt="Whirlpool">
</p>

<h1 align="center">Whirlpool · WP行情带</h1>

<p align="center">
  <b>A desktop stock ticker for your watchlist.</b><br>
  Seamless scrolling quotes · compact quote board · floating ticker with visual layout controls.<br>
  Free key-less data: Yahoo + Tencent. No subscription, no telemetry.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License GPL-3.0" src="https://img.shields.io/badge/code-GPL--3.0-blue.svg"></a>
  <img alt="CC BY-NC-SA assets" src="https://img.shields.io/badge/assets-CC%20BY--NC--SA%204.0-lightgrey.svg">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-lightblue.svg">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.7-orange.svg">
  <a href="README.zh-CN.md"><img alt="中文文档" src="https://img.shields.io/badge/docs-%E4%B8%AD%E6%96%87-success.svg"></a>
</p>

---

<p align="center">
  <img src="docs/img/whirlpool-demo.gif" width="960" alt="Whirlpool: LED ticker in the menu bar, floating ticker and quote board, in dark and light">
</p>

[简体中文](README.zh-CN.md) · English

A quiet desktop ticker for your watchlist. Whirlpool displays a scrolling LED ticker and a compact quote board, with price changes highlighted from the highest changed digit through the end of the price.

## Platforms

| | macOS | Windows (preview) |
|---|---|---|
| System integration | Menu bar + floating ticker + quote board | Notification-area icon + floating ticker + quote board |
| Language | English / Simplified Chinese / system default | same |
| Quotes | Yahoo Finance / Tencent, or clearly labeled demo data | same |
| Display | LED dots or system-font ticker with three sizes; pixel or system-font board; intraday chart | LED ticker; native board |
| Layout | Independent display cards; desktop preview; anchored or free placement; separate menu-bar width | Ticker/board cards; desktop preview; anchored or free placement |
| Light / dark | Per surface (menu bar, floating ticker, board) | Follows the Windows app mode, or fixed light/dark |
| Watchlists, precision, holidays, updates | Yes | Yes |
| Minimum system | macOS 13 | Windows 10/11 x64 (self-contained, no .NET install) |


## Use

On macOS, open `Whirlpool.app`. Right-click the menu-bar ticker, floating ticker, or quote board for **Settings…**. Left-click the menu-bar icon to pause/collapse or resume. A small menu-bar icon remains available when the menu-bar ticker is off. Whirlpool 2.0 uses a native sidebar with **Watchlist**, **Layout**, **Appearance**, and **General** pages, with visual cards for display areas, fonts, colors, and placement.

On Windows, run `Whirlpool.exe` (no installer). Right-click the notification-area icon, the ticker or the board for the menu; double-click the icon for Settings. The settings tabs are **Layout**, **Appearance**, **Watchlist**, and **General**. Ctrl-click the ticker to switch watchlists; double-click a board row to open its chart. Settings live in `%APPDATA%\Whirlpool\config.json` (settings from the Pinwheel era are copied over once). The Windows build remains a preview; native Windows acceptance is tracked in [docs/WINDOWS-TESTING.md](docs/WINDOWS-TESTING.md).

### Place and size the ticker

- In **Layout**, select the display cards independently: menu-bar ticker, floating ticker, and quote board on macOS; floating ticker and quote board on Windows. Any combination with at least one display enabled is supported.
- Pick a screen and one of six floating-ticker anchors: top or bottom, aligned left, center, or right. Anchors use the available desktop area, clear of the Dock, menu bar, or Windows taskbar, with a small edge margin. Dragging the real ticker switches it to **Free position**; selecting an anchor attaches it to that edge again.
- Set the floating ticker to **20–100%** of the available width, use **¼ / ½ / ⅔ / Fill** presets (**Full width** on Windows), or drag either end of the real ticker. Centered and free tickers grow around their center; left/right anchors keep their aligned edge. Filling the width retains the edge margins. Changing font size does not set the window width.
- On macOS, **Menu bar width** is a separate setting in points. macOS mirrors the same status item, with one shared width, to each screen's menu bar. Whirlpool caps it at 40% of the chosen screen's width (or the primary screen for Automatic); a crowded menu bar can still hide the item, so reduce this setting if necessary.

The desktop preview is a settings draft: drag its ticker or edges to try a layout, then **Save** to apply it. **Cancel** leaves the running layout and saved configuration unchanged. Moving or resizing the real floating ticker applies immediately and is remembered. Existing configurations retain their watchlists and compatible window positions and widths; changing a width control opts that surface into its new independent width setting.

**Lock Floating Windows** stops accidental moves and resizing. **Click Through Floating Ticker** lets clicks reach the windows underneath; turn it off from the menu-bar or notification-area icon to interact with the ticker again. The chosen screen also determines the quote board's default placement; both floating windows can be reset from Layout.

### Appearance and watchlists

On macOS, colors follow the surface they are drawn on: symbols and prices are white on a dark menu bar and near-black on a light one, and red/green switch to darker, contrast-checked shades on light backgrounds (**Appearance → Colors**: Adaptive, Monochrome, Amber, Green). The floating ticker can sit on a glass capsule so it stays readable over light windows. Windows offers System Default, Light, and Dark theme cards in **Appearance**. Hover over a ticker to pause it; double-click a board row (or use **Open Chart** in the menu) to open TradingView/Yahoo.

On macOS, scrolling is GPU-composited: each round is rendered once and Core Animation moves it at the display refresh rate, so the app itself stays near 0% CPU while scrolling.

Keep several named watchlists and switch them from the menu (**Watchlists**), by Option-clicking a ticker on macOS or Ctrl-clicking it on Windows, or with `whirlpool --list NAME` on macOS. Price precision is automatic per instrument (FX 4 decimals, A-share ETFs 3, low-priced crypto more) and can be set per symbol in the Watchlist page.

Choose your data source in General. Demo prices are simulated and identified in the status menu. Symbols include `AAPL`, `^GSPC`, `600519`, `00700`, and `BTC-USD`. Stock symbols must be unique. Mainland China codes use six digits; Hong Kong codes use one to five digits and are left-padded for requests.


### Refreshing and rate limits

The default refresh interval is **30 seconds**. All displays share one cached snapshot and one in-flight fetch. The configured interval is the minimum delay between completed fetches, not a promise of streaming market data. Scrolling continues independently; the ticker adopts updated data at its next cycle. A manual refresh does not bypass provider backoff or the five-second minimum between attempts.

Yahoo requests are per symbol. Four symbols every five seconds would be approximately **48 requests/minute / 2,880 per hour**, before retries or other apps sharing the same IP. With **Refresh slowly while all watched markets are closed** (on by default), Whirlpool stretches the interval while every watched market is outside its session — using exchange calendars with holidays and half days (NYSE rules; China A-share and HKEX tables for the published years; crypto, futures and FX count as always open) — and resumes at the next open. A market whose latest trade is under five minutes old always counts as open. Fetching and scrolling also pause while the screens sleep. There is no fixed public allowance that Whirlpool can guarantee. Short intervals can trigger HTTP 429 even if they worked previously. Whirlpool retains the latest known prices, merges partial results, honors `Retry-After`, and backs off from 30 seconds up to 15 minutes on repeated failures. Failed symbols have their own retry schedule, so one unavailable code does not slow healthy quotes; a full outage or HTTP 429 still backs off the shared feed. The menu shows unavailable/stale/rate-limited state and the last successful update time. Data may be delayed by its provider or market.

Whirlpool uses native HTTP requests to public Yahoo/Tencent endpoints; it does **not** depend on Python or yfinance. The [yfinance project](https://ranaroussi.github.io/yfinance/) uses related Yahoo endpoints and [handles HTTP 429](https://github.com/ranaroussi/yfinance/blob/main/yfinance/data.py); it is not an official Yahoo service. The application's GPL-3.0 license does not grant rights to redistribute market data. Review each provider's applicable terms for your use.

## Build

### macOS

Requires Swift 5.7+ and Apple Command Line Tools or Xcode.

```sh
swift build
.build/debug/whirlpool
bash tools/test-price-flash.sh
bash build-app.sh
# Optional universal app (Apple Silicon + Intel):
bash build-app.sh --arch arm64 --arch x86_64
```

The built app is `.build/apps.noindex/Whirlpool.app`. Install it as `/Applications/Whirlpool.app` and launch the installed copy; development bundles stay outside app discovery. Generated apps and release archives are not tracked in Git.

The app is locally ad-hoc signed. Developer ID signing/notarization requires the maintainer's own Apple credentials and is not supplied by this repository.

### Windows

Requires the .NET 10 SDK (it cross-compiles from macOS or Linux; running the UI requires Windows).

```sh
cd Windows
dotnet run --project Whirlpool.Core.Tests          # platform-independent checks
dotnet publish Whirlpool.Windows -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=none -o ../dist/windows-x64
```

On Windows, `Whirlpool.exe --smoke-test` builds every window in both languages and themes. See [docs/WINDOWS-TESTING.md](docs/WINDOWS-TESTING.md) for the acceptance checklist.


## Configuration and privacy

- macOS: `~/.config/whirlpool/config.json` (the existing path is retained for upgrades).
- Update check: once a day one anonymous request to `api.github.com` for the latest release (turn off in **General → Check for updates automatically**). Nothing is downloaded automatically.
- No account, telemetry, analytics, or cloud sync. Watchlists/settings stay on the device. Requested symbols and network metadata are sent to Yahoo/Tencent when using live data. Demo mode makes no quote requests.
- Saving is atomic. Missing fields receive defaults; malformed files are not silently replaced on startup. No private watchlist/configuration is included in this repository.
- Use **Advanced → Show Configuration File…** on macOS  for the file location.

## macOS CLI

The application binary is also a local client:

```sh
whirlpool --settings
whirlpool --status
whirlpool --send 'TEXT'
whirlpool --urgent 'TEXT'
whirlpool --very-urgent 'TEXT'
whirlpool --standby 'TEXT' --duration 10
whirlpool --width 30
whirlpool --mode marquee,bar,board
whirlpool --list NAME|N|next|prev
whirlpool --clear
whirlpool --restart
whirlpool --quit
```

`--mode` accepts `marquee`, `bar`, `board`, `marquee,bar`, `marquee,board`, `bar,board`, or `marquee,bar,board`. The legacy `--width N` command still temporarily sets both ticker widths in reference character units; use Settings for independent floating and menu-bar widths.

Messages support `\c[green]` / `\c[]` colors, `\p[3]` pauses, and `\b[1:green]` / `\b[0]` suffix pulses. Pause and standby durations are capped at 24 hours; sticky blink counts at 100. Non-finite or negative inline pause values are ignored. The socket is per-user at `/tmp/whirlpool-<uid>.sock`, restricted to that user. `--on-click` intentionally executes a local shell command; use only commands you trust. The CLI is not a network service.

`--status` prints the pid, version, whether the menu bar item is actually visible (macOS hides status items that do not fit next to a long app menu — lower **Layout → Menu bar width** if it disappears) and the live scroll positions. Launches and exits are logged with their reason: `log show --last 1d --predicate 'subsystem == "local.whirlpool"'`.

The app runs as a menu-bar agent and shows no Dock icon by default — **Settings → General → "Show Dock icon"** gives you a visible handle (right-click to quit). From a terminal, the bundled binary works directly: `/Applications/Whirlpool.app/Contents/MacOS/whirlpool --status | --restart | --quit`, or hard-reset with `pkill -x whirlpool && open -a Whirlpool`.

## Project

- [Changelog](CHANGELOG.md)
- [Contributing, translations, and releases](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Original renderer notes](TECHNICAL.md)
- [License](LICENSE) and [attribution](ATTRIBUTION.md)

Built on the MIT-licensed [rhsev/ticker](https://github.com/rhsev/ticker) display engine. Original copyright notices are retained.

## License & Attribution

Code: **GPL-3.0-only** (see [LICENSE](LICENSE)). The LED renderer derives from
[rhsev/ticker](https://github.com/rhsev/ticker) by Ralf Hülsmann — MIT, retained
in [LICENSE-MIT](LICENSE-MIT) per its terms.

App icon, product name and documentation: **CC BY-NC-SA 4.0** — forks and media
coverage are welcome, but keep the attribution; do not rebrand or monetize the
artwork. See [NOTICE.md](NOTICE.md).

> 转载 / 二次开发请保留本行出处:Project **Whirlpool · WP行情带** by
> [NexusKFK](https://github.com/NexusKFK) · github.com/NexusKFK/whirlpool
