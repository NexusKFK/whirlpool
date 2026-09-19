using System.Globalization;
using System.Text.Json;

namespace Whirlpool.Core;

/// <summary>One watchlist row. <c>Decimals</c> null = automatic precision.</summary>
public sealed record WatchEntry(string Symbol, string Market, int? Decimals = null);

/// <summary>A named watchlist; several can exist and one is active.</summary>
public sealed class Watchlist
{
    public string Name { get; set; } = "";
    public List<WatchEntry> Entries { get; set; } = [];
}

public sealed record Quote(double Price, double ChangePct, DateTimeOffset ReceivedAt, double[]? Series = null,
                           int? Decimals = null, DateTimeOffset? MarketTime = null);

public sealed record PriceFlash(string Prefix, string Suffix, bool Red)
{
    public const double Duration = 0.55;

    public static string Format(double price, int decimals = 2) =>
        price.ToString("F" + Math.Clamp(decimals, 0, 8), CultureInfo.InvariantCulture);

    /// <summary>The whole suffix from the highest changed digit, compared at the instrument's precision.</summary>
    public static PriceFlash? Between(double? previous, double current, bool redUp, int decimals = 2)
    {
        if (previous is not double old || !double.IsFinite(old) || !double.IsFinite(current) || old == current) return null;
        var before = Format(old, decimals); var after = Format(current, decimals);
        if (before == after) return null;
        var index = 0;
        if (before.Length == after.Length) while (index < after.Length && before[index] == after[index]) index++;
        return new(after[..index], after[index..], (current > old) == redUp);
    }

    /// <summary>Row override, then the provider hint, then the HKEX tick table, then two places.</summary>
    public static int DecimalsFor(WatchEntry entry, Quote? quote)
    {
        if (entry.Decimals is int d) return Math.Clamp(d, 0, 8);
        if (quote?.Decimals is int hint) return Math.Clamp(hint, 0, 8);
        if (entry.Market == "hk" && quote is { Price: < 0.5 }) return 3;
        return 2;
    }
}

public enum Tone { Dark, Light }

/// <summary>Semantic ticker colors resolved for a dark or light surface (same values as macOS).</summary>
public static class Palette
{
    public static (byte R, byte G, byte B) Neutral(Tone t) => t == Tone.Dark ? ((byte)255, (byte)255, (byte)255) : ((byte)20, (byte)20, (byte)23);
    public static (byte R, byte G, byte B) Green(Tone t) => t == Tone.Dark ? ((byte)0, (byte)255, (byte)64) : ((byte)0, (byte)143, (byte)51);
    public static (byte R, byte G, byte B) Red(Tone t) => t == Tone.Dark ? ((byte)255, (byte)26, (byte)0) : ((byte)214, (byte)20, (byte)10);
    public static (byte R, byte G, byte B) Background(Tone t) => t == Tone.Dark ? ((byte)20, (byte)22, (byte)27) : ((byte)246, (byte)246, (byte)248);
}

/// <summary>TradingView for US/China/Hong Kong stocks, Yahoo for indices, futures, FX and crypto.</summary>
public static class ChartLinks
{
    private static readonly Dictionary<string, string> Indices = new()
    {
        ["^GSPC"] = "SP:SPX", ["^SPX"] = "SP:SPX", ["^IXIC"] = "NASDAQ:IXIC", ["^NDX"] = "NASDAQ:NDX",
        ["^DJI"] = "DJ:DJI", ["^VIX"] = "CBOE:VIX", ["^RUT"] = "TVC:RUT", ["^HSI"] = "HSI:HSI",
    };

    public static Uri For(WatchEntry entry)
    {
        var s = entry.Symbol;
        string? tv = entry.Market switch
        {
            "cn" => (s.StartsWith('6') || s.StartsWith('5') || s.StartsWith('9') ? "SSE:" : "SZSE:") + s,
            "hk" => "HKEX:" + (int.TryParse(s, out var n) ? n : 0),
            "crypto" => null,
            _ => Indices.TryGetValue(s, out var mapped) ? mapped
                 : !s.Contains('^') && !s.Contains('=') && !s.EndsWith("-USD") ? s : null,
        };
        return tv is not null
            ? new Uri("https://www.tradingview.com/chart/?symbol=" + Uri.EscapeDataString(tv).Replace("%3A", ":"))
            : new Uri("https://finance.yahoo.com/quote/" + Uri.EscapeDataString(s));
    }
}

public static class I18n
{
    public static string Language { get; set; } = "system";
    public static bool Chinese => ChineseFor(Language);
    private static bool ChineseFor(string language) =>
        language == "zh-Hans" || language == "system" && CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    private static readonly Dictionary<string, string> Translations = Load();
    private static Dictionary<string, string> Load()
    {
        var assembly = typeof(I18n).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith("localization.json")))!;
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)!;
    }
    public static string T(string key) => TFor(Language, key);
    public static string TFor(string language, string key) => ChineseFor(language) && Translations.TryGetValue(key, out var value) ? value : key;
}
