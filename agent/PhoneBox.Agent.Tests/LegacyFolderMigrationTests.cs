using PhoneBox.Agent;
using Xunit;

/// <summary>NikoDeck's first run copies an existing PhoneBox settings folder once (AppPaths.MigrateLegacy).</summary>
public sealed class LegacyFolderMigrationTests : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("nikodeck-migration-");
    private string Legacy => Path.Combine(_root.FullName, "PhoneBox");
    private string Target => Path.Combine(_root.FullName, "NikoDeck");

    public void Dispose() => _root.Delete(true);

    private void Write(string relative, string text)
    {
        var path = Path.Combine(Legacy, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    [Fact]
    public void CopiesSettingsAndMediaAndLeavesPhoneBoxAsItWas()
    {
        Write("config.json", "{ \"pages\": [] }");
        Write("config.json.bak", "backup");
        Write("data.json", "push");
        Write(Path.Combine("icons", "a.png"), "icon");
        Write("wallpaper-1.jpg", "wall");
        Write("appearance-note.txt", "kept");             // only the exact names below are left out
        Write(Path.Combine("app", "PhoneBoxAgent"), "binary"); // macOS: the install lives in the same folder
        Write(Path.Combine("updates", "x.zip"), "zip");
        Write("agent.log", "log");
        Write("agent.log.1", "old log");

        Assert.True(AppPaths.MigrateLegacy(Legacy, Target));

        Assert.Equal("{ \"pages\": [] }", File.ReadAllText(Path.Combine(Target, "config.json")));
        Assert.Equal("backup", File.ReadAllText(Path.Combine(Target, "config.json.bak")));
        Assert.Equal("push", File.ReadAllText(Path.Combine(Target, "data.json")));
        Assert.Equal("icon", File.ReadAllText(Path.Combine(Target, "icons", "a.png")));
        Assert.Equal("wall", File.ReadAllText(Path.Combine(Target, "wallpaper-1.jpg")));
        Assert.True(File.Exists(Path.Combine(Target, "appearance-note.txt")));
        Assert.False(Directory.Exists(Path.Combine(Target, "app")));
        Assert.False(Directory.Exists(Path.Combine(Target, "updates")));
        Assert.False(File.Exists(Path.Combine(Target, "agent.log")));
        Assert.False(File.Exists(Path.Combine(Target, "agent.log.1")));
        Assert.False(Directory.Exists(Target + ".migrating"));
        // a copy, not a move
        Assert.Equal("{ \"pages\": [] }", File.ReadAllText(Path.Combine(Legacy, "config.json")));
        Assert.True(File.Exists(Path.Combine(Legacy, "app", "PhoneBoxAgent")));
    }

    [Fact]
    public void RunsOnlyOnceAnExistingNikoDeckFolderIsNeverTouched()
    {
        Write("config.json", "from PhoneBox");
        Directory.CreateDirectory(Target);
        File.WriteAllText(Path.Combine(Target, "config.json"), "NikoDeck's own");

        Assert.False(AppPaths.MigrateLegacy(Legacy, Target));
        Assert.Equal("NikoDeck's own", File.ReadAllText(Path.Combine(Target, "config.json")));
    }

    [Fact]
    public void AFolderWithoutSettingsYetIsFilledInAndKeepsWhatIsThere()
    {
        // macOS: setup.sh puts the install inside the settings folder before the agent's first run
        Write("config.json", "from PhoneBox");
        Write(Path.Combine("icons", "a.png"), "icon");
        Directory.CreateDirectory(Path.Combine(Target, "app"));
        File.WriteAllText(Path.Combine(Target, "app", "NikoDeck"), "new binary");

        Assert.True(AppPaths.MigrateLegacy(Legacy, Target));

        Assert.Equal("from PhoneBox", File.ReadAllText(Path.Combine(Target, "config.json")));
        Assert.Equal("icon", File.ReadAllText(Path.Combine(Target, "icons", "a.png")));
        Assert.Equal("new binary", File.ReadAllText(Path.Combine(Target, "app", "NikoDeck")));
        Assert.False(Directory.Exists(Target + ".migrating"));
    }

    [Fact]
    public void WithoutPhoneBoxSettingsNothingIsCreated()
    {
        Assert.False(AppPaths.MigrateLegacy(Legacy, Target));
        Directory.CreateDirectory(Legacy); // a folder without config.json (logs only, say) is not worth copying
        Assert.False(AppPaths.MigrateLegacy(Legacy, Target));
        Assert.False(Directory.Exists(Target));
    }

    [Fact]
    public void CopiedSettingsUpdateFromNikoDeckNotFromUpstream()
    {
        Write("config.json", "{ \"updates\": { \"auto\": true, \"repo\": \"ersinkoc/phonebox\" } }");
        Assert.True(AppPaths.MigrateLegacy(Legacy, Target));
        Assert.Equal("LordSigfrid/NikoDeck", new ConfigStore(Path.Combine(Target, "config.json")).Get().Updates.Repo);
    }

    [Fact]
    public void AnotherForkChosenOnPurposeIsKept()
    {
        Write("config.json", "{ \"updates\": { \"repo\": \"someone/their-fork\" } }");
        Assert.Equal("someone/their-fork", new ConfigStore(Path.Combine(Legacy, "config.json")).Get().Updates.Repo);
    }
}
