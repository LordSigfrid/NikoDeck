using System.Text.Json;
using Microsoft.AspNetCore.Http;
using PhoneBox.Agent;
using Xunit;

namespace PhoneBox.Agent.Tests;

/// <summary>The Visor widget's background media goes through the wallpaper's upload path (<see cref="MediaStore"/>),
/// with pictures, GIFs and short videos allowed.</summary>
public sealed class VisorMediaTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("phonebox-visor-").FullName;
    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    private static readonly byte[] Gif = [(byte)'G', (byte)'I', (byte)'F', (byte)'8', (byte)'9', (byte)'a', 1, 0, 1, 0];
    private static readonly byte[] Mp4 = [0, 0, 0, 0x18, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'i', (byte)'s', (byte)'o', (byte)'m', 0, 0, 2, 0];
    private static readonly byte[] Mov = [0, 0, 0, 0x14, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'q', (byte)'t', (byte)' ', (byte)' ', 0, 0, 0, 0];
    private static readonly byte[] Webm = [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0x82, 0x84, (byte)'w', (byte)'e', (byte)'b', (byte)'m'];
    private static readonly byte[] Mkv = [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88, (byte)'m', (byte)'a', (byte)'t', (byte)'r', (byte)'o', (byte)'s', (byte)'k', (byte)'a'];
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D];

    [Theory]
    [InlineData("gif", "image/gif")]
    [InlineData("mp4", "video/mp4")]
    [InlineData("webm", "video/webm")]
    [InlineData("png", "image/png")]
    public void PicturesGifsAndVideosAreKeptWithTheirType(string kind, string type)
    {
        var bytes = kind switch { "gif" => Gif, "mp4" => Mp4, "webm" => Webm, _ => Png };
        var store = new VisorMediaStore(_dir);
        Assert.Null(store.Save(bytes));
        var (read, contentType) = store.Read()!.Value;
        Assert.Equal(bytes, read);
        Assert.Equal(type, contentType);
        Assert.Equal(MediaStore.ContentRevision(bytes), store.Revision());
        Assert.True(File.Exists(Path.Combine(_dir, "visor-media." + kind)));
    }

    [Fact]
    public void ANewUploadReplacesTheOtherFormatAndRemovingLeavesNone()
    {
        var store = new VisorMediaStore(_dir);
        Assert.Null(store.Save(Mp4));
        var first = store.Revision();
        Assert.Null(store.Save(Gif));
        Assert.NotEqual(first, store.Revision());
        Assert.False(File.Exists(Path.Combine(_dir, "visor-media.mp4")));
        Assert.Equal("image/gif", store.Read()!.Value.ContentType);
        Assert.Null(store.Remove());
        Assert.Null(store.Read());
        Assert.Null(store.Revision());
    }

    [Fact]
    public void ItIsKeptApartFromTheWallpaper()
    {
        var media = new VisorMediaStore(_dir);
        var wallpaper = new WallpaperStore(_dir);
        Assert.Null(wallpaper.Save(Png));
        Assert.Null(media.Save(Mp4));
        Assert.Equal("image/png", wallpaper.Read()!.Value.ContentType);
        Assert.Null(media.Remove());
        Assert.NotNull(wallpaper.Read()); // removing the media leaves the wallpaper alone
    }

    [Fact]
    public void OtherFilesAreRefused()
    {
        var store = new VisorMediaStore(_dir);
        Assert.Contains("MP4 or WEBM", store.Save(Mov));     // a QuickTime movie: not every WebView plays it
        Assert.Contains("MP4 or WEBM", store.Save(Mkv));     // Matroska that is not WebM
        Assert.Contains("MP4 or WEBM", store.Save("<svg/>"u8.ToArray()));
        Assert.Contains("empty", store.Save([]));
        Assert.Null(store.Read());
        // the wallpaper still takes pictures only
        Assert.Contains("Only JPEG, PNG or WEBP", new WallpaperStore(_dir).Save(Gif));
    }

    private static byte[] Ftyp(string brand)
    {
        var b = new byte[16];
        b[3] = 0x10;
        "ftyp"u8.CopyTo(b.AsSpan(4));
        System.Text.Encoding.ASCII.GetBytes(brand).CopyTo(b, 8);
        return b;
    }

    [Theory]
    [InlineData("isom")]
    [InlineData("mp42")]
    [InlineData("avc1")]
    [InlineData("M4V ")]
    [InlineData("dash")]
    public void Mp4VideoBrandsAreTaken(string brand)
    {
        var store = new VisorMediaStore(_dir);
        Assert.Null(store.Save(Ftyp(brand)));
        Assert.Equal("video/mp4", store.Read()!.Value.ContentType);
    }

    [Theory]
    [InlineData("heic")] // an iPhone photo
    [InlineData("avif")]
    [InlineData("M4A ")] // audio
    [InlineData("3gp4")]
    [InlineData("qt  ")]
    public void OtherIsoMediaIsRefused(string brand)
    {
        var store = new VisorMediaStore(_dir);
        Assert.Contains("MP4 or WEBM", store.Save(Ftyp(brand)));
        Assert.Null(store.Read());
    }

    [Fact]
    public void TheTooLargeMessageIsTheOneASaveGives()
    {
        Assert.Equal(new VisorMediaStore(_dir).Save(null), new VisorMediaStore(_dir).TooLargeMessage);
        Assert.Equal("The picture is larger than 4 MB", new WallpaperStore(_dir).TooLargeMessage);
    }

    [Fact]
    public void APictureHasALowerLimitThanAVideo()
    {
        var store = new VisorMediaStore(_dir);
        Assert.Equal(VisorMediaStore.MaxVideoBytes, store.Limit);
        Assert.Equal(WallpaperStore.MaxBytes, new WallpaperStore(_dir).Limit);

        var bigGif = new byte[VisorMediaStore.MaxImageBytes + 1];
        Gif.CopyTo(bigGif, 0);
        Assert.Contains("GIF file may be up to 8 MB", store.Save(bigGif));
        Assert.Null(store.Read());

        var bigVideo = new byte[VisorMediaStore.MaxImageBytes + 1];
        Mp4.CopyTo(bigVideo, 0);
        Assert.Null(store.Save(bigVideo)); // the same size is fine for a video
        Assert.Contains("larger than 20 MB", store.Save(null));
    }

    [Fact]
    public async Task ReadBoundedStopsAtTheStoresLimit()
    {
        var limit = new VisorMediaStore(_dir).Limit;
        Assert.Null(await MediaStore.ReadBounded(new MemoryStream(new byte[limit + 1]), limit));
        Assert.Equal(limit, (await MediaStore.ReadBounded(new MemoryStream(new byte[limit]), limit))!.Length);
    }

    [Fact]
    public void ThePhoneGetsTheRevisionAndMayReadTheFileButNotUploadIt()
    {
        var path = Path.Combine(_dir, "config.json");
        File.WriteAllText(path, "{}");
        var cfg = new ConfigStore(path).Get();
        var json = JsonSerializer.Serialize(cfg.ToPublic(visorMediaRev: 9019088123725100163), ConfigStore.WriteOpts);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal("9019088123725100163", doc.RootElement.GetProperty("visorMediaRev").GetString());

        var none = JsonSerializer.Serialize(cfg.ToPublic(), ConfigStore.WriteOpts);
        using var noneDoc = JsonDocument.Parse(none);
        Assert.True(!noneDoc.RootElement.TryGetProperty("visorMediaRev", out var rev) || rev.ValueKind == JsonValueKind.Null);

        Assert.True(Lan.AllowedOverLan(new PathString("/api/visor-media")));
        Assert.False(Lan.AllowedOverLan(new PathString("/api/settings/visor-media")));
    }
}
