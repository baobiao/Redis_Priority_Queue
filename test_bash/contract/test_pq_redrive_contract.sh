#!/usr/bin/env bash
# [US3] Contract test for pq_redrive: KEYS (DLQ, source, message Hash) + ARGV
# (member), OK on a move / NOOP when absent from the DLQ, write-flag (rejected
# under FCALL_RO), and the EKEYS/EARGS/ETAG errors. Spec: FR-013..017.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== redrive contract on: $e =="
  q="pq:{rc}"; pfx="pq:{rc}:m:"; dl="dlq:{rc}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}k" >/dev/null

  # Place k in the DLQ with its Hash at the normal source-prefixed key.
  fcall "$e" pq_enqueue 2 "$q" "${pfx}k" k 1 Priority 5 Payload hello >/dev/null
  mk=$(printf '%020d:%s' 1 k)
  engine_cli "$e" ZREM "$q" "$mk" >/dev/null
  engine_cli "$e" ZADD "$dl" 5 "$mk" >/dev/null

  # Move it back -> OK; then a second redrive is a NOOP (no longer in the DLQ).
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}k" "$mk")
  expect "redrive returns OK" "OK" "$out"
  expect "k moved back to the source" "5" "$(engine_cli "$e" ZSCORE "$q" "$mk")"
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}k" "$mk")
  expect "redrive of an absent DLQ member -> NOOP" "NOOP" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" pq_redrive 2 "$dl" "$q" "$mk" 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"

  # Empty member -> EARGS.
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}k" "" 2>&1 || true)
  expect_contains "empty member -> EARGS" "EARGS" "$out"

  # Tag mismatch across the three keys -> ETAG.
  out=$(fcall "$e" pq_redrive 3 "dlq:{rc}" "pq:{other}" "pq:{rc}:m:k" "$mk" 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Write function: must be rejected under FCALL_RO.
  out=$(fcall_ro "$e" pq_redrive 3 "$dl" "$q" "${pfx}k" "$mk" 2>&1 || true)
  expect_contains "redrive rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
}

run_suite suite
