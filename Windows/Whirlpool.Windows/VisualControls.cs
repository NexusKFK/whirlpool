using System.Drawing.Drawing2D;
using System.ComponentModel;
using Whirlpool.Core;
using static Whirlpool.Core.I18n;

namespace Whirlpool.Windows;

/// <summary>Keyboard-accessible option card with a small vector illustration.</summary>
internal sealed class ChoiceCard : CheckBox
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string Illustration { get; set; } = "ticker";
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool Compact { get; set; }
    public ChoiceCard(string text, string illustration, bool compact = false)
    {
        Text = T(text); AccessibleName = Text; Illustration = illustration; Compact = compact;
        AutoSize = false; Appearance = Appearance.Button; FlatStyle = FlatStyle.Flat;
        Size = compact ? new(104, 60) : new(188, 96);
        Margin = new(0, 0, 10, 10); Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        CheckedChanged += (_, _) => Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        float unit = DeviceDpi / 96f;
        var accent = Enabled ? Color.FromArgb(53, 94, 199) : SystemColors.GrayText;
        using var fill = new SolidBrush(Checked ? Color.FromArgb(235, 241, 255) : SystemColors.Window);
        using var border = new Pen(Checked ? accent : SystemColors.ControlDark, Checked ? 1.6f : 1);
        var rect = new RectangleF(1, 1, Width - 3, Height - 3);
        g.FillRound(fill, rect, 9 * unit); g.DrawRound(border, rect, 9 * unit);
        var icon = Compact ? new RectangleF(Width / 2f - 19 * unit, 8 * unit, 38 * unit, 23 * unit)
            : new RectangleF(14 * unit, 13 * unit, 64 * unit, 39 * unit);
        using var ink = new SolidBrush(accent); using var iconPen = new Pen(accent, 1.25f * unit);
        if (Illustration is "light" or "dark" or "system")
        {
            using var sample = new SolidBrush(Illustration == "light" ? Color.FromArgb(244, 245, 247) : Color.FromArgb(39, 44, 54));
            g.FillRound(sample, icon, 5 * unit);
            if (Illustration == "system")
            {
                using var half = new SolidBrush(Color.FromArgb(232, 236, 244));
                g.FillRectangle(half, icon.X + icon.Width / 2, icon.Y + 1, icon.Width / 2 - 1, icon.Height - 2);
            }
            using var line = new Pen(Illustration == "dark" ? Color.FromArgb(109, 211, 173) : accent, 2 * unit);
            g.DrawLine(line, icon.X + 8 * unit, icon.Y + icon.Height / 2, icon.Right - 8 * unit, icon.Y + icon.Height / 2);
        }
        else
        {
            g.DrawRound(iconPen, icon, 3 * unit);
            if (Illustration == "board")
            {
                var board = new RectangleF(icon.Right - 23 * unit, icon.Y + 5 * unit, 18 * unit, icon.Height - 10 * unit);
                g.FillRound(ink, board, 2 * unit);
            }
            else if (Illustration == "free")
            {
                g.DrawLine(iconPen, icon.X + 8 * unit, icon.Y + icon.Height / 2, icon.Right - 8 * unit, icon.Y + icon.Height / 2);
                g.DrawLine(iconPen, icon.X + icon.Width / 2, icon.Y + 5 * unit, icon.X + icon.Width / 2, icon.Bottom - 5 * unit);
            }
            else
            {
                float width = icon.Width * .55f;
                float x = Illustration.EndsWith("-left") ? icon.X + 4 * unit
                    : Illustration.EndsWith("-right") ? icon.Right - width - 4 * unit : icon.X + (icon.Width - width) / 2;
                float y = Illustration.StartsWith("top-") ? icon.Y + 4 * unit : icon.Bottom - 8 * unit;
                g.FillRound(ink, new(x, y, width, 4 * unit), 2 * unit);
            }
        }
        var label = new Rectangle((int)(10 * unit), (int)(Compact ? 34 * unit : 62 * unit), Width - (int)(20 * unit), Height - (int)(Compact ? 36 * unit : 66 * unit));
        TextRenderer.DrawText(g, Text, Font, label, Enabled ? SystemColors.ControlText : SystemColors.GrayText,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Checked && !Compact)
        {
            var x = Width - 24 * unit; var y = 17 * unit;
            using var check = new Pen(accent, 2 * unit);
            g.DrawLines(check, new PointF[] { new(x - 4 * unit, y), new(x, y + 4 * unit), new(x + 7 * unit, y - 4 * unit) });
        }
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -5, -5));
    }
}

