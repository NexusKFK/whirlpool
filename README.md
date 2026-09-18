# Pinwheel

[简体中文](README.zh-CN.md) · English

A quiet desktop ticker for your watchlist. Pinwheel displays a scrolling LED ticker and a compact quote board, with price changes highlighted from the highest changed digit through the end of the price.

## Platforms

| | macOS | Windows preview |
|---|---|---|
| System integration | Menu bar + floating ticker + quote board | System tray + floating ticker + quote board |
| Language | English / Simplified Chinese / system default | English / Simplified Chinese / system default |
| Quotes | Yahoo Finance / Tencent, or clearly labeled demo data | Yahoo Finance / Tencent, or clearly labeled demo data |
| Display | LED ticker; pixel or system-font board; intraday chart | LED ticker; native quote list |
| Configuration | Native tabbed settings, ordered watchlist | Native tabbed settings, ordered watchlist |
| Minimum system | macOS 13 | Windows 10/11 x64 with .NET 10 OS support |

Windows is a preview port. A successful cross-build and core tests do **not** constitute Windows GUI validation. See [the Windows test checklist](docs/WINDOWS-TESTING.md). The macOS CLI and mini charts are not included in the Windows preview.

## Use

On macOS, open `Pinwheel.app`. Right-click the menu-bar ticker, floating ticker, or quote board for **Settings…**. Left-click the menu-bar icon to pause/collapse or resume. Drag floating windows to position them. A small menu-bar icon remains available in board-only mode. Settings are grouped into **Watchlist**, **Display**, and **General**; changes apply after **Save**, while **Cancel** leaves them untouched.

On Windows, extract the whole ZIP, run `Pinwheel.exe`, and use its system-tray menu. The portable build includes its runtime; no separate .NET installation is needed. Drag the floating ticker with the left mouse button. Closing the quote board hides it; **Quit Pinwheel** in the tray menu exits the app.

Choose your data source in General. Demo prices are simulated and identified in the status menu. Symbols include `AAPL`, `^GSPC`, `600519`, `00700`, and `BTC-USD`. Stock symbols must be unique. Mainland China codes use six digits; Hong Kong codes use one to five digits and are left-padded for requests.

### Price flashes

`81.20 → 81.30` flashes **30**, including the unchanged final zero. Color follows the previous quote rather than the daily percentage change. The pulse lasts 0.55 seconds, then restores the original text color. Each scrolling suffix starts its own pulse when readable; wrapping does not replay a pulse. First quotes and changes hidden by rounding do not flash. Prices retain two decimal places, including above 1,000. Market color preferences apply to both quote direction and daily change.

### Refreshing and rate limits

The default refresh interval is **30 seconds**. All displays share one cached snapshot and one in-flight fetch. The configured interval is the minimum delay between completed fetches, not a promise of streaming market data. Scrolling continues independently; the ticker adopts updated data at its next cycle. A manual refresh does not bypass provider backoff or the five-second minimum between attempts.

Yahoo requests are per symbol. Four symbols every five seconds would be approximately **48 requests/minute / 2,880 per hour**, before retries or other apps sharing the same IP. There is no fixed public allowance that Pinwheel can guarantee. Short intervals can trigger HTTP 429 even if they worked previously. Pinwheel retains the latest known prices, merges partial results, honors `Retry-After`, and backs off from 30 seconds up to 15 minutes on repeated failures. The menu shows unavailable/stale/rate-limited state and the last successful update time. Data may be delayed by its provider or market.

Pinwheel uses native HTTP requests to public Yahoo/Tencent endpoints; it does **not** depend on Python or yfinance. The [yfinance project](https://ranaroussi.github.io/yfinance/) uses related Yahoo endpoints and [handles HTTP 429](https://github.com/ranaroussi/yfinance/blob/main/yfinance/data.py); it is not an official Yahoo service. The application's MIT license does not grant rights to redistribute market data. Review each provider's applicable terms for your use.

## Build

### macOS

Requires Swift 5.7+ and Apple Command Line Tools or Xcode.

```sh
swift build
.build/debug/pinwheel
bash tools/test-price-flash.sh
bash build-app.sh
# Optional universal app (Apple Silicon + Intel):
bash build-app.sh --arch arm64 --arch x86_64
```

The app is locally ad-hoc signed. Developer ID signing/notarization requires the maintainer's own Apple credentials and is not supplied by this repository.

### Windows (also cross-buildable from macOS/Linux)

Requires the .NET 10 SDK **for building**. The shipped app includes its runtime.

```sh
dotnet run --project Windows/Pinwheel.Core.Tests -c Release
dotnet publish Windows/Pinwheel.Windows -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -o dist/windows-x64
```

`EnableWindowsTargeting` is set in the Windows project. GUI execution still requires Windows. The GitHub Actions workflow builds both platforms, runs core tests, and includes a Windows control-creation/render smoke test. Local release packaging is described in [CONTRIBUTING.md](CONTRIBUTING.md).

## Configuration and privacy

- macOS: `~/.config/pinwheel/config.json` (the existing path is retained for upgrades).
- Windows: `%APPDATA%\Pinwheel\config.json`.
- No account, telemetry, analytics, or cloud sync. Watchlists/settings stay on the device. Requested symbols and network metadata are sent to Yahoo/Tencent when using live data. Demo mode makes no quote requests.
- Saving is atomic. Missing fields receive defaults; malformed files are not silently replaced on startup. No private watchlist/configuration is included in this repository.
- Use **Advanced → Show Configuration File…** on macOS or **Show Configuration File…** in the Windows tray menu for the file location.

## macOS CLI

The application binary is also a local client:

```sh
pinwheel --settings
pinwheel --status
pinwheel --send 'TEXT'
pinwheel --urgent 'TEXT'
pinwheel --very-urgent 'TEXT'
pinwheel --standby 'TEXT' --duration 10
pinwheel --width 30
pinwheel --clear
pinwheel --quit
```

Messages support `\c[green]` / `\c[]` colors, `\p[3]` pauses, and `\b[1:green]` / `\b[0]` suffix pulses. The socket is per-user at `/tmp/pinwheel-<uid>.sock`, restricted to that user. `--on-click` intentionally executes a local shell command; use only commands you trust. The CLI is not a network service.

## Project

- [Changelog](CHANGELOG.md)
- [Contributing, translations, and releases](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Original renderer notes](TECHNICAL.md)
- [License](LICENSE) and [attribution](ATTRIBUTION.md)

Built on the MIT-licensed [rhsev/ticker](https://github.com/rhsev/ticker) display engine. Original copyright notices are retained.
