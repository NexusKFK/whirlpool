using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Pinwheel.Core;

public record WatchEntry(string Symbol, string Market);
public record Quote(double Price, double ChangePct, DateTimeOffset ReceivedAt, double[]? Series = null);
public record PriceFlash(string Prefix, string Suffix, bool Red)
{
    public const double Duration = 0.55;
    public static string Format(double price) => price.ToString("F2", CultureInfo.InvariantCulture);
    public static PriceFlash? Between(double? previous, double current, bool redUp)
    {
        if (previous is not double old || !double.IsFinite(old) || !double.IsFinite(current) || old == current) return null;
        var before = Format(old); var after = Format(current);
        if (before == after) return null;
        var index = 0;
        if (before.Length == after.Length) while (index < after.Length && before[index] == after[index]) index++;
        return new(after[..index], after[index..], (current > old) == redUp);
    }
}

public sealed class Settings
{
    public string Language { get; set; } = "system";
    public string Provider { get; set; } = "real";
    public List<WatchEntry> Watchlist { get; set; } = [new("AAPL", "us"), new("SPY", "us"), new("QQQ", "us")];
    public int RefreshSeconds { get; set; } = 30;
    public int ColumnsPerSecond { get; set; } = 30;
    public int WidthCharacters { get; set; } = 45;
    public bool ShowTicker { get; set; } = true;
    public bool ShowBoard { get; set; }
    public bool AlwaysOnTop { get; set; } = true;
    public bool ChangeArrows { get; set; } = true;
    public bool FlashChanges { get; set; } = true;
    public List<string> RedUpMarkets { get; set; } = ["cn", "hk"];
    public int[]? TickerOrigin { get; set; }
    public int[]? BoardOrigin { get; set; }
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true };
    public static string ConfigPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinwheel", "config.json");
    public Settings Clone() => JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(this, Json), Json)!;
    public void Normalize()
    {
        RefreshSeconds = Math.Clamp(RefreshSeconds, 5, 3600);
        ColumnsPerSecond = Math.Clamp(ColumnsPerSecond, 10, 50);
        WidthCharacters = Math.Clamp(WidthCharacters, 8, 60);
        Language = new[] { "system", "en", "zh-Hans" }.Contains(Language) ? Language : "system";
        Provider = Provider == "demo" ? "demo" : "real";
        Watchlist ??= []; RedUpMarkets ??= [];
        Watchlist = Watchlist.Where(e => e is not null && !string.IsNullOrWhiteSpace(e.Symbol))
            .Select(e => e with { Symbol = e.Symbol.Trim().ToUpperInvariant() }).DistinctBy(e => e.Symbol).ToList();
        if (Watchlist.Count == 0) Watchlist = new Settings().Watchlist;
        if (TickerOrigin?.Length != 2) TickerOrigin = null;
        if (BoardOrigin?.Length != 2) BoardOrigin = null;
        if (!ShowBoard && !ShowTicker) ShowTicker = true;
    }
    public static Settings Load(string? path = null)
    {
        path ??= ConfigPath;
        if (!File.Exists(path)) return new();
        var config = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json) ?? throw new InvalidDataException("Empty configuration");
        config.Normalize(); return config;
    }
    public void Save(string? path = null)
    {
        path ??= ConfigPath;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(this, Json)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static bool ValidEntries(IReadOnlyList<WatchEntry> entries)
    {
        var seen = new HashSet<string>();
        return entries.Count > 0 && entries.All(e => seen.Add(e.Market == "hk" ? e.Symbol.PadLeft(5, '0') : e.Symbol) && Regex.IsMatch(e.Symbol, e.Market switch
        {
            "cn" => "^[0-9]{6}$", "hk" => "^[0-9]{1,5}$", "us" or "crypto" => "^[A-Z0-9^][A-Z0-9.^=_-]{0,31}$", _ => "(?!)"
        }));
    }
}

public static class I18n
{
    public static string Language { get; set; } = "system";
    public static bool Chinese => Language == "zh-Hans" || Language == "system" && CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    private static readonly Dictionary<string, string> Translations = Load();
    private static Dictionary<string, string> Load()
    {
        var assembly = typeof(I18n).Assembly;
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith("localization.json")))!;
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)!;
    }
    public static string T(string key) => Chinese && Translations.TryGetValue(key, out var value) ? value : key;
}
