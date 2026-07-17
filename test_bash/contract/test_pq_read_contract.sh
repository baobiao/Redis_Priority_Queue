#!/usr/bin/env bash
# [US2] Contract test for pq_read: FCALL_RO-callable, NOTFOUND, EMALFORMED.
# Spec: FR-009/FR-010/FR-013  Contract: contracts/functions.md
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== pq_read contract on: $e =="

  engine_cli "$e" DEL "q:{r1}" "q:{absent}" "q:{wrong}" >/dev/null
  fcall "$e" pq_create 1 "q:{r1}" Payload hi Priority 9 >/dev/null

  # read is callable via FCALL_RO (no-writes flag)
  out=$(fcall_ro "$e" pq_read 1 "q:{r1}")
  expect_contains "read returns Payload" "hi" "$out"
  expect_contains "read returns Priority" "9" "$out"
  expect_contains "read returns field names" "ReadAttempts" "$out"

  # absent key -> NOTFOUND
  out=$(fcall_ro "$e" pq_read 1 "q:{absent}")
  expect "absent key -> NOTFOUND" "NOTFOUND" "$out"

  # wrong type (string at key) -> EMALFORMED
  engine_cli "$e" SET "q:{wrong}" notahash >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{wrong}" 2>&1 || true)
  expect_contains "wrong-type key -> EMALFORMED" "EMALFORMED" "$out"

  # --- Feature 005: VisibleAt is the sixth returned field ---
  engine_cli "$e" DEL "q:{rv}" >/dev/null
  fcall "$e" pq_create 1 "q:{rv}" Priority 5 VisibleAt 4242 >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{rv}")
  expect_contains "read returns VisibleAt label" "VisibleAt" "$out"
  expect_contains "read returns VisibleAt value" "4242" "$out"

  # A message missing ONLY VisibleAt (stored before Feature 005) reads as VisibleAt=0, no error.
  engine_cli "$e" DEL "q:{rlegacy}" >/dev/null
  engine_cli "$e" HSET "q:{rlegacy}" ReadAttempts 0 DirtyBit 0 ReadDateTime 0 Priority 5 Payload old >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{rlegacy}")
  expect_contains "legacy 5-field message still reads (Payload)" "old" "$out"
  expect_contains "legacy message reports VisibleAt" "VisibleAt" "$out"

  # A message missing an ORIGINAL field still -> EMALFORMED (only VisibleAt is tolerated).
  engine_cli "$e" DEL "q:{rbad}" >/dev/null
  engine_cli "$e" HSET "q:{rbad}" ReadAttempts 0 DirtyBit 0 ReadDateTime 0 Priority 5 >/dev/null  # no Payload
  out=$(fcall_ro "$e" pq_read 1 "q:{rbad}" 2>&1 || true)
  expect_contains "missing original field still -> EMALFORMED" "EMALFORMED" "$out"

  # --- Feature 006: DeadLetteredAt is the seventh returned field ---
  engine_cli "$e" DEL "q:{rdla}" >/dev/null
  fcall "$e" pq_create 1 "q:{rdla}" Priority 5 DeadLetteredAt 7777 >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{rdla}")
  expect_contains "read returns DeadLetteredAt label" "DeadLetteredAt" "$out"
  expect_contains "read returns DeadLetteredAt value" "7777" "$out"

  # A message missing only VisibleAt AND DeadLetteredAt (pre-005/006) reads as 0/0, no error.
  engine_cli "$e" DEL "q:{rlegacy6}" >/dev/null
  engine_cli "$e" HSET "q:{rlegacy6}" ReadAttempts 0 DirtyBit 0 ReadDateTime 0 Priority 5 Payload old2 >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{rlegacy6}")
  expect_contains "legacy message still reads (Payload)" "old2" "$out"
  expect_contains "legacy message reports DeadLetteredAt" "DeadLetteredAt" "$out"
}

run_suite suite