/// <summary>The desktop preview edits a settings draft, never the live windows.</summary>
internal sealed class DesktopPreview : Control
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Rectangle WorkArea { get; set; } = new(0, 0, 1920, 1040);
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal double Fraction { get; set; } = .6;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string Placement { get; set; } = "bottom-center";
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Point? FreeOrigin { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool TickerVisible { get; set; } = true;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool BoardVisible { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool LayoutLocked { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string PreviewTheme { get; set; } = "system";
    public event Action<Point>? Dragged;
    public event Action<double>? WidthEdited;
    private RectangleF desktop, ticker;
    private Point dragStart;
    private Point? initialOrigin;
    private RectangleF initialTicker;
    private int operation; // 1: move, 2/3: left/right resize
    // Display old pixel widths faithfully, including values narrower than the new 20% minimum.
    private int ActualWidth => TickerLayout.Width(null, (int)Math.Round(Fraction * Math.Max(1, WorkArea.Width - 24)), WorkArea.Width);

    public DesktopPreview()
    {
        Height = 190; Dock = DockStyle.Top; Margin = new(0, 8, 0, 10);
        AccessibleName = T("Desktop preview"); AccessibleDescription = T("Drag the ticker to place it. Drag either end to change its width.");
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(SystemColors.Window);
        desktop = new RectangleF(1, 1, Width - 3, Height - 22);
        using var wall = new LinearGradientBrush(desktop, Color.FromArgb(230, 237, 247), Color.FromArgb(211, 223, 239), 45);
        using var line = new Pen(Color.FromArgb(190, 202, 219));
        g.FillRound(wall, desktop, 10); g.DrawRound(line, desktop, 10);
        using var window = new SolidBrush(Color.FromArgb(145, 255, 255, 255));
        var ghost = new RectangleF(desktop.X + desktop.Width * .14f, desktop.Y + desktop.Height * .2f, desktop.Width * .55f, desktop.Height * .49f);
        g.FillRound(window, ghost, 8); g.DrawLine(line, ghost.Left, ghost.Top + 24, ghost.Right, ghost.Top + 24);
        for (int i = 0; i < 3; i++) g.DrawLine(line, ghost.Left + 20, ghost.Top + 45 + i * 13, ghost.Left + ghost.Width * (.5f + i % 2 * .2f), ghost.Top + 45 + i * 13);
        if (BoardVisible)
        {
            var board = new RectangleF(desktop.Right - 122, desktop.Top + 26, 105, 102);
            g.FillRound(window, board, 7);
            TextRenderer.DrawText(g, "AAPL  192.45\nSPY    581.30\nQQQ   492.71", Font, Rectangle.Round(RectangleF.Inflate(board, -8, -8)), Color.FromArgb(45, 59, 82));
        }
        if (TickerVisible)
        {
            int actualWidth = ActualWidth;
            int actualHeight = Math.Max(38, (int)(25 * WorkArea.Height / Math.Max(1, desktop.Height)));
            var origin = TickerLayout.Origin(Placement, FreeOrigin, new(actualWidth, actualHeight), WorkArea);
            ticker = new(desktop.Left + (origin.X - WorkArea.Left) * desktop.Width / WorkArea.Width,
                desktop.Top + (origin.Y - WorkArea.Top) * desktop.Height / WorkArea.Height,
                actualWidth * desktop.Width / WorkArea.Width, 25);
            bool dark = PreviewTheme == "dark" || PreviewTheme == "system" && WinTheme.SystemTone() == Tone.Dark;
            using var bar = new SolidBrush(dark ? Color.FromArgb(36, 41, 50) : Color.White);
            g.FillRound(bar, ticker, 9);
            using var outline = new Pen(Color.FromArgb(92, 124, 187)); g.DrawRound(outline, ticker, 9);
            TextRenderer.DrawText(g, "AAPL 192.45  +0.82%    SPY 581.30  +0.24%    QQQ 492.71", Font,
                Rectangle.Round(RectangleF.Inflate(ticker, -9, -2)), dark ? Color.FromArgb(112, 217, 180) : Color.FromArgb(17, 110, 84),
                TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            if (!LayoutLocked)
            {
                g.DrawLine(outline, ticker.Left + 4, ticker.Top + 9, ticker.Left + 4, ticker.Bottom - 9);
                g.DrawLine(outline, ticker.Right - 4, ticker.Top + 9, ticker.Right - 4, ticker.Bottom - 9);
            }
        }
        TextRenderer.DrawText(g, T("Preview · changes apply after saving"), Font, new Rectangle(0, Height - 20, Width, 20), SystemColors.GrayText,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Right);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || !TickerVisible || LayoutLocked || !ticker.Contains(e.Location)) return;
        dragStart = e.Location; initialTicker = ticker;
        int width = ActualWidth;
        int height = Math.Max(38, (int)(25 * WorkArea.Height / Math.Max(1, desktop.Height)));
        initialOrigin = TickerLayout.Origin(Placement, FreeOrigin, new(width, height), WorkArea);
        operation = e.X - ticker.Left < 9 ? 2 : ticker.Right - e.X < 9 ? 3 : 1;
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (operation == 1 && initialOrigin is Point start)
        {
            FreeOrigin = new(start.X + (int)((e.X - dragStart.X) * WorkArea.Width / Math.Max(1, desktop.Width)),
                start.Y + (int)((e.Y - dragStart.Y) * WorkArea.Height / Math.Max(1, desktop.Height)));
            Placement = "free"; Dragged?.Invoke(FreeOrigin.Value); Invalidate();
        }
        else if (operation is 2 or 3)
        {
            double delta = (e.X - dragStart.X) * (operation == 2 ? -1 : 1);
            if (Placement.EndsWith("-center") || Placement == "free") delta *= 2;
            Fraction = Math.Clamp((initialTicker.Width + delta) * WorkArea.Width / Math.Max(1, desktop.Width) / Math.Max(1, WorkArea.Width - 24), .2, 1);
            WidthEdited?.Invoke(Fraction);
            Invalidate();
        }
        else Cursor = TickerVisible && !LayoutLocked && ticker.Contains(e.Location)
            ? e.X - ticker.Left < 9 || ticker.Right - e.X < 9 ? Cursors.SizeWE : Cursors.SizeAll : Cursors.Default;
    }

    protected override void OnMouseUp(MouseEventArgs e) { operation = 0; Capture = false; base.OnMouseUp(e); }
    protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) operation = 0; base.OnMouseCaptureChanged(e); }
}

internal static class VectorDrawing
{
    private static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        float diameter = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
        var path = new GraphicsPath();
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure(); return path;
    }
    public static void FillRound(this Graphics graphics, Brush brush, RectangleF rect, float radius)
    { using var path = Rounded(rect, radius); graphics.FillPath(brush, path); }
    public static void DrawRound(this Graphics graphics, Pen pen, RectangleF rect, float radius)
    { using var path = Rounded(rect, radius); graphics.DrawPath(pen, path); }
}
