using System.Text.RegularExpressions;

namespace Whirlpool.Core;

/// <summary>
/// Exchange sessions and holidays for smart refresh (same data and rules as the macOS MarketClock).
/// NYSE holidays and 1:00 p.m. early closes are computed from the exchange rules; China A-share and
/// HKEX closures come from the official tables below and must be extended each year when published.
/// Years without data fall back to "weekdays are open", and a trade timestamp younger than five
/// minutes always counts as open.
/// </summary>
public static class MarketClock
{
    public enum Exchange { Nyse, Sse, Hkex }
    public readonly record struct Session(int Start, int End);   // local minutes [Start, End)

    // China A-shares: State Council notice (gov.cn content_7047091), checked day by day against the SZSE trading calendar.
    public static readonly HashSet<DateOnly> SseClosed = Dates(
        "2026-01-01", "2026-01-02", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20",
        "2026-02-23", "2026-04-06", "2026-05-01", "2026-05-04", "2026-05-05", "2026-06-19", "2026-09-25",
        "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07");
    // HKEX Trading Calendar and Holiday Schedule (updated 2026-07-31).
    public static readonly HashSet<DateOnly> HkexClosed = Dates(
        "2026-01-01", "2026-02-17", "2026-02-18", "2026-02-19", "2026-04-03", "2026-04-06", "2026-04-07",
        "2026-05-01", "2026-05-25", "2026-06-19", "2026-07-01", "2026-10-01", "2026-10-19", "2026-12-25",
        "2027-01-01", "2027-02-08", "2027-02-09", "2027-03-26", "2027-03-29", "2027-04-05", "2027-05-13",
        "2027-06-09", "2027-07-01", "2027-09-16", "2027-10-01", "2027-10-08", "2027-12-27");
    public static readonly HashSet<DateOnly> HkexHalfDay = Dates(
        "2026-02-16", "2026-12-24", "2026-12-31", "2027-02-05", "2027-12-24", "2027-12-31");

    private static HashSet<DateOnly> Dates(params string[] values) => values.Select(v => DateOnly.Parse(v, System.Globalization.CultureInfo.InvariantCulture)).ToHashSet();

    public static Exchange? ExchangeFor(WatchEntry entry) => entry.Market switch
    {
        "crypto" => null,
        "cn" => Exchange.Sse,
        "hk" => Exchange.Hkex,
        _ => YahooExchange(entry.Symbol),
    };

    private static readonly HashSet<string> UsIndices = ["^GSPC", "^SPX", "^DJI", "^IXIC", "^NDX", "^RUT", "^VIX", "^NYA", "^XAX",
        "^SOX", "^OEX", "^DJT", "^DJU", "^W5000", "^TNX", "^TYX", "^FVX", "^IRX"];
    private static readonly HashSet<string> HongKongIndices = ["^HSI", "^HSCE"];

    /// <summary>
    /// Yahoo symbols name their venue: no suffix is a US listing, and .HK/.SS/.SZ use the tables above. Other venues
    /// (7203.T, VOD.L, ^N225…) have no modeled calendar, so they never count as closed.
    /// </summary>
    public static Exchange? YahooExchange(string symbol)
    {
        // Futures and FX (ES=F, EURUSD=X) trade almost 24×5; crypto pairs (BTC-USD, ETH-EUR) 24×7.
        if (symbol.Contains('=') || Regex.IsMatch(symbol, "-[A-Z]{3,}$")) return null;
        if (symbol.StartsWith('^')) return UsIndices.Contains(symbol) ? Exchange.Nyse : HongKongIndices.Contains(symbol) ? Exchange.Hkex : null;
        var dot = symbol.LastIndexOf('.');
        if (dot < 0) return Exchange.Nyse;
        return symbol[(dot + 1)..] switch { "HK" => Exchange.Hkex, "SS" or "SZ" => Exchange.Sse, _ => null };
    }

