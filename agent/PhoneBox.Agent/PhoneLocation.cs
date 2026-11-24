using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PhoneBox.Agent;

/// <summary>
/// The phone app's approximate location, used as the weather location while Settings › General › Weather ›
/// "Use the phone's location" (<see cref="WeatherConfig.Auto"/>) is on. The phone sends only coordinates rounded to
/// about a kilometre and the town name its own Geocoder found; nothing here leaves the computer. Kept apart from the
/// HTTP endpoint so the rules can be tested directly, like <see cref="NoteEdit"/>.
/// </summary>
public static class PhoneLocation
{
    public const int MaxCity = 80;
    /// <summary>A move shorter than this keeps the saved location, so a phone on the desk doesn't rewrite config.json
    /// every half hour (each save also makes every panel and the settings page reload the settings).</summary>
    public const double MinMoveKm = 1.0;
    /// <summary>A fix vaguer than this (a country-wide guess) would move the weather to the wrong town.</summary>
    public const double MaxAccuracyM = 25_000;

    public sealed class Report
    {
        public double? Lat { get; set; }
        public double? Lon { get; set; }
        public string? City { get; set; }
        [JsonPropertyName("accuracyM")]
        public double? AccuracyM { get; set; }
    }

    /// <summary><paramref name="Updated"/>: the settings were saved. <paramref name="City"/>: the town name the phone
    /// gave (null without one), for the log line, which never carries the coordinates.</summary>
    public sealed record Result(int Status, string? Error = null, bool Updated = false, string? City = null, string? Reason = null);

    internal static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true, NumberHandling = JsonNumberHandling.Strict };

    /// <summary>Two decimals: about 1.1 km north–south, less east–west. Enough for the weather, not a street address.</summary>
    public static double Round(double v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);

    /// <summary>The town name without control or format characters (a stray newline, a direction override), trimmed;
    /// null when nothing is left, so the caller can tell "too long" from "none".</summary>
    public static string? CleanCity(string? city)
    {
        if (city is null) return null;
        // a control character (a line break) separates words; a format character (an invisible direction mark) goes
        var clean = new string(city.Where(ch => CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.Format)
            .Select(ch => char.IsControl(ch) ? ' ' : ch).ToArray());
        clean = string.Join(' ', clean.Split(' ', StringSplitOptions.RemoveEmptyEntries)).Trim();
        return clean.Length > 0 ? clean : null;
    }

    /// <summary>Great-circle distance in km (haversine).</summary>
    public static double DistanceKm(double lat1, double lon1, double lat2, double lon2)
    {
        static double Rad(double d) => d * Math.PI / 180;
        var dLat = Rad(lat2 - lat1);
        var dLon = Rad(lon2 - lon1);
        var a = Math.Sin(dLat / 2) * Math.Sin(dLat / 2) + Math.Cos(Rad(lat1)) * Math.Cos(Rad(lat2)) * Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
        return 2 * 6371 * Math.Asin(Math.Min(1, Math.Sqrt(a)));
    }

    /// <summary>Checks a report on its own: a reason to refuse it (HTTP 400), or null.</summary>
    public static string? Validate(Report? r)
    {
        if (r is null) return "location expected";
        if (r.Lat is not { } lat || r.Lon is not { } lon) return "lat and lon expected";
        if (!double.IsFinite(lat) || !double.IsFinite(lon) || lat is < -90 or > 90 || lon is < -180 or > 180) return "invalid location";
        if (r.AccuracyM is { } acc && (!double.IsFinite(acc) || acc < 0)) return "invalid accuracy";
        if (CleanCity(r.City) is { Length: > MaxCity }) return "city too long";
        return null;
    }

    /// <summary>
    /// Applies a report to the saved weather location when <see cref="WeatherConfig.Auto"/> is on and the phone moved
    /// at least <see cref="MinMoveKm"/> or names another town. The caller holds the settings write lock
    /// (Program.IconCommit), as for a Note edit.
    /// </summary>
    public static Result Apply(ConfigStore cfg, Report? report)
    {
        if (Validate(report) is { } error) return new(400, error);
        var current = cfg.Get().Weather;
        if (!current.Auto) return new(200, Reason: "off");
        if (report!.AccuracyM is > MaxAccuracyM) return new(200, Reason: "inaccurate");

        var lat = Round(report.Lat!.Value);
        var lon = Round(report.Lon!.Value);
        var named = CleanCity(report.City);
        var moved = DistanceKm(current.Lat, current.Lon, lat, lon) >= MinMoveKm;
        var renamed = named is not null && !string.Equals(named, current.City, StringComparison.CurrentCultureIgnoreCase);
        if (!moved && !renamed) return new(200, Reason: "unchanged");
        // without a name from the phone, a new place is shown by its coordinates rather than under the old town's name
        var city = named ?? (moved ? string.Create(CultureInfo.InvariantCulture, $"{lat:0.00}, {lon:0.00}") : current.City);

        // work on a copy: cfg.Get() is the shared, cached config, and the save may still refuse
        var version = cfg.Version;
        var copy = JsonSerializer.Deserialize<AgentConfig>(JsonSerializer.Serialize(cfg.Get(), ConfigStore.WriteOpts), ConfigStore.WriteOpts);
        if (copy is null) return new(500, "settings unreadable");
        copy.Weather.City = city;
        copy.Weather.Lat = lat;
        copy.Weather.Lon = lon;
        var err = cfg.Save(JsonSerializer.Serialize(copy, ConfigStore.WriteOpts), version, out _);
        if (err == ConfigStore.Conflict) return new(409, err);
        return err is null ? new(200, Updated: true, City: named) : new(400, err);
    }
}
