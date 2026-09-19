using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Whirlpool.Core;

public sealed class QuoteFeed : IDisposable
{
    private readonly HttpClient http;
    private readonly Func<DateTimeOffset> clock;
    private DateTimeOffset Now => clock();
    private readonly SemaphoreSlim gate = new(1);
    private readonly Dictionary<string, Quote> cache = [];
    private DateTimeOffset nextFetch = DateTimeOffset.MinValue, cooldownUntil = DateTimeOffset.MinValue, lastAttempt = DateTimeOffset.MinValue;
    private int failures, rateLimits;
    private string key = "";
    private (int Interval, bool Smart)? cadence;
    public string Status { get; private set; } = "Waiting for quotes";
    public DateTimeOffset? LastUpdated { get; private set; }
    public static string Version { get; set; } = "1.9.3";

    public QuoteFeed(HttpMessageHandler? handler = null, Func<DateTimeOffset>? clock = null)
    {
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(12);
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Whirlpool/" + Version);
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static double RetryDelay(int count) => Math.Min(900, 30 * Math.Pow(2, Math.Clamp(count - 1, 0, 5)));
    public static string TencentCode(WatchEntry entry) => entry.Market == "hk" ? "hk" + entry.Symbol.PadLeft(5, '0')
        : (entry.Symbol.StartsWith('6') || entry.Symbol.StartsWith('5') || entry.Symbol.StartsWith('9') ? "sh" : "sz") + entry.Symbol;

    /// <summary>Makes the next call fetch (still honoring backoff), e.g. after waking from sleep.</summary>
    public void Invalidate() { if (failures == 0 && Now >= cooldownUntil) nextFetch = DateTimeOffset.MinValue; }

    public async Task<IReadOnlyDictionary<string, Quote>> RefreshAsync(Settings settings, bool force = false, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var entries = settings.Watchlist;
            var requestKey = settings.Provider + ":" + string.Join('|', entries.Select(e => e.Market + ":" + e.Symbol).Order());
            if (requestKey != key)
            {
                key = requestKey; cache.Clear(); nextFetch = DateTimeOffset.MinValue; LastUpdated = null;
                failures = 0; Status = "Waiting for quotes";
            }
            var now = Now;
            var requestedCadence = (settings.RefreshSeconds, settings.SmartRefresh);
            if (cadence != requestedCadence) { cadence = requestedCadence; Invalidate(); }
            if (settings.Provider != "demo" && now < cooldownUntil) { Status = "Rate limited · retrying later"; return new Dictionary<string, Quote>(cache); }
            // Keep an early manual refresh pending until the minimum spacing expires.
            // The UI consumes its force flag once, so simply returning here loses that request.
            if (force && failures == 0) nextFetch = Min(nextFetch, Max(now, lastAttempt.AddSeconds(5)));
            if (now < nextFetch || now < lastAttempt.AddSeconds(5)) return new Dictionary<string, Quote>(cache);
            lastAttempt = now;
            if (settings.Provider == "demo")
            {
                foreach (var e in entries)
                {
                    var previous = cache.GetValueOrDefault(e.Symbol)?.Price ?? 100;
                    cache[e.Symbol] = new(Math.Max(0.01, previous + Random.Shared.NextDouble() - 0.5), Random.Shared.NextDouble() * 4 - 2, now);
                }
                LastUpdated = now; Status = "Demo · simulated prices"; nextFetch = now.AddSeconds(settings.RefreshSeconds);
                return new Dictionary<string, Quote>(cache);
            }
            Status = cache.Count == 0 ? "Loading quotes…" : Status;
            var fresh = new Dictionary<string, Quote>();
            // China / Hong Kong: one batched Tencent request.
            var tencent = entries.Where(e => e.Market is "cn" or "hk").ToList();
            if (tencent.Count > 0)
            {
                try { foreach (var pair in await TencentAsync(tencent, token)) fresh[pair.Key] = pair.Value; }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (Exception error) when (error is HttpRequestException or TaskCanceledException or FormatException) { /* Retain previous quotes. */ }
            }
            foreach (var entry in entries.Where(e => e.Market is not ("cn" or "hk")))
            {
                token.ThrowIfCancellationRequested();
                if (Now < cooldownUntil) break;
                try
                {
                    var quote = await YahooAsync(entry, token);
                    if (quote is not null && double.IsFinite(quote.Price) && quote.Price > 0 && double.IsFinite(quote.ChangePct)) fresh[entry.Symbol] = quote;
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (Exception error) when (error is HttpRequestException or JsonException or TaskCanceledException or InvalidOperationException or FormatException or KeyNotFoundException) { /* Retain previous quotes. */ }
                await Task.Delay(350, token);
            }
            foreach (var pair in fresh) cache[pair.Key] = pair.Value;
            if (fresh.Count > 0) LastUpdated = Now;
            if (Now < cooldownUntil) { Status = "Rate limited · retrying later"; nextFetch = cooldownUntil; }
            else if (fresh.Count < entries.Count)
            {
                failures++; Status = fresh.Count == 0 ? "Offline · showing last prices" : "Some quotes unavailable · showing last prices";
                nextFetch = Now.AddSeconds(Math.Max(settings.RefreshSeconds, RetryDelay(failures)));
            }
            else
            {
                failures = 0;
                // Smart refresh: slow down while every watched market is closed; resume at the next open.
                var lastTrade = cache.Where(p => p.Value.MarketTime is not null).ToDictionary(p => p.Key, p => p.Value.MarketTime!.Value);
                var next = settings.SmartRefresh ? MarketClock.RefreshSeconds(entries, settings.RefreshSeconds, Now, lastTrade) : settings.RefreshSeconds;
                Status = next > settings.RefreshSeconds ? "Markets closed · refreshing slowly" : "Updated";
                nextFetch = Now.AddSeconds(next);
            }
            return new Dictionary<string, Quote>(cache);
        }
        finally { gate.Release(); }
    }

    private async Task<byte[]?> GetAsync(string url, CancellationToken token)
    {
        using var response = await http.GetAsync(url, token);
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            rateLimits++;
            var retry = response.Headers.RetryAfter;
            var delay = retry?.Delta?.TotalSeconds ?? (retry?.Date - Now)?.TotalSeconds ?? 0;
            cooldownUntil = Now.AddSeconds(Math.Max(RetryDelay(rateLimits), Math.Max(0, delay)));
            return null;
        }
        if (!response.IsSuccessStatusCode) return null;
        rateLimits = 0;
        return await response.Content.ReadAsByteArrayAsync(token);
    }

