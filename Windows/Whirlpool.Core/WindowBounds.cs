using System.Drawing;

namespace Whirlpool.Core;

public static class WindowBounds
{
    /// <summary>Keep a floating window reachable after resizing or disconnecting a display.</summary>
    public static Point Clamp(Point origin, Size size, Rectangle area, int margin = 8) => new(
        Math.Clamp(origin.X, area.Left + margin, Math.Max(area.Left + margin, area.Right - size.Width - margin)),
        Math.Clamp(origin.Y, area.Top + margin, Math.Max(area.Top + margin, area.Bottom - size.Height - margin)));
}
