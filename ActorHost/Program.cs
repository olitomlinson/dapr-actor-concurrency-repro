using System.Collections.Concurrent;
using Dapr.Actors;
using Dapr.Actors.Runtime;

// A minimal actor host. SlowActor.Work only waits DelayMs - no state, no other actors, no lifecycle hooks -
// and counts the invocations of Work in progress per actor id from its first line to its finally. With
// Dapr's turn-based concurrency, that count can never exceed 1.
var builder = WebApplication.CreateBuilder(args);
var reentrancy = Environment.GetEnvironmentVariable("REENTRANCY") == "true";
builder.Services.AddActors(options =>
{
    options.Actors.RegisterActor<SlowActor>();
    options.ReentrancyConfig = new ActorReentrancyConfig { Enabled = reentrancy };
});

var app = builder.Build();
app.MapActorsHandlers();
app.MapGet("/stats", () => Turns.Snapshot(reentrancy));
app.MapPost("/stats/reset", () => { Turns.Reset(); return Results.Ok(); });
app.MapGet("/timeline", () => Turns.Timeline());
app.Run();

public record WorkRequest(int DelayMs, string Tag);

public record WorkResponse(string Tag, int OtherTurnsInProgressAtStart, string Host);

public interface ISlowActor : IActor
{
    Task<WorkResponse> Work(WorkRequest request);
}

public static class Turns
{
    private static readonly ConcurrentDictionary<string, int> InProgress = new();
    private static int _calls, _overlapping, _max;
    private static readonly ConcurrentQueue<(string Tag, long StartMs, long EndMs, int InProgressAtStart)> Invocations = new();

    /// <summary>One invocation of Work, for GET /timeline: unix ms from its first line to its finally.</summary>
    public static void Record(string tag, long startMs, long endMs, int inProgressAtStart) =>
        Invocations.Enqueue((tag, startMs, endMs, inProgressAtStart));

    public static object Timeline() => Invocations
        .Select(i => new { tag = i.Tag, startMs = i.StartMs, endMs = i.EndMs, inProgressAtStart = i.InProgressAtStart, host = Environment.MachineName })
        .OrderBy(i => i.startMs)
        .ToList();

    /// <summary>Counts this turn in; returns how many were in progress, this one included.</summary>
    public static int Enter(string actorId)
    {
        var n = InProgress.AddOrUpdate(actorId, 1, (_, v) => v + 1);
        Interlocked.Increment(ref _calls);
        if (n > 1)
        {
            Interlocked.Increment(ref _overlapping);
        }

        int seen;
        while ((seen = Volatile.Read(ref _max)) < n && Interlocked.CompareExchange(ref _max, n, seen) != seen)
        {
        }
        return n;
    }

    public static void Exit(string actorId) => InProgress.AddOrUpdate(actorId, 0, (_, v) => v - 1);

    public static object Snapshot(bool reentrancy) => new
    {
        host = Environment.MachineName,
        reentrancy,
        calls = _calls,
        callsStartedWhileAnotherWasInProgress = _overlapping,
        maxTurnsInProgress = _max
    };

    public static void Reset()
    {
        _calls = 0;
        _overlapping = 0;
        _max = 0;
        Invocations.Clear();
    }
}

public class SlowActor(ActorHost host) : Actor(host), ISlowActor
{
    // Counted inside the method itself - no OnPre/OnPost hooks - so the window is exactly the time Work is
    // executing. Two overlapping windows on one actor id can only mean two invocations of Work at once.
    public async Task<WorkResponse> Work(WorkRequest request)
    {
        var startMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var inProgress = Turns.Enter(Id.GetId());
        try
        {
            if (inProgress > 1)
            {
                Logger.LogError("CONCURRENT TURN on {ActorId}: Work started with {Others} other invocation(s) in progress",
                    Id.GetId(), inProgress - 1);
            }

            await Task.Delay(request.DelayMs);
            return new WorkResponse(request.Tag, inProgress - 1, Environment.MachineName);
        }
        finally
        {
            Turns.Exit(Id.GetId());
            Turns.Record(request.Tag, startMs, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), inProgress);
        }
    }
}
