#!/usr/bin/env bash
# [US1+US2] Integration: acquire in priority then FIFO order, lease fields set,
# Payload fidelity, null on empty; ack removes (idempotent NOOP on retry); nack
# releases and the message is redelivered with ReadAttempts retained.
# Spec: FR-002/003/004/005/006/009/010/012, SC-001/002/004/005/009.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dequeue round-trip on: $e =="
  load_library "$e"

  q="pq:{d1}"; pfx="pq:{d1}:m:"
  engine_cli "$e" DEL "$q" "${pfx}a" "${pfx}b" "${pfx}c" >/dev/null

  # a: seq1 pri10 ; b: seq2 pri5 ; c: seq3 pri10  -> order b, a, c.
  fcall "$e" pq_enqueue 2 "$q" "${pfx}a" a 1 Priority 10 Payload task-a >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}b" b 2 Priority 5  Payload task-b >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}c" c 3 Priority 10 Payload task-c >/dev/null

  # --- Priority then FIFO order ---
  d1=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "1st acquire = highest priority (b, pri5)" "task-b" "$d1"
  d2=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "2nd acquire = a (pri10, seq1 before c)" "task-a" "$d2"
  d3=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "3rd acquire = c (pri10, seq3)" "task-c" "$d3"

  # --- All in-flight -> null (distinct from an empty payload) ---
  d4=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect "4th acquire returns null (all leased)" "" "$d4"

  # --- Lease fields set on the acquired message b ---
  expect "b DirtyBit=1 after acquire"     "1"    "$(engine_cli "$e" HGET "${pfx}b" DirtyBit)"
  expect "b ReadAttempts=1 after acquire" "1"    "$(engine_cli "$e" HGET "${pfx}b" ReadAttempts)"
  expect "b ReadDateTime=now after acquire" "1000" "$(engine_cli "$e" HGET "${pfx}b" ReadDateTime)"

  # --- ack removes b (member + hash); ZCARD drops from 3 to 2; retry is NOOP ---
  before=$(engine_cli "$e" ZCARD "$q")
  ackout=$(fcall "$e" pq_ack 2 "$q" "${pfx}b" "$(printf '%020d:%s' 2 b)" 1)
  expect "ack b returns OK" "OK" "$ackout"
  expect "b hash deleted" "NOTFOUND" "$(fcall_ro "$e" pq_read 1 "${pfx}b")"
  expect "queue cardinality drops by 1" "$((before - 1))" "$(engine_cli "$e" ZCARD "$q")"
  expect "re-ack b is idempotent NOOP" "NOOP" "$(fcall "$e" pq_ack 2 "$q" "${pfx}b" "$(printf '%020d:%s' 2 b)" 1)"

  # --- nack releases a; DirtyBit back to 0, ReadDateTime/ReadAttempts retained ---
  nackout=$(fcall "$e" pq_nack 1 "${pfx}a" 1)
  expect "nack a returns OK" "OK" "$nackout"
  expect "a DirtyBit=0 after nack"        "0"    "$(engine_cli "$e" HGET "${pfx}a" DirtyBit)"
  expect "a ReadAttempts retained (1)"    "1"    "$(engine_cli "$e" HGET "${pfx}a" ReadAttempts)"
  expect "a ReadDateTime retained (1000)" "1000" "$(engine_cli "$e" HGET "${pfx}a" ReadDateTime)"

  # --- a is available again and redelivered with a higher ReadAttempts ---
  d5=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 2000 30000)
  expect_contains "a redelivered after nack" "task-a" "$d5"
  expect "a ReadAttempts incremented to 2" "2"    "$(engine_cli "$e" HGET "${pfx}a" ReadAttempts)"
  expect "a ReadDateTime updated to 2000"  "2000" "$(engine_cli "$e" HGET "${pfx}a" ReadDateTime)"
done

finish
