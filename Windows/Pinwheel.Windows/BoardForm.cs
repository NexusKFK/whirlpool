using System.Diagnostics;
using Pinwheel.Core;
using static Pinwheel.Core.I18n;

namespace Pinwheel.Windows;

internal sealed class BoardForm : Form
{
    private readonly DataGridView grid = new() { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, SelectionMode = DataGridViewSelectionMode.FullRowSelect, MultiSelect = false, BorderStyle = BorderStyle.None, BackgroundColor = SystemColors.Window };
    private readonly Label status = new() { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(10, 4, 10, 4), ForeColor = SystemColors.GrayText, AutoEllipsis = true };
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 40 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Dictionary<string, double> previous = [];
    private readonly Dictionary<string, (PriceFlash flash, double since)> pulses = [];
    private Settings settings = new();
    public event Action<Point>? PositionSaved;
    public event Action? UserClosed;
    public BoardForm()
    {
        Text = "Pinwheel"; ShowInTaskbar = false; Size = new(450, 320); MinimumSize = new(360, 220); AutoScaleMode = AutoScaleMode.Dpi;
        grid.Columns.Add("Symbol", "Symbol"); grid.Columns.Add("Price", "Price"); grid.Columns.Add("Change", "Change");
        grid.Columns[1].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
        grid.Columns[2].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
        grid.DefaultCellStyle.Font = new Font("Consolas", 11);
        grid.RowTemplate.Height = 30;
        grid.CellPainting += PaintPrice;
        Controls.Add(grid); Controls.Add(status);
        animation.Tick += (_, _) => { if (pulses.Count == 0) { animation.Stop(); return; } grid.InvalidateColumn(1); };
        FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); UserClosed?.Invoke(); } };
        ResizeEnd += (_, _) => PositionSaved?.Invoke(Location);
        VisibleChanged += (_, _) => { if (!Visible) animation.Stop(); };
    }
    public void Configure(Settings value)
    {
        settings = value.Clone(); TopMost = settings.AlwaysOnTop;
        grid.Columns[0].HeaderText = T("Symbol"); grid.Columns[1].HeaderText = T("Price"); grid.Columns[2].HeaderText = T("Change");
        WindowPlacement.Apply(this, settings.BoardOrigin, true);
    }
    public void SetStatus(string text, DateTimeOffset? time) => status.Text = text + (time is null ? "" : "\n" + T("Updated at") + " " + time.Value.ToLocalTime().ToString("T"));
    public void SetQuotes(Settings value, IReadOnlyDictionary<string, Quote> quotes)
    {
        settings = value.Clone();
        var symbols = settings.Watchlist.Where(e => quotes.ContainsKey(e.Symbol)).ToList();
        if (grid.Rows.Count != symbols.Count || symbols.Where((entry, i) => grid.Rows[i].Cells[0].Value?.ToString() != entry.Symbol).Any())
        {
            grid.Rows.Clear(); foreach (var entry in symbols) grid.Rows.Add(entry.Symbol, "", "");
        }
        for (int i = 0; i < symbols.Count; i++)
        {
            var entry = symbols[i]; var quote = quotes[entry.Symbol];
            var flash = settings.FlashChanges ? PriceFlash.Between(previous.TryGetValue(entry.Symbol, out var old) ? old : null, quote.Price, settings.RedUpMarkets.Contains(entry.Market)) : null;
            if (flash is not null) { pulses[entry.Symbol] = (flash, clock.Elapsed.TotalSeconds); if (Visible) animation.Start(); }
            previous[entry.Symbol] = quote.Price;
            grid.Rows[i].Cells[1].Value = PriceFlash.Format(quote.Price);
            bool flat = Math.Abs(quote.ChangePct) < 0.005, up = quote.ChangePct >= 0;
            var mark = flat ? "−" : settings.ChangeArrows ? up ? "▲" : "▼" : up ? "+" : "−";
            grid.Rows[i].Cells[2].Value = mark + Math.Abs(quote.ChangePct).ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "%";
            var color = flat ? SystemColors.WindowText : up == settings.RedUpMarkets.Contains(entry.Market) ? Color.Firebrick : Color.SeaGreen;
            grid.Rows[i].Cells[2].Style.ForeColor = color; grid.Rows[i].Cells[2].Style.SelectionForeColor = color;
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
        TextRenderer.DrawText(e.Graphics!, pulse.flash.Suffix, font, new Rectangle(e.CellBounds.Right - suffixWidth - 4, e.CellBounds.Top, suffixWidth, e.CellBounds.Height), pulse.flash.Red ? Color.Firebrick : Color.SeaGreen, flags);
        e.Handled = true;
    }
    protected override void Dispose(bool disposing) { if (disposing) animation.Dispose(); base.Dispose(disposing); }
}
