#!/usr/bin/env bash
# Runs the repro on Docker Compose instead of Kubernetes: for reentrancy off and then on, brings the
# stack up (docker-compose.yml) and runs the same scenarios as run.sh. CANCEL_TRIALS=1 runs
# run-cancel.sh's cancellation trials instead.
#
#   ./compose-run.sh
#   CANCEL_TRIALS=1 ./compose-run.sh
set -euo pipefail
cd "$(dirname "$0")"
HOST_PORTS=(18210 18211)

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
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  REENTRANCY=$REENTRANCY docker compose up -d --build >/dev/null 2>&1
  for p in 18200 "${HOST_PORTS[@]}"; do
    until curl -s -o /dev/null "http://127.0.0.1:$p/"; do sleep 0.5; done
  done
  # Activate the actor once the hosts have registered with placement.
  until curl -s -X POST "http://127.0.0.1:18200/blast?actor=a1&n=1&delayMs=10" | grep -q '"ok":1'; do sleep 2; done
  echo "dapr runtime: $(docker compose images --format json 2>/dev/null | grep -o '"Repository":"daprio/daprd","Tag":"[^"]*"' | head -1 || true)"

  if [[ "${CANCEL_TRIALS:-0}" == "1" ]]; then
    for cancel in 500 1500 2500 4000; do
      for trial in 1 2 3; do
        scenario "client cancels each call at ${cancel}ms (trial $trial): 20 calls x 2000ms" "n=20&delayMs=2000&cancelAfterMs=$cancel" 45
      done
    done
  else
    scenario "serial: 20 calls x 1000ms" "n=20&delayMs=1000"
    scenario "fan-in: 100 calls x 200ms" "n=100&delayMs=200"
    scenario "client cancels each call at 500ms: 20 calls x 2000ms" "n=20&delayMs=2000&cancelAfterMs=500" 50
  fi
done
docker compose down --remove-orphans >/dev/null 2>&1 || true
