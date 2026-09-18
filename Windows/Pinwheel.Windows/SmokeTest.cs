using Pinwheel.Core;
namespace Pinwheel.Windows;
internal static class SmokeTest
{
    public static void Run()
    {
        var config = new Settings { Provider = "demo" };
        var quotes = new Dictionary<string, Quote> { ["AAPL"] = new(81.20, -0.59, DateTimeOffset.UtcNow) };
        foreach (var language in new[] { "en", "zh-Hans" })
        {
            I18n.Language = language; config.Language = language;
            using var settings = new SettingsForm(config);
            using var ticker = new TickerForm();
            using var board = new BoardForm();
            settings.CreateControl(); ticker.CreateControl(); board.CreateControl();
            ticker.Configure(config); board.Configure(config);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            quotes["AAPL"] = new(81.30, -0.59, DateTimeOffset.UtcNow);
            ticker.SetQuotes(config, quotes); board.SetQuotes(config, quotes);
            using var image = new Bitmap(ticker.Width, ticker.Height);
            ticker.DrawToBitmap(image, ticker.ClientRectangle);
        }
    }
}
