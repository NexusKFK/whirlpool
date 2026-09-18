using System.Net;
using System.Text;
using Pinwheel.Core;

static void Check(bool value, string name) { if (!value) throw new Exception("FAILED: " + name); Console.WriteLine("PASS: " + name); }
foreach (var (old, current, prefix, suffix) in new[] { (81.20, 81.30, "81.", "30"), (81.30, 81.20, "81.", "20"), (123.45, 133.45, "1", "33.45"), (99.90, 100.90, "", "100.90"), (1000.01, 1000.02, "1000.0", "2") })
{
    var flash = PriceFlash.Between(old, current, false);
    Check(flash?.Prefix == prefix && flash.Suffix == suffix && flash.Red == (current < old), "price suffix " + current);
}
Check(PriceFlash.Between(null, 81.3, false) is null && PriceFlash.Between(81.301, 81.304, false) is null, "first quote and invisible rounding");
Check(PriceFlash.Between(81.2, 81.3, true)?.Red == true, "red-up market");
Check(QuoteFeed.TencentCode(new("700", "hk")) == "hk00700", "Hong Kong padding");
Check(QuoteFeed.RetryDelay(1) == 30 && QuoteFeed.RetryDelay(10) == 900, "bounded exponential backoff");
Check(!Settings.ValidEntries([new("700", "hk"), new("00700", "hk")]), "canonical duplicate validation");
Check(!Settings.ValidEntries([new("AAPL\\c[red]", "us")]), "invalid symbol rejected");
I18n.Language = "en"; Check(I18n.T("Settings…") == "Settings…", "English");
I18n.Language = "zh-Hans"; Check(I18n.T("Settings…") == "设置…", "Chinese");
var path = Path.Combine(Path.GetTempPath(), "pinwheel-tests-" + Guid.NewGuid(), "config.json");
try
{
    var settings = new Settings { RefreshSeconds = 15, Language = "zh-Hans" }; settings.Save(path);
    Check(Settings.Load(path).RefreshSeconds == 15 && Settings.Load(path).Language == "zh-Hans", "configuration round-trip");
    File.WriteAllText(path, "{\"refreshSeconds\":0}");
    Check(Settings.Load(path).RefreshSeconds == 5 && Settings.Load(path).Watchlist.Count > 0, "old settings defaults and clamping");
    File.WriteAllText(path, "invalid json");
    try { Settings.Load(path); throw new Exception("Expected malformed JSON failure"); } catch (System.Text.Json.JsonException) { }
    Check(File.ReadAllText(path) == "invalid json", "corrupt settings preserved");
}
finally { Directory.Delete(Path.GetDirectoryName(path)!, true); }
var time = DateTimeOffset.Parse("2026-01-01T00:00:00Z");
var handler = new FakeHandler();
using var feed = new QuoteFeed(handler, () => time);
var config = new Settings { Watchlist = [new("TLT", "us")], RefreshSeconds = 30 };
handler.Response = new(HttpStatusCode.OK) { Content = new StringContent("{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":81.3,\"chartPreviousClose\":82}}]}}") };
var initial = await feed.RefreshAsync(config);
Check(initial["TLT"].Price == 81.3 && initial["TLT"].ChangePct < 0 && handler.Calls == 1, "Yahoo parsing");
await feed.RefreshAsync(config); await feed.RefreshAsync(config, true);
Check(handler.Calls == 1, "cache and rapid manual refresh coalesced");
time = time.AddSeconds(31);
handler.Response = new(HttpStatusCode.TooManyRequests); handler.Response.Headers.RetryAfter = new(TimeSpan.FromSeconds(120));
var stale = await feed.RefreshAsync(config);
Check(stale["TLT"].Price == 81.3 && feed.Status == "Rate limited · retrying later", "429 retains last quote");
time = time.AddSeconds(31); await feed.RefreshAsync(config, true);
Check(handler.Calls == 2, "Retry-After respected even on manual refresh");
Console.WriteLine("All Windows core regression checks passed.");

sealed class FakeHandler : HttpMessageHandler
{
    public HttpResponseMessage Response = new(HttpStatusCode.OK);
    public int Calls;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { Calls++; return Task.FromResult(Response); }
}