    private static TimeZoneInfo Zone(string iana, string windows)
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById(iana); }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException) { return TimeZoneInfo.FindSystemTimeZoneById(windows); }
    }
    private static readonly TimeZoneInfo NewYork = Zone("America/New_York", "Eastern Standard Time");
    private static readonly TimeZoneInfo Shanghai = Zone("Asia/Shanghai", "China Standard Time");
    private static readonly TimeZoneInfo HongKong = Zone("Asia/Hong_Kong", "China Standard Time");
    public static TimeZoneInfo ZoneOf(Exchange ex) => ex switch { Exchange.Nyse => NewYork, Exchange.Sse => Shanghai, _ => HongKong };

    // ── NYSE Rule 7.2 ──
    public static (int Month, int Day) Easter(int y)
    {
        int a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4;
        int f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30;
        int i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451;
        return ((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1);
    }
    private static DateOnly Nth(int n, DayOfWeek day, int month, int year)
    {
        var d = new DateOnly(year, month, 1);
        while (d.DayOfWeek != day) d = d.AddDays(1);
        return d.AddDays(7 * (n - 1));
    }
    private static DateOnly LastMonday(int month, int year)
    {
        var d = new DateOnly(year, month, DateTime.DaysInMonth(year, month));
        while (d.DayOfWeek != DayOfWeek.Monday) d = d.AddDays(-1);
        return d;
    }
    /// <summary>Saturday holidays move to Friday, Sunday to Monday; New Year's Day on a Saturday is not observed.</summary>
    private static DateOnly? Observed(int year, int month, int day, bool saturdayRule = true)
    {
        var d = new DateOnly(year, month, day);
        return d.DayOfWeek switch { DayOfWeek.Saturday => saturdayRule ? d.AddDays(-1) : null, DayOfWeek.Sunday => d.AddDays(1), _ => d };
    }
    public static HashSet<DateOnly> NyseHolidays(int year)
    {
        var days = new HashSet<DateOnly>();
        foreach (var d in new[] { Observed(year, 1, 1, false), Observed(year, 6, 19), Observed(year, 7, 4), Observed(year, 12, 25) })
            if (d is DateOnly value) days.Add(value);
        days.Add(Nth(3, DayOfWeek.Monday, 1, year));
        days.Add(Nth(3, DayOfWeek.Monday, 2, year));
        days.Add(LastMonday(5, year));
        days.Add(Nth(1, DayOfWeek.Monday, 9, year));
        days.Add(Nth(4, DayOfWeek.Thursday, 11, year));
        var (em, ed) = Easter(year);
        days.Add(new DateOnly(year, em, ed).AddDays(-2));
        return days;
    }
    /// <summary>1:00 p.m. closes: the day after Thanksgiving, Christmas Eve and July 3 when they are trading weekdays.</summary>
    public static HashSet<DateOnly> NyseEarlyClose(int year)
    {
        var holidays = NyseHolidays(year);
        var days = new HashSet<DateOnly> { Nth(4, DayOfWeek.Thursday, 11, year).AddDays(1) };
        foreach (var d in new[] { new DateOnly(year, 12, 24), new DateOnly(year, 7, 3) })
            if (d.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday) && !holidays.Contains(d)) days.Add(d);
        return days;
    }
    private static readonly Dictionary<int, (HashSet<DateOnly> Closed, HashSet<DateOnly> Early)> NyseCache = [];

    public static IReadOnlyList<Session> Sessions(Exchange ex, DateOnly day)
    {
        if (day.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) return [];
        switch (ex)
        {
            case Exchange.Nyse:
                lock (NyseCache)
                {
                    if (!NyseCache.TryGetValue(day.Year, out var table)) NyseCache[day.Year] = table = (NyseHolidays(day.Year), NyseEarlyClose(day.Year));
                    if (table.Closed.Contains(day)) return [];
                    return [new(9 * 60 + 25, (table.Early.Contains(day) ? 13 : 16) * 60 + 5)];
                }
            case Exchange.Sse:
                return SseClosed.Contains(day) ? [] : [new(9 * 60 + 10, 11 * 60 + 35), new(12 * 60 + 55, 15 * 60 + 5)];
            default:
                // HKEX full days include the extended morning session (continuous 9:30–16:00); half days end at noon.
                return HkexClosed.Contains(day) ? [] : [new(9 * 60 + 15, HkexHalfDay.Contains(day) ? 12 * 60 + 15 : 16 * 60 + 15)];
        }
    }

    public static bool IsOpen(WatchEntry entry, DateTimeOffset now)
    {
        if (ExchangeFor(entry) is not Exchange ex) return true;
        var local = TimeZoneInfo.ConvertTime(now, ZoneOf(ex));
        var minute = local.Hour * 60 + local.Minute;
        return Sessions(ex, DateOnly.FromDateTime(local.DateTime)).Any(s => minute >= s.Start && minute < s.End);
    }

    public static DateTimeOffset? NextOpen(WatchEntry entry, DateTimeOffset after)
    {
        if (ExchangeFor(entry) is not Exchange ex) return after;
        var zone = ZoneOf(ex);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(after, zone).DateTime);
        for (int offset = 0; offset <= 20; offset++)
        {
            var day = today.AddDays(offset);
            foreach (var s in Sessions(ex, day))
            {
                var local = day.ToDateTime(TimeOnly.MinValue).AddMinutes(s.Start);
                var start = new DateTimeOffset(local, zone.GetUtcOffset(local));
                if (start > after) return start;
            }
        }
        return null;
    }

    /// <summary>Base interval while any market is open (or just traded); otherwise until the next open, at most 30 minutes.</summary>
    public static double RefreshSeconds(IReadOnlyList<WatchEntry> entries, double baseSeconds, DateTimeOffset now,
                                        IReadOnlyDictionary<string, DateTimeOffset>? lastTrade = null)
    {
        if (entries.Count == 0 || entries.Any(e => IsOpen(e, now))) return baseSeconds;
        if (lastTrade is not null && entries.Any(e => lastTrade.TryGetValue(e.Symbol, out var t) && (now - t).TotalSeconds < 300)) return baseSeconds;
        var untilOpen = entries.Select(e => NextOpen(e, now)).OfType<DateTimeOffset>().Select(t => (t - now).TotalSeconds).DefaultIfEmpty(1800).Min();
        return Math.Min(1800, Math.Max(baseSeconds, untilOpen + 5));
    }
}
