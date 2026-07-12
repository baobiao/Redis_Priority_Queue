#!/usr/bin/env bash
# [US1] Integration test: priority ordering (incl. boundary values), FIFO among
# equal priorities, and stored-message fidelity.
# Spec: FR-002/004/005/013/016, SC-001/SC-002/SC-003.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== enqueue round-trip on: $e =="
  load_library "$e"

  # --- Priority ordering across distinct priorities, including boundary values ---
  engine_cli "$e" DEL "pq:{o1}" "pq:{o1}:m:low" "pq:{o1}:m:mid" "pq:{o1}:m:hi" \
                      "pq:{o1}:m:min" "pq:{o1}:m:max" >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{o1}" "pq:{o1}:m:low" low 1 Priority 1000 >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{o1}" "pq:{o1}:m:mid" mid 2 Priority 100  >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{o1}" "pq:{o1}:m:hi"  hi  3 Priority 5    >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{o1}" "pq:{o1}:m:min" min 4 Priority -9007199254740992 >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{o1}" "pq:{o1}:m:max" max 5 Priority 9007199254740992  >/dev/null

  # Ascending by score: min(-2^53) < hi(5) < mid(100) < low(1000) < max(2^53).
  expected="$(printf '%020d:%s' 4 min)"$'\n'"$(printf '%020d:%s' 3 hi)"$'\n'"$(printf '%020d:%s' 2 mid)"$'\n'"$(printf '%020d:%s' 1 low)"$'\n'"$(printf '%020d:%s' 5 max)"
  order=$(engine_cli "$e" ZRANGE "pq:{o1}" 0 -1)
  expect "priority order (incl. boundaries) ascending by score" "$expected" "$order"

  # --- FIFO among equal priorities (same Priority, ordered by sequence) ---
  engine_cli "$e" DEL "pq:{f1}" "pq:{f1}:m:a" "pq:{f1}:m:b" "pq:{f1}:m:c" >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{f1}" "pq:{f1}:m:b" b 11 Priority 50 >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{f1}" "pq:{f1}:m:a" a 10 Priority 50 >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{f1}" "pq:{f1}:m:c" c 12 Priority 50 >/dev/null
  expected="$(printf '%020d:%s' 10 a)"$'\n'"$(printf '%020d:%s' 11 b)"$'\n'"$(printf '%020d:%s' 12 c)"
  order=$(engine_cli "$e" ZRANGE "pq:{f1}" 0 -1)
  expect "FIFO by sequence within equal priority" "$expected" "$order"

  # --- Stored-message fidelity: defaults applied; score equals Priority ---
  engine_cli "$e" DEL "pq:{r1}" "pq:{r1}:m:1" >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{r1}" "pq:{r1}:m:1" 1 1 Payload order-42 Priority 5 >/dev/null
  msg=$(fcall_ro "$e" pq_read 1 "pq:{r1}:m:1")
  expect_contains "stored Payload readable" "order-42" "$msg"
  expect "score equals Priority" "5" "$(engine_cli "$e" ZSCORE "pq:{r1}" "$(printf '%020d:%s' 1 1)")"
  expect "omitted ReadAttempts defaulted" "0" "$(engine_cli "$e" HGET "pq:{r1}:m:1" ReadAttempts)"
  expect "omitted DirtyBit defaulted"     "0" "$(engine_cli "$e" HGET "pq:{r1}:m:1" DirtyBit)"
  expect "stored Priority field" "5" "$(engine_cli "$e" HGET "pq:{r1}:m:1" Priority)"
done

finish
