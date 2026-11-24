using PhoneBox.Agent;
using Xunit;

public class PhoneLocationTests
{
    private static (ConfigStore Store, string Path) Make(bool? auto = true, string city = "Tallinn", double lat = 59.44, double lon = 24.75)
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"phonebox-location-{Guid.NewGuid():N}.json");
        var autoField = auto is { } a ? $"\"auto\":{(a ? "true" : "false")}," : "";
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        File.WriteAllText(path, "{\"weather\":{" + autoField + "\"city\":\"" + city + "\",\"lat\":" + lat.ToString(inv) + ",\"lon\":" + lon.ToString(inv) + ",\"unit\":\"celsius\"}}");
        return (new ConfigStore(path), path);
    }

    private static void Cleanup(string path)
    {
        File.Delete(path);
        File.Delete(path + ".bak");
    }

    private static PhoneLocation.Report At(double? lat, double? lon, string? city = null, double? acc = 500) =>
        new() { Lat = lat, Lon = lon, City = city, AccuracyM = acc };

    [Theory]
    [InlineData(double.NaN, 10.0)]
    [InlineData(10.0, double.PositiveInfinity)]
    [InlineData(90.5, 10.0)]
    [InlineData(-91.0, 10.0)]
    [InlineData(10.0, 180.01)]
    [InlineData(10.0, -181.0)]
    public void AnImpossibleLocationIsRefused(double lat, double lon)
    {
        var (cfg, path) = Make();
        try
        {
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(lat, lon)).Status);
            Assert.Equal("Tallinn", cfg.Get().Weather.City);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void AMissingCoordinateOrBodyIsRefused()
    {
        var (cfg, path) = Make();
        try
        {
            Assert.Equal(400, PhoneLocation.Apply(cfg, null).Status);
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(10, null)).Status);
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(null, 10)).Status);
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(10, 10, acc: -1)).Status);
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(10, 10, acc: double.NaN)).Status);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void ATownNameOverEightyCharactersIsRefused()
    {
        var (cfg, path) = Make();
        try
        {
            Assert.Equal(400, PhoneLocation.Apply(cfg, At(-23.55, -46.63, new string('a', 81))).Status);
            Assert.Equal(200, PhoneLocation.Apply(cfg, At(-23.55, -46.63, new string('a', 80))).Status);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void ControlAndFormatCharactersAreStrippedFromTheTownName()
    {
        Assert.Equal("São Paulo", PhoneLocation.CleanCity("  São\nPaulo‮\u0000 "));
        Assert.Null(PhoneLocation.CleanCity("\r\n\t"));
        Assert.Null(PhoneLocation.CleanCity(null));
    }

    [Fact]
    public void ANewPlaceIsSavedRoundedToTwoDecimals()
    {
        var (cfg, path) = Make();
        try
        {
            var before = cfg.Version;
            var r = PhoneLocation.Apply(cfg, At(-23.550520, -46.633309, "São Paulo"));
            Assert.Equal(200, r.Status);
            Assert.True(r.Updated);
            Assert.Equal("São Paulo", r.City);
            var w = cfg.Get().Weather;
            Assert.Equal("São Paulo", w.City);
            Assert.Equal(-23.55, w.Lat);
            Assert.Equal(-46.63, w.Lon);
            Assert.NotEqual(before, cfg.Version); // panels see a new version and fetch the new forecast
        }
        finally { Cleanup(path); }
    }

    [Theory]
    [InlineData(0.004, 0.0)]
    [InlineData(12.346, 12.35)]
    [InlineData(-12.344, -12.34)]
    [InlineData(-46.633309, -46.63)]
    [InlineData(179.999, 180.0)]
    public void RoundsToTwoDecimals(double value, double expected) => Assert.Equal(expected, PhoneLocation.Round(value));

    [Fact]
    public void NothingIsSavedWhileTheOptionIsOff()
    {
        var (cfg, path) = Make(auto: false);
        try
        {
            var before = cfg.Version;
            var r = PhoneLocation.Apply(cfg, At(-23.55, -46.63, "São Paulo"));
            Assert.Equal(200, r.Status);
            Assert.False(r.Updated);
            Assert.Equal("off", r.Reason);
            Assert.Equal("Tallinn", cfg.Get().Weather.City);
            Assert.Equal(59.44, cfg.Get().Weather.Lat);
            Assert.Equal(before, cfg.Version);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void SettingsWithoutTheFieldFollowThePhone()
    {
        var (cfg, path) = Make(auto: null);
        try
        {
            Assert.True(cfg.Get().Weather.Auto);
            Assert.True(PhoneLocation.Apply(cfg, At(-23.55, -46.63, "São Paulo")).Updated);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void ASmallMoveInTheSameTownDoesNotRewriteTheSettings()
    {
        var (cfg, path) = Make();
        try
        {
            var before = cfg.Version;
            var written = File.GetLastWriteTimeUtc(path);
            // rounds to 24.76, about 0.6 km east of the saved point: a new value, but the same place (and the same town)
            var r = PhoneLocation.Apply(cfg, At(59.4401, 24.758, "tallinn"));
            Assert.Equal(200, r.Status);
            Assert.False(r.Updated);
            Assert.Equal("unchanged", r.Reason);
            Assert.Equal(before, cfg.Version);
            Assert.Equal(written, File.GetLastWriteTimeUtc(path));
            Assert.Equal(59.44, cfg.Get().Weather.Lat);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void ANewTownNameNearbyIsSaved()
    {
        var (cfg, path) = Make();
        try
        {
            var r = PhoneLocation.Apply(cfg, At(59.44, 24.75, "Kesklinn"));
            Assert.True(r.Updated);
            Assert.Equal("Kesklinn", cfg.Get().Weather.City);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void ANewPlaceWithoutANameShowsItsCoordinates()
    {
        var (cfg, path) = Make();
        try
        {
            var r = PhoneLocation.Apply(cfg, At(58.38, 26.72));
            Assert.True(r.Updated);
            Assert.Null(r.City); // the log line gets no coordinates
            Assert.Equal("58.38, 26.72", cfg.Get().Weather.City);
            // no name and no move: the saved name stays
            Assert.False(PhoneLocation.Apply(cfg, At(58.381, 26.721)).Updated);
            Assert.Equal("58.38, 26.72", cfg.Get().Weather.City);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void AVagueFixIsIgnored()
    {
        var (cfg, path) = Make();
        try
        {
            var r = PhoneLocation.Apply(cfg, At(-23.55, -46.63, "São Paulo", acc: 80_000));
            Assert.False(r.Updated);
            Assert.Equal("inaccurate", r.Reason);
            Assert.Equal("Tallinn", cfg.Get().Weather.City);
        }
        finally { Cleanup(path); }
    }

    [Fact]
    public void TheDistanceIsTheGreatCircleOne()
    {
        // Tallinn – Tartu is about 160 km
        Assert.InRange(PhoneLocation.DistanceKm(59.437, 24.745, 58.378, 26.729), 155, 170);
        Assert.Equal(0, PhoneLocation.DistanceKm(10, 10, 10, 10), 6);
    }
}
