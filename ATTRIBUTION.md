# Attribution

显示引擎(LED 点阵渲染、滚动状态机、Unix socket 协议、CLI)fork 自:

- **rhsev/ticker** — https://github.com/rhsev/ticker
- Copyright (c) 2025 Ralf Hülsmann, MIT License(见 LICENSE,原样保留)

本仓在 fork 基础上的改动:

- 改名/命名空间:pinwheel,socket `/tmp/pinwheel.sock`,配置 `~/.config/pinwheel/`
- 新增 `QuoteEngine.swift`:QuoteProvider 协议 + 跑马灯文本拼装(按市场红涨绿跌/绿涨红跌、`\p` 停留标记)
- 新增 `RealProvider.swift`:真实行情源模板
- `AppDelegate`:end-of-message → 拉新行情重新入队的循环钩子;拉取失败 15s 重试;菜单加 Quote loop 开关与 Edit config…
- `Config`:watchlist / redUpMarkets / pausePerSymbol / provider 字段;默认彩色透明模式(涨跌配色可见)
- 移除上游的 milan:// URL handler 集成
