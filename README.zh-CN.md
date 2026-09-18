# Pinwheel

简体中文 · [English](README.md)

一个轻量的桌面自选行情工具：LED 跑马灯、浮动行情条、紧凑报价卡，以及按价格变化位闪色的提示。

## 平台

| | macOS | Windows 预览版 |
|---|---|---|
| 系统入口 | 菜单栏、浮动行情条、报价卡 | 系统托盘、浮动行情条、报价卡 |
| 语言 | 中文 / 英文 / 跟随系统 | 中文 / 英文 / 跟随系统 |
| 行情 | Yahoo / 腾讯，或明确标注的模拟行情 | Yahoo / 腾讯，或明确标注的模拟行情 |
| 显示 | LED 点阵；像素或系统字体报价卡；分时图 | LED 点阵；原生报价列表 |
| 设置 | 分区设置、自选股增删改与排序 | 分区设置、自选股增删改与排序 |
| 系统要求 | macOS 13 及以上 | .NET 10 支持的 Windows 10/11 x64 |

Windows 是首个预览移植版。交叉编译和核心逻辑测试通过，不代表已经完成 Windows 实机 GUI 验证。详见[Windows 验收清单](docs/WINDOWS-TESTING.md)。Windows 预览版暂不含 macOS 的 CLI 插播和分时缩略图。

## 使用

macOS：打开 `Pinwheel.app`，右键菜单栏、行情条或报价卡 → **设置…**。左键菜单栏图标可暂停/收起与继续；浮窗可拖动。仅开报价卡时仍保留一个小菜单栏入口。

Windows：解压完整 ZIP 后运行 `Pinwheel.exe`，通过系统托盘菜单操作。发布包自带运行时，不需要另装 .NET。左键拖动行情条；关闭报价卡只是隐藏，退出应用请用托盘菜单的 **退出 Pinwheel**。

设置分为 **自选股 / 显示 / 通用**。保存后立即生效，取消不改动配置。可切换语言、行情来源、显示模式、刷新间隔、滚动速度与宽度、价格闪色、市场红绿规则，也可重置浮窗位置。

代码示例：`AAPL`、`^GSPC`、`600519`、`00700`、`BTC-USD`。同一代码不能重复。A 股使用六位代码，港股一至五位代码会在请求时向左补零。演示源使用模拟价格，状态菜单会明确标注。

## 价格闪色

`81.20 → 81.30` 时闪整个 **30**，包括没变的末尾 `0`。颜色按上一笔价格的方向决定，与当日涨跌幅独立，遵循对应市场的红绿规则。闪色持续 0.55 秒后恢复原色。每段滚入可读区域后独立计时，同一轮环绕不重复闪。首笔、未变化或舍入后没有可见变化时不闪。超过 1000 的价格也保留两位小数。

## 刷新与限流

默认建议 **30 秒**。所有显示共用缓存和一次进行中的行情请求。配置值表示两次完整拉取之间的最短间隔，不代表交易所逐笔行情。滚动独立运行，跑马灯在下一轮采用新数据；手动刷新也不能绕过限流等待或五秒的最短请求间隔。

Yahoo 按标的逐个请求。四只股票每五秒拉一次，约为 **48 次/分钟、2880 次/小时**，尚未计入重试或同一 IP 下的其他软件。没有可保证的固定免费额度，五秒不能保证不被限流。遇到失败时保留最近报价、合并部分成功结果，HTTP 429 时遵循 `Retry-After`；连续失败从 30 秒递增退避，最高 15 分钟。菜单会显示连接失败、部分行情不可用、被限流等状态和最近成功更新时间。数据可能受提供方或市场规则影响而延迟。

Pinwheel 使用原生 HTTP 请求访问 Yahoo/腾讯公开端点，**不依赖 Python 或 yfinance**。[yfinance](https://ranaroussi.github.io/yfinance/) 使用相关 Yahoo 接口，也会[处理 HTTP 429](https://github.com/ranaroussi/yfinance/blob/main/yfinance/data.py)，并非 Yahoo 官方服务。软件采用 MIT 协议，不代表同时取得了行情数据再分发权；数据使用遵循提供方条款。

## 从源码构建

macOS 需要 Swift 5.7+ 及 Command Line Tools 或 Xcode：

```sh
swift build
.build/debug/pinwheel
bash tools/test-price-flash.sh
bash build-app.sh
# 可选：Apple Silicon + Intel 通用包
bash build-app.sh --arch arm64 --arch x86_64
```

构建产物 `Pinwheel.app` 采用本地 ad-hoc 签名；Developer ID 签名与公证需要维护者自己的 Apple 凭据。

Windows 构建需要 .NET 10 SDK，可在 macOS/Linux 交叉编译：

```sh
dotnet run --project Windows/Pinwheel.Core.Tests -c Release
dotnet publish Windows/Pinwheel.Windows -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -o dist/windows-x64
```

发布包自带运行时。Windows GUI 仍需在 Windows 上执行验证。仓库附有 GitHub Actions 双平台构建、核心测试和 Windows 控件创建/渲染冒烟检查。

## 配置与隐私

- macOS：`~/.config/pinwheel/config.json`；沿用原路径，升级保留自选股。
- Windows：`%APPDATA%\Pinwheel\config.json`。
- 无账号、遥测、分析或云同步。自选股与配置保存在本机；真实行情请求会将代码及网络元数据发送到 Yahoo/腾讯。演示源不发行情请求。
- 原子保存；旧配置缺字段时补默认值，损坏文件不会在启动时被默认配置悄悄覆盖。仓库不包含私人自选股配置。
- macOS 菜单 **高级 → 显示配置文件…** 或 Windows 托盘 **显示配置文件…** 可定位文件。

macOS 还支持 `--settings`、`--status`、`--send`、`--urgent`、`--very-urgent`、`--standby`、`--width`、`--clear`、`--quit`，详细示例见[英文说明](README.md#macos-cli)。本地控制 socket 按用户隔离，不对网络开放。`--on-click` 会执行本地 shell 命令，只应传入可信命令。

## 开发与发布

[更新记录](CHANGELOG.md) · [贡献与翻译](CONTRIBUTING.md) · [安全说明](SECURITY.md) · [架构](docs/ARCHITECTURE.md) · [许可证](LICENSE) · [致谢](ATTRIBUTION.md)

macOS 显示引擎基于 MIT 许可的 [rhsev/ticker](https://github.com/rhsev/ticker) 改造，保留原始版权声明。

## 许可与署名

代码:**GPL-3.0-only**(见 [LICENSE](LICENSE));LED 渲染引擎衍生自
[rhsev/ticker](https://github.com/rhsev/ticker)(MIT,原文保留于
[LICENSE-MIT](LICENSE-MIT))。图标、名称与文档:**CC BY-NC-SA 4.0**,
转载须署名、禁商用,详见 [NOTICE.md](NOTICE.md)。

> 转载 / 二次开发请保留本行出处:Project **Pinwheel 风车星系** by
> [NexusKFK](https://github.com/NexusKFK) · github.com/NexusKFK/pinwheel