    /// <summary>Yahoo 1-day summary: price, previous close, precision hint and last trade time.</summary>
    private async Task<Quote?> YahooAsync(WatchEntry entry, CancellationToken token)
    {
        var data = await GetAsync("https://query1.finance.yahoo.com/v8/finance/chart/" + Uri.EscapeDataString(entry.Symbol) + "?interval=1d&range=1d", token);
        return data is null ? null : ParseYahoo(data, Now);
    }

    public static Quote? ParseYahoo(byte[] data, DateTimeOffset now)
    {
        using var json = JsonDocument.Parse(data);
        var result = json.RootElement.GetProperty("chart").GetProperty("result");
        if (result.ValueKind != JsonValueKind.Array || result.GetArrayLength() == 0) return null;
        var meta = result[0].GetProperty("meta");
        if (!meta.TryGetProperty("regularMarketPrice", out var rawPrice) || !meta.TryGetProperty("chartPreviousClose", out var rawClose)) return null;
        var price = rawPrice.GetDouble(); var close = rawClose.GetDouble();
        if (close <= 0) return null;
        int? hint = meta.TryGetProperty("priceHint", out var h) && h.TryGetInt32(out var places) ? places : null;
        DateTimeOffset? time = meta.TryGetProperty("regularMarketTime", out var t) && t.TryGetInt64(out var epoch) ? DateTimeOffset.FromUnixTimeSeconds(epoch) : null;
        return new(price, (price / close - 1) * 100, now, null, hint, time);
    }

    private async Task<Dictionary<string, Quote>> TencentAsync(List<WatchEntry> entries, CancellationToken token)
    {
        var codes = entries.GroupBy(TencentCode).ToDictionary(g => g.Key, g => g.First().Symbol);
        var data = await GetAsync("https://qt.gtimg.cn/q=" + string.Join(',', codes.Keys), token);
        var result = new Dictionary<string, Quote>();
        if (data is null) return result;
        foreach (var line in Encoding.GetEncoding("GB18030").GetString(data).Split(';'))
            if (ParseTencentLine(line, Now) is { } parsed && codes.TryGetValue(parsed.Code, out var symbol)) result[symbol] = parsed.Quote;
        return result;
    }

    /// <summary>
    /// <c>v_sh510300="1~name~code~4.582~…"</c>: field 3 price (A-share strings carry the precision; Hong Kong
    /// always writes three places, so its precision comes from the tick table), 30 time, 32 change %.
    /// </summary>
    public static (string Code, Quote Quote)? ParseTencentLine(string line, DateTimeOffset now)
    {
        var eq = line.IndexOf('=');
        if (eq < 0) return null;
        var code = line[..eq].Trim().Replace("v_", "");
        var parts = line[(eq + 1)..].Trim().Trim('"').Split('~');
        if (parts.Length <= 32 || !double.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var price)
            || !double.TryParse(parts[32], NumberStyles.Float, CultureInfo.InvariantCulture, out var change)
            || !double.IsFinite(price) || price <= 0 || !double.IsFinite(change)) return null;
        var hongKong = code.StartsWith("hk");
        int? places = !hongKong && parts[3].IndexOf('.') is int dot and >= 0 ? parts[3].Length - dot - 1 : null;
        return (code, new Quote(price, change, now, null, places, TencentTime(parts[30], hongKong)));
    }

    /// <summary>A-shares "20260918150003" (Beijing), Hong Kong "2026/09/18 16:08:32" (Hong Kong); both UTC+8.</summary>
    public static DateTimeOffset? TencentTime(string raw, bool hongKong)
    {
        var format = raw.Contains('/') ? "yyyy/MM/dd HH:mm:ss" : "yyyyMMddHHmmss";
        return DateTime.TryParseExact(raw.Trim(), format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)
            ? new DateTimeOffset(local, TimeSpan.FromHours(8)) : null;
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;
    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    // HttpClient.Dispose cancels requests; their finally blocks still need to release the gate.
    // No WaitHandle is allocated for this managed semaphore, so it can be collected normally.
    public void Dispose() { http.Dispose(); }
}
