#!/usr/bin/env bash
# Builds the repro, deploys it to a kind cluster that already has Dapr installed, and runs each scenario
# with actor reentrancy off and then on. The hosts count, inside each turn, how many turns are in
# progress on the same actor id - with turn-based concurrency that never exceeds 1.
#
#   ./run.sh [--cluster NAME]   (default: daprmq-e2e)
set -euo pipefail
CLUSTER=daprmq-e2e
[[ "${1:-}" == "--cluster" ]] && CLUSTER="$2"
CTX="kind-${CLUSTER}"
cd "$(dirname "$0")"
k() { kubectl --context "$CTX" -n actor-repro "$@"; }

echo "== build"
docker build -q --build-arg PROJECT=ActorHost -t dapr-actor-repro-host:dev . >/dev/null
docker build -q --build-arg PROJECT=Client -t dapr-actor-repro-client:dev . >/dev/null
kind load docker-image --name "$CLUSTER" dapr-actor-repro-host:dev dapr-actor-repro-client:dev >/dev/null
echo "dapr runtime: $(kubectl --context "$CTX" -n dapr-system get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -m1 placement || true)"

PIDS=()
cleanup() { [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null || true; }
trap cleanup EXIT

forward() { # forward <target> <local port>
  k port-forward "$1" "$2:8080" >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$2/" && return; sleep 0.25; done
}

host_stats() { for p in "${HOST_PORTS[@]}"; do curl -s "http://127.0.0.1:$p/stats"; echo; done; }
reset_stats() { for p in "${HOST_PORTS[@]}"; do curl -s -X POST "http://127.0.0.1:$p/stats/reset" >/dev/null; done; }

scenario() { # scenario <name> <query> [settle seconds]
  local name=$1 query=$2 settle=${3:-0}
  reset_stats
  echo "-- $name ($query)"
  curl -s -X POST "http://127.0.0.1:18200/blast?actor=a1&$query"; echo
  [[ $settle -gt 0 ]] && sleep "$settle"
  host_stats | sed 's/^/   host: /'
}

for REENTRANCY in false true; do
  echo; echo "==================== reentrancy=$REENTRANCY"
  sed "s/__REENTRANCY__/$REENTRANCY/g" k8s/repro.yaml | kubectl --context "$CTX" apply -f - >/dev/null
  k rollout restart deploy/actor-host deploy/client >/dev/null
  k rollout status deploy/actor-host --timeout=180s >/dev/null && k rollout status deploy/client --timeout=180s >/dev/null
  sleep 10 # let the hosts register with placement
  cleanup; PIDS=(); HOST_PORTS=()
  forward deploy/client 18200
  port=18210
  for p in $(k get pods -l app=actor-host --field-selector=status.phase=Running -o name); do forward "$p" $port; HOST_PORTS+=($port); port=$((port + 1)); done
  curl -s -X POST "http://127.0.0.1:18200/blast?actor=a1&n=1&delayMs=10" >/dev/null # activate the actor

  scenario "serial: 20 calls x 1000ms" "n=20&delayMs=1000"
  scenario "fan-in: 100 calls x 200ms" "n=100&delayMs=200"
  scenario "callers give up: 20 calls x 2000ms, cancelled after 500ms" "n=20&delayMs=2000&cancelAfterMs=500" 50
done
