using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Pinwheel.Core;

public sealed class QuoteFeed : IDisposable
{
    private readonly HttpClient http;
    private readonly Func<DateTimeOffset> clock;
    private DateTimeOffset Now => clock();
    private readonly SemaphoreSlim gate = new(1);
    private readonly Dictionary<string, Quote> cache = [];
    private DateTimeOffset nextFetch = DateTimeOffset.MinValue, cooldownUntil = DateTimeOffset.MinValue, lastAttempt = DateTimeOffset.MinValue;
    private int failures;
    private string key = "";
    public string Status { get; private set; } = "Waiting for quotes";
    public DateTimeOffset? LastUpdated { get; private set; }
    public QuoteFeed(HttpMessageHandler? handler = null, Func<DateTimeOffset>? clock = null)
    {
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(12);
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Pinwheel/1.6 (+desktop-market-ticker)");
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }
    public static double RetryDelay(int count) => Math.Min(900, 30 * Math.Pow(2, Math.Clamp(count - 1, 0, 5)));
    public static string TencentCode(WatchEntry entry) => entry.Market == "hk" ? "hk" + entry.Symbol.PadLeft(5, '0')
        : (entry.Symbol.StartsWith('6') || entry.Symbol.StartsWith('5') || entry.Symbol.StartsWith('9') ? "sh" : "sz") + entry.Symbol;

    public async Task<IReadOnlyDictionary<string, Quote>> RefreshAsync(Settings settings, bool force = false, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var requestKey = settings.Provider + ":" + string.Join('|', settings.Watchlist.Select(e => e.Market + ":" + e.Symbol).Order());
            if (requestKey != key) { key = requestKey; cache.Clear(); nextFetch = DateTimeOffset.MinValue; LastUpdated = null; }
            var now = Now;
            if (settings.Provider != "demo" && now < cooldownUntil) { Status = "Rate limited · retrying later"; return new Dictionary<string, Quote>(cache); }
            if (now < nextFetch && (!force || failures > 0) || now < lastAttempt.AddSeconds(5)) return new Dictionary<string, Quote>(cache);
            lastAttempt = now;
            if (settings.Provider == "demo")
            {
                foreach (var e in settings.Watchlist)
                {
                    var previous = cache.GetValueOrDefault(e.Symbol)?.Price ?? 100;
                    cache[e.Symbol] = new(Math.Max(0.01, previous + Random.Shared.NextDouble() - 0.5), Random.Shared.NextDouble() * 4 - 2, now);
                }
                LastUpdated = now; Status = "Demo · simulated prices"; nextFetch = now.AddSeconds(settings.RefreshSeconds);
                return new Dictionary<string, Quote>(cache);
            }
            Status = cache.Count == 0 ? "Loading quotes…" : Status;
            var fresh = new Dictionary<string, Quote>();
            foreach (var entry in settings.Watchlist)
            {
                token.ThrowIfCancellationRequested();
                if (Now < cooldownUntil) break;
                try
                {
                    var quote = entry.Market is "cn" or "hk" ? await TencentAsync(entry, token) : await YahooAsync(entry, token);
                    if (quote is not null && double.IsFinite(quote.Price) && quote.Price > 0 && double.IsFinite(quote.ChangePct)) fresh[entry.Symbol] = quote;
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (Exception error) when (error is HttpRequestException or JsonException or TaskCanceledException or InvalidOperationException or FormatException or KeyNotFoundException) { /* Retain previous quotes. */ }
                await Task.Delay(350, token);
            }
            foreach (var pair in fresh) cache[pair.Key] = pair.Value;
            if (fresh.Count > 0) LastUpdated = Now;
            if (Now < cooldownUntil) { Status = "Rate limited · retrying later"; nextFetch = cooldownUntil; }
            else if (fresh.Count < settings.Watchlist.Count)
            {
                failures++; Status = fresh.Count == 0 ? "Offline · showing last prices" : "Some quotes unavailable · showing last prices";
                nextFetch = Now.AddSeconds(Math.Max(settings.RefreshSeconds, RetryDelay(failures)));
            }
            else { failures = 0; Status = "Updated"; nextFetch = Now.AddSeconds(settings.RefreshSeconds); }
            return new Dictionary<string, Quote>(cache);
        }
        finally { gate.Release(); }
    }
    private async Task<byte[]?> GetAsync(string url, CancellationToken token)
    {
        using var response = await http.GetAsync(url, token);
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            failures++;
            var retry = response.Headers.RetryAfter;
            var delay = retry?.Delta?.TotalSeconds ?? (retry?.Date - Now)?.TotalSeconds ?? 0;
            cooldownUntil = Now.AddSeconds(Math.Max(RetryDelay(failures), Math.Max(0, delay)));
            return null;
        }
        if (!response.IsSuccessStatusCode) return null;
        return await response.Content.ReadAsByteArrayAsync(token);
    }
    private async Task<Quote?> YahooAsync(WatchEntry entry, CancellationToken token)
    {
        var data = await GetAsync("https://query1.finance.yahoo.com/v8/finance/chart/" + Uri.EscapeDataString(entry.Symbol) + "?interval=1m&range=1d", token);
        if (data is null) return null;
        using var json = JsonDocument.Parse(data);
        var result = json.RootElement.GetProperty("chart").GetProperty("result");
        if (result.ValueKind != JsonValueKind.Array || result.GetArrayLength() == 0) return null;
        var first = result[0]; var meta = first.GetProperty("meta");
        if (!meta.TryGetProperty("regularMarketPrice", out var rawPrice) || !meta.TryGetProperty("chartPreviousClose", out var rawClose)) return null;
        var price = rawPrice.GetDouble(); var close = rawClose.GetDouble();
        if (close <= 0) return null;
        double[]? series = null;
        if (first.TryGetProperty("indicators", out var indicators) && indicators.TryGetProperty("quote", out var quotes) && quotes.GetArrayLength() > 0 && quotes[0].TryGetProperty("close", out var values))
            series = values.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.Number).Select(v => v.GetDouble()).Where(double.IsFinite).ToArray();
        return new(price, (price / close - 1) * 100, Now, series);
    }
    private async Task<Quote?> TencentAsync(WatchEntry entry, CancellationToken token)
    {
        var data = await GetAsync("https://qt.gtimg.cn/q=" + TencentCode(entry), token);
        if (data is null) return null;
        var text = Encoding.GetEncoding("GB18030").GetString(data);
        var parts = text.Split('~');
        return parts.Length > 32 && double.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var price)
            && double.TryParse(parts[32], NumberStyles.Float, CultureInfo.InvariantCulture, out var change)
            ? new(price, change, Now) : null;
    }
    public void Dispose() { http.Dispose(); gate.Dispose(); }
}
