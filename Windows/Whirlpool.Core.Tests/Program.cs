using System.Net;
using System.Text;
using Whirlpool.Core;

static void Check(bool value, string name) { if (!value) throw new Exception("FAILED: " + name); Console.WriteLine("PASS: " + name); }
static DateTimeOffset At(string local, string zone)
{
    var tz = TimeZoneInfo.FindSystemTimeZoneById(zone);
    var dt = DateTime.ParseExact(local, "yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture);
    return new DateTimeOffset(dt, tz.GetUtcOffset(dt));
}

// ── Price flashes and precision ──
foreach (var (old, current, prefix, suffix) in new[] { (81.20, 81.30, "81.", "30"), (81.30, 81.20, "81.", "20"), (123.45, 133.45, "1", "33.45"), (99.90, 100.90, "", "100.90"), (1000.01, 1000.02, "1000.0", "2") })
{
    var flash = PriceFlash.Between(old, current, false);
    Check(flash?.Prefix == prefix && flash.Suffix == suffix && flash.Red == (current < old), "price suffix " + current);
}
Check(PriceFlash.Between(null, 81.3, false) is null && PriceFlash.Between(81.301, 81.304, false) is null, "first quote and invisible rounding");
Check(PriceFlash.Between(81.2, 81.3, true)?.Red == true, "red-up market");
var tick = PriceFlash.Between(4.580, 4.582, true, 3);
Check(tick?.Prefix == "4.58" && tick.Suffix == "2" && PriceFlash.Between(4.580, 4.582, true) is null, "3-decimal flash (2 places would hide it)");
var etf = new WatchEntry("510300", "cn");
Check(PriceFlash.DecimalsFor(etf, new Quote(4.582, 1, default, Decimals: 3)) == 3, "provider precision hint");
Check(PriceFlash.DecimalsFor(etf with { Decimals = 2 }, new Quote(4.582, 1, default, Decimals: 3)) == 2, "row override wins");
Check(PriceFlash.DecimalsFor(new("700", "hk"), new Quote(0.315, 0, default)) == 3 && PriceFlash.DecimalsFor(new("700", "hk"), new Quote(419, 0, default)) == 2, "HKEX tick table");
Check(PriceFlash.Format(1.14896, 4) == "1.1490" && PriceFlash.Format(419, 3) == "419.000", "format precision");

// ── Providers ──
Check(QuoteFeed.TencentCode(new("700", "hk")) == "hk00700", "Hong Kong padding");
Check(QuoteFeed.RetryDelay(1) == 30 && QuoteFeed.RetryDelay(10) == 900, "bounded exponential backoff");
var fields = Enumerable.Repeat("0", 40).ToArray();
fields[3] = "4.582"; fields[30] = "20260918161452"; fields[32] = "1.10";
var cn = QuoteFeed.ParseTencentLine("v_sh510300=\"" + string.Join('~', fields) + "\"", default);
Check(cn?.Code == "sh510300" && cn.Value.Quote.Decimals == 3 && cn.Value.Quote.MarketTime == At("2026-09-18 16:14", "Asia/Shanghai").AddSeconds(52), "Tencent A-share precision and time");
fields[3] = "419.000"; fields[30] = "2026/09/18 16:08:32";
var hk = QuoteFeed.ParseTencentLine("v_hk00700=\"" + string.Join('~', fields) + "\"", default);
Check(hk is { } h && h.Quote.Decimals is null && h.Quote.MarketTime == At("2026-09-18 16:08", "Asia/Hong_Kong").AddSeconds(32), "Tencent Hong Kong");
var yahoo = QuoteFeed.ParseYahoo(Encoding.UTF8.GetBytes("{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.1489,\"chartPreviousClose\":1.15,\"priceHint\":4,\"regularMarketTime\":1789761600}}]}}"), default);
Check(yahoo?.Decimals == 4 && yahoo.MarketTime == DateTimeOffset.FromUnixTimeSeconds(1789761600), "Yahoo precision hint and time");

// ── Settings: validation, migration, multiple watchlists ──
Check(!Settings.ValidEntries([new("700", "hk"), new("00700", "hk")]), "canonical duplicate validation");
Check(!Settings.ValidEntries([new("AAPL\\c[red]", "us")]), "invalid symbol rejected");
I18n.Language = "en"; Check(I18n.T("Settings…") == "Settings…", "English");
I18n.Language = "zh-Hans"; Check(I18n.T("Settings…") == "设置…" && I18n.T("About Whirlpool") == "关于 Whirlpool", "Chinese");
var dir = Path.Combine(Path.GetTempPath(), "whirlpool-tests-" + Guid.NewGuid());
var path = Path.Combine(dir, "config.json");
try
{
    var settings = new Settings { RefreshSeconds = 15, Language = "zh-Hans" }; settings.Save(path);
    Check(Settings.Load(path).RefreshSeconds == 15 && Settings.Load(path).Language == "zh-Hans", "configuration round-trip");
    File.WriteAllText(path, "{\"refreshSeconds\":0}");
    Check(Settings.Load(path).RefreshSeconds == 5 && Settings.Load(path).Watchlist.Count > 0, "old settings defaults and clamping");
    File.WriteAllText(path, "{\"language\":\"zh-Hans\",\"watchlist\":[{\"symbol\":\"qqq\",\"market\":\"us\"}]}");
    var migrated = Settings.Load(path);
    Check(migrated.Watchlists.Count == 1 && migrated.Watchlist.Single().Symbol == "QQQ" && migrated.Active.Name == "自选股", "pre-1.9 single list migrates");
    var multi = new Settings();
    multi.Watchlists = [new() { Name = "Tech", Entries = [new("AAPL", "us", 3)] }, new() { Name = "Tech", Entries = [new("600519", "cn")] }, new() { Name = "Empty" }];
    multi.ActiveWatchlist = 1; multi.Normalize(); multi.Save(path);
    var text = File.ReadAllText(path);
    var back = Settings.Load(path);
    Check(back.Watchlists.Select(l => l.Name).SequenceEqual(["Tech", "Tech 2"]) && back.ActiveWatchlist == 1, "empty list dropped, duplicate names suffixed");
    Check(back.Watchlists[0].Entries[0].Decimals == 3 && text.Contains("\"watchlist\"") && back.Watchlist[0].Symbol == "600519", "decimals round-trip; legacy key mirrors the active list");
    File.WriteAllText(path, "invalid json");
    try { Settings.Load(path); throw new Exception("Expected malformed JSON failure"); } catch (System.Text.Json.JsonException) { }
    Check(File.ReadAllText(path) == "invalid json", "corrupt settings preserved");
    var legacy = Path.Combine(dir, "Pinwheel", "config.json"); var target = Path.Combine(dir, "Whirlpool", "config.json");
    Directory.CreateDirectory(Path.GetDirectoryName(legacy)!); File.WriteAllText(legacy, "{\"refreshSeconds\":42}");
    Check(Settings.MigrateLegacy(legacy, target) && Settings.Load(target).RefreshSeconds == 42 && File.Exists(legacy) && !Settings.MigrateLegacy(legacy, target), "Pinwheel settings migrate once, original kept");
}
finally { Directory.Delete(dir, true); }

// ── Exchange calendars ──
Check(MarketClock.NyseHolidays(2026).Select(d => d.ToString("yyyy-MM-dd")).Order().SequenceEqual(["2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25"]), "NYSE 2026 matches the official calendar");
Check(MarketClock.NyseHolidays(2027).Select(d => d.ToString("yyyy-MM-dd")).Order().SequenceEqual(["2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18", "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24"]), "NYSE 2027 matches the official calendar");
Check(MarketClock.NyseEarlyClose(2026).Select(d => d.ToString("yyyy-MM-dd")).Order().SequenceEqual(["2026-11-27", "2026-12-24"]) && MarketClock.NyseEarlyClose(2027).Select(d => d.ToString("yyyy-MM-dd")).SequenceEqual(["2027-11-26"]), "NYSE early closes");
WatchEntry spy = new("SPY", "us"), moutai = new("600519", "cn"), tencent = new("700", "hk");
Check(!MarketClock.IsOpen(spy, At("2026-11-26 11:00", "America/New_York")) && MarketClock.IsOpen(spy, At("2026-11-27 12:30", "America/New_York")) && !MarketClock.IsOpen(spy, At("2026-11-27 13:30", "America/New_York")), "Thanksgiving and early close");
Check(!MarketClock.IsOpen(tencent, At("2026-02-17 10:00", "Asia/Hong_Kong")) && MarketClock.IsOpen(tencent, At("2026-02-16 11:00", "Asia/Hong_Kong")) && !MarketClock.IsOpen(tencent, At("2026-02-16 13:30", "Asia/Hong_Kong")), "HKEX holiday and half day");
Check(MarketClock.IsOpen(tencent, At("2026-09-18 12:30", "Asia/Hong_Kong")), "HKEX extended morning session");
Check(!MarketClock.IsOpen(moutai, At("2026-10-05 10:00", "Asia/Shanghai")) && MarketClock.NextOpen(moutai, At("2026-09-30 16:00", "Asia/Shanghai")) == At("2026-10-08 09:10", "Asia/Shanghai"), "Golden Week and next open");
Check(MarketClock.NextOpen(spy, At("2026-09-19 12:00", "America/New_York")) == At("2026-09-21 09:25", "America/New_York"), "weekend next open");
var holiday = At("2026-10-05 10:00", "Asia/Shanghai");
Check(MarketClock.RefreshSeconds([moutai], 30, holiday) > 30 && MarketClock.RefreshSeconds([moutai], 30, holiday, new Dictionary<string, DateTimeOffset> { ["600519"] = holiday.AddMinutes(-2) }) == 30, "holiday backs off; fresh trade overrides");
Check(MarketClock.RefreshSeconds([spy, new("BTC-USD", "crypto")], 30, At("2026-09-19 12:00", "America/New_York")) == 30, "crypto keeps the base cadence");

// ── Updates and chart links ──
Check(UpdateChecker.ParseVersion("v1.6.0-main")!.SequenceEqual([1, 6, 0]) && UpdateChecker.IsNewer("1.10", "1.9.9") && !UpdateChecker.IsNewer("1.6.0", "1.9.0") && !UpdateChecker.IsNewer("2.0", "dev"), "version compare");
Check(UpdateChecker.ParseRelease("{\"tag_name\":\"v1.9.0-main\",\"name\":\"Whirlpool v1.9.0\",\"html_url\":\"https://github.com/NexusKFK/whirlpool/releases/tag/v1.9.0-main\"}")?.Version == "1.9.0"
      && UpdateChecker.ParseRelease("{\"tag_name\":\"v2.0.0\",\"prerelease\":true}") is null, "release parsing");
Check(ChartLinks.For(spy).ToString() == "https://www.tradingview.com/chart/?symbol=SPY" && ChartLinks.For(moutai).ToString().EndsWith("SSE:600519")
      && ChartLinks.For(new("00700", "hk")).ToString().EndsWith("HKEX:700") && ChartLinks.For(new("BTC-USD", "crypto")).Host == "finance.yahoo.com", "chart links");

// ── Feed caching, 429 and smart refresh ──
var time = DateTimeOffset.Parse("2026-09-16T14:00:00Z");   // Wednesday 10:00 New York
var handler = new FakeHandler();
using var feed = new QuoteFeed(handler, () => time);
var config = new Settings { RefreshSeconds = 30 }; config.Watchlist = [new("TLT", "us")];
handler.Response = () => new(HttpStatusCode.OK) { Content = new StringContent("{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":81.3,\"chartPreviousClose\":82}}]}}") };
var initial = await feed.RefreshAsync(config);
Check(initial["TLT"].Price == 81.3 && initial["TLT"].ChangePct < 0 && handler.Calls == 1 && handler.LastUrl!.Contains("interval=1d"), "Yahoo 1-day summary");
await feed.RefreshAsync(config); await feed.RefreshAsync(config, true);
Check(handler.Calls == 1, "cache and rapid manual refresh coalesced");
time = time.AddSeconds(31);
handler.Response = () => { var r = new HttpResponseMessage(HttpStatusCode.TooManyRequests); r.Headers.RetryAfter = new(TimeSpan.FromSeconds(120)); return r; };
var stale = await feed.RefreshAsync(config);
Check(stale["TLT"].Price == 81.3 && feed.Status == "Rate limited · retrying later", "429 retains last quote");
time = time.AddSeconds(31); await feed.RefreshAsync(config, true);
Check(handler.Calls == 2, "Retry-After respected even on manual refresh");
var weekend = DateTimeOffset.Parse("2026-09-19T16:00:00Z");   // Saturday
var calm = new FakeHandler { Response = () => new(HttpStatusCode.OK) { Content = new StringContent("{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":81.3,\"chartPreviousClose\":82}}]}}") } };
var now = weekend;
using var slow = new QuoteFeed(calm, () => now);
await slow.RefreshAsync(config);
now = now.AddMinutes(5); await slow.RefreshAsync(config);
Check(slow.Status == "Markets closed · refreshing slowly" && calm.Calls == 1, "weekend: smart refresh backs off");
var mixed = new FakeHandler { Response = () => new(HttpStatusCode.OK) { Content = new StringContent("v_sh600519=\"1~贵州茅台~600519~1257.12~" + string.Join('~', Enumerable.Repeat("0", 26)) + "~20260918161436~0~-0.78~0\";v_hk00700=\"1~腾讯~00700~419.000~" + string.Join('~', Enumerable.Repeat("0", 26)) + "~2026/09/18 16:08:32~0~-1.64~0\";", Encoding.UTF8) } };
using var batch = new QuoteFeed(mixed, () => time);
var china = new Settings(); china.Watchlist = [new("600519", "cn"), new("700", "hk")];
var both = await batch.RefreshAsync(china);
Check(mixed.Calls == 1 && both.Count == 2 && both["600519"].Decimals == 2 && both["700"].Price == 419, "Tencent batched into one request");
Console.WriteLine("All Windows core regression checks passed.");

sealed class FakeHandler : HttpMessageHandler
{
    public Func<HttpResponseMessage> Response = () => new(HttpStatusCode.OK);
    public int Calls;
    public string? LastUrl;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { Calls++; LastUrl = request.RequestUri?.ToString(); return Task.FromResult(Response()); }
}
