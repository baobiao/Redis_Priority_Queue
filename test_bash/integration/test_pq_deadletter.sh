#!/usr/bin/env bash
# [US1] Integration: dead-letter at dequeue (SQS-style max-receive cap).
# An available message whose ReadAttempts >= cap is moved to the DLQ (index-only:
# score=Priority, member verbatim, message Hash untouched) instead of being leased;
# an unexpired in-flight message is never dead-lettered; an expired-lease over-cap
# message is; a below-cap message is delivered; omitting the DLQ/cap reproduces
# Feature 003 exactly. Spec: FR-001..007, SC-001/002/003; contracts/functions.md.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dead-letter on: $e =="
  load_library "$e"

  # ---- Scenario A: cap reached -> moved to the DLQ, not delivered ----
  q="pq:{dlA}"; pfx="pq:{dlA}:m:"; dl="dlq:{dlA}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}A" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}A" A 1 Priority 5 Payload PAY-A >/dev/null
  mA=$(printf '%020d:%s' 1 A)
  # Two deliver-then-nack cycles bring ReadAttempts to 2 (= cap).
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 2 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}A" 1 >/dev/null
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 2000 30000 0 2 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}A" 2 >/dev/null
  expect "A at cap: ReadAttempts=2" "2" "$(engine_cli "$e" HGET "${pfx}A" ReadAttempts)"
  # Next dead-letter dequeue: A is available (DirtyBit=0) and ReadAttempts>=cap -> DLQ.
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 3000 30000 0 2)
  expect "poison A not delivered (null reply)" "" "$out"
  expect "A moved to DLQ at score=Priority" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mA")"
  expect "A removed from the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mA")"
  expect "A message Hash untouched (Payload)" "PAY-A" "$(engine_cli "$e" HGET "${pfx}A" Payload)"

  # ---- Scenario B: a below-cap message is delivered normally ----
  q="pq:{dlB}"; pfx="pq:{dlB}:m:"; dl="dlq:{dlB}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}B" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}B" B 1 Priority 5 Payload PAY-B >/dev/null
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 2)
  expect_contains "below-cap B is leased and returned" "PAY-B" "$out"
  mB=$(printf '%020d:%s' 1 B)
  expect "B NOT dead-lettered" "" "$(engine_cli "$e" ZSCORE "$dl" "$mB")"

  # ---- Scenario C: over-cap but in-flight/unexpired is NOT dead-lettered;
  #      the same message once its lease EXPIRES is dead-lettered ----
  q="pq:{dlC}"; pfx="pq:{dlC}:m:"; dl="dlq:{dlC}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}C" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}C" C 1 Priority 5 Payload PAY-C >/dev/null
  mC=$(printf '%020d:%s' 1 C)
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 2 >/dev/null   # RA=1, in-flight
  fcall "$e" pq_nack 1 "${pfx}C" 1 >/dev/null                          # RA=1, DirtyBit=0
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 2000 30000 0 2 >/dev/null   # RA=2, in-flight, RDT=2000
  expect "C in-flight after 2nd lease: DirtyBit=1" "1" "$(engine_cli "$e" HGET "${pfx}C" DirtyBit)"
  # now=2001: lease NOT expired (1ms < 30000) and RA>=cap -> C must be skipped, not dead-lettered.
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 2001 30000 0 2)
  expect "unexpired in-flight over-cap yields null" "" "$out"
  expect "C NOT dead-lettered while in-flight" "" "$(engine_cli "$e" ZSCORE "$dl" "$mC")"
  expect "C still in the source queue" "5" "$(engine_cli "$e" ZSCORE "$q" "$mC")"
  # now=40000: lease expired (38000ms >= 30000) and RA>=cap -> C is dead-lettered.
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 40000 30000 0 2)
  expect "expired-lease over-cap yields null" "" "$out"
  expect "C moved to DLQ once lease expired" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mC")"
  expect "C removed from the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mC")"

  # ---- Scenario E: Feature 003 parity -- omitting DLQ/cap never dead-letters ----
  q="pq:{dlE}"; pfx="pq:{dlE}:m:"
  engine_cli "$e" DEL "$q" "${pfx}E" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}E" E 1 Priority 5 Payload PAY-E >/dev/null
  mE=$(printf '%020d:%s' 1 E)
  fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}E" 1 >/dev/null
  fcall "$e" pq_dequeue 2 "$q" "$pfx" 2000 30000 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}E" 2 >/dev/null
  # ReadAttempts=2, but the 2-key call has no cap -> must lease, never dead-letter.
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 3000 30000)
  expect_contains "2-key dequeue still delivers an over-cap message (F003 parity)" "PAY-E" "$out"
  expect "E remains in the source (not dead-lettered)" "5" "$(engine_cli "$e" ZSCORE "$q" "$mE")"

  # ---- Scenario F: a member already present in the DLQ is not duplicated (FR-005) ----
  q="pq:{dlF}"; pfx="pq:{dlF}:m:"; dl="dlq:{dlF}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}F" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}F" F 1 Priority 7 Payload PAY-F >/dev/null
  mF=$(printf '%020d:%s' 1 F)
  engine_cli "$e" ZADD "$dl" 7 "$mF" >/dev/null            # simulate prior DLQ presence
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 2 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}F" 1 >/dev/null
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 2000 30000 0 2 >/dev/null
  fcall "$e" pq_nack 1 "${pfx}F" 2 >/dev/null
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 3000 30000 0 2 >/dev/null   # dead-letter F (already in DLQ)
  expect "DLQ still holds exactly one F member (no duplicate)" "1" "$(engine_cli "$e" ZCARD "$dl")"
  expect "F removed from the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mF")"
done

finish
