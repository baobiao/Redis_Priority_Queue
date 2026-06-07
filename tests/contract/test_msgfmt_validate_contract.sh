#!/usr/bin/env bash
# [US3] Contract test for msgfmt_validate: no KEYS, FCALL_RO-callable, VALID/error.
# Spec: FR-011/FR-012  Contract: contracts/functions.md
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== msgfmt_validate contract on: $e =="
  load_library "$e"

  # No keys (numkeys 0), callable via FCALL_RO
  out=$(fcall_ro "$e" msgfmt_validate 0 Priority 5 DirtyBit true)
  expect "valid input -> VALID" "VALID" "$out"

  out=$(fcall_ro "$e" msgfmt_validate 0)
  expect "empty (all defaults) -> VALID" "VALID" "$out"

  out=$(fcall_ro "$e" msgfmt_validate 0 ReadAttempts -1 2>&1 || true)
  expect_contains "invalid -> EINVAL" "EINVAL: ReadAttempts" "$out"

  out=$(fcall_ro "$e" msgfmt_validate 0 Nope 1 2>&1 || true)
  expect_contains "unknown -> EFIELD" "EFIELD: Nope" "$out"
done

finish
