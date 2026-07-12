#!/usr/bin/env bash
# [US2] Contract test for pq_stats: KEYS=queue,prefix,[DLQ]; ARGV=now,timeout,
# [max_scan]; cheap flat map; no-writes (callable via FCALL_RO); EKEYS/ENOW/ETMO/
# ESCAN/ETAG/EMALFORMED. Spec: FR-008/011.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== stats contract on: $e =="
  load_library "$e"
  q="pq:{sc}"; pfx="pq:{sc}:m:"; dl="dlq:{sc}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}1" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}1" 1 1 Priority 5 Payload x >/dev/null

  # Cheap tier via FCALL_RO (no-writes): returns depth/dlq_depth/front_priority.
  out=$(fcall_ro "$e" pq_stats 3 "$q" "$pfx" "$dl" 1000 30000)
  expect_contains "cheap map has depth" "depth" "$out"
  expect_contains "cheap map has dlq_depth" "dlq_depth" "$out"
  expect_contains "cheap map has front_priority" "front_priority" "$out"

  # 2-key form (no DLQ) is valid.
  out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" 1000 30000)
  expect_contains "2-key form valid" "depth" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall_ro "$e" pq_stats 1 "$q" 1000 30000 2>&1 || true)
  expect_contains "one key -> EKEYS" "EKEYS" "$out"
  out=$(fcall_ro "$e" pq_stats 4 "$q" "$pfx" "$dl" "x:{sc}" 1000 30000 2>&1 || true)
  expect_contains "four keys -> EKEYS" "EKEYS" "$out"

  # Bad args.
  out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" -1 30000 2>&1 || true)
  expect_contains "bad now -> ENOW" "ENOW" "$out"
  out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" 1000 0 2>&1 || true)
  expect_contains "bad timeout -> ETMO" "ETMO" "$out"
  out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" 1000 30000 -1 2>&1 || true)
  expect_contains "bad max_scan -> ESCAN" "ESCAN" "$out"

  # Tag mismatch -> ETAG.
  out=$(fcall_ro "$e" pq_stats 2 "pq:{sc}" "pq:{other}:m:" 1000 30000 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Non-zset queue -> EMALFORMED.
  engine_cli "$e" DEL "str:{sc}" >/dev/null
  engine_cli "$e" SET "str:{sc}" notazset >/dev/null
  out=$(fcall_ro "$e" pq_stats 2 "str:{sc}" "str:{sc}:m:" 1000 30000 2>&1 || true)
  expect_contains "non-zset queue -> EMALFORMED" "EMALFORMED" "$out"

  # It is no-writes: FCALL (write path) also works, and it left the message unleased.
  out=$(fcall "$e" pq_stats 2 "$q" "$pfx" 1000 30000)
  expect_contains "stats callable via FCALL too" "depth" "$out"
  expect "stats wrote nothing (message unleased)" "0" "$(engine_cli "$e" HGET "${pfx}1" DirtyBit)"
done

finish
