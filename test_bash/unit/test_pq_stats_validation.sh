#!/usr/bin/env bash
# [US2] Unit: pq_stats validation, read-only. Invalid now/timeout/max_scan, tag
# mismatch, and a non-zset queue return the correct PQ E... errors; stats never
# writes. Spec: FR-008..011.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== stats validation on: $e =="
  load_library "$e"
  q="pq:{sv}"; pfx="pq:{sv}:m:"
  engine_cli "$e" DEL "$q" "${pfx}1" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}1" 1 1 Priority 5 Payload x >/dev/null

  for bad in -1 1.5 abc; do
    out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" "$bad" 30000 2>&1 || true)
    expect_contains "now=$bad -> ENOW" "ENOW" "$out"
  done
  for bad in 0 -5 abc; do
    out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" 1000 "$bad" 2>&1 || true)
    expect_contains "timeout=$bad -> ETMO" "ETMO" "$out"
  done
  for bad in -1 1.5 abc; do
    out=$(fcall_ro "$e" pq_stats 2 "$q" "$pfx" 1000 30000 "$bad" 2>&1 || true)
    expect_contains "max_scan=$bad -> ESCAN" "ESCAN" "$out"
  done

  out=$(fcall_ro "$e" pq_stats 2 "pq:{sv}" "pq:{nope}:m:" 1000 30000 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  engine_cli "$e" DEL "str:{sv}" >/dev/null
  engine_cli "$e" SET "str:{sv}" notazset >/dev/null
  out=$(fcall_ro "$e" pq_stats 2 "str:{sv}" "str:{sv}:m:" 1000 30000 2>&1 || true)
  expect_contains "non-zset queue -> EMALFORMED" "EMALFORMED" "$out"

  # Read-only: the seeded message is unchanged (never leased) after all calls.
  expect "stats wrote nothing (DirtyBit still 0)" "0" "$(engine_cli "$e" HGET "${pfx}1" DirtyBit)"
done

finish
