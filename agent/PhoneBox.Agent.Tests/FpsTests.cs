using System.Text.Json;
using PhoneBox.Agent;
using Xunit;

public sealed class FpsTests
{
    private static AgentConfig Config(string widgets, bool enabled = true) => JsonSerializer.Deserialize<AgentConfig>(
        $$"""{"pages":[{"id":"p","enabled":{{(enabled ? "true" : "false")}},"widgets":{{widgets}}}]}""",
        new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;

    [Fact]
    public void TheTraceRunsOnlyWhileAnEnabledPageShowsTheFrameRate()
    {
        Assert.False(Config("""[{"type":"stat","options":{"metric":"cpu"}}]""").ShowFps());
        Assert.True(Config("""[{"type":"stat","options":{"metric":"fps"}}]""").ShowFps());
        Assert.True(Config("""[{"type":"gauge","options":{"metric":"fps"}}]""").ShowFps());
        Assert.True(Config("""[{"type":"chart","options":{"metrics":["cpu","fps"]}}]""").ShowFps());
        Assert.False(Config("""[{"type":"chart","options":{"metrics":["cpu"]}}]""").ShowFps());
        Assert.False(Config("""[{"type":"stat","options":{"metric":"fps"}}]""", enabled: false).ShowFps());
        // a Smart Stack card counts while it is enabled
        Assert.True(Config("""[{"type":"stack","options":{"widgets":[{"type":"stat","options":{"metric":"fps"}}]}}]""").ShowFps());
        Assert.False(Config("""[{"type":"stack","options":{"widgets":[{"type":"stat","enabled":false,"options":{"metric":"fps"}}]}}]""").ShowFps());
        // another widget with a "metric" option is not a frame-rate display
        Assert.False(Config("""[{"type":"push","options":{"metric":"fps"}}]""").ShowFps());
    }

    [Fact]
    public void FramesAreCountedByTheirTimeStampsNotByWhenTheyArrive()
    {
        const long second = 1000;
        // 3 seconds at 100 frames a second, delivered at once (one buffer): still 100, not 300
        var stamps = Enumerable.Range(0, 300).Select(i => 10_000L + i * 10).ToList();
        Assert.Equal(100, SystemMonitor.FramesInLastSecond(stamps, second));
        // a slower game: one frame every 25 ms
        Assert.Equal(40, SystemMonitor.FramesInLastSecond(Enumerable.Range(0, 80).Select(i => i * 25L).ToList(), second));
        Assert.Equal(0, SystemMonitor.FramesInLastSecond([], second));
    }

    [Fact]
    public void TheFrameRateIsThatOfTheProgramInFront()
    {
        var game = SystemMonitor.PickFps(144, 10, "  Some Game ");
        Assert.Equal(144, game.Value);
        Assert.Equal("Some Game", game.App);
        Assert.Equal("ok", game.State);
    }

    [Fact]
    public void AProgramInFrontThatDrewNothingHasNoFrameRateAndNoName()
    {
        var idle = SystemMonitor.PickFps(null, 30, "Settings");
        Assert.Null(idle.Value);
        Assert.Null(idle.App);
        Assert.Null(SystemMonitor.PickFps(0, 30, "Settings").Value);
        Assert.Null(SystemMonitor.PickFps(120, 0, null).Value); // nothing in front (the lock screen)
    }
}
