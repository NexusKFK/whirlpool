using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Whirlpool.Core;

public sealed class Settings
{
    public string Language { get; set; } = "system";
    public string Provider { get; set; } = "real";
    public List<Watchlist> Watchlists { get; set; } = [DefaultList("system")];
    public int ActiveWatchlist { get; set; }
    /// <summary>Pre-1.9 single list. Read for migration, written as the active list so older builds still work.</summary>
    [JsonPropertyName("watchlist")] public List<WatchEntry>? LegacyWatchlist { get; set; }
    public int RefreshSeconds { get; set; } = 30;
    public int ColumnsPerSecond { get; set; } = 30;
    public int WidthCharacters { get; set; } = 45;
    /// <summary>Fraction of the selected display's available width. Null retains pre-2.0 character sizing.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
    public double? TickerWidthFraction { get; set; } = .60;
    /// <summary>Six screen anchors, or "free" after a direct drag.</summary>
    public string TickerPlacement { get; set; } = "bottom-center";
    /// <summary>Upper bound for WidthCharacters; the ticker is additionally limited to its screen width.</summary>
    public const int MaxWidth = 120;
    public bool ShowTicker { get; set; } = true;
    public bool ShowBoard { get; set; }
    public bool AlwaysOnTop { get; set; } = true;
    public bool ChangeArrows { get; set; } = true;
    public bool FlashChanges { get; set; } = true;
    public bool HoverPause { get; set; } = true;
    public bool SmartRefresh { get; set; } = true;
    public bool CheckUpdates { get; set; } = true;
    /// <summary>system | light | dark</summary>
    public string Theme { get; set; } = "system";
    /// <summary>Floating windows cannot be dragged (menus and hover still work).</summary>
    public bool LockPosition { get; set; }
    /// <summary>Mouse clicks pass through the ticker to the windows below (turn off from the tray menu).</summary>
    public bool ClickThrough { get; set; }
    /// <summary>Screen device name for the floating windows; "auto" = primary screen.</summary>
    public string DisplayScreen { get; set; } = "auto";
    public List<string> RedUpMarkets { get; set; } = ["cn", "hk"];
    public int[]? TickerOrigin { get; set; }
    public int[]? BoardOrigin { get; set; }

    /// <summary>The active watchlist's entries (what is shown and fetched).</summary>
    [JsonIgnore]
    public List<WatchEntry> Watchlist
    {
        get => Active.Entries;
        set => Active.Entries = value;
    }

    [JsonIgnore]
    public Watchlist Active
    {
        get
        {
            if (Watchlists is not { Count: > 0 }) Watchlists = [DefaultList(Language)];
            return Watchlists[Math.Clamp(ActiveWatchlist, 0, Watchlists.Count - 1)];
        }
    }

    public static Watchlist DefaultList(string language) => new()
    {
        Name = I18n.TFor(language, "Watchlist"),
        Entries = [new("AAPL", "us"), new("SPY", "us"), new("QQQ", "us")],
    };

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    public static string ConfigPath => Path.Combine(AppData, "Whirlpool", "config.json");
    /// <summary>Where the app kept its settings before the Pinwheel → Whirlpool rename.</summary>
    public static string LegacyConfigPath => Path.Combine(AppData, "Pinwheel", "config.json");

