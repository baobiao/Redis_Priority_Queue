#!/usr/bin/env bash
# [US2] Contract test for msgfmt_read: FCALL_RO-callable, NOTFOUND, EMALFORMED.
# Spec: FR-009/FR-010/FR-013  Contract: contracts/functions.md
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== msgfmt_read contract on: $e =="
  load_library "$e"

  engine_cli "$e" DEL "q:{r1}" "q:{absent}" "q:{wrong}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{r1}" Payload hi Priority 9 >/dev/null

  # read is callable via FCALL_RO (no-writes flag)
  out=$(fcall_ro "$e" msgfmt_read 1 "q:{r1}")
  expect_contains "read returns Payload" "hi" "$out"
  expect_contains "read returns Priority" "9" "$out"
  expect_contains "read returns field names" "ReadAttempts" "$out"

  # absent key -> NOTFOUND
  out=$(fcall_ro "$e" msgfmt_read 1 "q:{absent}")
  expect "absent key -> NOTFOUND" "NOTFOUND" "$out"

  # wrong type (string at key) -> EMALFORMED
  engine_cli "$e" SET "q:{wrong}" notahash >/dev/null
  out=$(fcall_ro "$e" msgfmt_read 1 "q:{wrong}" 2>&1 || true)
  expect_contains "wrong-type key -> EMALFORMED" "EMALFORMED" "$out"
done

finish
