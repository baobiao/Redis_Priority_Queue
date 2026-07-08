#!/usr/bin/env bash
# [US2] State-conflict integration test: occupied message location, wrong-type
# queue key, already-enqueued member, and atomic no-write on failure.
# Spec: FR-009/FR-010/FR-011/FR-012, SC-004/SC-006.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== enqueue conflicts on: $e =="
  load_library "$e"

  # --- Occupied message location -> EEXISTS; existing message + queue unchanged ---
  engine_cli "$e" DEL "pq:{x1}" "pq:{x1}:m:1" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "pq:{x1}" "pq:{x1}:m:1" 1 1 Priority 5 >/dev/null
  before=$(engine_cli "$e" ZCARD "pq:{x1}")
  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{x1}" "pq:{x1}:m:1" 1 2 Priority 9 2>&1 || true)
  expect_contains "occupied message key -> EEXISTS" "EEXISTS" "$out"
  expect "queue cardinality unchanged after EEXISTS" "$before" "$(engine_cli "$e" ZCARD "pq:{x1}")"
  expect "original score unchanged after EEXISTS" "5" "$(engine_cli "$e" ZSCORE "pq:{x1}" "$(printf '%020d:%s' 1 1)")"

  # --- Wrong-type queue key -> EMALFORMED; nothing written ---
  engine_cli "$e" DEL "pq:{x2}" "pq:{x2}:m:1" >/dev/null
  engine_cli "$e" SET "pq:{x2}" notazset >/dev/null
  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{x2}" "pq:{x2}:m:1" 1 1 Priority 5 2>&1 || true)
  expect_contains "wrong-type queue -> EMALFORMED" "EMALFORMED" "$out"
  expect "message hash not created on wrong-type queue" "0" "$(engine_cli "$e" EXISTS "pq:{x2}:m:1")"

  # --- Already-enqueued member (same id+sequence, different message key) -> EQDUP ---
  engine_cli "$e" DEL "pq:{x3}" "pq:{x3}:m:1" "pq:{x3}:m:2" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "pq:{x3}" "pq:{x3}:m:1" dup 7 Priority 5 >/dev/null
  before=$(engine_cli "$e" ZCARD "pq:{x3}")
  out=$(fcall "$e" msgfmt_enqueue 2 "pq:{x3}" "pq:{x3}:m:2" dup 7 Priority 9 2>&1 || true)
  expect_contains "already-enqueued member -> EQDUP" "EQDUP" "$out"
  expect "queue cardinality unchanged after EQDUP" "$before" "$(engine_cli "$e" ZCARD "pq:{x3}")"
  expect "second message hash not created after EQDUP" "0" "$(engine_cli "$e" EXISTS "pq:{x3}:m:2")"
done

finish
