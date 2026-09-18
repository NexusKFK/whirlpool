using Pinwheel.Core;
using static Pinwheel.Core.I18n;

namespace Pinwheel.Windows;

internal sealed class SettingsForm : Form
{
    private readonly Settings draft;
    private readonly DataGridView list = new() { Dock = DockStyle.Fill, AllowUserToAddRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = SystemColors.Window, BorderStyle = BorderStyle.FixedSingle };
    private readonly ComboBox language = Combo([T("System Default"), "English", "简体中文"]);
    private readonly ComboBox source = Combo([T("Yahoo / Tencent"), T("Demo (simulated prices)")]);
    private readonly ComboBox mode = Combo([T("Floating Ticker"), T("Quote Board"), T("Ticker + Board")]);
    private readonly NumericUpDown interval = new() { Minimum = 5, Maximum = 3600, Width = 110 };
    private readonly NumericUpDown speed = new() { Minimum = 10, Maximum = 50, Width = 110 };
    private readonly NumericUpDown width = new() { Minimum = 8, Maximum = 60, Width = 110 };
    private readonly CheckBox arrows = new() { Text = T("Use ▲ / ▼ for price changes"), AutoSize = true };
    private readonly CheckBox flash = new() { Text = T("Flash changed price suffixes"), AutoSize = true };
    private readonly CheckBox topmost = new() { Text = T("Always on top"), AutoSize = true };
    private readonly CheckBox redUp = new() { Text = T("Red means up in China / Hong Kong"), AutoSize = true };
    public event Action<Settings>? Saved;
    public SettingsForm(Settings settings)
    {
        draft = settings.Clone();
        Text = T("Pinwheel Settings"); Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        Size = new(700, 600); MinimumSize = new(660, 550); StartPosition = FormStartPosition.CenterScreen;
        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 8) };
        tabs.TabPages.Add(WatchlistTab()); tabs.TabPages.Add(DisplayTab()); tabs.TabPages.Add(GeneralTab());
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 56, FlowDirection = FlowDirection.RightToLeft, Padding = new(12), WrapContents = false };
        var save = Button("Save", (_, _) => Save()); var cancel = Button("Cancel", (_, _) => Close());
        footer.Controls.Add(save); footer.Controls.Add(cancel); AcceptButton = save; CancelButton = cancel;
        Controls.Add(tabs); Controls.Add(footer); Padding = new(14);
        language.SelectedIndex = Array.IndexOf(new[] { "system", "en", "zh-Hans" }, draft.Language);
        source.SelectedIndex = draft.Provider == "real" ? 0 : 1;
        mode.SelectedIndex = draft.ShowTicker && draft.ShowBoard ? 2 : draft.ShowBoard ? 1 : 0;
        interval.Value = draft.RefreshSeconds; speed.Value = draft.ColumnsPerSecond; width.Value = draft.WidthCharacters;
        arrows.Checked = draft.ChangeArrows; flash.Checked = draft.FlashChanges; topmost.Checked = draft.AlwaysOnTop;
        redUp.Checked = draft.RedUpMarkets.Contains("cn") && draft.RedUpMarkets.Contains("hk");
    }
    private TabPage WatchlistTab()
    {
        list.Columns.Add(new DataGridViewTextBoxColumn { Name = "symbol", HeaderText = T("Symbol"), FillWeight = 60 });
        var markets = new[] { new Market("us", T("US / Global")), new Market("cn", T("China A-shares")), new Market("hk", T("Hong Kong")), new Market("crypto", T("Crypto")) };
        list.Columns.Add(new DataGridViewComboBoxColumn { Name = "market", HeaderText = T("Market"), DataSource = markets, ValueMember = "Key", DisplayMember = "Label", FillWeight = 40, DisplayStyle = DataGridViewComboBoxDisplayStyle.DropDownButton });
        foreach (var entry in draft.Watchlist) list.Rows.Add(entry.Symbol, entry.Market);
        list.DataError += (_, e) => { e.ThrowException = false; };
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44 };
        actions.Controls.Add(Button("Add", (_, _) => { var row = list.Rows.Add("", "us"); list.CurrentCell = list.Rows[row].Cells[0]; list.BeginEdit(true); }));
        actions.Controls.Add(Button("Remove", (_, _) => { if (list.CurrentRow is { } row) list.Rows.Remove(row); }));
        actions.Controls.Add(Button("Move Up", (_, _) => Move(-1))); actions.Controls.Add(Button("Move Down", (_, _) => Move(1)));
        var page = Page("Watchlist");
        page.Controls.Add(list); page.Controls.Add(actions);
        page.Controls.Add(new Label { Text = T("Symbols scroll in this order. Double-click a symbol to edit it."), Dock = DockStyle.Top, Height = 42 });
        page.Controls.Add(new Label { Text = T("Examples: AAPL, ^GSPC, 600519, 00700, BTC-USD"), Dock = DockStyle.Bottom, Height = 34 });
        return page;
    }
    private TabPage DisplayTab()
    {
        var form = FormRows();
        Row(form, "Display mode", mode); Row(form, "Scroll speed", speed); Row(form, "Display width", width);
        Wide(form, new Label { Text = T("columns / sec") + " · " + T("characters"), AutoSize = true, ForeColor = SystemColors.GrayText });
        Wide(form, arrows); Wide(form, flash); Wide(form, topmost);
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
        Wide(form, redUp); Wide(form, Note("Your watchlist stays on this device. Symbols are sent only to the selected quote provider."));
        var page = Page("General"); page.Controls.Add(form); return page;
    }
    private static ComboBox Combo(string[] titles) { var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 310 }; c.Items.AddRange(titles); return c; }
    private static TabPage Page(string title) => new(T(title)) { Padding = new(18) };
    private static Button Button(string title, EventHandler action) { var b = new Button { Text = T(title), AutoSize = true, MinimumSize = new(82, 30), Padding = new(5, 0, 5, 0) }; b.Click += action; return b; }
    private static Label Note(string title) => new() { Text = T(title), AutoSize = true, MaximumSize = new(560, 0), ForeColor = SystemColors.GrayText, Margin = new(3, 5, 3, 12) };
    private static TableLayoutPanel FormRows() { var p = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2 }; p.ColumnStyles.Add(new(SizeType.Absolute, 155)); p.ColumnStyles.Add(new(SizeType.Percent, 100)); return p; }
    private static void Row(TableLayoutPanel p, string title, Control c) { int row = p.RowCount++; p.Controls.Add(new Label { Text = T(title), AutoSize = true, Anchor = AnchorStyles.Left, Margin = new(3, 10, 3, 10) }, 0, row); c.Margin = new(3, 8, 3, 8); p.Controls.Add(c, 1, row); }
    private static void Wide(TableLayoutPanel p, Control c) { int row = p.RowCount++; p.Controls.Add(c, 0, row); p.SetColumnSpan(c, 2); }
    private void Move(int delta)
    {
        list.EndEdit(); if (list.CurrentRow is not { } row) return; int index = row.Index, next = index + delta;
        if (next < 0 || next >= list.Rows.Count) return;
        var values = row.Cells.Cast<DataGridViewCell>().Select(c => c.Value).ToArray();
        list.Rows.RemoveAt(index); list.Rows.Insert(next, values); list.CurrentCell = list.Rows[next].Cells[0];
    }
    private void Save()
    {
        list.EndEdit();
        var entries = list.Rows.Cast<DataGridViewRow>().Select(r => new WatchEntry((r.Cells[0].Value?.ToString() ?? "").Trim().ToUpperInvariant(), r.Cells[1].Value?.ToString() ?? "us")).ToList();
        if (!Settings.ValidEntries(entries)) { MessageBox.Show(T(entries.Count == 0 ? "Add at least one symbol." : "Use unique symbols with valid market codes."), T("Invalid Settings"), MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        draft.Watchlist = entries; draft.Language = new[] { "system", "en", "zh-Hans" }[language.SelectedIndex];
        draft.Provider = source.SelectedIndex == 0 ? "real" : "demo";
        draft.RefreshSeconds = (int)interval.Value; draft.ColumnsPerSecond = (int)speed.Value; draft.WidthCharacters = (int)width.Value;
        draft.ShowTicker = mode.SelectedIndex != 1; draft.ShowBoard = mode.SelectedIndex != 0;
        draft.ChangeArrows = arrows.Checked; draft.FlashChanges = flash.Checked; draft.AlwaysOnTop = topmost.Checked;
        draft.RedUpMarkets.RemoveAll(m => m is "cn" or "hk"); if (redUp.Checked) draft.RedUpMarkets.AddRange(["cn", "hk"]);
        try { draft.Save(); Saved?.Invoke(draft); Close(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { MessageBox.Show(e.Message, T("Could Not Save Settings"), MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
    private record Market(string Key, string Label);
}
