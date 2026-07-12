#!/usr/bin/env bash
# [US1] Contract test for msgfmt_reap: KEYS[1]=DLQ, KEYS[2]=prefix; ARGV=now,
# retention, limit; returns {removed,scanned,truncated}; write-flag (rejected
# under FCALL_RO); EKEYS/ENOW/ERET/ELIMIT/ETAG/EMALFORMED. Spec: FR-003/004.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== reap contract on: $e =="
  load_library "$e"
  dl="dlq:{rc}"; pfx="pq:{rc}:m:"
  engine_cli "$e" DEL "$dl" "${pfx}1" >/dev/null

  # Empty DLQ -> zero map.
  out=$(fcall "$e" msgfmt_reap 2 "$dl" "$pfx" 1000 1000 10)
  expect_contains "empty DLQ reports removed" "removed" "$out"
  expect_contains "empty DLQ reports scanned" "scanned" "$out"
  expect_contains "empty DLQ reports truncated" "truncated" "$out"

  # One expired entry -> removed (member + Hash).
  fcall "$e" msgfmt_create 1 "${pfx}1" Priority 5 Payload x DeadLetteredAt 100 >/dev/null
  m1=$(printf '%020d:%s' 1 1)
  engine_cli "$e" ZADD "$dl" 5 "$m1" >/dev/null
  out=$(fcall "$e" msgfmt_reap 2 "$dl" "$pfx" 100000 1000 10)
  expect_contains "expired entry removed" "removed" "$out"
  expect "member gone" "" "$(engine_cli "$e" ZSCORE "$dl" "$m1")"
  expect "hash deleted" "0" "$(engine_cli "$e" EXISTS "${pfx}1")"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" msgfmt_reap 1 "$dl" 1000 1000 10 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"

  # Invalid args.
  out=$(fcall "$e" msgfmt_reap 2 "$dl" "$pfx" -1 1000 10 2>&1 || true)
  expect_contains "bad now -> ENOW" "ENOW" "$out"
  out=$(fcall "$e" msgfmt_reap 2 "$dl" "$pfx" 1000 -1 10 2>&1 || true)
  expect_contains "bad retention -> ERET" "ERET" "$out"
  out=$(fcall "$e" msgfmt_reap 2 "$dl" "$pfx" 1000 1000 0 2>&1 || true)
  expect_contains "bad limit -> ELIMIT" "ELIMIT" "$out"

  # Tag mismatch -> ETAG.
  out=$(fcall "$e" msgfmt_reap 2 "dlq:{rc}" "pq:{other}:m:" 1000 1000 10 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Non-zset DLQ -> EMALFORMED.
  engine_cli "$e" DEL "str:{rc}" >/dev/null
  engine_cli "$e" SET "str:{rc}" notazset >/dev/null
  out=$(fcall "$e" msgfmt_reap 2 "str:{rc}" "str:{rc}:m:" 1000 1000 10 2>&1 || true)
  expect_contains "non-zset DLQ -> EMALFORMED" "EMALFORMED" "$out"

  # Write function: rejected under FCALL_RO.
  out=$(fcall_ro "$e" msgfmt_reap 2 "$dl" "$pfx" 1000 1000 10 2>&1 || true)
  expect_contains "reap rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
done

finish
