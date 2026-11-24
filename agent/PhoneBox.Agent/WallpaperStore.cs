using System.Security.Cryptography;

namespace PhoneBox.Agent;

/// <summary>
/// One file the user uploads in the settings page for the panel to show, kept in the config folder as
/// &lt;name&gt;.&lt;ext&gt;. The panel asks for it with its revision in the URL, so the phone may keep it as long as it
/// likes and loads it again only when it changes. The panel wallpaper and the Visor widget's background media share
/// this upload path; each one is its own store with its own formats and size limits.
/// </summary>
public abstract class MediaStore
{
    /// <summary>A format the store accepts: its type, the extension it is saved with and the largest file of it.</summary>
    protected sealed record Format(string ContentType, string Ext, int MaxBytes);

    private readonly string _dir;
    private readonly string _name;
    private readonly Format[] _formats;
    private readonly string _noun;        // "picture", "file": what a too-large message calls it
    private readonly string _refused;     // the message for a file of another kind
    private readonly string _what;        // "wallpaper": what an in-use message calls it
    private readonly Lock _gate = new();
    // the content revision of the file it was computed from: a file replaced or deleted by hand gets a new one
    private (string Path, long Length, DateTime Written, long Revision)? _revision;

    protected MediaStore(string? dir, string name, Format[] formats, string noun, string refused, string what)
    {
        _dir = dir ?? AppPaths.ConfigDir;
        _name = name;
        _formats = formats;
        _noun = noun;
        _refused = refused;
        _what = what;
    }

    /// <summary>The largest upload of any accepted format; <see cref="ReadBounded(Stream, int)"/> stops there.</summary>
    public int Limit => _formats.Max(f => f.MaxBytes);

    private string PathFor(string ext) => Path.Combine(_dir, _name + ext);

