#!/usr/bin/env bash
# [US1] Contract test for msgfmt_create.
# Spec: specs/001-message-format/spec.md  Contract: contracts/functions.md
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== msgfmt_create contract on: $e =="
  load_library "$e"
  engine_cli "$e" DEL "q:{c1}" >/dev/null

  out=$(fcall "$e" msgfmt_create 1 "q:{c1}")
  expect "create all-defaults returns OK" "OK" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{c1}" Payload hello Priority 5)
  expect "create with values returns OK" "OK" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{c1}" Payload 2>&1 || true)
  expect_contains "odd ARGV -> EARGS" "EARGS" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{c1}" Color red 2>&1 || true)
  expect_contains "unknown field -> EFIELD" "EFIELD" "$out"

  out=$(fcall "$e" msgfmt_create 1 "q:{c1}" Priority 1 Priority 2 2>&1 || true)
  expect_contains "duplicate field -> EDUP" "EDUP" "$out"
done

finish
