using Microsoft.Win32;
using Whirlpool.Core;
using static Whirlpool.Core.I18n;

namespace Whirlpool.Windows;

internal static class Program
{
    public static string Version
    {
        get
        {
            var v = typeof(Program).Assembly.GetName().Version;
            return v is null ? "dev" : $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }
    }

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        QuoteFeed.Version = Version;
        if (args.Contains("--smoke-test"))
        {
            try { SmokeTest.Run(); Environment.ExitCode = 0; }
            catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }
            return;
        }
        // Local session scope: multiple Windows users do not share a ticker instance.
        using var mutex = new Mutex(true, "Local\\Whirlpool.Desktop", out bool first);
        if (!first) { MessageBox.Show(T("Whirlpool is already running in the notification area."), "Whirlpool"); return; }
        try
        {
            Application.Run(new TickerApplication());
        }
        catch (Exception error) { MessageBox.Show(error.Message, T("Could not start Whirlpool"), MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

internal sealed class TickerApplication : ApplicationContext
{
    private Settings settings;
    private readonly QuoteFeed feed = new();
    private readonly HttpClient updateHttp = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly NotifyIcon tray;
    private readonly TickerForm ticker;
    private readonly BoardForm board;
    private readonly System.Windows.Forms.Timer poll = new() { Interval = 1000 };
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 60_000 };
    private CancellationTokenSource cancellation = new();
    private SettingsForm? settingsForm;
    private readonly UpdateState updateState = UpdateState.Load();
    private Release? available;
    private bool paused, suspended, refreshing, force, exiting, canSave = true;
    private bool powerSuspended, sessionSuspended;
    private int generation;

    public TickerApplication()
    {
        try { settings = Settings.Load(); }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException or InvalidDataException or UnauthorizedAccessException)
        {
            settings = new(); settings.Normalize(); canSave = false;
            MessageBox.Show(T("The original file has been preserved. Check its format before saving new settings.") + "\n\n" + error.Message, T("Configuration Could Not Be Read"));
        }
        Language = settings.Language;
        tray = new NotifyIcon { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application, Text = "Whirlpool", Visible = true };
        ticker = new TickerForm(); board = new BoardForm();
        ticker.LayoutSaved += (point, placement, fraction) =>
        {
            settings.TickerOrigin = [point.X, point.Y]; settings.TickerPlacement = placement;
            settings.TickerWidthFraction = fraction; SaveSettings();
        };
        ticker.NextWatchlistRequested += () => SwitchWatchlist((settings.ActiveWatchlist + 1) % settings.Watchlists.Count);
        board.PositionSaved += p => { settings.BoardOrigin = [p.X, p.Y]; SaveSettings(); };
        board.UserClosed += () => { settings.ShowBoard = false; if (!settings.ShowTicker) settings.ShowTicker = true; Apply(); SaveSettings(); };
        board.OpenChartRequested += OpenChart;
        tray.DoubleClick += (_, _) => ShowSettings();
        tray.BalloonTipClicked += (_, _) => OpenUpdatePage();
        poll.Tick += async (_, _) => await RefreshAsync();
        updateTimer.Tick += async (_, _) => { updateTimer.Interval = 3_600_000; await CheckForUpdatesAsync(manual: false); };
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        Apply(); poll.Start(); _ = RefreshAsync();
        if (settings.CheckUpdates) updateTimer.Start();
    }

    // ── Menu ──

    private ContextMenuStrip CreateMenu()
    {
        var menu = new ContextMenuStrip();
        if (available is { } release && updateState.Skipped != release.Version)
        {
            menu.Items.Add(T("Whirlpool %@ is available…").Replace("%@", release.Version), null, (_, _) => OpenUpdatePage());
            menu.Items.Add(new ToolStripSeparator());
        }
        menu.Items.Add(T("About Whirlpool"), null, (_, _) => MessageBox.Show(
            "Whirlpool " + Program.Version + " · " + T("Windows preview") + "\n\n" + T("A quiet desktop ticker for your watchlist.") + "\n\n"
            + T("Open-source software under GPL-3.0. Market data remains subject to provider terms.") + "\n\ngithub.com/NexusKFK/whirlpool", T("About Whirlpool")));
        menu.Items.Add(T("Check for Updates…"), null, async (_, _) => await CheckForUpdatesAsync(manual: true));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(T(paused ? "Paused" : feed.Status)) { Enabled = false });
        if (feed.LastUpdated is { } date) menu.Items.Add(new ToolStripMenuItem(T("Updated at") + " " + date.ToLocalTime().ToString("T")) { Enabled = false });
        menu.Items.Add(T(paused ? "Resume" : "Pause"), null, (_, _) => { paused = !paused; Apply(); });
        menu.Items.Add(T("Refresh Quotes"), null, async (_, _) => { paused = false; force = true; Apply(); await RefreshAsync(); });

        var lists = new ToolStripMenuItem(T("Watchlists"));
        for (int i = 0; i < settings.Watchlists.Count; i++)
        {
            int index = i;
            lists.DropDownItems.Add(new ToolStripMenuItem(settings.Watchlists[i].Name, null, (_, _) => SwitchWatchlist(index)) { Checked = i == settings.ActiveWatchlist });
        }
        lists.DropDownItems.Add(new ToolStripSeparator());
        lists.DropDownItems.Add(new ToolStripMenuItem(T("Ctrl-click the ticker to switch")) { Enabled = false });
        lists.DropDownItems.Add(T("Edit Watchlists…"), null, (_, _) => ShowSettings());
        menu.Items.Add(lists);
        var charts = new ToolStripMenuItem(T("Open Chart"));
        foreach (var entry in settings.Watchlist) charts.DropDownItems.Add(entry.Symbol, null, (_, _) => OpenChart(entry));
        menu.Items.Add(charts);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("Settings…"), null, (_, _) => ShowSettings());
        var tickerItem = new ToolStripMenuItem(T("Show Ticker")) { Checked = settings.ShowTicker };
        tickerItem.Click += (_, _) => { settings.ShowTicker = !settings.ShowTicker; if (!settings.ShowTicker) settings.ShowBoard = true; Apply(); SaveSettings(); };
        menu.Items.Add(tickerItem);
        var lockItem = new ToolStripMenuItem(T("Lock Floating Windows")) { Checked = settings.LockPosition };
        lockItem.Click += (_, _) => { settings.LockPosition = !settings.LockPosition; Apply(); SaveSettings(); };
        var throughItem = new ToolStripMenuItem(T("Click Through Ticker")) { Checked = settings.ClickThrough, Enabled = settings.ShowTicker };
        throughItem.Click += (_, _) => { settings.ClickThrough = !settings.ClickThrough; Apply(); SaveSettings(); };
        var boardItem = new ToolStripMenuItem(T("Show Board")) { Checked = settings.ShowBoard };
        boardItem.Click += (_, _) => { settings.ShowBoard = !settings.ShowBoard; if (!settings.ShowBoard) settings.ShowTicker = true; Apply(); SaveSettings(); };
        menu.Items.Add(boardItem);
        menu.Items.Add(lockItem);
        menu.Items.Add(throughItem);
        menu.Items.Add(T("Show Configuration File…"), null, (_, _) =>
        {
            if (File.Exists(Settings.ConfigPath)) Open("explorer.exe", "/select,\"" + Settings.ConfigPath + "\"");
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("Quit Whirlpool"), null, (_, _) => ExitThread());
        return menu;
    }

    private void RebuildMenu()
    {
        var old = tray.ContextMenuStrip;
        var menu = CreateMenu();
        tray.ContextMenuStrip = menu; ticker.ContextMenuStrip = menu; board.ContextMenuStrip = menu;
        old?.Dispose();
    }

    // ── State ──

    private void Apply()
    {
        Language = settings.Language;
        ticker.Configure(settings); board.Configure(settings);
        ApplyTheme();
        bool running = !paused && !suspended;
        if (settings.ShowTicker && !paused) ticker.Show(); else ticker.Hide();
        if (settings.ShowBoard && !paused) board.Show(); else board.Hide();
        ticker.SetRunning(running);
        RebuildMenu();
    }

    private void ApplyTheme()
    {
        var tone = WinTheme.Resolve(settings.Theme);
        ticker.ApplyTheme(tone); board.ApplyTheme(tone);
    }

    private void SaveSettings()
    {
        if (!canSave || exiting) return;
        try { settings.Save(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private void SwitchWatchlist(int index)
    {
        if (index < 0 || index >= settings.Watchlists.Count || settings.Watchlists.Count < 2 && index == settings.ActiveWatchlist) return;
        settings.ActiveWatchlist = index; SaveSettings();
        Restart();
        var name = settings.Active.Name;
        if (settings.ShowTicker) ticker.ShowBanner("> " + (TickerForm.CanRender(name) ? name : "LIST " + (index + 1)));
    }

    private void Restart()
    {
        generation++;
        cancellation.Cancel(); cancellation.Dispose(); cancellation = new();
        force = true; Apply(); _ = RefreshAsync();
    }

    private void ShowSettings()
    {
        if (settingsForm is { IsDisposed: false }) { settingsForm.Activate(); return; }
        settingsForm = new SettingsForm(settings, () => settings);
        settingsForm.Saved += value =>
        {
            var checkUpdates = value.CheckUpdates;
            settings = value; canSave = true;
            if (checkUpdates) updateTimer.Start(); else updateTimer.Stop();
            Restart();
        };
        settingsForm.Show(); settingsForm.Activate();
    }

    private static void Open(string target, string? arguments = null)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target, arguments ?? "") { UseShellExecute = true }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    private static void OpenChart(WatchEntry entry) => Open(ChartLinks.For(entry).ToString());
    private void OpenUpdatePage() => Open((available?.Page ?? UpdateChecker.ReleasesPage).ToString());

    // ── Quotes ──

    private async Task RefreshAsync()
    {
        if (paused || suspended || refreshing || exiting) return;
        refreshing = true;
        var revision = generation; var token = cancellation.Token;
        var forced = force; force = false;
        try
        {
            var quotes = await feed.RefreshAsync(settings.Clone(), forced, token);
            if (exiting || revision != generation || paused || suspended) return;
            ticker.SetQuotes(settings, quotes); board.SetQuotes(settings, quotes);
            var status = T(feed.Status);
            var text = "Whirlpool · " + status;
            tray.Text = text.Length > 63 ? text[..63] : text;
            board.SetStatus(status, feed.LastUpdated);
            // Rebuild only while closed: changing an open menu would disrupt input.
            if (tray.ContextMenuStrip?.Visible != true) RebuildMenu();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (!exiting)
        {
            board.SetStatus(T("Offline · showing last prices"), feed.LastUpdated);
            System.Diagnostics.Debug.WriteLine(error);
        }
        finally { refreshing = false; }
    }

    // ── Updates ──

    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (!manual && (!settings.CheckUpdates || DateTimeOffset.UtcNow - updateState.LastCheck < TimeSpan.FromHours(24))) return;
        Release? latest;
        try { latest = await UpdateChecker.LatestAsync(updateHttp, Program.Version); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            if (exiting) return;
            if (manual) MessageBox.Show(error.Message, T("Could Not Check for Updates"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (exiting) return;
        updateState.LastCheck = DateTimeOffset.UtcNow;
        available = latest is not null && UpdateChecker.IsNewer(latest.Version, Program.Version) ? latest : null;
        if (available is { } release)
        {
            if (manual)
            {
                var download = new TaskDialogButton(T("Download"));
                var skip = new TaskDialogButton(T("Skip This Version"));
                var later = new TaskDialogButton(T("Later"));
                var page = new TaskDialogPage
                {
                    Caption = "Whirlpool", Heading = T("Whirlpool %@ is available").Replace("%@", release.Version),
                    Text = T("You have %@. Download the new version from GitHub?").Replace("%@", Program.Version),
                    Buttons = { download, later, skip }, Icon = TaskDialogIcon.Information,
                };
                var choice = TaskDialog.ShowDialog(page);
                if (choice == download) OpenUpdatePage();
                else if (choice == skip) updateState.Skipped = release.Version;
            }
            else if (updateState.Skipped != release.Version && updateState.Announced != release.Version)
            {
                // One notification per version; the menu keeps the entry until it is installed or skipped.
                tray.ShowBalloonTip(10_000, T("Whirlpool %@ is available").Replace("%@", release.Version),
                                    T("A new version is available. Click to download."), ToolTipIcon.Info);
                updateState.Announced = release.Version;
            }
        }
        else if (manual)
        {
            MessageBox.Show(T("Version %@ is the latest release.").Replace("%@", Program.Version), T("Whirlpool is up to date"));
        }
        updateState.Save();
        if (tray.ContextMenuStrip?.Visible != true) RebuildMenu();
    }

    // ── System events: stop polling and animation while asleep or locked; follow theme changes ──

    private void OnUi(Action action)
    {
        if (exiting) return;
        if (ticker.IsHandleCreated && ticker.InvokeRequired) ticker.BeginInvoke(action); else action();
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) OnUi(() => { powerSuspended = true; SetSuspended(true); });
        else if (e.Mode == PowerModes.Resume) OnUi(() => { powerSuspended = false; SetSuspended(sessionSuspended); });
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect)
            OnUi(() => { sessionSuspended = true; SetSuspended(true); });
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect or SessionSwitchReason.RemoteConnect)
            OnUi(() => { sessionSuspended = false; SetSuspended(powerSuspended); });
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle) OnUi(ApplyTheme);
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => OnUi(Apply);

    private void SetSuspended(bool value)
    {
        if (suspended == value) return;
        suspended = value;
        ticker.SetRunning(!suspended && !paused);
        if (!suspended) { feed.Invalidate(); force = true; _ = RefreshAsync(); }
    }

    protected override void ExitThreadCore()
    {
        exiting = true;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        poll.Stop(); poll.Dispose(); updateTimer.Stop(); updateTimer.Dispose(); cancellation.Cancel();
        tray.Visible = false; tray.Dispose(); ticker.Dispose(); board.Dispose(); settingsForm?.Dispose();
        feed.Dispose(); updateHttp.Dispose();
        base.ExitThreadCore();
    }
}

internal static class WindowPlacement
{
    /// <summary>The chosen screen, or the primary one for "auto" / a disconnected screen.</summary>
    public static Screen? Target(string key) =>
        (key == "auto" ? null : Screen.AllScreens.FirstOrDefault(s => s.DeviceName == key)) ?? Screen.PrimaryScreen;

    public static string Label(Screen screen, int index) =>
        $"{index + 1}. {screen.Bounds.Width}×{screen.Bounds.Height}" + (screen.Primary ? " · " + T("Main display") : "");

    public static Screen? ForOrigin(int[]? origin, Size size, string key)
    {
        if (origin is not { Length: 2 }) return Target(key);
        var point = new Point(origin[0], origin[1]);
        var containing = Screen.AllScreens.FirstOrDefault(s => s.Bounds.Contains(point));
        if (containing is not null) return containing;
        var rect = new Rectangle(point, size);
        return Screen.AllScreens
            .Select(s => (Screen: s, Overlap: Rectangle.Intersect(s.WorkingArea, rect)))
            .Where(p => p.Overlap.Width >= Math.Min(80, size.Width) && p.Overlap.Height >= Math.Min(20, size.Height))
            .OrderByDescending(p => (long)p.Overlap.Width * p.Overlap.Height).Select(p => p.Screen).FirstOrDefault() ?? Target(key);
    }

    public static void Apply(Form form, int[]? origin, bool board, string screenKey = "auto")
    {
        var work = ForOrigin(origin, form.Size, screenKey)?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        var point = origin is { Length: 2 } ? new Point(origin[0], origin[1])
            : new Point(board ? work.Right - form.Width - 20 : work.Left + (work.Width - form.Width) / 2, work.Bottom - form.Height - (board ? 80 : 18));
        form.StartPosition = FormStartPosition.Manual; form.Location = WindowBounds.Clamp(point, form.Size, work);
    }
}
