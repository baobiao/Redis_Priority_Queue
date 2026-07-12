#!/usr/bin/env bash
# [US1] Integration: scheduled delivery via VisibleAt (not-before). A future
# VisibleAt is skipped by dequeue until now >= it, then delivered normally; a
# not-yet-visible high-priority message does not block a visible lower-priority
# one; VisibleAt=0/absent is immediately visible. Spec: FR-001..004/007, SC-001/005.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== scheduled delivery on: $e =="
  load_library "$e"

  # --- Future VisibleAt: skipped before, delivered at/after (boundary now==VisibleAt) ---
  q="pq:{sc}"; pfx="pq:{sc}:m:"
  engine_cli "$e" DEL "$q" "${pfx}A" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}A" A 1 Priority 5 Payload PAY-A VisibleAt 5000 >/dev/null
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 4999 30000)
  expect "not visible yet (now<VisibleAt) -> null" "" "$out"
  expect "skipped message not leased: DirtyBit=0"     "0" "$(engine_cli "$e" HGET "${pfx}A" DirtyBit)"
  expect "skipped message not leased: ReadAttempts=0" "0" "$(engine_cli "$e" HGET "${pfx}A" ReadAttempts)"
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 5000 30000)
  expect_contains "visible at now==VisibleAt (>=) -> delivered" "PAY-A" "$out"

  # --- A not-yet-visible HIGH-priority message does not block a visible LOWER-priority one ---
  q="pq:{sd}"; pfx="pq:{sd}:m:"
  engine_cli "$e" DEL "$q" "${pfx}H" "${pfx}L" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}H" H 1 Priority 5  Payload PAY-H VisibleAt 5000 >/dev/null  # higher prio, hidden
  fcall "$e" pq_enqueue 2 "$q" "${pfx}L" L 2 Priority 10 Payload PAY-L VisibleAt 0    >/dev/null  # lower prio, visible
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "visible low-priority L delivered while high-priority H is hidden" "PAY-L" "$out"
  case "$out" in *PAY-H*) TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); echo "  FAIL : hidden H must not be delivered early" ;; *) TESTS_RUN=$((TESTS_RUN+1)); echo "  ok   : hidden H not delivered early" ;; esac
  # Once H is visible it takes precedence (higher priority) over any remaining visible message.
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 5000 30000)
  expect_contains "H delivered once visible" "PAY-H" "$out"

  # --- VisibleAt = 0 (and omitted) are immediately visible ---
  q="pq:{s0}"; pfx="pq:{s0}:m:"
  engine_cli "$e" DEL "$q" "${pfx}Z" "${pfx}Y" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}Z" Z 1 Priority 5 Payload PAY-Z VisibleAt 0 >/dev/null
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1 30000)
  expect_contains "explicit VisibleAt=0 is immediately visible" "PAY-Z" "$out"
  fcall "$e" pq_enqueue 2 "$q" "${pfx}Y" Y 2 Priority 5 Payload PAY-Y >/dev/null   # no VisibleAt field
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1 30000)
  expect_contains "omitted VisibleAt defaults to immediately visible" "PAY-Y" "$out"
done

finish
