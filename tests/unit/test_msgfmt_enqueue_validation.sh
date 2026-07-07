#!/usr/bin/env bash
# [US2] Unit tests for enqueue input rejection and the no-write guarantee.
# Spec: FR-008/FR-012, SC-004.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== enqueue validation on: $e =="
  load_library "$e"
  engine_cli "$e" DEL "pq:{u1}" "pq:{u1}:m:x" >/dev/null

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" "" 1 2>&1 || true)
  expect_contains "empty id -> EID" "EID" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x -1 2>&1 || true)
  expect_contains "negative sequence -> ESEQ" "ESEQ" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x 1.5 2>&1 || true)
  expect_contains "non-integer sequence -> ESEQ" "ESEQ" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x abc 2>&1 || true)
  expect_contains "non-numeric sequence -> ESEQ" "ESEQ" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x 1 Priority foo 2>&1 || true)
  expect_contains "bad Priority -> EINVAL Priority" "EINVAL: Priority" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x 1 Color red 2>&1 || true)
  expect_contains "unknown field -> EFIELD Color" "EFIELD: Color" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x 1 Priority 1 Priority 2 2>&1 || true)
  expect_contains "duplicate field -> EDUP Priority" "EDUP: Priority" "$out"

  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{u1}" "pq:{u1}:m:x" x 1 Payload 2>&1 || true)
  expect_contains "odd field pairs -> EARGS" "EARGS" "$out"

  # Nothing written to either structure after any failure.
  expect "no message hash stored" "0" "$(engine_cli "$e" EXISTS "pq:{u1}:m:x")"
  expect "queue index not created" "0" "$(engine_cli "$e" EXISTS "pq:{u1}")"
done

finish
