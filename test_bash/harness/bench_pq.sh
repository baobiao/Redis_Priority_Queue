#!/usr/bin/env bash
#
# bench_pq.sh - lightweight, repeatable timing gate for priority_queue.lua (Feature 008, FR-013).
#
# Reuses redis-cli ONLY (no new dependency / framework). It measures the Lua-level execution
# cost of the hottest read-only functions - pq_stats (bounded breakdown) and pq_peek (top-N),
# each ~14/~N redis.call per invocation - by repeating the call N times over ONE connection with
# `redis-cli -r`, so per-iteration process/connection overhead is amortised and the measured
# delta reflects Lua execution time (the thing global-localisation changes). Read-only functions
# are used so repetition is idempotent; enqueue/dequeue behaviour is covered by the suites.
#
# Usage:
#   bench_pq.sh <engine: redis|valkey> <library.lua> [N] [SEED]
# Compare a baseline vs a candidate by running twice with different <library.lua> on the same
# engine/host and diffing the us/call figures. The FR-013 gate: candidate p50 <= baseline * 1.05.
#
set -uo pipefail

ENGINE="${1:?usage: bench_pq.sh <redis|valkey> <library.lua> [N] [SEED]}"
LIB="${2:?path to the library .lua to load}"
N="${3:-2000}"          # timed repetitions per function
SEED="${4:-200}"        # messages seeded into the bench queue
CT="pq-${ENGINE}"

cli() { docker exec -i "$CT" sh -lc 'if command -v redis-cli >/dev/null 2>&1; then exec redis-cli "$@"; else exec valkey-cli "$@"; fi' _ "$@"; }

[ -f "$LIB" ] || { echo "bench_pq.sh: library not found: $LIB" >&2; exit 1; }

# Load the library under test.
cli -x FUNCTION LOAD REPLACE < "$LIB" >/dev/null

Q='pq:{bench}'; PFX='pq:{bench}:m:'; DLQ='dlq:{bench}'

# Reset bench keys (all share the {bench} tag, so a single multi-key DEL is cluster-safe).
delkeys="$Q $DLQ"; i=1
while [ "$i" -le "$SEED" ]; do delkeys="$delkeys ${PFX}${i}"; i=$((i + 1)); done
# shellcheck disable=SC2086
cli DEL $delkeys >/dev/null

# Seed SEED messages across a spread of priorities (fixed, deterministic).
i=1
while [ "$i" -le "$SEED" ]; do
  cli FCALL pq_enqueue 2 "$Q" "${PFX}${i}" "$i" "$i" Priority "$((i % 50))" Payload "p$i" >/dev/null
  i=$((i + 1))
done

now=1700000000000; tmo=30000; scan=100

timeit() {
  local label="$1"; shift
  cli -r 50 -i 0 "$@" >/dev/null           # warm-up (discarded)
  local t0 t1 per tot
  t0=$(date +%s%N)
  cli -r "$N" -i 0 "$@" >/dev/null
  t1=$(date +%s%N)
  per=$(( (t1 - t0) / N / 1000 ))          # microseconds per call (incl. one constant round-trip)
  tot=$(( (t1 - t0) / 1000000 ))
  printf '  %-22s %6s calls  %5s us/call  (%s ms total)\n' "$label" "$N" "$per" "$tot"
}

echo "== bench $ENGINE  lib=$(basename "$LIB")  N=$N  seed=$SEED =="
timeit "pq_stats(scan=$scan)" FCALL_RO pq_stats 3 "$Q" "$PFX" "$DLQ" "$now" "$tmo" "$scan"
timeit "pq_peek(top-50)"      FCALL_RO pq_peek  2 "$Q" "$PFX" "$now" "$tmo" 50
