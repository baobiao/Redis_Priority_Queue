#!/usr/bin/env bash
# [US2] Integration test: create->read type fidelity and read-does-not-mutate.
# Spec: FR-009/FR-010/FR-014/FR-015, SC-003.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== read round-trip on: $e =="
  load_library "$e"

  # DirtyBit=false round-trips to integer 0 (not nil); large epoch preserved.
  engine_cli "$e" DEL "q:{rt}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{rt}" DirtyBit false ReadDateTime 1700000000000 Priority -5 >/dev/null

  out=$(fcall_ro "$e" msgfmt_read 1 "q:{rt}")
  expect_contains "read shows DirtyBit field"   "DirtyBit"      "$out"
  expect_contains "read preserves epoch ms"     "1700000000000" "$out"
  expect_contains "read preserves negative Priority" "-5"        "$out"

  # DirtyBit=true round-trips to integer 1
  engine_cli "$e" DEL "q:{rt2}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{rt2}" DirtyBit 1 >/dev/null
  expect "DirtyBit true stored as 1" "1" "$(engine_cli "$e" HGET "q:{rt2}" DirtyBit)"

  # read does not mutate the stored hash
  before=$(engine_cli "$e" HGETALL "q:{rt}" | sort)
  fcall_ro "$e" msgfmt_read 1 "q:{rt}" >/dev/null
  after=$(engine_cli "$e" HGETALL "q:{rt}" | sort)
  expect "read does not mutate" "$before" "$after"
done

finish
