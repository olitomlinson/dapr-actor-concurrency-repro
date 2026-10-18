# Dapr actor calls overlap when callers cancel

When callers cancel actor calls that are still queued behind an actor's running turn, the Dapr sidecar dispatches those calls into the actor while the earlier turn is still in progress. Two or more turns then run on the same actor id at once, which breaks turn-based concurrency. It happens with actor reentrancy **off** as well as on.

Without cancellation, turns are serialised correctly.

## Versions

- Dapr runtime 1.18.7 (Kubernetes, installed with the Dapr Helm chart, single-node kind cluster)
- Dapr .NET SDK `Dapr.Actors` / `Dapr.Actors.AspNetCore` 1.18.10, .NET 10
- State store: `state.in-memory` with `actorStateStore: "true"`

## The reproduction

- **`ActorHost`** (2 replicas) hosts `SlowActor`, whose only method `Work` waits `DelayMs`. It has no state, makes no other calls, and doesn't override any actor lifecycle hooks.
  - `Work` counts the invocations in progress per actor id: in on its first line, out in its `finally`.
  - Under turn-based concurrency that count can never go above 1. When it does, the host logs `CONCURRENT TURN`, and `GET /stats` reports the number of overlapping calls and the most invocations in progress at once.
- **`Client`** is a non-actor app. `POST /blast?actor=a1&n=20&delayMs=2000&cancelAfterMs=500` sends `n` calls to one actor id at the same time, through `ActorProxy`'s non-remoting `InvokeMethodAsync`, and optionally cancels each call's token after `cancelAfterMs`.
- **`run.sh`** builds both images, loads them into kind, deploys `k8s/repro.yaml` into the namespace `actor-repro`, and runs the scenarios with reentrancy off and then on. **`run-cancel.sh`** runs only the cancellation trials. The reentrancy setting is applied to both the Dapr `Configuration` (the `Actor.Reentrancy` feature) and the SDK (`ActorReentrancyConfig.Enabled`).

```bash
./run.sh --cluster <kind cluster with Dapr installed>
./run-cancel.sh --cluster <kind cluster with Dapr installed>
```

## Results

These results come from an earlier version of the counter, which counted from `OnPreActorMethodAsync` to `OnPostActorMethodAsync` or `OnActorMethodFailedAsync` rather than inside `Work`. Both run inside the turn, before the response goes back to the sidecar. The counter now sits inside `Work`, so the hook lifecycle can't be what produces the overlaps. A rerun with it is in progress, and these tables will be updated with its results.

**Without cancellation, there's no overlap.** Every call ran on its own, and the total time was calls × delay.

| Scenario | Reentrancy off | Reentrancy on |
|---|---|---|
| 20 calls × 1,000ms | 20.1s; 0 overlapping calls; at most 1 turn in progress | 20.1s; 0; 1 |
| 100 calls × 200ms | 20.3s; 0; 1 | 20.3s; 0; 1 |

**When callers cancel, turns overlap.** Each trial was 20 calls × 2,000ms to one actor, with every caller cancelling after the time shown. The counts are summed over both hosts.

| Reentrancy | Callers cancel after | Trial | Calls that reached the actor | Calls started while another turn was in progress | Most turns in progress at once |
|---|---|---|---|---|---|
| off | 500ms | 1 | 6 | 5 | **6** |
| off | 500ms | 2 | 5 | 4 | **5** |
| off | 500ms | 3 | 2 | 1 | 2 |
| off | 1,500ms | 1 | 3 | 2 | 3 |
| off | 1,500ms | 2 | 6 | 5 | **6** |
| off | 1,500ms | 3 | 2 | 1 | 2 |
| off | 2,500ms | 1–3 | 2 each | 0 | 1 |
| off | 4,000ms | 1, 2 | 2 each | 0 | 1 |
| off | 4,000ms | 3 | 3 | 1 | 2 |
| on | 500ms | 1, 2, 3 | 5, 6, 5 | 4, 5, 4 | **5, 6, 5** |
| on | 1,500ms | 1, 2, 3 | 4, 1, 1 | 3, 0, 0 | 4, 1, 1 |
| on | 2,500ms | 1, 2, 3 | 7, 2, 4 | 5, 0, 2 | **6**, 1, 3 |
| on | 4,000ms | 1–3 | 2 each | 0 | 1 |

In total, turns overlapped in **7 of 12** trials with reentrancy off and **7 of 12** with it on.

## What this shows

1. Calls whose callers cancelled while they were queued behind a running turn **still reached the actor**. In the 500ms trials every caller had already given up, yet 5 or 6 calls ran.
2. Those calls were **dispatched while the earlier turn was still in progress**: up to 6 turns on one actor id at once.
3. It doesn't depend on reentrancy.

## Expected behaviour

A cancelled call is either dropped before it reaches the actor, or dispatched only once the turn in progress has finished. A turn should never start while another turn on the same actor id is running.

## Found through

[DaprMQ](https://github.com/olitomlinson/dapr-mq): a queue actor under heavy load, whose callers time out after 10s, ended up with turns overwriting each other's state, losing counts and orphaning records.
