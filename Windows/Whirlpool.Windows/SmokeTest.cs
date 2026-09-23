using Whirlpool.Core;
namespace Whirlpool.Windows;

/// <summary><c>Whirlpool.exe --smoke-test</c>: builds every window in both languages and tones without showing them.</summary>
internal static class SmokeTest
{
    public static void Run()
    {
        var config = new Settings { Provider = "demo" };
        config.Watchlists = [new() { Name = "US", Entries = [new("AAPL", "us"), new("510300", "cn", 3)] }, new() { Name = "自选股", Entries = [new("700", "hk")] }];
        config.Normalize();
        var quotes = new Dictionary<string, Quote> { ["AAPL"] = new(81.20, -0.59, DateTimeOffset.UtcNow), ["510300"] = new(4.580, 1.1, DateTimeOffset.UtcNow, Decimals: 3) };
        foreach (var language in new[] { "en", "zh-Hans" })
        foreach (var tone in new[] { Tone.Dark, Tone.Light })
        {
            I18n.Language = language; config.Language = language;
            using var settings = new SettingsForm(config);
            using var ticker = new TickerForm();
            using var board = new BoardForm();
            settings.CreateControl(); ticker.CreateControl(); board.CreateControl();
            ticker.Configure(config); board.Configure(config);
            var area = WindowPlacement.Target(config.DisplayScreen)!.WorkingArea;
            foreach (string anchor in TickerLayout.Placements.Where(p => p != "free"))
            {
                var placed = config.Clone(); placed.TickerPlacement = anchor; placed.TickerWidthFraction = .5;
                ticker.Configure(placed);
                int margin = Math.Max(12, (int)Math.Round(12 * ticker.DeviceDpi / 96.0));
                if (ticker.Location != TickerLayout.Origin(anchor, null, ticker.Size, area, margin)
                    || ticker.Width != TickerLayout.Width(.5, 0, area.Width, margin))
                    throw new Exception("Ticker geometry does not match the graphical layout editor: " + anchor);
            }
            ticker.Configure(config);
            var tabs = settings.Controls.OfType<TabControl>().Single();
            foreach (TabPage page in tabs.TabPages)
            {
                tabs.SelectedTab = page;
                settings.PerformLayout();
                using var layoutImage = new Bitmap(settings.Width, settings.Height);
                settings.DrawToBitmap(layoutImage, settings.ClientRectangle);
            }
            ticker.ApplyTheme(tone); board.ApplyTheme(tone);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            quotes["AAPL"] = new(81.30, -0.59, DateTimeOffset.UtcNow);
            quotes["510300"] = new(4.582, 1.1, DateTimeOffset.UtcNow, Decimals: 3);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            ticker.ShowBanner("> US");
            using var image = new Bitmap(ticker.Width, ticker.Height);
            ticker.DrawToBitmap(image, ticker.ClientRectangle);
            var switched = config.Clone(); switched.ActiveWatchlist = 1;
            ticker.Configure(switched); board.Configure(switched);
            if (board.Controls.OfType<DataGridView>().Single().Rows.Count != 0)
                throw new Exception("Switching watchlists left stale board rows visible.");
            using var emptyTicker = new TickerForm();
            emptyTicker.Configure(switched); emptyTicker.ApplyTheme(tone);
            using var actual = new Bitmap(ticker.Width, ticker.Height);
            using var expected = new Bitmap(emptyTicker.Width, emptyTicker.Height);
            ticker.DrawToBitmap(actual, ticker.ClientRectangle);
            emptyTicker.DrawToBitmap(expected, emptyTicker.ClientRectangle);
            for (int y = 0; y < actual.Height; y++)
                for (int x = 0; x < actual.Width; x++)
                    if (actual.GetPixel(x, y) != expected.GetPixel(x, y))
                        throw new Exception("Switching watchlists retained the previous ticker strip or banner.");
        }
    }
}
