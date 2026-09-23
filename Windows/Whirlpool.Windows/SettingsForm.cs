using Whirlpool.Core;
using static Whirlpool.Core.I18n;

namespace Whirlpool.Windows;

internal sealed class SettingsForm : Form
{
    private static readonly string[] DecimalChoices = ["Auto", "0", "1", "2", "3", "4", "5", "6", "7", "8"];
    private bool resetPositions;
    private bool initializing = true, placementEdited, widthEdited;
    private double? draftFreeCenter;
    private readonly Func<Settings>? currentSettings;
    private readonly Settings draft;
    private readonly List<Watchlist> lists;
    private int current;
    private readonly DataGridView list = new() { Dock = DockStyle.Fill, AllowUserToAddRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = SystemColors.Window, BorderStyle = BorderStyle.FixedSingle };
    private readonly ComboBox picker = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
    private readonly Button deleteList;
    private readonly ComboBox language = Combo([T("System Default"), "English", "简体中文"]);
    private readonly ComboBox source = Combo([T("Yahoo / Tencent"), T("Demo (simulated prices)")]);
    private readonly ChoiceCard tickerCard = new("Floating Ticker", "ticker");
    private readonly ChoiceCard boardCard = new("Quote Board", "board");
    private readonly Dictionary<string, ChoiceCard> themeCards = [];
    private readonly Dictionary<string, ChoiceCard> placementCards = [];
    private readonly DesktopPreview preview = new();
    private readonly TrackBar width = new() { Minimum = 20, Maximum = 100, TickFrequency = 10, SmallChange = 1, LargeChange = 5, Width = 235, Height = 44, AccessibleName = T("Screen width") };
    private readonly Label widthLabel = new() { AutoSize = true, ForeColor = Color.FromArgb(53, 94, 199), Margin = new(8, 10, 3, 3) };
    private readonly ComboBox screen = Combo([]);
    private readonly List<string> screenKeys = [];
    private readonly NumericUpDown interval = new() { Minimum = 5, Maximum = 3600, Width = 110 };
    private readonly NumericUpDown speed = new() { Minimum = 10, Maximum = 50, Width = 110 };
    private readonly CheckBox arrows = Check("Use ▲ / ▼ for price changes");
    private readonly CheckBox flash = Check("Flash changed price suffixes");
    private readonly CheckBox topmost = Check("Always on top");
    private readonly CheckBox hover = Check("Pause scrolling while the pointer is over the ticker");
    private readonly CheckBox locked = Check("Lock floating windows in place");
    private readonly CheckBox through = Check("Let clicks pass through the floating ticker (turn off from the tray menu)");
    private readonly CheckBox redUp = Check("Red means up in China / Hong Kong");
    private readonly CheckBox smart = Check("Refresh slowly while all watched markets are closed");
    private readonly CheckBox login = Check("Launch at login");
    private readonly CheckBox updates = Check("Check for updates automatically");
    public event Action<Settings>? Saved;

