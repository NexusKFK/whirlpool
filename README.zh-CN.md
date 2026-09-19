# Whirlpool

简体中文 · [English](README.md)

一个轻量的桌面自选行情工具：LED 跑马灯、浮动行情条、紧凑报价卡，以及贴在屏幕边缘的行情组件。

## 平台

| | macOS |
|---|---|
| 系统入口 | 菜单栏、浮动行情条、报价卡 |
| 语言 | 中文 / 英文 / 跟随系统 |
| 行情 | Yahoo / 腾讯，或明确标注的模拟行情 |
| 显示 | LED 点阵或系统字体跑马灯，三档字号；像素或系统字体报价卡；分时图 |
| 设置 | 分区设置、自选股增删改与排序 |
| 系统要求 | macOS 13 及以上 |


## 使用

macOS：打开 `Whirlpool.app`，右键菜单栏、行情条或报价卡 → **设置…**。左键菜单栏图标可暂停/收起与继续；浮窗可拖动。仅开报价卡时仍保留一个小菜单栏入口。

设置分为 **自选股 / 显示 / 通用**。保存后立即生效，取消不改动配置。可切换语言、行情来源、显示模式、刷新间隔、滚动速度与宽度、价格闪色、市场红绿规则，也可重置浮窗位置。

代码示例：`AAPL`、`^GSPC`、`600519`、`00700`、`BTC-USD`。同一代码不能重复。A 股使用六位代码，港股一至五位代码会在请求时向左补零。演示源使用模拟价格，状态菜单会明确标注。

## 刷新与限流

默认建议 **30 秒**。所有显示共用缓存和一次进行中的行情请求。配置值表示两次完整拉取之间的最短间隔，不代表交易所逐笔行情。滚动独立运行，跑马灯在下一轮采用新数据；手动刷新也不能绕过限流等待或五秒的最短请求间隔。

Yahoo 按标的逐个请求。四只股票每五秒拉一次，约为 **48 次/分钟、2880 次/小时**，尚未计入重试或同一 IP 下的其他软件。没有可保证的固定免费额度，五秒不能保证不被限流。遇到失败时保留最近报价、合并部分成功结果，HTTP 429 时遵循 `Retry-After`；连续失败从 30 秒递增退避，最高 15 分钟。菜单会显示连接失败、部分行情不可用、被限流等状态和最近成功更新时间。数据可能受提供方或市场规则影响而延迟。

Whirlpool 使用原生 HTTP 请求访问 Yahoo/腾讯公开端点，**不依赖 Python 或 yfinance**。[yfinance](https://ranaroussi.github.io/yfinance/) 使用相关 Yahoo 接口，也会[处理 HTTP 429](https://github.com/ranaroussi/yfinance/blob/main/yfinance/data.py)，并非 Yahoo 官方服务。软件采用 MIT 协议，不代表同时取得了行情数据再分发权；数据使用遵循提供方条款。

## 从源码构建

macOS 需要 Swift 5.7+ 及 Command Line Tools 或 Xcode：

```sh
swift build
.build/debug/whirlpool
bash tools/test-price-flash.sh
bash build-app.sh
# 可选：Apple Silicon + Intel 通用包
bash build-app.sh --arch arm64 --arch x86_64
```

构建产物 `Whirlpool.app` 采用本地 ad-hoc 签名；Developer ID 签名与公证需要维护者自己的 Apple 凭据。

## 配置与隐私

- macOS：`~/.config/whirlpool/config.json`；沿用原路径，升级保留自选股。
- 无账号、遥测、分析或云同步。自选股与配置保存在本机；真实行情请求会将代码及网络元数据发送到 Yahoo/腾讯。演示源不发行情请求。
- 原子保存；旧配置缺字段时补默认值，损坏文件不会在启动时被默认配置悄悄覆盖。仓库不包含私人自选股配置。
- macOS 菜单 **高级 → 显示配置文件…** 可定位文件。

macOS 还支持 `--settings`、`--status`、`--send`、`--urgent`、`--very-urgent`、`--standby`、`--width`、`--mode`、`--clear`、`--restart`、`--quit`，详细示例见[英文说明](README.md#macos-cli)。本地控制 socket 按用户隔离，不对网络开放。`--on-click` 会执行本地 shell 命令，只应传入可信命令。应用默认不占程序坞；**设置 → 通用 → 「在程序坞显示图标」**可让进程可见（右键即可退出）。终端里可直接用 `/Applications/Whirlpool.app/Contents/MacOS/whirlpool --status | --restart | --quit`，或硬重置 `pkill -x whirlpool && open -a Whirlpool`。

## 开发与发布

[更新记录](CHANGELOG.md) · [贡献与翻译](CONTRIBUTING.md) · [安全说明](SECURITY.md) · [架构](docs/ARCHITECTURE.md) · [许可证](LICENSE) · [致谢](ATTRIBUTION.md)

macOS 显示引擎基于 MIT 许可的 [rhsev/ticker](https://github.com/rhsev/ticker) 改造，保留原始版权声明。

## 许可与署名

代码:**GPL-3.0-only**(见 [LICENSE](LICENSE));LED 渲染引擎衍生自
[rhsev/ticker](https://github.com/rhsev/ticker)(MIT,原文保留于
[LICENSE-MIT](LICENSE-MIT))。图标、名称与文档:**CC BY-NC-SA 4.0**,
转载须署名、禁商用,详见 [NOTICE.md](NOTICE.md)。

> 转载 / 二次开发请保留本行出处:Project **Whirlpool 涡状星系** by
> [NexusKFK](https://github.com/NexusKFK) · github.com/NexusKFK/whirlpool
