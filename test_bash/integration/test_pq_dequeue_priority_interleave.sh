#!/usr/bin/env bash
# [US1] Integration: messages enqueued WHILE a consumer is actively consuming.
# A higher-priority arrival is delivered on the next acquire ahead of a
# lower-priority arrival, but NEITHER preempts the message already in-flight.
# Priority is delivery order among AVAILABLE (un-leased) messages, not a global
# processing-order guarantee, and each acquire re-scans the queue from the front.
# Spec: priority-then-FIFO ordering + concurrent lease visibility (US1).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

# Local negative assertion (the shared harness only has expect / expect_contains).
expect_absent() { # <label> <needle> <haystack>
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$3" in
    *"$2"*) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL : $1 -- [$3] unexpectedly contains [$2]" ;;
    *)      echo "  ok   : $1" ;;
  esac
}

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dequeue priority interleave on: $e =="
  load_library "$e"

  q="pq:{pi1}"; pfx="pq:{pi1}:m:"
  engine_cli "$e" DEL "$q" "${pfx}A" "${pfx}B" "${pfx}C" >/dev/null

  # A is the only message initially: seq1, Priority 10.
  fcall "$e" pq_enqueue 2 "$q" "${pfx}A" A 1 Priority 10 Payload PAY-A >/dev/null

  # Consumer acquires A -> A is now in-flight (DirtyBit=1, ReadAttempts=1, ReadDateTime=1000).
  dA=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "acquire 1 leases A (the only message)" "PAY-A" "$dA"
  expect "A leased: DirtyBit=1"        "1"    "$(engine_cli "$e" HGET "${pfx}A" DirtyBit)"
  expect "A leased: ReadAttempts=1"    "1"    "$(engine_cli "$e" HGET "${pfx}A" ReadAttempts)"
  expect "A leased: ReadDateTime=1000" "1000" "$(engine_cli "$e" HGET "${pfx}A" ReadDateTime)"

  # --- While A is IN-FLIGHT, enqueue a HIGHER-priority (B, pri5) and a
  #     LOWER-priority (C, pri20) message. ---
  fcall "$e" pq_enqueue 2 "$q" "${pfx}B" B 2 Priority 5  Payload PAY-B >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}C" C 3 Priority 20 Payload PAY-C >/dev/null
  expect "queue now holds 3 members" "3" "$(engine_cli "$e" ZCARD "$q")"

  # Next acquire must return the NEW higher-priority B (jumps ahead of C),
  # must NOT re-deliver the leased A, and must NOT skip to the lower-priority C.
  dB=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1001 30000)
  expect_contains "acquire 2 = new higher-priority B" "PAY-B" "$dB"
  expect_absent   "acquire 2 does not re-deliver leased A" "PAY-A" "$dB"
  expect_absent   "acquire 2 does not jump to lower-priority C" "PAY-C" "$dB"

  # The higher-priority arrival must NOT have preempted the in-flight A:
  # A's lease fields are untouched by acquiring B.
  expect "A still in-flight, not preempted: DirtyBit=1" "1"    "$(engine_cli "$e" HGET "${pfx}A" DirtyBit)"
  expect "A ReadAttempts unchanged (1)"                 "1"    "$(engine_cli "$e" HGET "${pfx}A" ReadAttempts)"
  expect "A ReadDateTime unchanged (1000)"              "1000" "$(engine_cli "$e" HGET "${pfx}A" ReadDateTime)"

  # With A and B both leased, the lower-priority C is delivered last.
  dC=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1002 30000)
  expect_contains "acquire 3 = lower-priority C (A,B leased)" "PAY-C" "$dC"
  expect_absent   "acquire 3 does not re-deliver A" "PAY-A" "$dC"
  expect_absent   "acquire 3 does not re-deliver B" "PAY-B" "$dC"

  # All three now leased and unexpired -> nothing available (null, not empty payload).
  dNull=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1003 30000)
  expect "acquire 4 returns null (all three leased)" "" "$dNull"
done

finish
