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
            ticker.ApplyTheme(tone); board.ApplyTheme(tone);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            quotes["AAPL"] = new(81.30, -0.59, DateTimeOffset.UtcNow);
            quotes["510300"] = new(4.582, 1.1, DateTimeOffset.UtcNow, Decimals: 3);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            ticker.ShowBanner("> US");
            using var image = new Bitmap(ticker.Width, ticker.Height);
            ticker.DrawToBitmap(image, ticker.ClientRectangle);
        }
    }
}
