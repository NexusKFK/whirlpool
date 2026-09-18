# Attribution / 致谢

The macOS LED renderer, bitmap font, scrolling state machine, local socket protocol, and CLI originated in [rhsev/ticker](https://github.com/rhsev/ticker), copyright (c) 2025 Ralf Hülsmann, licensed under MIT. The original license is retained in [LICENSE](LICENSE). The Windows LED glyph table is derived from the same font data.

Pinwheel adds the market-data adapters, watchlist/configuration UI, floating displays, mini charts on macOS, price suffix animations, bilingual UI, caching/backoff, and Windows implementation. The Windows application uses Microsoft's .NET / Windows Forms runtime; self-contained distributions include its applicable third-party notices and licenses.

Yahoo Finance and Tencent are external data providers. Their names and trademarks belong to their owners. Pinwheel is not affiliated with or endorsed by either provider. The repository's MIT license covers software, not provider data or branding. No market data is bundled with a release; demo quotes are generated locally.

中文：macOS 点阵引擎、字形、滚动状态机、本地协议与 CLI 基于 rhsev/ticker 的 MIT 开源代码。Windows 字形沿用同源数据，运行时使用 .NET / Windows Forms。保留原始许可与版权。行情数据和外部品牌的权利不属于本仓库的 MIT 授权范围。