    public Settings Clone() => JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(this, Json), Json)!;

    public void Normalize()
    {
        RefreshSeconds = Math.Clamp(RefreshSeconds, 5, 3600);
        ColumnsPerSecond = Math.Clamp(ColumnsPerSecond, 10, 50);
        WidthCharacters = Math.Clamp(WidthCharacters, 8, MaxWidth);
        TickerWidthFraction = TickerWidthFraction is double fraction && double.IsFinite(fraction) ? Math.Clamp(fraction, .2, 1) : null;
        TickerPlacement = TickerLayout.Placements.Contains(TickerPlacement) ? TickerPlacement : "bottom-center";
        Language = new[] { "system", "en", "zh-Hans" }.Contains(Language) ? Language : "system";
        Theme = new[] { "system", "light", "dark" }.Contains(Theme) ? Theme : "system";
        DisplayScreen = string.IsNullOrWhiteSpace(DisplayScreen) ? "auto" : DisplayScreen.Trim();
        Provider = Provider == "demo" ? "demo" : "real";
        RedUpMarkets ??= [];
        Watchlists ??= [];
        var active = Watchlists.ElementAtOrDefault(ActiveWatchlist);
        Watchlists.RemoveAll(list => list is null);
        foreach (var list in Watchlists)
        {
            list.Name = (list.Name ?? "").Trim();
            list.Entries = (list.Entries ?? []).Where(e => e is not null && !string.IsNullOrWhiteSpace(e.Symbol))
                .Select(e => e with { Symbol = e.Symbol.Trim().ToUpperInvariant(), Decimals = e.Decimals is int d ? Math.Clamp(d, 0, 8) : null })
                .DistinctBy(e => e.Symbol).ToList();
        }
        Watchlists.RemoveAll(l => l.Entries.Count == 0);
        if (Watchlists.Count == 0) Watchlists = [DefaultList(Language)];
        ActiveWatchlist = active is not null && Watchlists.Contains(active) ? Watchlists.IndexOf(active)
            : Math.Clamp(ActiveWatchlist, 0, Watchlists.Count - 1);
        // Unique, non-empty names (the tray menu and switching rely on them).
        var names = new HashSet<string>();
        for (int i = 0; i < Watchlists.Count; i++)
        {
            var baseName = Watchlists[i].Name.Length == 0 ? $"{I18n.TFor(Language, "Watchlist")} {i + 1}" : Watchlists[i].Name;
            var name = baseName;
            for (int n = 2; !names.Add(name); n++) name = $"{baseName} {n}";
            Watchlists[i].Name = name;
        }
        if (TickerOrigin?.Length != 2) TickerOrigin = null;
        if (BoardOrigin?.Length != 2) BoardOrigin = null;
        if (!ShowBoard && !ShowTicker) ShowTicker = true;
    }

    /// <summary>Copies the pre-rename configuration once; the original is left untouched.</summary>
    public static bool MigrateLegacy(string legacy, string target)
    {
        if (File.Exists(target) || !File.Exists(legacy)) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(target))!);
        File.Copy(legacy, target);
        return true;
    }

    public static Settings Load(string? path = null)
    {
        if (path is null)
        {
            try { MigrateLegacy(LegacyConfigPath, ConfigPath); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        path ??= ConfigPath;
        if (!File.Exists(path)) { var fresh = new Settings(); fresh.Normalize(); return fresh; }
        var text = File.ReadAllText(path);
        var config = JsonSerializer.Deserialize<Settings>(text, Json) ?? throw new InvalidDataException("Empty configuration");
        // A config without "watchlists" predates multiple lists: its single list becomes the first one.
        using (var document = JsonDocument.Parse(text))
        {
            var hasLists = document.RootElement.EnumerateObject().Any(p => p.Name.Equals("watchlists", StringComparison.OrdinalIgnoreCase));
            var hasWidth = document.RootElement.EnumerateObject().Any(p => p.Name.Equals("tickerWidthFraction", StringComparison.OrdinalIgnoreCase));
            var hasPlacement = document.RootElement.EnumerateObject().Any(p => p.Name.Equals("tickerPlacement", StringComparison.OrdinalIgnoreCase));
            if (!hasWidth) config.TickerWidthFraction = null;
            if (!hasPlacement && config.TickerOrigin is { Length: 2 }) config.TickerPlacement = "free";
            if (!hasLists && config.LegacyWatchlist is { Count: > 0 } legacy)
            {
                config.Watchlists = [new Watchlist { Name = I18n.TFor(config.Language, "Watchlist"), Entries = legacy }];
                config.ActiveWatchlist = 0;
            }
        }
        config.Normalize(); return config;
    }

    public void Save(string? path = null)
    {
        path ??= ConfigPath;
        LegacyWatchlist = Watchlist;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(this, Json)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static bool ValidEntries(IReadOnlyList<WatchEntry> entries)
    {
        // Symbols key the quote cache; China/Hong Kong rows are also unique by the Tencent code they request
        // (700 = 00700, SZ000001 = 000001). Those codes are lowercase, so they cannot collide with a symbol.
        var seen = new HashSet<string>();
        return entries.Count > 0 && entries.All(e => Regex.IsMatch(e.Symbol, e.Market switch
        {
            "cn" => "^(SH|SZ|BJ)?[0-9]{6}$", "hk" => "^[0-9]{1,5}$", "us" or "crypto" => "^[A-Z0-9^][A-Z0-9.^=_-]{0,31}$", _ => "(?!)"
        }) && seen.Add(e.Symbol) && (e.Market is not ("cn" or "hk") || seen.Add(QuoteFeed.TencentCode(e))));
    }
}
