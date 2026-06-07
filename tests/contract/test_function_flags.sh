#!/usr/bin/env bash
# [Polish T016] Verify msgfmt_read/msgfmt_validate carry the no-writes flag and
# that the writer msgfmt_create cannot be called via FCALL_RO. Principle VII.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== function flags on: $e =="
  load_library "$e"

  listing=$(engine_cli "$e" FUNCTION LIST WITHCODE 2>/dev/null || engine_cli "$e" FUNCTION LIST)
  expect_contains "library registered" "message_format" "$listing"
  expect_contains "no-writes flag present" "no-writes" "$listing"

  # Writer must be rejected under FCALL_RO (it has no no-writes flag).
  out=$(fcall_ro "$e" msgfmt_create 1 "q:{flag}" 2>&1 || true)
  expect_contains "create rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # Reader works under the read-only command.
  engine_cli "$e" DEL "q:{flag}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{flag}" >/dev/null
  out=$(fcall_ro "$e" msgfmt_read 1 "q:{flag}")
  expect_contains "read works via FCALL_RO" "Priority" "$out"
done

finish
