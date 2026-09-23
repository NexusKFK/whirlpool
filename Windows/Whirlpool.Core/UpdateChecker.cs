using System.Text.Json;
using System.Text.RegularExpressions;

namespace Whirlpool.Core;

public sealed record Release(string Version, string Name, Uri Page);

/// <summary>
/// At most one anonymous request a day to GitHub's latest release (no identifiers beyond the
/// User-Agent version). Nothing is downloaded or replaced; the release page opens in the browser.
/// </summary>
public static class UpdateChecker
{
    public const string Endpoint = "https://api.github.com/repos/NexusKFK/whirlpool/releases/latest";
    public static readonly Uri ReleasesPage = new("https://github.com/NexusKFK/whirlpool/releases");

    public static int[]? ParseVersion(string text)
    {
        var match = Regex.Match(text ?? "", @"\d+(\.\d+)+");
        if (!match.Success) return null;
        var parts = match.Value.Split('.');
        var numbers = new int[parts.Length];
        for (int i = 0; i < parts.Length; i++) if (!int.TryParse(parts[i], out numbers[i])) return null;
        return numbers;
    }

    public static bool IsNewer(string candidate, string current)
    {
        if (ParseVersion(candidate) is not { } a || ParseVersion(current) is not { } b) return false;
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>Tag names such as "v1.6.0-main" or "Whirlpool v1.6.0"; drafts and pre-releases are ignored.</summary>
    public static Release? ParseRelease(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) return null;
        if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) return null;
        if (root.TryGetProperty("prerelease", out var pre) && pre.ValueKind == JsonValueKind.True) return null;
        var tag = root.TryGetProperty("tag_name", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() ?? "" : "";
        var name = root.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() ?? tag : tag;
        if ((ParseVersion(tag) ?? ParseVersion(name)) is not { } numbers) return null;
        var page = root.TryGetProperty("html_url", out var u) && u.ValueKind == JsonValueKind.String
            && Uri.TryCreate(u.GetString(), UriKind.Absolute, out var parsed) ? parsed : ReleasesPage;
        return new(string.Join('.', numbers), name, page);
    }

    public static async Task<Release?> LatestAsync(HttpClient http, string currentVersion, CancellationToken token = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("Whirlpool/" + currentVersion);
        using var response = await http.SendAsync(request, token);
        response.EnsureSuccessStatusCode();
        return ParseRelease(await response.Content.ReadAsStringAsync(token));
    }
}

/// <summary>Update bookkeeping kept apart from the user's settings.</summary>
public sealed class UpdateState
{
    public DateTimeOffset LastCheck { get; set; }
    public string? Skipped { get; set; }
    public string? Announced { get; set; }

    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Whirlpool", "state.json");

    public static UpdateState Load(string? path = null)
    {
        try { return JsonSerializer.Deserialize<UpdateState>(File.ReadAllText(path ?? DefaultPath), Settings.Json) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, Settings.Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
