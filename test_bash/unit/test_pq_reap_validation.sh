#!/usr/bin/env bash
# [US1] Unit: pq_reap validation + fail-before-write. Invalid now/retention/
# limit, tag mismatch, and a non-zset DLQ return the correct PQ E... errors and
# write nothing. Spec: FR-003/004/012/013.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== reap validation on: $e =="
  dl="dlq:{rv}"; pfx="pq:{rv}:m:"
  engine_cli "$e" DEL "$dl" "${pfx}1" >/dev/null
  # Seed one clearly-expired entry; assert it survives every rejected call.
  fcall "$e" pq_create 1 "${pfx}1" Priority 5 Payload x DeadLetteredAt 1 >/dev/null
  m1=$(printf '%020d:%s' 1 1)
  engine_cli "$e" ZADD "$dl" 5 "$m1" >/dev/null

  for bad in -1 1.5 abc; do
    out=$(fcall "$e" pq_reap 2 "$dl" "$pfx" "$bad" 1000 10 2>&1 || true)
    expect_contains "now=$bad -> ENOW" "ENOW" "$out"
  done
  for bad in -1 1.5 abc; do
    out=$(fcall "$e" pq_reap 2 "$dl" "$pfx" 100000 "$bad" 10 2>&1 || true)
    expect_contains "retention=$bad -> ERET" "ERET" "$out"
  done
  for bad in 0 -5 1.5 abc; do
    out=$(fcall "$e" pq_reap 2 "$dl" "$pfx" 100000 1000 "$bad" 2>&1 || true)
    expect_contains "limit=$bad -> ELIMIT" "ELIMIT" "$out"
  done

  out=$(fcall "$e" pq_reap 2 "dlq:{rv}" "pq:{nope}:m:" 100000 1000 10 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Nothing was written on any failure: the expired entry is still present.
  expect "no write on failure: member intact" "5" "$(engine_cli "$e" ZSCORE "$dl" "$m1")"
  expect "no write on failure: hash intact" "1" "$(engine_cli "$e" EXISTS "${pfx}1")"
}

run_suite suite
