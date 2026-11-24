using System.Reflection;

namespace PhoneBox.Agent;

/// <summary>File locations. The install folder is replaced on update; settings and logs are kept.</summary>
public static class AppPaths
{
    public const string AppName = "NikoDeck";

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile, Environment.SpecialFolderOption.DoNotVerify);
    private static string Xdg(string variable, string fallback) =>
        Environment.GetEnvironmentVariable(variable) is { Length: > 0 } v ? v : Path.Combine(Home, fallback);

    /// <summary>%APPDATA%\NikoDeck — user settings (config.json).</summary>
    /// <summary>Windows: %APPDATA%\NikoDeck. Linux: ~/.config/NikoDeck. macOS: ~/Library/Application Support/NikoDeck.</summary>
    public static readonly string ConfigDir = Path.Combine(
        OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)
        : OperatingSystem.IsMacOS() ? Path.Combine(Home, "Library", "Application Support")
        : Xdg("XDG_CONFIG_HOME", ".config"), AppName);

    /// <summary>%LOCALAPPDATA%\NikoDeck — logs and the installed binaries.</summary>
    /// <summary>Windows: %LOCALAPPDATA%\NikoDeck. Linux: ~/.local/share/NikoDeck. macOS: same folder as the settings.</summary>
    public static readonly string LocalDir = Path.Combine(
        OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        : OperatingSystem.IsMacOS() ? Path.Combine(Home, "Library", "Application Support")
        : Xdg("XDG_DATA_HOME", Path.Combine(".local", "share")), AppName);

    public static readonly string ConfigPath = Path.Combine(ConfigDir, "config.json");
    public static readonly string LogPath = Path.Combine(LocalDir, "agent.log");

    /// <summary>Where install scripts put the agent; self-update only works for this copy.</summary>
    public static readonly string InstallDir = Path.Combine(LocalDir, "app");

    /// <summary>"windows", "linux" or "macos".</summary>
    public static string Os => OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";

    /// <summary>Release asset suffix for this machine: win-x64, linux-x64, linux-arm64, osx-arm64 or osx-x64.</summary>
    public static string Rid =>
        (OperatingSystem.IsWindows() ? "win" : OperatingSystem.IsMacOS() ? "osx" : "linux") + "-" +
        (System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64");

    public static readonly string StartupShortcut =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), AppName + ".lnk");

    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "0.0.0";

    /// <summary>The upstream PhoneBox settings folder next to <see cref="ConfigDir"/>; a new NikoDeck install starts from a copy of it.</summary>
    public static readonly string LegacyConfigDir = Path.Combine(Path.GetDirectoryName(ConfigDir)!, "PhoneBox");

    /// <summary>Set when this run copied the PhoneBox settings (see <see cref="MigrateLegacy"/>); logged at startup.</summary>
    public static string? MigratedFrom { get; private set; }

    // macOS keeps the install, the logs and the caches in the settings folder too: those stay with PhoneBox
    private static readonly string[] NotMigrated = ["app", "updates", "photos-cache", "radio-logos", "claude-quota.json"];

    /// <summary>
    /// First NikoDeck run on a computer that has PhoneBox: copies (never moves) PhoneBox's settings folder once, with
    /// config.json and its backup, the push data, uploaded icons, wallpapers and the Wi-Fi keys, so both can stay
    /// installed. Does nothing when <paramref name="configDir"/> already has a config.json or <paramref name="legacyDir"/> has no
    /// config.json. The copy is made next to the target and renamed into place, so a failed copy leaves no half folder
    /// (the agent then starts with the default settings). Links are not followed. True when the folder was copied.
    /// </summary>
    internal static bool MigrateLegacy(string legacyDir, string configDir)
    {
        // the folder itself may already exist without settings (macOS: setup.sh puts the install in it first)
        if (File.Exists(Path.Combine(configDir, "config.json")) || !File.Exists(Path.Combine(legacyDir, "config.json"))) return false;
        var staging = configDir.TrimEnd('\\', '/') + ".migrating";
        try
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            CopyTree(legacyDir, staging, top: true);
            if (!Directory.Exists(configDir)) Directory.Move(staging, configDir);
            else
            {
                // move the copied entries in one by one, leaving whatever is already there (the install, its logs)
                // config.json last: it marks the copy as done, so a move that fails halfway is tried again next run
                foreach (var entry in new DirectoryInfo(staging).EnumerateFileSystemInfos()
                             .OrderBy(e => e.Name.Equals("config.json", StringComparison.OrdinalIgnoreCase)))
                {
                    var target = Path.Combine(configDir, entry.Name);
                    if (File.Exists(target) || Directory.Exists(target)) continue;
                    if (entry is DirectoryInfo dir) dir.MoveTo(target); else ((FileInfo)entry).MoveTo(target);
                }
                Directory.Delete(staging, true);
            }
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            return false;
        }
    }

    private static void CopyTree(string from, string to, bool top)
    {
        Directory.CreateDirectory(to);
        foreach (var entry in new DirectoryInfo(from).EnumerateFileSystemInfos())
        {
            if (entry.LinkTarget is not null) continue;
            if (top && (NotMigrated.Contains(entry.Name, StringComparer.OrdinalIgnoreCase)
                        || entry.Name.StartsWith("agent.log", StringComparison.OrdinalIgnoreCase))) continue;
            if (entry is DirectoryInfo dir) CopyTree(dir.FullName, Path.Combine(to, dir.Name), top: false);
            else CopyPrivate(entry.FullName, Path.Combine(to, entry.Name));
        }
    }

    /// <summary>Writes the default settings file on first run (after copying PhoneBox's settings, when there are any).</summary>
    public static void EnsureConfig()
    {
        if (File.Exists(ConfigPath)) return;
        if (MigrateLegacy(LegacyConfigDir, ConfigDir)) MigratedFrom = LegacyConfigDir;
        if (File.Exists(ConfigPath)) return;
        Directory.CreateDirectory(ConfigDir);
        var name = OperatingSystem.IsMacOS() ? "config.default.macos.json" : OperatingSystem.IsLinux() ? "config.default.linux.json" : "config.default.json";
        using var src = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)!;
        using var dst = CreatePrivate(ConfigPath);
        src.CopyTo(dst);
    }

    private const UnixFileMode OwnerOnly = UnixFileMode.UserRead | UnixFileMode.UserWrite;

    /// <summary>
    /// Tightens the settings file in use and its backup to owner only on macOS/Linux: older versions wrote them with the
    /// umask (often 0644), and they hold the Wi-Fi, webhook and Home Assistant keys. Also for a <c>--config</c> path.
    /// </summary>
    public static void RestrictConfig(string configPath)
    {
        RestrictToOwner(configPath);
        RestrictToOwner(configPath + ".bak");
    }

    /// <summary>
    /// Creates a file only its owner can read on macOS/Linux (0600), replacing any file at <paramref name="path"/>;
    /// Windows keeps the profile ACLs. On Unix an existing file is removed first and the new one is created exclusively,
    /// so the content never lands in a file with another owner or mode (a leftover or planted .tmp).
    /// </summary>
    public static FileStream CreatePrivate(string path)
    {
        if (OperatingSystem.IsWindows())
            return new FileStream(path, new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write, Share = FileShare.None });
        File.Delete(path);
        return new FileStream(path, new FileStreamOptions
        {
            Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, UnixCreateMode = OwnerOnly,
        });
    }

    /// <summary>Copies a file into a new owner-only file (see <see cref="CreatePrivate"/>), unlike File.Copy, which keeps the source's mode.</summary>
    public static void CopyPrivate(string source, string destination)
    {
        using var src = File.OpenRead(source);
        using var dst = CreatePrivate(destination);
        src.CopyTo(dst);
    }

    /// <summary><see cref="File.WriteAllText(string, string?)"/> into a file only its owner can read (see <see cref="CreatePrivate"/>).</summary>
    public static void WriteAllTextPrivate(string path, string text)
    {
        using var stream = CreatePrivate(path);
        using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false));
        writer.Write(text);
    }

    /// <summary>Sets an existing file to 0600 on macOS/Linux; no-op on Windows or when the file is missing.</summary>
    public static void RestrictToOwner(string path)
    {
        if (OperatingSystem.IsWindows() || !File.Exists(path)) return;
        try { if (File.GetUnixFileMode(path) != OwnerOnly) File.SetUnixFileMode(path, OwnerOnly); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    public static Stream? Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream(name);

    /// <summary>Neutral working directory for child processes, so they never lock the install folder.</summary>
    public static string NeutralCwd => Path.GetTempPath();
}
