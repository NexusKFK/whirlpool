using System.Drawing;

namespace Whirlpool.Core;

/// <summary>Geometry shared by the real ticker and the graphical layout editor.</summary>
public static class TickerLayout
{
    public static readonly string[] Placements = ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right", "free"];

    public static int Width(double? fraction, int legacyWidth, int areaWidth, int margin = 12)
    {
        int available = Math.Max(1, areaWidth - margin * 2);
        double requested = fraction is double value && double.IsFinite(value)
            ? available * Math.Clamp(value, .2, 1) : legacyWidth;
        return Math.Clamp((int)Math.Round(requested), Math.Min(120, available), available);
    }

    public static Point Origin(string placement, Point? free, Size size, Rectangle area, int margin = 12)
    {
        if (placement == "free" && free is Point saved) return WindowBounds.Clamp(saved, size, area, margin);
        int x = placement.EndsWith("-left") ? area.Left + margin
            : placement.EndsWith("-right") ? area.Right - size.Width - margin : area.Left + (area.Width - size.Width) / 2;
        int y = placement.StartsWith("top-") ? area.Top + margin : area.Bottom - size.Height - margin;
        return WindowBounds.Clamp(new(x, y), size, area, margin);
    }

    public static Point ResizeFreeOrigin(Point origin, int oldWidth, Size newSize, Rectangle area, int margin = 12) =>
        WindowBounds.Clamp(new(origin.X + (oldWidth - newSize.Width) / 2, origin.Y), newSize, area, margin);

    /// <summary>A settings draft must not undo a drag or edge resize that happened while it was open.</summary>
    public static void MergeLiveLayout(Settings draft, Settings live, bool placementEdited, bool widthEdited, bool screenEdited)
    {
        if (!placementEdited && !screenEdited)
        {
            draft.TickerPlacement = live.TickerPlacement;
            draft.TickerOrigin = live.TickerOrigin?.ToArray();
        }
        if (!widthEdited) draft.TickerWidthFraction = live.TickerWidthFraction;
        if (!screenEdited) draft.BoardOrigin = live.BoardOrigin?.ToArray();
    }
}
