using System.Diagnostics;
using Dapr.Actors;
using Dapr.Actors.Client;

// A non-actor caller. POST /blast sends n calls at once to one actor id through ActorProxy's non-remoting
// InvokeMethodAsync - the same call shape DaprMQ's gateway makes - optionally giving up on each after
// cancelAfterMs.
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<IActorProxyFactory>(new ActorProxyFactory(new ActorProxyOptions { RequestTimeout = TimeSpan.FromMinutes(10) }));
var app = builder.Build();

app.MapPost("/blast", async (string actor, int n, int delayMs, int? cancelAfterMs, IActorProxyFactory proxies) =>
{
    var sw = Stopwatch.StartNew();
    var results = await Task.WhenAll(Enumerable.Range(0, n).Select(async i =>
    {
        using var cts = cancelAfterMs is > 0 ? new CancellationTokenSource(cancelAfterMs.Value) : new CancellationTokenSource();
        try
        {
            var response = await proxies.Create(new ActorId(actor), "SlowActor")
                .InvokeMethodAsync<WorkRequest, WorkResponse>("Work", new WorkRequest(delayMs, $"call-{i}"), cts.Token);
            return (Outcome: "ok", Others: response.OtherTurnsInProgressAtStart);
        }
        catch (OperationCanceledException)
        {
            return (Outcome: "cancelled by caller", Others: -1);
        }
        catch (Exception e)
        {
            return (Outcome: $"failed: {e.GetType().Name}", Others: -1);
        }
    }));

    return Results.Ok(new
    {
        actor,
        n,
        delayMs,
        cancelAfterMs,
        elapsedMs = sw.ElapsedMilliseconds,
        serialisedWouldTakeAtLeastMs = cancelAfterMs is > 0 ? (long?)null : (long)n * delayMs,
        outcomes = results.GroupBy(r => r.Outcome).ToDictionary(g => g.Key, g => g.Count()),
        completedCallsThatSawAnotherTurnInProgress = results.Count(r => r.Others > 0),
        maxOtherTurnsSeenByACompletedCall = results.Max(r => r.Others)
    });
});

app.Run();

public record WorkRequest(int DelayMs, string Tag);

public record WorkResponse(string Tag, int OtherTurnsInProgressAtStart, string Host);
