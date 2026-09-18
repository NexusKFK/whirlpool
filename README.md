<p align="center">
  <img src="icons/whirlpool_1024.png" width="128" alt="Whirlpool">
</p>

<h1 align="center">Whirlpool 涡状星系</h1>

<p align="center">
  <b>A LED stock ticker that lives in your macOS menu bar.</b><br>
  Seamless scrolling quotes · dock-side pixel board · bottom bar for rotated displays.<br>
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

[简体中文](README.zh-CN.md) · English

A quiet desktop ticker for your watchlist. Whirlpool displays a scrolling LED ticker and a compact quote board, with price changes highlighted from the highest changed digit through the end of the price.

## Platforms

| | macOS |
|---|---|
| System integration | Menu bar + floating ticker + quote board |
| Language | English / Simplified Chinese / system default |
| Quotes | Yahoo Finance / Tencent, or clearly labeled demo data |
| Display | LED ticker with three dot sizes; pixel or system-font board; intraday chart |
| Configuration | Native tabbed settings, ordered watchlist |
| Minimum system | macOS 13 |


## Use

On macOS, open `Whirlpool.app`. Right-click the menu-bar ticker, floating ticker, or quote board for **Settings…**. Left-click the menu-bar icon to pause/collapse or resume. Drag floating windows to position them. A small menu-bar icon remains available in board-only mode. Settings are grouped into **Watchlist**, **Display**, and **General**; changes apply after **Save**, while **Cancel** leaves them untouched.


Choose your data source in General. Demo prices are simulated and identified in the status menu. Symbols include `AAPL`, `^GSPC`, `600519`, `00700`, and `BTC-USD`. Stock symbols must be unique. Mainland China codes use six digits; Hong Kong codes use one to five digits and are left-padded for requests.


### Refreshing and rate limits

The default refresh interval is **30 seconds**. All displays share one cached snapshot and one in-flight fetch. The configured interval is the minimum delay between completed fetches, not a promise of streaming market data. Scrolling continues independently; the ticker adopts updated data at its next cycle. A manual refresh does not bypass provider backoff or the five-second minimum between attempts.

Yahoo requests are per symbol. Four symbols every five seconds would be approximately **48 requests/minute / 2,880 per hour**, before retries or other apps sharing the same IP. There is no fixed public allowance that Whirlpool can guarantee. Short intervals can trigger HTTP 429 even if they worked previously. Whirlpool retains the latest known prices, merges partial results, honors `Retry-After`, and backs off from 30 seconds up to 15 minutes on repeated failures. The menu shows unavailable/stale/rate-limited state and the last successful update time. Data may be delayed by its provider or market.

Whirlpool uses native HTTP requests to public Yahoo/Tencent endpoints; it does **not** depend on Python or yfinance. The [yfinance project](https://ranaroussi.github.io/yfinance/) uses related Yahoo endpoints and [handles HTTP 429](https://github.com/ranaroussi/yfinance/blob/main/yfinance/data.py); it is not an official Yahoo service. The application's MIT license does not grant rights to redistribute market data. Review each provider's applicable terms for your use.

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

The app is locally ad-hoc signed. Developer ID signing/notarization requires the maintainer's own Apple credentials and is not supplied by this repository.


## Configuration and privacy

- macOS: `~/.config/whirlpool/config.json` (the existing path is retained for upgrades).
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
whirlpool --clear
whirlpool --quit
```

Messages support `\c[green]` / `\c[]` colors, `\p[3]` pauses, and `\b[1:green]` / `\b[0]` suffix pulses. The socket is per-user at `/tmp/whirlpool-<uid>.sock`, restricted to that user. `--on-click` intentionally executes a local shell command; use only commands you trust. The CLI is not a network service.

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

> 转载 / 二次开发请保留本行出处:Project **Whirlpool 涡状星系** by
> [NexusKFK](https://github.com/NexusKFK) · github.com/NexusKFK/whirlpool
