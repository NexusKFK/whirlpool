# Contributing / 参与开发

Issues and pull requests are welcome in English or Chinese. Keep changes focused and include the platform, app version, expected behavior, and a minimal reproduction. Do not attach private watchlists, tokens, or personal screenshots without redacting them.

## Layout and checks

- `Sources/`: native macOS app (Swift / AppKit).
- `Windows/Whirlpool.Core/`: Windows models, quote client, localization, and price rules; runs on any .NET 10 host.
- `Windows/Whirlpool.Windows/`: Windows Forms UI and tray integration.
- `Shared/localization.json`: English keys → Simplified Chinese strings, shared by both apps.
- `Shared/font.json`: Windows copy of the MIT-licensed LED glyphs from `Sources/FontData.swift`.
- `Tests/` and `Windows/Whirlpool.Core.Tests/`: deterministic regressions using fixtures, no live market requests.

Run `bash tools/test-price-flash.sh` on macOS and `dotnet run --project Windows/Whirlpool.Core.Tests -c Release` on any .NET 10 host. Run `Whirlpool.exe --smoke-test` on Windows to instantiate both languages and render the ticker. This is a smoke test, not a substitute for the Windows manual checklist.

## Translations / 翻译

Edit `Shared/localization.json`, then run `python3 tools/generate-localizations.py`. Commit the generated `Sources/Localization.swift` too. English is the source language; avoid stitching translated sentence fragments together. Test both languages at larger text/display scaling. UI strings must use `L(...)` on macOS or `I18n.T(...)` on Windows.

## Release checklist / 发布检查

1. Run both sets of core checks. Inspect settings in English and Chinese.
2. Update `Info.plist`, the Windows project version, and `CHANGELOG.md` together.
3. Build macOS with `bash build-app.sh --arch arm64 --arch x86_64` and verify `codesign --verify --deep --strict Whirlpool.app`.
4. Publish Windows using the command in the README. Do not claim native Windows QA from a cross-build. Complete `docs/WINDOWS-TESTING.md` on real Windows before promoting the preview.
5. Create archives using `bash tools/package-release.sh`. Include license/attribution and the Windows test checklist.
6. Scan the staged files for secrets/private configurations. Do not commit `dist/`, `.build/`, `bin/`, `obj/`, or user data.
7. Code-sign and notarize with the maintainer's own credentials if available. Builds here are locally signed on macOS and unsigned on Windows.
8. Publish release artifacts only after review. The workflow uploads CI artifacts; it does not automatically create a public release.

New config fields must have defaults. Invalid config files must not be silently destroyed. Preserve the suffix flash rule, separate quote direction from daily change, and never bypass provider cooldowns to make refresh appear faster.

中文：新增配置项必须兼容旧版；保存/取消应有明确边界；行情失败时保留最近报价并显示状态。修改频率控制时需覆盖缓存、并发合并、429、部分失败和恢复场景。GUI 冒烟检查不能替代 Windows 实机验收。
