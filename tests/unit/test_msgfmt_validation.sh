#!/usr/bin/env bash
# [US3] Unit tests for validation rules: invalid values, unknown/duplicate fields,
# and the guarantee that nothing is stored on failure. Spec: FR-011/FR-012, SC-004.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== validation rules on: $e =="
  load_library "$e"
  engine_cli "$e" DEL "q:{bad}" >/dev/null

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" ReadAttempts -1 2>&1 || true)
  expect_contains "negative ReadAttempts -> EINVAL ReadAttempts" "EINVAL: ReadAttempts" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" ReadAttempts 1.5 2>&1 || true)
  expect_contains "non-integer ReadAttempts -> EINVAL" "EINVAL: ReadAttempts" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" ReadAttempts abc 2>&1 || true)
  expect_contains "non-numeric ReadAttempts -> EINVAL" "EINVAL: ReadAttempts" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" DirtyBit maybe 2>&1 || true)
  expect_contains "bad DirtyBit -> EINVAL DirtyBit" "EINVAL: DirtyBit" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" ReadDateTime -7 2>&1 || true)
  expect_contains "negative ReadDateTime -> EINVAL" "EINVAL: ReadDateTime" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" Priority xx 2>&1 || true)
  expect_contains "non-numeric Priority -> EINVAL" "EINVAL: Priority" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" Color red 2>&1 || true)
  expect_contains "unknown field -> EFIELD Color" "EFIELD: Color" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{bad}" Priority 1 Priority 2 2>&1 || true)
  expect_contains "duplicate field -> EDUP" "EDUP: Priority" "$out"

  # Nothing stored on any failure
  expect "no hash stored after failures" "0" "$(engine_cli "$e" EXISTS "q:{bad}")"
done

finish
