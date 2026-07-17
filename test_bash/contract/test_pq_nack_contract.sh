#!/usr/bin/env bash
# [US2] Contract test for pq_nack: KEYS[1]=message Hash; ARGV[1]=token, optional
# ARGV[2]=VisibleAt (Feature 005). OK / NOOP / ENOTLEASED / EFENCED unchanged; the
# optional VisibleAt path + EVIS; write-flag (rejected under FCALL_RO). Spec: FR-008/009.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== nack contract on: $e =="
  q="pq:{nc}"; pfx="pq:{nc}:m:"
  engine_cli "$e" DEL "$q" "${pfx}1" >/dev/null

  # Absent message -> idempotent NOOP.
  out=$(fcall "$e" pq_nack 1 "${pfx}1" 1)
  expect "absent message -> NOOP" "NOOP" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" pq_nack 2 "$q" "${pfx}1" 1 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"

  # Non-integer token -> EARGS.
  out=$(fcall "$e" pq_nack 1 "${pfx}1" notanum 2>&1 || true)
  expect_contains "bad token -> EARGS" "EARGS" "$out"

  fcall "$e" pq_enqueue 2 "$q" "${pfx}1" 1 1 Priority 5 Payload w >/dev/null
  fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null   # lease: token=1, DirtyBit=1

  # Stale token -> EFENCED (unchanged).
  out=$(fcall "$e" pq_nack 1 "${pfx}1" 999 2>&1 || true)
  expect_contains "stale token -> EFENCED" "EFENCED" "$out"

  # Optional VisibleAt: invalid -> EVIS (fail-before-write).
  out=$(fcall "$e" pq_nack 1 "${pfx}1" 1 -1 2>&1 || true)
  expect_contains "invalid VisibleAt -> EVIS" "EVIS" "$out"

  # Valid nack with VisibleAt -> OK, sets VisibleAt.
  out=$(fcall "$e" pq_nack 1 "${pfx}1" 1 4000)
  expect "nack with VisibleAt -> OK" "OK" "$out"
  expect "VisibleAt set" "4000" "$(engine_cli "$e" HGET "${pfx}1" VisibleAt)"

  # Not in-flight now (released) -> ENOTLEASED on a second settle.
  out=$(fcall "$e" pq_nack 1 "${pfx}1" 1 2>&1 || true)
  expect_contains "not in-flight -> ENOTLEASED" "ENOTLEASED" "$out"

  # Write function: rejected under FCALL_RO.
  out=$(fcall_ro "$e" pq_nack 1 "${pfx}1" 1 2>&1 || true)
  expect_contains "nack rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
}

run_suite suite
