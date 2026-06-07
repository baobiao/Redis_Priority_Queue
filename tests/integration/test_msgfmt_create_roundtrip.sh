#!/usr/bin/env bash
# [US1] Integration test: create-with-defaults and create-with-explicit-values,
# verified by direct Hash inspection. Spec: FR-002..FR-008, SC-001/SC-002.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== create round-trip on: $e =="
  load_library "$e"

  # Defaults
  engine_cli "$e" DEL "q:{d1}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{d1}" >/dev/null
  expect "default ReadAttempts" "0"    "$(engine_cli "$e" HGET "q:{d1}" ReadAttempts)"
  expect "default DirtyBit"     "0"    "$(engine_cli "$e" HGET "q:{d1}" DirtyBit)"
  expect "default ReadDateTime" "0"    "$(engine_cli "$e" HGET "q:{d1}" ReadDateTime)"
  expect "default Priority"     "1000" "$(engine_cli "$e" HGET "q:{d1}" Priority)"
  expect "default Payload"      ""     "$(engine_cli "$e" HGET "q:{d1}" Payload)"

  # Explicit values (incl. large epoch-ms and DirtyBit token 'true')
  engine_cli "$e" DEL "q:{v1}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{v1}" \
    ReadAttempts 3 DirtyBit true ReadDateTime 1700000000000 Priority 5 Payload order-42 >/dev/null
  expect "explicit ReadAttempts" "3"             "$(engine_cli "$e" HGET "q:{v1}" ReadAttempts)"
  expect "explicit DirtyBit(true->1)" "1"        "$(engine_cli "$e" HGET "q:{v1}" DirtyBit)"
  expect "explicit ReadDateTime" "1700000000000" "$(engine_cli "$e" HGET "q:{v1}" ReadDateTime)"
  expect "explicit Priority" "5"                 "$(engine_cli "$e" HGET "q:{v1}" Priority)"
  expect "explicit Payload" "order-42"           "$(engine_cli "$e" HGET "q:{v1}" Payload)"

  # Partial: only Payload + Priority, rest default
  engine_cli "$e" DEL "q:{p1}" >/dev/null
  fcall "$e" msgfmt_create 1 "q:{p1}" Payload x Priority 7 >/dev/null
  expect "partial Payload"  "x" "$(engine_cli "$e" HGET "q:{p1}" Payload)"
  expect "partial Priority" "7" "$(engine_cli "$e" HGET "q:{p1}" Priority)"
  expect "partial default ReadAttempts" "0" "$(engine_cli "$e" HGET "q:{p1}" ReadAttempts)"
done

finish
