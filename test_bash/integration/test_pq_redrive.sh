#!/usr/bin/env bash
# [US3] Integration: redrive a message from the DLQ back to the source. The member
# moves DLQ -> source at score=Priority (verbatim), delivery state resets
# (ReadAttempts=0, DirtyBit=0) while ReadDateTime is retained, and it is redelivered
# on the next dequeue; a member not in the DLQ is a NOOP; a member already in the
# source is rejected with no duplicate. Spec: FR-013..017, SC-006/007.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== redrive on: $e =="

  # ---- Dead-letter G (cap=1), then redrive it ----
  q="pq:{rd}"; pfx="pq:{rd}:m:"; dl="dlq:{rd}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}G" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}G" G 1 Priority 5 Payload PAY-G >/dev/null
  mG=$(printf '%020d:%s' 1 G)
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 1 >/dev/null   # RA 0<1 -> leased, RA=1, RDT=1000
  fcall "$e" pq_nack 1 "${pfx}G" 1 >/dev/null                          # RA=1, DirtyBit=0
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 2000 30000 0 1 >/dev/null   # RA=1>=1 -> dead-lettered
  expect "G is in the DLQ before redrive" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mG")"

  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}G" "$mG")
  expect "redrive returns OK" "OK" "$out"
  expect "G back in the source at score=Priority" "5" "$(engine_cli "$e" ZSCORE "$q" "$mG")"
  expect "G removed from the DLQ" "" "$(engine_cli "$e" ZSCORE "$dl" "$mG")"
  expect "redrive reset ReadAttempts=0" "0" "$(engine_cli "$e" HGET "${pfx}G" ReadAttempts)"
  expect "redrive reset DirtyBit=0"     "0" "$(engine_cli "$e" HGET "${pfx}G" DirtyBit)"
  expect "redrive retained ReadDateTime (1000)" "1000" "$(engine_cli "$e" HGET "${pfx}G" ReadDateTime)"

  # Redelivered on the next dequeue (below the cap after reset).
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 5000 30000 0 1)
  expect_contains "redriven G is delivered again" "PAY-G" "$out"

  # ---- NOOP when the member is not in the DLQ ----
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}G" "$mG")
  expect "redrive of a non-DLQ member -> NOOP" "NOOP" "$out"

  # ---- Reject (no duplicate) when the member is already in the source ----
  q2="pq:{rd2}"; pfx2="pq:{rd2}:m:"; dl2="dlq:{rd2}"
  engine_cli "$e" DEL "$q2" "$dl2" "${pfx2}H" >/dev/null
  fcall "$e" pq_enqueue 2 "$q2" "${pfx2}H" H 1 Priority 5 Payload PAY-H >/dev/null
  mH=$(printf '%020d:%s' 1 H)
  engine_cli "$e" ZADD "$dl2" 5 "$mH" >/dev/null            # H present in BOTH source and DLQ
  out=$(fcall "$e" pq_redrive 3 "$dl2" "$q2" "${pfx2}H" "$mH" 2>&1 || true)
  expect_contains "already-in-source redrive -> EQDUP" "EQDUP" "$out"
  expect "source still holds H (unchanged)" "5" "$(engine_cli "$e" ZSCORE "$q2" "$mH")"
  expect "DLQ copy of H untouched by the rejected redrive" "5" "$(engine_cli "$e" ZSCORE "$dl2" "$mH")"
}

run_suite suite
