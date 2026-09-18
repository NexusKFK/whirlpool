using Pinwheel.Core;
using static Pinwheel.Core.I18n;

namespace Pinwheel.Windows;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--smoke-test"))
        {
            try { SmokeTest.Run(); Environment.ExitCode = 0; }
            catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }
            return;
        }
        // Local session scope: multiple Windows users do not share a ticker instance.
        using var mutex = new Mutex(true, "Local\\Pinwheel.Desktop", out bool first);
        if (!first) { MessageBox.Show(T("Pinwheel is already running in the system tray."), "Pinwheel"); return; }
        try
        {
            Application.Run(new TickerApplication());
        }
        catch (Exception error) { MessageBox.Show(error.Message, T("Could not start Pinwheel"), MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

internal sealed class TickerApplication : ApplicationContext
{
    private Settings settings;
    private readonly QuoteFeed feed = new();
    private readonly NotifyIcon tray;
    private readonly TickerForm ticker;
    private readonly BoardForm board;
    private readonly System.Windows.Forms.Timer poll = new() { Interval = 1000 };
    private CancellationTokenSource cancellation = new();
    private SettingsForm? settingsForm;
    private bool paused, refreshing, force, exiting, canSave = true;
    private int generation;

    public TickerApplication()
    {
        try { settings = Settings.Load(); }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException or InvalidDataException or UnauthorizedAccessException)
        {
            settings = new(); canSave = false;
            MessageBox.Show(T("The original file has been preserved. Check its format before saving new settings.") + "\n\n" + error.Message, T("Configuration Could Not Be Read"));
        }
        Language = settings.Language;
        tray = new NotifyIcon { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application, Text = "Pinwheel", Visible = true };
        ticker = new TickerForm(); board = new BoardForm();
        ticker.PositionSaved += p => { settings.TickerOrigin = [p.X, p.Y]; SavePosition(); };
        board.PositionSaved += p => { settings.BoardOrigin = [p.X, p.Y]; SavePosition(); };
        board.UserClosed += () => { settings.ShowBoard = false; if (!settings.ShowTicker) settings.ShowTicker = true; Apply(); SavePosition(); };
        tray.DoubleClick += (_, _) => ShowSettings();
        poll.Tick += async (_, _) => await RefreshAsync();
        Apply(); poll.Start(); _ = RefreshAsync();
    }

    private ContextMenuStrip CreateMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(T("About Pinwheel"), null, (_, _) => MessageBox.Show("Pinwheel 1.6.0 · " + T("Windows preview") + "\n\n" + T("A quiet desktop ticker for your watchlist.") + "\n\n" + T("Open-source software under the MIT license. Market data remains subject to provider terms."), T("About Pinwheel")));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(T(paused ? "Paused" : feed.Status)) { Enabled = false });
        if (feed.LastUpdated is { } date) menu.Items.Add(new ToolStripMenuItem(T("Updated at") + " " + date.ToLocalTime().ToString("T")) { Enabled = false });
        menu.Items.Add(T(paused ? "Resume" : "Pause"), null, (_, _) => { paused = !paused; Apply(); });
        menu.Items.Add(T("Refresh Quotes"), null, async (_, _) => { paused = false; force = true; Apply(); await RefreshAsync(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("Settings…"), null, (_, _) => ShowSettings());
        var tickerItem = new ToolStripMenuItem(T("Show Ticker")) { Checked = settings.ShowTicker };
        tickerItem.Click += (_, _) => { settings.ShowTicker = !settings.ShowTicker; if (!settings.ShowTicker) settings.ShowBoard = true; Apply(); SavePosition(); };
        menu.Items.Add(tickerItem);
        var boardItem = new ToolStripMenuItem(T("Show Board")) { Checked = settings.ShowBoard };
        boardItem.Click += (_, _) => { settings.ShowBoard = !settings.ShowBoard; if (!settings.ShowBoard) settings.ShowTicker = true; Apply(); SavePosition(); };
        menu.Items.Add(boardItem);
        menu.Items.Add(T("Show Configuration File…"), null, (_, _) =>
        {
            if (File.Exists(Settings.ConfigPath)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", "/select,\"" + Settings.ConfigPath + "\"") { UseShellExecute = true });
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("Quit Pinwheel"), null, (_, _) => ExitThread());
        return menu;
    }
    private void RebuildMenu()
    {
        var old = tray.ContextMenuStrip;
        var menu = CreateMenu();
        tray.ContextMenuStrip = menu; ticker.ContextMenuStrip = menu; board.ContextMenuStrip = menu;
        old?.Dispose();
    }
    private void Apply()
    {
        Language = settings.Language;
        ticker.Configure(settings); board.Configure(settings);
        if (settings.ShowTicker && !paused) ticker.Show(); else ticker.Hide();
        if (settings.ShowBoard && !paused) board.Show(); else board.Hide();
        RebuildMenu();
    }
    private void SavePosition()
    {
        if (!canSave || exiting) return;
        try { settings.Save(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    private void ShowSettings()
    {
        if (settingsForm is { IsDisposed: false }) { settingsForm.Activate(); return; }
        settingsForm = new SettingsForm(settings);
        settingsForm.Saved += value =>
        {
            settings = value; canSave = true; generation++;
            cancellation.Cancel(); cancellation.Dispose(); cancellation = new();
            force = true; Apply();
        };
        settingsForm.Show(); settingsForm.Activate();
    }
    private async Task RefreshAsync()
    {
        if (paused || refreshing || exiting) return;
        refreshing = true;
        var revision = generation; var token = cancellation.Token;
        var forced = force; force = false;
        try
        {
            var quotes = await feed.RefreshAsync(settings.Clone(), forced, token);
            if (exiting || revision != generation || paused) return;
            ticker.SetQuotes(settings, quotes); board.SetQuotes(settings, quotes);
            var status = T(feed.Status);
            tray.Text = ("Pinwheel · " + status)[..Math.Min(63, 11 + status.Length)];
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
    protected override void ExitThreadCore()
    {
        exiting = true; poll.Stop(); poll.Dispose(); cancellation.Cancel();
        tray.Visible = false; tray.Dispose(); ticker.Dispose(); board.Dispose(); settingsForm?.Dispose();
        base.ExitThreadCore();
    }
}

internal static class WindowPlacement
{
    public static void Apply(Form form, int[]? origin, bool board)
    {
        var work = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        var point = origin is { Length: 2 } ? new Point(origin[0], origin[1])
            : new Point(board ? work.Right - form.Width - 20 : work.Left + (work.Width - form.Width) / 2, work.Bottom - form.Height - (board ? 80 : 18));
        var rect = new Rectangle(point, form.Size);
        if (!Screen.AllScreens.Any(s => Rectangle.Intersect(s.WorkingArea, rect) is { Width: > 80, Height: > 20 })) point = new(work.Left + 20, work.Top + 40);
        form.StartPosition = FormStartPosition.Manual; form.Location = point;
    }
}
