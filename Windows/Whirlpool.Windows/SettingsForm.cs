using Whirlpool.Core;
using static Whirlpool.Core.I18n;

namespace Whirlpool.Windows;

internal sealed class SettingsForm : Form
{
    private static readonly string[] DecimalChoices = ["Auto", "0", "1", "2", "3", "4", "5", "6"];
    private readonly Settings draft;
    private readonly List<Watchlist> lists;
    private int current;
    private readonly DataGridView list = new() { Dock = DockStyle.Fill, AllowUserToAddRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = SystemColors.Window, BorderStyle = BorderStyle.FixedSingle };
    private readonly ComboBox picker = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
    private readonly Button deleteList;
    private readonly ComboBox language = Combo([T("System Default"), "English", "简体中文"]);
    private readonly ComboBox source = Combo([T("Yahoo / Tencent"), T("Demo (simulated prices)")]);
    private readonly ComboBox mode = Combo([T("Floating Ticker"), T("Quote Board"), T("Ticker + Board")]);
    private readonly ComboBox theme = Combo([T("System Default"), T("Light"), T("Dark")]);
    private readonly NumericUpDown interval = new() { Minimum = 5, Maximum = 3600, Width = 110 };
    private readonly NumericUpDown speed = new() { Minimum = 10, Maximum = 50, Width = 110 };
    private readonly NumericUpDown width = new() { Minimum = 8, Maximum = 60, Width = 110 };
    private readonly CheckBox arrows = Check("Use ▲ / ▼ for price changes");
    private readonly CheckBox flash = Check("Flash changed price suffixes");
    private readonly CheckBox topmost = Check("Always on top");
    private readonly CheckBox hover = Check("Pause scrolling while the pointer is over the ticker");
    private readonly CheckBox redUp = Check("Red means up in China / Hong Kong");
    private readonly CheckBox smart = Check("Refresh slowly while all watched markets are closed");
    private readonly CheckBox login = Check("Launch at login");
    private readonly CheckBox updates = Check("Check for updates automatically");
    public event Action<Settings>? Saved;

    public SettingsForm(Settings settings)
    {
        draft = settings.Clone();
        lists = draft.Watchlists.Select(l => new Watchlist { Name = l.Name, Entries = [.. l.Entries] }).ToList();
        current = Math.Clamp(draft.ActiveWatchlist, 0, lists.Count - 1);
        deleteList = Button("Delete List", (_, _) => RemoveList());
        Text = T("Whirlpool Settings"); Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        Size = new(760, 680); MinimumSize = new(700, 620); StartPosition = FormStartPosition.CenterScreen;
        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 8) };
        tabs.TabPages.Add(WatchlistTab()); tabs.TabPages.Add(DisplayTab()); tabs.TabPages.Add(GeneralTab());
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 56, FlowDirection = FlowDirection.RightToLeft, Padding = new(12), WrapContents = false };
        var save = Button("Save", (_, _) => Save()); var cancel = Button("Cancel", (_, _) => Close());
        footer.Controls.Add(save); footer.Controls.Add(cancel); AcceptButton = save; CancelButton = cancel;
        Controls.Add(tabs); Controls.Add(footer); Padding = new(14);
        language.SelectedIndex = Math.Max(0, Array.IndexOf(new[] { "system", "en", "zh-Hans" }, draft.Language));
        source.SelectedIndex = draft.Provider == "real" ? 0 : 1;
        mode.SelectedIndex = draft.ShowTicker && draft.ShowBoard ? 2 : draft.ShowBoard ? 1 : 0;
        theme.SelectedIndex = Math.Max(0, Array.IndexOf(new[] { "system", "light", "dark" }, draft.Theme));
        interval.Value = draft.RefreshSeconds; speed.Value = draft.ColumnsPerSecond; width.Value = draft.WidthCharacters;
        arrows.Checked = draft.ChangeArrows; flash.Checked = draft.FlashChanges; topmost.Checked = draft.AlwaysOnTop;
        hover.Checked = draft.HoverPause; smart.Checked = draft.SmartRefresh; updates.Checked = draft.CheckUpdates;
        login.Checked = LoginItem.Enabled;
        redUp.Checked = draft.RedUpMarkets.Contains("cn") && draft.RedUpMarkets.Contains("hk");
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
        Row(form, "Display mode", mode); Row(form, "Scroll speed", speed); Row(form, "Display width", width); Row(form, "Colors", theme);
        Wide(form, new Label { Text = T("columns / sec") + " · " + T("characters"), AutoSize = true, ForeColor = SystemColors.GrayText });
        Wide(form, arrows); Wide(form, flash); Wide(form, topmost); Wide(form, hover);
        Wide(form, Note("Flash color follows the previous quote; daily change keeps its own color."));
        var resetLabel = new Label { AutoSize = true, ForeColor = SystemColors.GrayText };
        Wide(form, Button("Reset Floating Windows", (_, _) => { draft.TickerOrigin = null; draft.BoardOrigin = null; resetLabel.Text = T("Window positions will reset after you save."); }));
        Wide(form, resetLabel);
        var page = Page("Display"); page.Controls.Add(form); return page;
    }

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
        draft.Theme = new[] { "system", "light", "dark" }[Math.Max(0, theme.SelectedIndex)];
        draft.RefreshSeconds = (int)interval.Value; draft.ColumnsPerSecond = (int)speed.Value; draft.WidthCharacters = (int)width.Value;
        draft.ShowTicker = mode.SelectedIndex != 1; draft.ShowBoard = mode.SelectedIndex != 0;
        draft.ChangeArrows = arrows.Checked; draft.FlashChanges = flash.Checked; draft.AlwaysOnTop = topmost.Checked;
        draft.HoverPause = hover.Checked; draft.SmartRefresh = smart.Checked; draft.CheckUpdates = updates.Checked;
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
