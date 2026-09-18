using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Pinwheel.Core;

namespace Pinwheel.Windows;

internal sealed class TickerForm : Form
{
    private record Column(byte Bits, Color Color);
    private sealed class Pulse(int start, int end, Color color) { public int Start = start, End = end; public Color Color = color; public double? Since; }
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 20 };
    private readonly System.Windows.Forms.Timer moved = new() { Interval = 300 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly List<Column> columns = [];
    private readonly List<Pulse> pulses = [];
    private readonly Dictionary<string, double> previous = [];
    private static readonly Dictionary<string, byte[]> Glyphs = LoadFont();
    private Settings settings = new();
    private IReadOnlyDictionary<string, Quote> pending = new Dictionary<string, Quote>();
    private double offset, lastTick;
    private bool placing;
    private string signature = "";
    public event Action<Point>? PositionSaved;
    public TickerForm()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; DoubleBuffered = true;
        BackColor = Color.FromArgb(20, 22, 27); Height = 38; Text = "Pinwheel";
        AutoScaleMode = AutoScaleMode.Dpi;
        animation.Tick += (_, _) =>
        {
            var now = clock.Elapsed.TotalSeconds;
            offset += Math.Min(0.1, now - lastTick) * settings.ColumnsPerSecond; lastTick = now;
            if (columns.Count > 0 && offset >= columns.Count) { offset %= columns.Count; ApplyPending(); }
            Invalidate();
        };
        VisibleChanged += (_, _) => { lastTick = clock.Elapsed.TotalSeconds; if (Visible) animation.Start(); else animation.Stop(); };
        Move += (_, _) => { if (!placing) { moved.Stop(); moved.Start(); } };
        moved.Tick += (_, _) => { moved.Stop(); PositionSaved?.Invoke(Location); };
        MouseDown += (_, e) => { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, 2, 0); } };
    }
    public void Configure(Settings value)
    {
        bool changedLayout = value.WidthCharacters != settings.WidthCharacters;
        settings = value.Clone(); TopMost = settings.AlwaysOnTop;
        placing = true; Width = Math.Min(settings.WidthCharacters * 18 + 16, Screen.PrimaryScreen?.WorkingArea.Width - 20 ?? 1200);
        WindowPlacement.Apply(this, settings.TickerOrigin, false); placing = false;
        if (changedLayout) offset = 0;
        signature = ""; ApplyPending();
    }
    public void SetQuotes(Settings value, IReadOnlyDictionary<string, Quote> quotes)
    {
        settings = value.Clone(); pending = quotes;
        if (columns.Count == 0) ApplyPending();
    }
    private void ApplyPending()
    {
        var nextSignature = string.Join('|', settings.Watchlist.Where(e => pending.ContainsKey(e.Symbol))
            .Select(e => e.Symbol + ":" + PriceFlash.Format(pending[e.Symbol].Price) + ":" + pending[e.Symbol].ChangePct.ToString("F2", System.Globalization.CultureInfo.InvariantCulture)));
        if (nextSignature == signature) return;
        signature = nextSignature; columns.Clear(); pulses.Clear();
        foreach (var entry in settings.Watchlist)
        {
            if (!pending.TryGetValue(entry.Symbol, out var quote)) continue;
            Append(entry.Symbol + " ", Color.White);
            var redUp = settings.RedUpMarkets.Contains(entry.Market);
            var flash = settings.FlashChanges ? PriceFlash.Between(previous.TryGetValue(entry.Symbol, out var old) ? old : null, quote.Price, redUp) : null;
            if (flash is not null)
            {
                Append(flash.Prefix, Color.White); var begin = columns.Count;
                Append(flash.Suffix, Color.White);
                pulses.Add(new(begin, columns.Count, flash.Red ? Color.Tomato : Color.SpringGreen));
            }
            else Append(PriceFlash.Format(quote.Price), Color.White);
            previous[entry.Symbol] = quote.Price;
            Append(" ", Color.White);
            var flat = Math.Abs(quote.ChangePct) < 0.005;
            var up = quote.ChangePct >= 0;
            var marker = flat ? "-" : settings.ChangeArrows ? up ? "▲" : "▼" : up ? "+" : "-";
            Append(marker + Math.Abs(quote.ChangePct).ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "%   ", flat ? Color.White : up == redUp ? Color.Tomato : Color.SpringGreen);
        }
        if (offset >= columns.Count) offset = 0;
    }
    private void Append(string text, Color color)
    {
        foreach (var ch in text.ToUpperInvariant()) foreach (byte b in Glyphs.GetValueOrDefault(ch.ToString(), Glyphs[" "])) columns.Add(new(b, color));
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (columns.Count == 0) { TextRenderer.DrawText(e.Graphics, I18n.T("Loading quotes…"), SystemFonts.MessageBoxFont, ClientRectangle, Color.Silver, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter); return; }
        int count = Math.Max(1, (Width - 16) / 3), start = (int)offset;
        double now = clock.Elapsed.TotalSeconds;
        var active = new Dictionary<int, Color>();
        foreach (var pulse in pulses)
        {
            for (int copy = 0; copy <= (start + count) / columns.Count; copy++)
            {
                int a = pulse.Start + copy * columns.Count, b = pulse.End + copy * columns.Count;
                if (pulse.Since is null && b > start + 8 && a < start + count - 8 && (b <= start + count - 8 || b - a > count - 16)) pulse.Since = now;
                if (pulse.Since is double since && now - since < PriceFlash.Duration)
                    for (int column = Math.Max(a, start); column < Math.Min(b, start + count); column++) active[column] = pulse.Color;
            }
        }
        for (int x = 0; x < count; x++)
        {
            var col = columns[(start + x) % columns.Count];
            var color = active.GetValueOrDefault(start + x, col.Color);
            int alpha = (int)(255 * Math.Min(1, Math.Min(x, count - 1 - x) / 8.0));
            using var brush = new SolidBrush(Color.FromArgb(Math.Max(0, alpha), color));
            for (int y = 0; y < 8; y++) if ((col.Bits & (1 << y)) != 0) e.Graphics.FillRectangle(brush, 8 + x * 3, (Height - 24) / 2 + y * 3, 2, 2);
        }
    }
    private static Dictionary<string, byte[]> LoadFont()
    {
        var assembly = typeof(TickerForm).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith("font.json")))!;
        var data = JsonSerializer.Deserialize<Dictionary<string, int[]>>(stream)!;
        return data.ToDictionary(kv => kv.Key, kv => kv.Value.Select(n => (byte)n).ToArray());
    }
    protected override void Dispose(bool disposing) { if (disposing) { animation.Dispose(); moved.Dispose(); } base.Dispose(disposing); }
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr handle, int msg, int wParam, int lParam);
}