    /// <summary>A value that changes with the file, or null when there is none. Hashed again only when the file
    /// changed (size or time); a file deleted by hand is noticed at once, and a failed read is not remembered.</summary>
    public long? Revision()
    {
        lock (_gate)
        {
            if (Current() is not { } file) { _revision = null; return null; }
            try
            {
                var info = new FileInfo(file);
                if (_revision is { } r && r.Path == file && r.Length == info.Length && r.Written == info.LastWriteTimeUtc)
                    return r.Revision;
                var rev = ContentRevision(File.ReadAllBytes(file));
                _revision = (file, info.Length, info.LastWriteTimeUtc, rev);
                return rev;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
        }
    }

    /// <summary>The file, in the order Read looks for it, or null.</summary>
    private string? Current() => _formats.Select(f => PathFor(f.Ext)).FirstOrDefault(File.Exists);

    internal static long ContentRevision(byte[] bytes) => BitConverter.ToInt64(SHA256.HashData(bytes));

    /// <summary>The file and its content type, or null when none was uploaded.</summary>
    public (byte[] Bytes, string ContentType)? Read()
    {
        lock (_gate)
        {
            foreach (var f in _formats)
            {
                var path = PathFor(f.Ext);
                if (!File.Exists(path)) continue;
                try { return (File.ReadAllBytes(path), f.ContentType); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
            }
            return null;
        }
    }

    /// <summary>Reads a request body up to <paramref name="max"/> bytes; null means it is larger.</summary>
    public static async Task<byte[]?> ReadBounded(Stream body, int max)
    {
        using var ms = new MemoryStream();
        var buf = new byte[81920];
        int read;
        while ((read = await body.ReadAsync(buf)) > 0)
        {
            if (ms.Length + read > max) return null;
            ms.Write(buf, 0, read);
        }
        return ms.ToArray();
    }

    private static string Mb(int bytes) => (bytes / (1024 * 1024)).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The message for an upload larger than <see cref="Limit"/>, also given before the body is read when the
    /// request says its length up front.</summary>
    public string TooLargeMessage => $"The {_noun} is larger than {Mb(Limit)} MB";

    /// <returns>An error message, or null on success.</returns>
    /// <remarks>The type comes from the file's own bytes, not from what the browser reports: some send an empty type
    /// or application/octet-stream for a valid file.</remarks>
    public string? Save(byte[]? bytes)
    {
        if (bytes is null) return TooLargeMessage;
        if (bytes.Length == 0) return "The file is empty";
        if (_formats.FirstOrDefault(f => LooksValid(f.Ext, bytes)) is not { } format) return _refused;
        // a video may be larger than a picture: the limit of the kind the bytes turned out to be
        if (bytes.Length > format.MaxBytes)
            return $"A {format.Ext[1..].ToUpperInvariant()} file may be up to {Mb(format.MaxBytes)} MB";

        Directory.CreateDirectory(_dir);
        var ext = format.Ext;
        var target = PathFor(ext);
        var tmp = target + ".tmp";
        lock (_gate)
        {
            // the new file is in place before the other formats go, so a failed write keeps the old one
            try
            {
                File.WriteAllBytes(tmp, bytes);
                File.Move(tmp, target, overwrite: true);
            }
            finally
            {
                try { File.Delete(tmp); } catch { }
            }
            RemoveLocked(exceptExtension: ext);
            _revision = null; // hashed again: a same-sized file can land on the same file time on Windows
            if (_formats.Any(other => other.Ext != ext && File.Exists(PathFor(other.Ext))))
            {
                // Read looks in a fixed order: an old file that could not be deleted would still be served
                try { File.Delete(target); } catch { }
                return $"The previous {_what} is in use and could not be replaced. Try again in a moment.";
            }
        }
        return null;
    }

    /// <summary>Deletes the file, whichever format it was saved in.</summary>
    /// <returns>An error message when a file could not be deleted (it would still be served), or null.</returns>
    public string? Remove()
    {
        lock (_gate)
        {
            RemoveLocked();
            return Current() is null ? null : $"The {_what} is in use and could not be removed. Try again in a moment.";
        }
    }

    private void RemoveLocked(string? exceptExtension = null)
    {
        foreach (var f in _formats)
        {
            if (f.Ext == exceptExtension) continue;
            try { File.Delete(PathFor(f.Ext)); } catch { }
        }
    }

    // the major brands (bytes 8-11 of an MP4) of plain MP4 video
    private static readonly HashSet<string> Mp4Brands = new(StringComparer.Ordinal)
        { "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "M4V ", "dash" };

    internal static bool LooksValid(string ext, byte[] b) => ext switch
    {
        ".jpg" => b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF,
        ".png" => b.Length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A,
        ".webp" => b.Length >= 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' && b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P',
        ".gif" => b.Length >= 6 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F' && b[3] == '8' && (b[4] == '7' || b[4] == '9') && b[5] == 'a',
        // ISO base media (MP4): a box whose type is "ftyp" comes first, then the major brand. Only the MP4 video brands
        // are taken: the same container also holds QuickTime ("qt  "), HEIC/AVIF pictures, M4A audio and 3GP, which a
        // <video> may not play
        ".mp4" => b.Length >= 12 && b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p'
            && Mp4Brands.Contains(System.Text.Encoding.ASCII.GetString(b, 8, 4)),
        // WebM is Matroska (an EBML header) whose DocType is "webm", within the header's first bytes
        ".webm" => b.Length >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3
            && System.Text.Encoding.ASCII.GetString(b, 0, Math.Min(b.Length, 64)).Contains("webm", StringComparison.Ordinal),
        _ => false,
    };
}

/// <summary>
/// The panel's wallpaper: one picture the user uploads in the settings page (JPEG, PNG or WEBP), kept in the config
/// folder as wallpaper.&lt;ext&gt; and drawn behind every page.
/// </summary>
public sealed class WallpaperStore(string? dir = null) : MediaStore(dir, "wallpaper",
    [new("image/jpeg", ".jpg", MaxBytes), new("image/png", ".png", MaxBytes), new("image/webp", ".webp", MaxBytes)],
    "picture", "Only JPEG, PNG or WEBP pictures are supported", "wallpaper")
{
    /// <summary>4 MB: a phone decodes the whole picture into memory, and the app fetches it again on each panel
    /// reload, so a smaller picture (a phone screen needs no more than about 2400 px) is kinder to both.</summary>
    public const int MaxBytes = 4 * 1024 * 1024;

    /// <summary>Reads a request body up to <see cref="MaxBytes"/>; null means it is larger.</summary>
    public static Task<byte[]?> ReadBounded(Stream body) => ReadBounded(body, MaxBytes);
}

/// <summary>
/// The Visor widget's background media (its "media" background): a picture, an animated GIF or a short muted video
/// looping behind the numbers, kept in the config folder as visor-media.&lt;ext&gt;. One file for every Visor widget.
/// </summary>
public sealed class VisorMediaStore(string? dir = null) : MediaStore(dir, "visor-media",
    [new("image/jpeg", ".jpg", MaxImageBytes), new("image/png", ".png", MaxImageBytes), new("image/webp", ".webp", MaxImageBytes),
     new("image/gif", ".gif", MaxImageBytes), new("video/mp4", ".mp4", MaxVideoBytes), new("video/webm", ".webm", MaxVideoBytes)],
    "file", "Only JPEG, PNG, WEBP or GIF pictures and MP4 or WEBM videos are supported", "background media")
{
    /// <summary>8 MB for a picture or a GIF: twice the wallpaper's, since an animated GIF is a whole set of pictures;
    /// the phone decodes it into memory all the same.</summary>
    public const int MaxImageBytes = 8 * 1024 * 1024;
    /// <summary>20 MB for a video: a short loop. The phone holds it in memory (as a blob) while a Visor page is mounted.</summary>
    public const int MaxVideoBytes = 20 * 1024 * 1024;
}
