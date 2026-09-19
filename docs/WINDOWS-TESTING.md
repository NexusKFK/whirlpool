# Windows preview acceptance / Windows 预览验收

Status: cross-compilation and core checks can run on macOS. Native Windows execution and visual QA require a Windows machine. Do not mark the items below as passed merely because compilation succeeded.

建议先在 Windows 10/11 x64 用少量自选股验收。发布包无安装步骤，解压后运行 `Whirlpool.exe`；尚未使用商业代码签名。

- [ ] Launch on a machine without .NET installed; verify the tray icon, ticker, and quit action.
- [ ] Launch a second copy; verify the single-instance message and that the first copy continues.
- [ ] Open settings in English and Chinese; verify no clipping at 100%, 150%, and 200% scaling.
- [ ] Add, edit, remove, and reorder symbols; reject empty, invalid, and duplicate entries.
- [ ] Cancel after edits and resetting window positions; confirm no settings changed.
- [ ] Save and restart; verify watchlist, language, mode, and window positions persist.
- [ ] Drag across monitors, disconnect a monitor, restart, and verify windows remain reachable.
- [ ] Switch between ticker, board, and both; close the board; restore it from the tray.
- [ ] Pause/resume and quit; verify timers and network polling stop while paused.
- [ ] Use demo data; verify the simulated-data status is clearly visible.
- [ ] Use a small live watchlist with the default 30-second interval; verify Yahoo and Tencent symbols.
- [ ] Disconnect the network; verify old prices remain and the status indicates failure.
- [ ] Verify `81.20 → 81.30` highlights the entire `30`, including the unchanged zero.
- [ ] Verify a rising tick can flash green while its daily percentage is red.
- [ ] Inspect with Narrator and keyboard-only navigation.
- [ ] Switch Windows between light and dark app mode; verify the ticker and board recolor (Settings → Display → Colors = System Default) and that Light/Dark override it.
- [ ] Create a second watchlist, rename it, save; switch with Ctrl-click on the ticker and from the tray menu; verify the list name appears briefly.
- [ ] Set a symbol's Decimals to 3 (e.g. `510300`); verify the ticker and board show three places and that `4.580 → 4.582` flashes the last digit.
- [ ] Hover over the ticker; verify scrolling pauses and resumes on leave.
- [ ] Double-click a board row and use Open Chart; verify TradingView/Yahoo opens.
- [ ] Enable Launch at login, sign out and in; disable it again.
- [ ] Lock the session or sleep; verify polling stops (no network traffic) and resumes after unlock/wake.
- [ ] Run Check for Updates… (newer release → Download/Later/Skip; otherwise "up to date"); verify the automatic check shows one notification per version.
- [ ] With an old `%APPDATA%\Pinwheel\config.json` and no Whirlpool config, verify the watchlist is carried over on first launch.
- [ ] Run `Whirlpool.exe --smoke-test` and inspect the process exit code.

Config: `%APPDATA%\Whirlpool\config.json`. To report issues, include OS version, display scaling, app version, and steps. Remove personal information from screenshots/configs before sharing.
