#!/usr/bin/env bash
# Records real per-call timings on kind (reentrancy off) and prints them as Mermaid Gantt charts:
#   1. baseline - 5 calls x 1000ms, nobody cancels
#   2. cancel   - 20 calls x 2000ms, the client cancels every call at 1500ms (retried until a trial shows >= 3 overlapping)
#
#   ./timeline.sh [--cluster NAME] > timeline.md
set -euo pipefail
CLUSTER=daprmq-e2e
[[ "${1:-}" == "--cluster" ]] && CLUSTER="$2"
CTX="kind-${CLUSTER}"
cd "$(dirname "$0")"
k() { kubectl --context "$CTX" -n actor-repro "$@"; }
log() { echo "$*" >&2; }

docker build -q --build-arg PROJECT=ActorHost -t dapr-actor-repro-host:dev . >/dev/null
docker build -q --build-arg PROJECT=Client -t dapr-actor-repro-client:dev . >/dev/null
kind load docker-image --name "$CLUSTER" dapr-actor-repro-host:dev dapr-actor-repro-client:dev >/dev/null 2>&1
sed "s/__REENTRANCY__/false/g" k8s/repro.yaml | kubectl --context "$CTX" apply -f - >/dev/null
k rollout restart deploy/actor-host deploy/client >/dev/null
k rollout status deploy/actor-host --timeout=180s >/dev/null && k rollout status deploy/client --timeout=180s >/dev/null
sleep 10

PIDS=()
trap '[[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null || true' EXIT
forward() { k port-forward "$1" "$2:8080" >/dev/null 2>&1 & PIDS+=($!); for _ in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$2/" && return; sleep 0.25; done; }
forward deploy/client 18300
HOST_PORTS=(); port=18310
for p in $(k get pods -l app=actor-host --field-selector=status.phase=Running -o name); do forward "$p" $port; HOST_PORTS+=($port); port=$((port + 1)); done
curl -s -X POST "http://127.0.0.1:18300/blast?actor=a1&n=1&delayMs=10" >/dev/null

# trial <query> <settle seconds> -> writes the merged timeline JSON, with the send time, to $OUT
trial() {
  for p in "${HOST_PORTS[@]}"; do curl -s -X POST "http://127.0.0.1:$p/stats/reset" >/dev/null; done
  local sent; sent=$(python3 -c 'import time; print(int(time.time()*1000))')
  curl -s -X POST "http://127.0.0.1:18300/blast?actor=a1&$1" >/dev/null
  sleep "$2"
  { echo "{\"sentMs\": $sent, \"calls\": ["; first=1
    for p in "${HOST_PORTS[@]}"; do
      body=$(curl -s "http://127.0.0.1:$p/timeline" | sed 's/^\[//; s/\]$//')
      [[ -z "$body" ]] && continue
      [[ $first -eq 0 ]] && echo ","; echo "$body"; first=0
    done
    echo "]}"; } > "$OUT"
}

chart() { # chart <json> <title> <cancelAfterMs or 0> <note>
  python3 - "$1" "$2" "$3" "$4" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1])); title = sys.argv[2]; cancel = int(sys.argv[3]); note = sys.argv[4]
t0 = data["sentMs"]
calls = sorted(data["calls"], key=lambda c: c["startMs"])
print("```mermaid")
print("gantt")
print(f"    title {title}")
print("    dateFormat x")
print("    axisFormat %S.%Ls")
if cancel:
    print("    section Client")
    print(f"    calls in flight until the client cancels them :done, 0, {cancel}")
print("    section Work on actor a1")
for c in calls:
    style = "crit, " if c["inProgressAtStart"] > 1 else ""
    label = f'{c["tag"]} ({c["inProgressAtStart"]} in progress)'
    print(f'    {label} :{style}{c["startMs"] - t0}, {c["endMs"] - t0}')
print("```")
print()
print(note)
print()
EOF
}

OUT=$(mktemp)
log "baseline"
trial "n=5&delayMs=1000" 2
chart "$OUT" "No cancellation - 5 calls x 1s run one after another" 0 \
  "Each bar is one invocation of \`Work\`, from its first line to its \`finally\`. Every call starts after the previous one finished."

for attempt in 1 2 3 4 5; do
  log "cancel trial $attempt"
  trial "n=20&delayMs=2000&cancelAfterMs=1500" 45
  overlapping=$(python3 -c "import json,sys; print(sum(1 for c in json.load(open('$OUT'))['calls'] if c['inProgressAtStart'] > 1))")
  log "  overlapping: $overlapping"
  [[ $overlapping -ge 3 ]] && break
done
chart "$OUT" "Client cancels every call at 1.5s - Work invocations overlap on one actor (reentrancy off)" 1500 \
  "The client sent 20 calls × 2s to actor \`a1\` at once, and cancelled every one of them at 1.5s, through the \`CancellationToken\` passed to \`ActorProxy.InvokeMethodAsync\`. Red bars started while another invocation of \`Work\` on the same actor was still running. This is attempt $attempt of up to 5; the script retries until a trial shows at least 3 overlapping calls."
rm -f "$OUT"