    public SettingsForm(Settings settings, Func<Settings>? currentSettings = null)
    {
        this.currentSettings = currentSettings;
        draft = settings.Clone();
        lists = draft.Watchlists.Select(l => new Watchlist { Name = l.Name, Entries = [.. l.Entries] }).ToList();
        current = Math.Clamp(draft.ActiveWatchlist, 0, lists.Count - 1);
        deleteList = Button("Delete List", (_, _) => RemoveList());
        Text = T("Whirlpool Settings"); Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        Size = new(820, 790); MinimumSize = new(720, 560); StartPosition = FormStartPosition.CenterScreen;
        var working = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 800);
        MinimumSize = new(Math.Min(720, working.Width - 32), Math.Min(560, working.Height - 32));
        Size = new(Math.Min(Width, working.Width - 32), Math.Min(Height, working.Height - 32));
        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 8) };
        tabs.TabPages.Add(DisplayTab()); tabs.TabPages.Add(AppearanceTab()); tabs.TabPages.Add(WatchlistTab()); tabs.TabPages.Add(GeneralTab());
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 56, FlowDirection = FlowDirection.RightToLeft, Padding = new(12), WrapContents = false };
        var save = Button("Save", (_, _) => Save()); var cancel = Button("Cancel", (_, _) => Close());
        footer.Controls.Add(save); footer.Controls.Add(cancel); AcceptButton = save; CancelButton = cancel;
        Controls.Add(tabs); Controls.Add(footer); Padding = new(14);
        language.SelectedIndex = Math.Max(0, Array.IndexOf(new[] { "system", "en", "zh-Hans" }, draft.Language));
        source.SelectedIndex = draft.Provider == "real" ? 0 : 1;
        tickerCard.Checked = draft.ShowTicker; boardCard.Checked = draft.ShowBoard;
        themeCards[draft.Theme].Checked = true;
        screenKeys.Add("auto"); screen.Items.Add(T("Automatic (primary display)"));
        var screens = Screen.AllScreens;
        for (int i = 0; i < screens.Length; i++) { screenKeys.Add(screens[i].DeviceName); screen.Items.Add(WindowPlacement.Label(screens[i], i)); }
        if (!screenKeys.Contains(draft.DisplayScreen)) { screenKeys.Add(draft.DisplayScreen); screen.Items.Add(T("Disconnected display")); }
        screen.SelectedIndex = Math.Max(0, screenKeys.IndexOf(draft.DisplayScreen));
        interval.Value = draft.RefreshSeconds; speed.Value = draft.ColumnsPerSecond;
        width.Minimum = Math.Min(20, (int)Math.Round(InitialFraction() * 100));
        width.Value = Math.Clamp((int)Math.Round(InitialFraction() * 100), width.Minimum, 100);
        arrows.Checked = draft.ChangeArrows; flash.Checked = draft.FlashChanges; topmost.Checked = draft.AlwaysOnTop;
        hover.Checked = draft.HoverPause; smart.Checked = draft.SmartRefresh; updates.Checked = draft.CheckUpdates;
        locked.Checked = draft.LockPosition; through.Checked = draft.ClickThrough;
        login.Checked = LoginItem.Enabled;
        redUp.Checked = draft.RedUpMarkets.Contains("cn") && draft.RedUpMarkets.Contains("hk");
        initializing = false; UpdatePreview();
        ReloadPicker(); LoadGrid();
        HandleCreated += (_, _) => WinTheme.TitleBar(this, WinTheme.SystemTone());
    }

    // ── Watchlists ──

    private TabPage WatchlistTab()
    {
        list.Columns.Add(new DataGridViewTextBoxColumn { Name = "symbol", HeaderText = T("Symbol"), FillWeight = 50 });
        var markets = new[] { new Market("us", T("US / Global")), new Market("cn", T("China A-shares")), new Market("hk", T("Hong Kong")), new Market("crypto", T("Crypto")) };
        list.Columns.Add(new DataGridViewComboBoxColumn { Name = "market", HeaderText = T("Market"), DataSource = markets, ValueMember = "Key", DisplayMember = "Label", FillWeight = 32, DisplayStyle = DataGridViewComboBoxDisplayStyle.DropDownButton });
        var decimals = new DataGridViewComboBoxColumn { Name = "decimals", HeaderText = T("Decimals"), FillWeight = 18, DisplayStyle = DataGridViewComboBoxDisplayStyle.DropDownButton };
        decimals.Items.AddRange(DecimalChoices.Select(c => c == "Auto" ? T("Auto") : c).ToArray<object>());
        list.Columns.Add(decimals);
        list.DataError += (_, e) => { e.ThrowException = false; };
        picker.SelectedIndexChanged += (_, _) =>
        {
            if (picker.SelectedIndex < 0 || picker.SelectedIndex == current) return;
            CommitGrid(); current = picker.SelectedIndex; LoadGrid();
        };
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44, WrapContents = false };
        top.Controls.Add(new Label { Text = T("Current list"), AutoSize = true, Margin = new(3, 10, 6, 3) });
        top.Controls.Add(picker);
        top.Controls.Add(Button("New List", (_, _) => NewList()));
        top.Controls.Add(Button("Rename…", (_, _) => RenameList()));
        top.Controls.Add(deleteList);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44 };
        actions.Controls.Add(Button("Add", (_, _) => AddRow()));
        actions.Controls.Add(Button("Remove", (_, _) => { if (list.CurrentRow is { } row) list.Rows.Remove(row); }));
        actions.Controls.Add(Button("Move Up", (_, _) => MoveRow(-1))); actions.Controls.Add(Button("Move Down", (_, _) => MoveRow(1)));
        var page = Page("Watchlist");
        page.Controls.Add(list); page.Controls.Add(actions);
        page.Controls.Add(new Label { Text = T("The list selected here is shown after saving. Switch lists from the menu or Ctrl-click the ticker."), Dock = DockStyle.Top, Height = 42, ForeColor = SystemColors.GrayText });
        page.Controls.Add(top);
        page.Controls.Add(new Label { Text = T("Examples: AAPL, ^GSPC, 600519, 00700, BTC-USD. Decimals: Auto uses the data source's precision (A-share ETFs 3, FX 4, low-priced crypto more)."), Dock = DockStyle.Bottom, Height = 48, ForeColor = SystemColors.GrayText });
        return page;
    }

    private void AddRow()
    {
        var row = list.Rows.Add("", "us", T("Auto"));
        list.CurrentCell = list.Rows[row].Cells[0]; list.BeginEdit(true);
    }

    private void ReloadPicker()
    {
        picker.BeginUpdate();
        picker.Items.Clear(); picker.Items.AddRange(lists.Select(l => l.Name).ToArray<object>());
        picker.EndUpdate();
        picker.SelectedIndex = current;
        deleteList.Enabled = lists.Count > 1;
    }

    private void LoadGrid()
    {
        list.Rows.Clear();
        foreach (var entry in lists[current].Entries)
            list.Rows.Add(entry.Symbol, entry.Market, entry.Decimals is int d ? d.ToString() : T("Auto"));
    }

    private void CommitGrid()
    {
        list.EndEdit();
        lists[current].Entries = list.Rows.Cast<DataGridViewRow>().Select(r =>
        {
            var symbol = (r.Cells[0].Value?.ToString() ?? "").Trim().ToUpperInvariant();
            var market = r.Cells[1].Value?.ToString() ?? "us";
            int? decimals = int.TryParse(r.Cells[2].Value?.ToString(), out var d) ? d : null;
            return new WatchEntry(symbol, market, decimals);
        }).Where(e => e.Symbol.Length > 0).ToList();
    }

    private void NewList()
    {
        CommitGrid();
        int n = lists.Count + 1;
        while (lists.Any(l => l.Name == $"{T("Watchlist")} {n}")) n++;
        lists.Add(new Watchlist { Name = $"{T("Watchlist")} {n}" });
        current = lists.Count - 1; ReloadPicker(); LoadGrid(); AddRow();
    }

    private void RenameList()
    {
        CommitGrid();
        var name = Prompt.Show(this, T("Rename List"), lists[current].Name);
        if (string.IsNullOrWhiteSpace(name)) return;
        name = name.Trim();
        if (lists.Where((_, i) => i != current).Any(l => l.Name == name)) { Warn(T("A list with this name already exists.")); return; }
        lists[current].Name = name; ReloadPicker();
    }

    private void RemoveList()
    {
        if (lists.Count <= 1) return;
        lists.RemoveAt(current); current = Math.Min(current, lists.Count - 1);
        ReloadPicker(); LoadGrid();
    }

    // ── Display / General ──

    private TabPage DisplayTab()
    {
        var form = FormRows();
        Wide(form, new Label { Text = T("Your desktop, your way"), AutoSize = true, Font = new Font(Font.FontFamily, 17, FontStyle.Bold), Margin = new(0, 0, 0, 8) });
        Wide(form, Note("Choose what stays visible, then place it on your desktop."));
        var surfaces = Flow(); surfaces.Controls.AddRange([tickerCard, boardCard]); Wide(form, surfaces);
        tickerCard.CheckedChanged += (_, _) => { if (!initializing && !tickerCard.Checked && !boardCard.Checked) boardCard.Checked = true; UpdatePreview(); };
        boardCard.CheckedChanged += (_, _) => { if (!initializing && !tickerCard.Checked && !boardCard.Checked) tickerCard.Checked = true; UpdatePreview(); };
        Row(form, "Screen", screen);
        screen.SelectedIndexChanged += (_, _) =>
        {
            if (initializing) return;
            draftFreeCenter = null;
            if (draft.TickerPlacement == "free") { draft.TickerOrigin = null; draft.TickerPlacement = "bottom-center"; placementEdited = true; }
            UpdatePreview();
        };
        Wide(form, preview);
        preview.Dragged += point => { placementEdited = true; draftFreeCenter = null; draft.TickerPlacement = "free"; draft.TickerOrigin = [point.X, point.Y]; UpdatePreview(); };
        preview.WidthEdited += value => SetDraftWidth(value);
        var anchors = new TableLayoutPanel { AutoSize = true, ColumnCount = 3, RowCount = 2, Margin = new(0) };
        foreach (string key in TickerLayout.Placements.Where(p => p != "free"))
        {
            var card = new ChoiceCard(PlacementLabel(key), key, true) { Width = 96, Margin = new(0, 0, 4, 6), Font = new Font(Font.FontFamily, 9), AutoCheck = false };
            card.Click += (_, _) => SelectPlacement(key);
            placementCards[key] = card; anchors.Controls.Add(card);
        }
        var placementGroup = FormRows();
        Wide(placementGroup, new Label { Text = T("Position"), AutoSize = true, Margin = new(0, 0, 0, 8) });
        Wide(placementGroup, anchors);
        var free = new ChoiceCard("Free position", "free", true) { Width = 150, AutoCheck = false };
        free.Click += (_, _) => SelectPlacement("free"); placementCards["free"] = free;
        Wide(placementGroup, free);
        var widthGroup = FormRows(); widthGroup.Margin = new(14, 0, 0, 0);
        Wide(widthGroup, new Label { Text = T("Screen width"), AutoSize = true, Margin = new(0, 0, 0, 8) });
        var sliderRow = Flow(); sliderRow.Controls.AddRange([width, widthLabel]); Wide(widthGroup, sliderRow);
        width.ValueChanged += (_, _) => { if (!initializing) SetDraftWidth(width.Value / 100.0); };
        var presets = Flow();
        foreach (var (label, fraction) in new[] { ("¼", .25), ("½", .5), ("⅔", 2.0 / 3), (T("Full width"), 1.0) })
        {
            var button = Button(label, (_, _) => SetDraftWidth(fraction));
            presets.Controls.Add(button);
        }
        Wide(widthGroup, presets);
        var layoutGroups = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, Margin = new(0, 8, 0, 8) };
        layoutGroups.ColumnStyles.Add(new(SizeType.Percent, 48)); layoutGroups.ColumnStyles.Add(new(SizeType.Percent, 52));
        layoutGroups.Controls.Add(placementGroup, 0, 0); layoutGroups.Controls.Add(widthGroup, 1, 0); Wide(form, layoutGroups);
        Wide(form, Note("Drag the ticker to place it. Drag either end to change its width."));
        Wide(form, Note("Anchors stay attached to the available desktop. Centered tickers expand equally on both sides."));
        Wide(form, topmost); Wide(form, locked); Wide(form, through);
        locked.CheckedChanged += (_, _) => UpdatePreview(); through.CheckedChanged += (_, _) => UpdatePreview();
        Wide(form, Button("Reset Floating Windows", (_, _) => { resetPositions = true; placementEdited = true; draftFreeCenter = null; draft.TickerOrigin = null; draft.BoardOrigin = null; draft.TickerPlacement = "bottom-center"; UpdatePreview(); }));
        var page = Page("Layout"); page.AutoScroll = true; page.Controls.Add(form); return page;
    }

    private TabPage AppearanceTab()
    {
        var form = FormRows();
        Wide(form, new Label { Text = T("Appearance"), AutoSize = true, Font = new Font(Font.FontFamily, 17, FontStyle.Bold), Margin = new(0, 0, 0, 14) });
        var themes = Flow();
        foreach (var (key, title) in new[] { ("system", "System Default"), ("light", "Light"), ("dark", "Dark") })
        {
            var card = new ChoiceCard(title, key) { Width = 174, AutoCheck = false };
            card.Click += (_, _) => { draft.Theme = key; foreach (var item in themeCards) item.Value.Checked = item.Key == key; UpdatePreview(); };
            themeCards[key] = card; themes.Controls.Add(card);
        }
        Wide(form, themes); Row(form, "Scroll speed", speed); Wide(form, Note("columns / sec"));
        Wide(form, arrows); Wide(form, flash); Wide(form, hover);
        Wide(form, Note("Flash color follows the previous quote; daily change keeps its own color."));
        var page = Page("Appearance"); page.AutoScroll = true; page.Controls.Add(form); return page;
    }

    private static string PlacementLabel(string key) => key switch
    {
        "top-left" => "Top left", "top-center" => "Top center", "top-right" => "Top right",
        "bottom-left" => "Bottom left", "bottom-center" => "Bottom center", "bottom-right" => "Bottom right", _ => "Free position",
    };

    private string SelectedScreen => screenKeys.ElementAtOrDefault(screen.SelectedIndex) ?? draft.DisplayScreen;
    private Rectangle SelectedWorkArea => (draft.TickerPlacement == "free" && draft.TickerOrigin is not null && SelectedScreen == draft.DisplayScreen
        ? WindowPlacement.ForOrigin(draft.TickerOrigin, new(800, 40), SelectedScreen) : WindowPlacement.Target(SelectedScreen))?.WorkingArea ?? new(0, 0, 1920, 1040);
    private int InitialWidth() => TickerLayout.Width(draft.TickerWidthFraction,
        (draft.WidthCharacters * 18 + 16) * Math.Max(1, (int)Math.Round(DeviceDpi / 96.0)), SelectedWorkArea.Width);
    private double InitialFraction() => InitialWidth() / (double)Math.Max(1, SelectedWorkArea.Width - 24);

    private void SelectPlacement(string key)
    {
        placementEdited = true; draftFreeCenter = null;
        if (key == "free" && draft.TickerPlacement != "free")
        {
            var area = SelectedWorkArea;
            var origin = TickerLayout.Origin(draft.TickerPlacement, null, new(InitialWidth(), 38), area);
            draft.TickerOrigin = [origin.X, origin.Y];
        }
        draft.TickerPlacement = key; UpdatePreview();
    }

    private void UpdatePreview()
    {
        if (initializing) return;
        preview.WorkArea = SelectedWorkArea; preview.Fraction = InitialFraction(); preview.Placement = draft.TickerPlacement;
        preview.FreeOrigin = draft.TickerOrigin is { Length: 2 } p ? new Point(p[0], p[1]) : null;
        preview.TickerVisible = tickerCard.Checked; preview.BoardVisible = boardCard.Checked;
        preview.LayoutLocked = locked.Checked || through.Checked; preview.PreviewTheme = draft.Theme;
        widthLabel.Text = $"{preview.Fraction:P0}"; width.Enabled = tickerCard.Checked;
        foreach (var pair in placementCards) { pair.Value.Checked = pair.Key == draft.TickerPlacement; pair.Value.Enabled = tickerCard.Checked; }
        preview.Invalidate();
    }

    private void SetDraftWidth(double fraction)
    {
        var area = SelectedWorkArea;
        int oldWidth = InitialWidth();
        fraction = Math.Clamp(fraction, .2, 1);
        if (draft.TickerPlacement == "free" && draft.TickerOrigin is { Length: 2 } saved)
        {
            draftFreeCenter ??= saved[0] + oldWidth / 2.0;
            var size = new Size(TickerLayout.Width(fraction, 0, area.Width), 38);
            var origin = WindowBounds.Clamp(new((int)Math.Round(draftFreeCenter.Value - size.Width / 2.0), saved[1]), size, area, 12);
            draft.TickerOrigin = [origin.X, origin.Y];
        }
        widthEdited = true; draft.TickerWidthFraction = fraction;
        initializing = true; width.Value = Math.Clamp((int)Math.Round(fraction * 100), 20, 100); initializing = false;
        UpdatePreview();
    }

    private static FlowLayoutPanel Flow() => new() { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = new(0) };

    private TabPage GeneralTab()
    {
        var form = FormRows(); Row(form, "Language", language); Wide(form, Note("Language changes apply after saving."));
        Row(form, "Data source", source); Row(form, "Refresh interval", interval);
        Wide(form, Note("30 seconds is recommended. Short intervals may be rate-limited. All displays share one request cycle."));
        Wide(form, smart);
        Wide(form, Note("Uses exchange calendars with holidays and half days (NYSE, SSE/SZSE, HKEX); crypto, futures and FX count as always open. Refreshing resumes at the next open."));
        Wide(form, redUp); Wide(form, login); Wide(form, updates);
        Wide(form, Note("Once a day Whirlpool asks GitHub for the latest release (no identifiers sent). New versions appear in the menu and as a notification."));
        Wide(form, Note("Your watchlist stays on this device. Symbols are sent only to the selected quote provider."));
        var page = Page("General"); page.AutoScroll = true; page.Controls.Add(form); return page;
    }

    private static ComboBox Combo(string[] titles) { var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 310 }; c.Items.AddRange(titles); return c; }
    private static CheckBox Check(string title) => new() { Text = T(title), AutoSize = true };
    private static TabPage Page(string title) => new(T(title)) { Padding = new(18) };
    private static Button Button(string title, EventHandler action) { var b = new Button { Text = T(title), AutoSize = true, MinimumSize = new(82, 30), Padding = new(5, 0, 5, 0) }; b.Click += action; return b; }
    private static Label Note(string title) => new() { Text = T(title), AutoSize = true, MaximumSize = new(600, 0), ForeColor = SystemColors.GrayText, Margin = new(3, 5, 3, 12) };
    private static TableLayoutPanel FormRows() { var p = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2 }; p.ColumnStyles.Add(new(SizeType.Absolute, 155)); p.ColumnStyles.Add(new(SizeType.Percent, 100)); return p; }
    private static void Row(TableLayoutPanel p, string title, Control c) { int row = p.RowCount++; p.Controls.Add(new Label { Text = T(title), AutoSize = true, Anchor = AnchorStyles.Left, Margin = new(3, 10, 3, 10) }, 0, row); c.Margin = new(3, 8, 3, 8); p.Controls.Add(c, 1, row); }
    private static void Wide(TableLayoutPanel p, Control c) { int row = p.RowCount++; p.Controls.Add(c, 0, row); p.SetColumnSpan(c, 2); }
    private void Warn(string message) => MessageBox.Show(this, message, T("Invalid Settings"), MessageBoxButtons.OK, MessageBoxIcon.Warning);

    private void MoveRow(int delta)
    {
        list.EndEdit(); if (list.CurrentRow is not { } row) return; int index = row.Index, next = index + delta;
        if (next < 0 || next >= list.Rows.Count) return;
        var values = row.Cells.Cast<DataGridViewCell>().Select(c => c.Value ?? "").ToArray();
        list.Rows.RemoveAt(index); list.Rows.Insert(next, values); list.CurrentCell = list.Rows[next].Cells[0];
    }

    private void Save()
    {
        CommitGrid();
        for (int i = 0; i < lists.Count; i++)
        {
            var entries = lists[i].Entries;
            if (Settings.ValidEntries(entries)) continue;
            current = i; ReloadPicker(); LoadGrid();
            Warn(T("List “%@”: ").Replace("%@", lists[i].Name) + T(entries.Count == 0 ? "Add at least one symbol." : "Use unique symbols with valid market codes."));
            return;
        }
        draft.Watchlists = lists; draft.ActiveWatchlist = current;
        draft.Language = new[] { "system", "en", "zh-Hans" }[Math.Max(0, language.SelectedIndex)];
        draft.Provider = source.SelectedIndex == 0 ? "real" : "demo";
        draft.RefreshSeconds = (int)interval.Value; draft.ColumnsPerSecond = (int)speed.Value;
        draft.ShowTicker = tickerCard.Checked; draft.ShowBoard = boardCard.Checked;
        draft.ChangeArrows = arrows.Checked; draft.FlashChanges = flash.Checked; draft.AlwaysOnTop = topmost.Checked;
        draft.HoverPause = hover.Checked; draft.SmartRefresh = smart.Checked; draft.CheckUpdates = updates.Checked;
        draft.LockPosition = locked.Checked; draft.ClickThrough = through.Checked;
        var screenKey = screenKeys[Math.Max(0, screen.SelectedIndex)];
        bool screenEdited = screenKey != draft.DisplayScreen || resetPositions;
        if (screenEdited) { if (!placementEdited) draft.TickerOrigin = null; draft.BoardOrigin = null; }
        if (currentSettings?.Invoke() is { } latest)
        {
            TickerLayout.MergeLiveLayout(draft, latest, placementEdited, widthEdited, screenEdited);
            if (widthEdited && !placementEdited && !screenEdited && draft.TickerPlacement == "free" && draft.TickerOrigin is { Length: 2 } saved)
            {
                var area = SelectedWorkArea;
                int oldWidth = TickerLayout.Width(latest.TickerWidthFraction, latest.WidthCharacters * 18 * Math.Max(1, (int)Math.Round(DeviceDpi / 96.0)) + 16, area.Width);
                var origin = TickerLayout.ResizeFreeOrigin(new(saved[0], saved[1]), oldWidth, new(TickerLayout.Width(draft.TickerWidthFraction, oldWidth, area.Width), 38), area);
                draft.TickerOrigin = [origin.X, origin.Y];
            }
        }
        draft.DisplayScreen = screenKey;
        draft.RedUpMarkets.RemoveAll(m => m is "cn" or "hk"); if (redUp.Checked) draft.RedUpMarkets.AddRange(["cn", "hk"]);
        draft.Normalize();
        try
        {
            draft.Save();
            if (login.Checked != LoginItem.Enabled) LoginItem.Set(login.Checked);
            Saved?.Invoke(draft); Close();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            MessageBox.Show(this, e.Message, T("Could Not Save Settings"), MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private record Market(string Key, string Label);
}

/// <summary>Minimal single-line input dialog.</summary>
internal static class Prompt
{
    public static string? Show(IWin32Window owner, string title, string value)
    {
        using var form = new Form
        {
            Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false,
            StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(360, 110), Font = new Font("Segoe UI", 10), AutoScaleMode = AutoScaleMode.Dpi,
        };
        var box = new TextBox { Text = value, Left = 14, Top = 16, Width = 330 };
        var ok = new Button { Text = T("Rename"), DialogResult = DialogResult.OK, Left = 164, Top = 60, Width = 86, Height = 30 };
        var cancel = new Button { Text = T("Cancel"), DialogResult = DialogResult.Cancel, Left = 258, Top = 60, Width = 86, Height = 30 };
        form.Controls.AddRange([box, ok, cancel]); form.AcceptButton = ok; form.CancelButton = cancel;
        return form.ShowDialog(owner) == DialogResult.OK ? box.Text : null;
    }
}
