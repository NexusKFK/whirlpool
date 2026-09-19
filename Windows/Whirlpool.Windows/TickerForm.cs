using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;
using Whirlpool.Core;

namespace Whirlpool.Windows;

/// <summary>
/// Floating LED ticker. Each round is rendered once into a strip bitmap; a frame only blits the
/// visible slice, the changed-digit overlays and the edge fades (instead of ~1,000 dot fills per frame).
/// </summary>
internal sealed class TickerForm : Form
{
    private enum Ink : byte { Neutral, Green, Red }
    private readonly record struct Column(byte Bits, Ink Ink);
    private sealed class Pulse(int start, int end, Ink ink)
    {
        public readonly int Start = start, End = end;
        public readonly Ink Ink = ink;
        public double? Since;
        public Bitmap? Overlay;
    }

    private readonly System.Windows.Forms.Timer animation = new() { Interval = 16 };
    private readonly System.Windows.Forms.Timer moved = new() { Interval = 300 };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly List<Column> columns = [];
    private readonly List<Pulse> pulses = [];
    private readonly Dictionary<string, double> previous = [];
    private static readonly Dictionary<string, byte[]> Glyphs = LoadFont();
    private Settings settings = new();
    private IReadOnlyDictionary<string, Quote> pending = new Dictionary<string, Quote>();
    private double offset, lastTick, bannerUntil;
    private bool placing, hovering;
    private string signature = "";
    private Tone tone = Tone.Dark;
    private Bitmap? strip, banner;
    private int scale = 1;
    private int Pitch => 3 * scale;
    private int Dot => 2 * scale;
    private int Inset => 8 * scale;

    public event Action<Point>? PositionSaved;
    public event Action? NextWatchlistRequested;

