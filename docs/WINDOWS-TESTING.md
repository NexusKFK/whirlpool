# Windows preview acceptance / Windows 预览验收

Version: **2.0.0 preview**. Cross-compilation and core checks can run on macOS. Native Windows execution and visual QA require a Windows machine. Do not mark the items below as passed merely because compilation succeeded.

建议先在 Windows 10/11 x64 用少量自选股验收。发布包无安装步骤，解压后运行 `Whirlpool.exe`；尚未使用商业代码签名。

- [ ] Launch on a machine without .NET installed; verify the tray icon, ticker, and quit action.
- [ ] Launch a second copy; verify the single-instance message and that the first copy continues.
- [ ] Open the Layout / Appearance / Watchlist / General tabs in English and Chinese; verify labels, selection states, and vector controls at 100%, 150%, and 200% scaling, in both light and dark modes.
- [ ] On a 1366×768 desktop, verify that long tabs scroll, the Save/Cancel footer remains accessible, and controls do not extend beyond the working area. Repeat after changing Windows scaling.
- [ ] Add, edit, remove, and reorder symbols; reject empty, invalid, and duplicate entries.
- [ ] Drag and resize the ticker inside the desktop preview, change appearance and display cards, reset positions, then Cancel; confirm neither the running windows nor the configuration file changed. Repeat using the close button.
- [ ] Save and restart; verify watchlist, language, mode, and window positions persist.
- [ ] Drag across monitors, disconnect a monitor, restart, and verify windows remain reachable.
- [ ] Select each of the six top/bottom left/center/right anchors; verify the real ticker matches the preview after Save, stays clear of the Windows taskbar, and retains a small edge margin. Repeat with the taskbar on another edge or set to auto-hide.
- [ ] Set 20%, 60%, and 100% widths; test quarter/half/two-thirds/full-width presets. Full width must retain the edge margins. Verify the percentage refers to the complete ticker, not a character count.
- [ ] Drag both ends of the actual ticker to resize. Centered and free tickers must grow about their center; left/right anchors must retain their aligned edge. Save and restart, then verify the width and placement persist.
- [ ] Drag an anchored ticker to a custom position; verify it switches to Free position. Open Settings and confirm the preview reflects that position. Re-select an anchor and Save to return to the selected screen edge.
- [ ] Widen the ticker near a display edge; verify it fits on that display. Move between narrow/wide displays and disconnect one while running; the ticker must resize and both windows must remain reachable without restarting. Reconnect the preferred display and verify anchored placement is consistent with the selected screen.
- [ ] Toggle the ticker and board cards independently, covering ticker-only, board-only, and both; at least one must remain enabled. Close the board and restore it from the tray.
- [ ] Pause/resume and quit; verify timers and network polling stop while paused.
- [ ] Use demo data; verify the simulated-data status is clearly visible.
- [ ] Use a small live watchlist with the default 30-second interval; verify Yahoo and Tencent symbols.
- [ ] Disconnect the network; verify old prices remain and the status indicates failure.
- [ ] Add an unavailable symbol alongside a working one; the working quote must keep its normal refresh cadence while the unavailable symbol retries less often and the menu retains its partial-failure status.
- [ ] Verify `81.20 → 81.30` highlights the entire `30`, including the unchanged zero.
- [ ] Verify a rising tick can flash green while its daily percentage is red.
- [ ] Inspect with Narrator and keyboard-only navigation.
- [ ] Switch Windows between light and dark app mode; verify the ticker and board recolor when Appearance → System Default is selected, and that the Light/Dark cards override it.
- [ ] Create a second watchlist, rename it, save; switch with Ctrl-click on the ticker and from the tray menu; verify the list name appears briefly.
- [ ] Set a symbol's Decimals to 3 (e.g. `510300`); verify the ticker and board show three places and that `4.580 → 4.582` flashes the last digit.
- [ ] Hover over the ticker; verify scrolling pauses and resumes on leave.
- [ ] Double-click a board row and use Open Chart; verify TradingView/Yahoo opens.
- [ ] Enable Launch at login, sign out and in; disable it again.
- [ ] Lock the session or sleep; verify polling stops (no network traffic) and resumes after unlock/wake.
- [ ] Run Check for Updates… (newer release → Download/Later/Skip; otherwise "up to date"); verify the automatic check shows one notification per version.
- [ ] With an old `%APPDATA%\Pinwheel\config.json` and no Whirlpool config, verify the watchlist is carried over on first launch. With a 1.x Whirlpool config, verify legacy ticker width and saved free position are retained until explicitly changed; saving an unrelated setting must not resize or reposition the ticker.
- [ ] With two monitors, choose each screen in Settings → Layout → Screen; verify the ticker and board move there and stay after restart. If the chosen display is absent, the windows must remain accessible on a connected display.
- [ ] Enable Lock Floating Windows; verify the ticker and board cannot be dragged, ticker-end resizing is disabled, and the tray menu still works.
- [ ] Enable Click Through Ticker; verify clicks reach the window underneath; turn it off from the tray menu.
- [ ] Run `Whirlpool.exe --smoke-test` and inspect the process exit code.
- [ ] While the network is unavailable, switch lists or between live/demo sources; the old list's rows, prices and banner must disappear immediately.
- [ ] During a closed-market interval, disable smart refresh or shorten the interval; polling should resume without waiting out the old 30-minute cache. An early manual refresh should run after the five-second guard.
- [ ] Keep Settings open, drag and resize the real floating ticker, change only an unrelated setting, then Save; the latest real position and width must survive. Repeat with an explicit preview position/width edit and verify that the draft edit wins for the property changed.
- [ ] In Free position, change width with the slider, a preset, and preview-end dragging; verify all three preserve the center and that the applied window matches the preview, including near a display edge.
- [ ] Reset positions and immediately Save; an older pending drag save must not restore the old position.
- [ ] Set Decimals to 7 or 8, save and reopen; both choices must remain selected and render correctly.
- [ ] Sleep while the session is locked; waking alone must not resume polling until the session is active too. Quit during an active request and verify a clean exit.

Config: `%APPDATA%\Whirlpool\config.json`. To report issues, include OS version, display scaling, app version, and steps. Remove personal information from screenshots/configs before sharing.
