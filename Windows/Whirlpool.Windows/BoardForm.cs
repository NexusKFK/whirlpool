using System.Diagnostics;
using Whirlpool.Core;
using static Whirlpool.Core.I18n;

namespace Whirlpool.Windows;

internal sealed class BoardForm : Form
{
    private readonly DataGridView grid = new()
    {
        Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, AllowUserToResizeRows = false,
        RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, SelectionMode = DataGridViewSelectionMode.FullRowSelect,
        MultiSelect = false, BorderStyle = BorderStyle.None, EnableHeadersVisualStyles = false, CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal,
        ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None,
    };
    private readonly Label status = new() { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(10, 4, 10, 4), AutoEllipsis = true };
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 40 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Dictionary<string, double> previous = [];
    private readonly Dictionary<string, (PriceFlash flash, double since)> pulses = [];
    private Settings settings = new();
    private Tone tone = Tone.Light;
    public event Action<Point>? PositionSaved;
    public event Action? UserClosed;
    public event Action<WatchEntry>? OpenChartRequested;

    public BoardForm()
    {
        Text = "Whirlpool"; ShowInTaskbar = false; Size = new(450, 320); MinimumSize = new(360, 220); AutoScaleMode = AutoScaleMode.Dpi;
        grid.Columns.Add("Symbol", "Symbol"); grid.Columns.Add("Price", "Price"); grid.Columns.Add("Change", "Change");
        grid.Columns[1].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
        grid.Columns[2].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
        grid.DefaultCellStyle.Font = new Font("Consolas", 11);
        grid.RowTemplate.Height = 30;
        grid.CellPainting += PaintPrice;
        grid.CellDoubleClick += (_, e) => { if (e.RowIndex >= 0 && grid.Rows[e.RowIndex].Tag is WatchEntry entry) OpenChartRequested?.Invoke(entry); };
        grid.ShowCellToolTips = true;
        Controls.Add(grid); Controls.Add(status);
        animation.Tick += (_, _) => { if (pulses.Count == 0) { animation.Stop(); return; } grid.InvalidateColumn(1); };
        FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); UserClosed?.Invoke(); } };
        ResizeEnd += (_, _) => PositionSaved?.Invoke(Location);
        VisibleChanged += (_, _) => { if (!Visible) animation.Stop(); };
        HandleCreated += (_, _) => WinTheme.TitleBar(this, tone);
    }

    public void Configure(Settings value)
    {
        settings = value.Clone(); TopMost = settings.AlwaysOnTop;
        grid.Columns[0].HeaderText = T("Symbol"); grid.Columns[1].HeaderText = T("Price"); grid.Columns[2].HeaderText = T("Change");
        WindowPlacement.Apply(this, settings.BoardOrigin, true, settings.DisplayScreen);
    }

    public void ApplyTheme(Tone value)
    {
        tone = value;
        BackColor = grid.BackgroundColor = WinTheme.Surface(tone);
        grid.GridColor = WinTheme.Grid(tone);
        grid.DefaultCellStyle.BackColor = WinTheme.Surface(tone);
        grid.DefaultCellStyle.ForeColor = WinTheme.Text(tone);
        grid.DefaultCellStyle.SelectionBackColor = WinTheme.Selection(tone);
        grid.DefaultCellStyle.SelectionForeColor = WinTheme.Text(tone);
        grid.ColumnHeadersDefaultCellStyle.BackColor = WinTheme.Header(tone);
        grid.ColumnHeadersDefaultCellStyle.ForeColor = WinTheme.Muted(tone);
        grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = WinTheme.Header(tone);
        status.BackColor = WinTheme.Surface(tone);
        status.ForeColor = WinTheme.Muted(tone);
        WinTheme.TitleBar(this, tone);
        SetQuotesColors();
        grid.Invalidate();
    }

    public void SetStatus(string text, DateTimeOffset? time) => status.Text = text + (time is null ? "" : "\n" + T("Updated at") + " " + time.Value.ToLocalTime().ToString("T"));

    private Color Up(bool redUp) => WinTheme.C(redUp ? Palette.Red(tone) : Palette.Green(tone));
    private Color Down(bool redUp) => WinTheme.C(redUp ? Palette.Green(tone) : Palette.Red(tone));

    public void SetQuotes(Settings value, IReadOnlyDictionary<string, Quote> quotes)
    {
        settings = value.Clone();
        var symbols = settings.Watchlist.Where(e => quotes.ContainsKey(e.Symbol)).ToList();
        if (grid.Rows.Count != symbols.Count || symbols.Where((entry, i) => grid.Rows[i].Cells[0].Value?.ToString() != entry.Symbol).Any())
        {
            grid.Rows.Clear();
            foreach (var entry in symbols) { var row = grid.Rows[grid.Rows.Add(entry.Symbol, "", "")]; row.Tag = entry; }
        }
        for (int i = 0; i < symbols.Count; i++)
        {
            var entry = symbols[i]; var quote = quotes[entry.Symbol];
            var places = PriceFlash.DecimalsFor(entry, quote);
            var redUp = settings.RedUpMarkets.Contains(entry.Market);
            var flash = settings.FlashChanges ? PriceFlash.Between(previous.TryGetValue(entry.Symbol, out var old) ? old : null, quote.Price, redUp, places) : null;
            if (flash is not null) { pulses[entry.Symbol] = (flash, clock.Elapsed.TotalSeconds); if (Visible) animation.Start(); }
            previous[entry.Symbol] = quote.Price;
            var row = grid.Rows[i];
            row.Tag = entry;
            row.Cells[0].ToolTipText = T("Double-click to open chart");
            row.Cells[1].Value = PriceFlash.Format(quote.Price, places);
            bool flat = Math.Abs(quote.ChangePct) < 0.005, up = quote.ChangePct >= 0;
            var mark = flat ? "−" : settings.ChangeArrows ? up ? "▲" : "▼" : up ? "+" : "−";
            row.Cells[2].Value = mark + Math.Abs(quote.ChangePct).ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "%";
            row.Cells[2].Tag = flat ? 0 : up ? 1 : -1;
        }
        SetQuotesColors();
    }

    /// <summary>Change colors follow the tone (darker red/green on light backgrounds).</summary>
    private void SetQuotesColors()
    {
        foreach (DataGridViewRow row in grid.Rows)
        {
            if (row.Tag is not WatchEntry entry || row.Cells[2].Tag is not int direction) continue;
            var redUp = settings.RedUpMarkets.Contains(entry.Market);
            var color = direction == 0 ? WinTheme.Text(tone) : direction > 0 ? Up(redUp) : Down(redUp);
            row.Cells[2].Style.ForeColor = color; row.Cells[2].Style.SelectionForeColor = color;
        }
    }

    private void PaintPrice(object? sender, DataGridViewCellPaintingEventArgs e)
    {
        if (e.ColumnIndex != 1 || e.RowIndex < 0) return;
        var symbol = grid.Rows[e.RowIndex].Cells[0].Value?.ToString() ?? "";
        if (!pulses.TryGetValue(symbol, out var pulse)) return;
        if (clock.Elapsed.TotalSeconds - pulse.since >= PriceFlash.Duration) { pulses.Remove(symbol); return; }
        e.PaintBackground(e.ClipBounds, true); e.Paint(e.ClipBounds, DataGridViewPaintParts.Border);
        var font = e.CellStyle!.Font ?? grid.Font;
        const TextFormatFlags flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
        var suffixWidth = TextRenderer.MeasureText(pulse.flash.Suffix, font, Size.Empty, flags).Width;
        var allWidth = TextRenderer.MeasureText(pulse.flash.Prefix + pulse.flash.Suffix, font, Size.Empty, flags).Width;
        var normal = (e.State & DataGridViewElementStates.Selected) != 0 ? e.CellStyle.SelectionForeColor : e.CellStyle.ForeColor;
        TextRenderer.DrawText(e.Graphics!, pulse.flash.Prefix, font, new Rectangle(e.CellBounds.Right - allWidth - 4, e.CellBounds.Top, allWidth - suffixWidth, e.CellBounds.Height), normal, flags);
        var flashColor = WinTheme.C(pulse.flash.Red ? Palette.Red(tone) : Palette.Green(tone));
        TextRenderer.DrawText(e.Graphics!, pulse.flash.Suffix, font, new Rectangle(e.CellBounds.Right - suffixWidth - 4, e.CellBounds.Top, suffixWidth, e.CellBounds.Height), flashColor, flags);
        e.Handled = true;
    }

    /// <summary>Locked: ignore caption drags and the system Move command.</summary>
    protected override void WndProc(ref Message m)
    {
        const int WM_NCLBUTTONDOWN = 0xA1, HTCAPTION = 2, WM_SYSCOMMAND = 0x112, SC_MOVE = 0xF010;
        if (settings.LockPosition && (m.Msg == WM_NCLBUTTONDOWN && (int)m.WParam == HTCAPTION
                                      || m.Msg == WM_SYSCOMMAND && ((int)m.WParam & 0xFFF0) == SC_MOVE)) return;
        base.WndProc(ref m);
    }

    protected override void Dispose(bool disposing) { if (disposing) animation.Dispose(); base.Dispose(disposing); }
}