    public TickerForm()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; Text = "Whirlpool";
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        BackColor = WinTheme.C(Palette.Background(tone));
        animation.Tick += (_, _) =>
        {
            var now = clock.Elapsed.TotalSeconds;
            // Hover pauses the motion so a price can be read; the clock keeps running.
            if (!(hovering && settings.HoverPause)) offset += Math.Min(0.1, now - lastTick) * settings.ColumnsPerSecond;
            lastTick = now;
            if (columns.Count > 0 && offset >= columns.Count) { offset %= columns.Count; ApplyPending(); }
            Invalidate();
        };
        VisibleChanged += (_, _) => { lastTick = clock.Elapsed.TotalSeconds; if (Visible) animation.Start(); else animation.Stop(); };
        Move += (_, _) => { if (!placing) { moved.Stop(); moved.Start(); } };
        moved.Tick += (_, _) => { moved.Stop(); PositionSaved?.Invoke(Location); };
        MouseEnter += (_, _) => hovering = true;
        MouseLeave += (_, _) => hovering = false;
        MouseDown += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            if ((ModifierKeys & Keys.Control) != 0) { NextWatchlistRequested?.Invoke(); return; }   // Ctrl+click: next watchlist
            if (settings.LockPosition) return;                                                       // locked: no dragging
            ReleaseCapture(); SendMessage(Handle, 0xA1, 2, 0);                                       // drag the borderless window
        };
        HandleCreated += (_, _) => { WinTheme.RoundCorners(this); ApplyClickThrough(); };
    }

    private const int GWL_EXSTYLE = -20, WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20;

    /// <summary>Click-through: a layered + transparent window lets the mouse reach the windows below.</summary>
    private void ApplyClickThrough()
    {
        if (!IsHandleCreated) return;
        var style = GetWindowLong(Handle, GWL_EXSTYLE);
        var wanted = settings.ClickThrough ? style | WS_EX_LAYERED | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT;
        if (wanted == style) return;
        SetWindowLong(Handle, GWL_EXSTYLE, wanted);
        if ((wanted & WS_EX_LAYERED) != 0) SetLayeredWindowAttributes(Handle, 0, 255, 0x2);   // LWA_ALPHA, fully opaque
    }

    /// <summary>Pause or resume the animation (sleep, lock, paused from the tray).</summary>
    public void SetRunning(bool running)
    {
        lastTick = clock.Elapsed.TotalSeconds;
        if (running && Visible) animation.Start(); else animation.Stop();
    }

    public void Configure(Settings value)
    {
        bool changedLayout = value.WidthCharacters != settings.WidthCharacters;
        settings = value.Clone(); TopMost = settings.AlwaysOnTop;
        scale = Math.Max(1, (int)Math.Round(DeviceDpi / 96.0));
        placing = true;
        Height = 8 * Pitch + 14 * scale;
        Width = Math.Min(settings.WidthCharacters * 18 * scale + 2 * Inset, (WindowPlacement.Target(settings.DisplayScreen)?.WorkingArea.Width ?? 1220) - 20);
        WindowPlacement.Apply(this, settings.TickerOrigin, false, settings.DisplayScreen); placing = false;
        ApplyClickThrough();
        if (changedLayout) offset = 0;
        signature = ""; ApplyPending(); RenderStrip();
    }

    public void ApplyTheme(Tone value)
    {
        tone = value;
        BackColor = WinTheme.C(Palette.Background(tone));
        RenderStrip(); Invalidate();
    }

    public void SetQuotes(Settings value, IReadOnlyDictionary<string, Quote> quotes)
    {
        settings = value.Clone(); pending = quotes;
        if (columns.Count == 0) ApplyPending();
    }

    /// <summary>Briefly shows a static label (the watchlist name after switching).</summary>
    public void ShowBanner(string text, double seconds = 1.2)
    {
        var cols = new List<Column>();
        AppendTo(cols, text, Ink.Neutral);
        banner?.Dispose();
        banner = Render(cols, null);
        bannerUntil = clock.Elapsed.TotalSeconds + seconds;
        Invalidate();
    }

    public static bool CanRender(string text) => text.ToUpperInvariant().All(c => Glyphs.ContainsKey(c.ToString()));

    private void ApplyPending()
    {
        var nextSignature = string.Join('|', settings.Watchlist.Where(e => pending.ContainsKey(e.Symbol))
            .Select(e => e.Symbol + ":" + PriceFlash.Format(pending[e.Symbol].Price, PriceFlash.DecimalsFor(e, pending[e.Symbol])) + ":"
                         + pending[e.Symbol].ChangePct.ToString("F2", System.Globalization.CultureInfo.InvariantCulture)));
        if (nextSignature == signature) return;
        signature = nextSignature; columns.Clear(); ClearPulses();
        foreach (var entry in settings.Watchlist)
        {
            if (!pending.TryGetValue(entry.Symbol, out var quote)) continue;
            var places = PriceFlash.DecimalsFor(entry, quote);
            Append(entry.Symbol + " ", Ink.Neutral);
            var redUp = settings.RedUpMarkets.Contains(entry.Market);
            var flash = settings.FlashChanges ? PriceFlash.Between(previous.TryGetValue(entry.Symbol, out var old) ? old : null, quote.Price, redUp, places) : null;
            if (flash is not null)
            {
                Append(flash.Prefix, Ink.Neutral); var begin = columns.Count;
                Append(flash.Suffix, Ink.Neutral);
                pulses.Add(new(begin, columns.Count, flash.Red ? Ink.Red : Ink.Green));
            }
            else Append(PriceFlash.Format(quote.Price, places), Ink.Neutral);
            previous[entry.Symbol] = quote.Price;
            Append(" ", Ink.Neutral);
            var flat = Math.Abs(quote.ChangePct) < 0.005;
            var up = quote.ChangePct >= 0;
            var marker = flat ? "-" : settings.ChangeArrows ? up ? "▲" : "▼" : up ? "+" : "-";
            Append(marker + Math.Abs(quote.ChangePct).ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "%", flat ? Ink.Neutral : up == redUp ? Ink.Red : Ink.Green);
            Append("   ", Ink.Neutral);
        }
        if (offset >= columns.Count) offset = 0;
        RenderStrip();
    }

    private void Append(string text, Ink ink) => AppendTo(columns, text, ink);
    private static void AppendTo(List<Column> target, string text, Ink ink)
    {
        foreach (var ch in text.ToUpperInvariant()) foreach (byte b in Glyphs.GetValueOrDefault(ch.ToString(), Glyphs[" "])) target.Add(new(b, ink));
    }

    private void ClearPulses() { foreach (var p in pulses) p.Overlay?.Dispose(); pulses.Clear(); }

    private Color InkColor(Ink ink) => WinTheme.C(ink switch { Ink.Green => Palette.Green(tone), Ink.Red => Palette.Red(tone), _ => Palette.Neutral(tone) });

    /// <summary>Draws columns (or only [range] in a flash color) into a transparent bitmap, once per round.</summary>
    private Bitmap? Render(List<Column> source, (int Start, int End, Ink Ink)? only)
    {
        int start = only?.Start ?? 0, end = only?.End ?? source.Count;
        if (end <= start) return null;
        var bitmap = new Bitmap((end - start) * Pitch, 8 * Pitch, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        var brushes = new Dictionary<Ink, SolidBrush>();
        try
        {
            for (int i = start; i < end; i++)
            {
                var col = source[i];
                var ink = only?.Ink ?? col.Ink;
                if (!brushes.TryGetValue(ink, out var brush)) brushes[ink] = brush = new SolidBrush(InkColor(ink));
                for (int y = 0; y < 8; y++)
                    if ((col.Bits & (1 << y)) != 0) g.FillRectangle(brush, (i - start) * Pitch, y * Pitch, Dot, Dot);
            }
        }
        finally { foreach (var b in brushes.Values) b.Dispose(); }
        return bitmap;
    }

    private void RenderStrip()
    {
        strip?.Dispose();
        strip = Render(columns, null);
        foreach (var p in pulses) { p.Overlay?.Dispose(); p.Overlay = Render(columns, (p.Start, p.End, p.Ink)); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        int y = (Height - 8 * Pitch) / 2 + scale, viewWidth = Math.Max(1, Width - 2 * Inset);
        if (banner is not null && clock.Elapsed.TotalSeconds < bannerUntil)
        {
            g.SetClip(new Rectangle(Inset, 0, viewWidth, Height));
            g.DrawImage(banner, new Rectangle(Inset, y, banner.Width, banner.Height));
            return;
        }
        if (columns.Count == 0 || strip is null)
        {
            TextRenderer.DrawText(g, I18n.T("Loading quotes…"), SystemFonts.MessageBoxFont, ClientRectangle, InkColor(Ink.Neutral),
                                  TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
            return;
        }
        g.SetClip(new Rectangle(Inset, 0, viewWidth, Height));
        int count = viewWidth / Pitch, start = (int)offset;
        int shift = (int)Math.Round(offset * Pitch);
        for (int x = Inset - shift; x < Inset + viewWidth; x += strip.Width)
            g.DrawImage(strip, new Rectangle(x, y, strip.Width, strip.Height));

        // Changed-digit flash: one pulse when the suffix becomes readable, never blanking the digits.
        double now = clock.Elapsed.TotalSeconds;
        foreach (var pulse in pulses)
        {
            if (pulse.Overlay is null) continue;
            for (int copy = 0; copy <= (start + count) / columns.Count; copy++)
            {
                int a = pulse.Start + copy * columns.Count, b = pulse.End + copy * columns.Count;
                if (pulse.Since is null && b > start + 8 && a < start + count - 8 && (b <= start + count - 8 || b - a > count - 16)) pulse.Since = now;
                if (pulse.Since is double since && now - since < PriceFlash.Duration)
                    g.DrawImage(pulse.Overlay, new Rectangle(Inset + a * Pitch - shift, y, pulse.Overlay.Width, pulse.Overlay.Height));
            }
        }

        // Soft edges: fade into the background over eight columns on each side.
        int fade = Math.Min(8 * Pitch, viewWidth / 2);
        using (var left = new LinearGradientBrush(new Rectangle(Inset - 1, 0, fade + 1, Height), BackColor, Color.FromArgb(0, BackColor), LinearGradientMode.Horizontal))
            g.FillRectangle(left, Inset, 0, fade, Height);
        using (var right = new LinearGradientBrush(new Rectangle(Inset + viewWidth - fade - 1, 0, fade + 1, Height), Color.FromArgb(0, BackColor), BackColor, LinearGradientMode.Horizontal))
            g.FillRectangle(right, Inset + viewWidth - fade, 0, fade, Height);
    }

    private static Dictionary<string, byte[]> LoadFont()
    {
        var assembly = typeof(TickerForm).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith("font.json")))!;
        var data = JsonSerializer.Deserialize<Dictionary<string, int[]>>(stream)!;
        return data.ToDictionary(kv => kv.Key, kv => kv.Value.Select(n => (byte)n).ToArray());
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { animation.Dispose(); moved.Dispose(); strip?.Dispose(); banner?.Dispose(); ClearPulses(); }
        base.Dispose(disposing);
    }

    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr handle, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr handle, int index, int value);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr handle, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr handle, int msg, int wParam, int lParam);
}
