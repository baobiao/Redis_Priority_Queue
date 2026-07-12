#!/usr/bin/env bash
# [US1] Integration: DLQ retention. Dead-lettering stamps DeadLetteredAt=now;
# pq_reap permanently removes (member + Hash) entries older than the retention
# window and keeps within-window ones; it is bounded by `limit` (truncated flag);
# it cleans dangling members; and pq_redrive clears DeadLetteredAt.
# Spec: FR-001..007, SC-001/002/003/007.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== retention on: $e =="
  load_library "$e"

  # --- Dead-letter stamps DeadLetteredAt; reap keeps within-window then removes ---
  q="pq:{rt}"; pfx="pq:{rt}:m:"; dl="dlq:{rt}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}7" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}7" 7 7 Priority 5 Payload job >/dev/null
  m7=$(printf '%020d:%s' 7 7)
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 1 >/dev/null   # RA 0<1 -> leased, RA=1
  fcall "$e" pq_nack 1 "${pfx}7" 1 >/dev/null
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 100000 30000 0 1 >/dev/null # RA=1>=1 -> dead-lettered at now=100000
  expect "dead-letter stamps DeadLetteredAt=now" "100000" "$(engine_cli "$e" HGET "${pfx}7" DeadLetteredAt)"
  expect "in DLQ before reap" "5" "$(engine_cli "$e" ZSCORE "$dl" "$m7")"
  # now=120000: age 20000 < 30000 -> kept.
  out=$(fcall "$e" pq_reap 2 "$dl" "$pfx" 120000 30000 100)
  expect_contains "within-window reap removes 0" "removed" "$out"
  expect "kept: still in DLQ" "5" "$(engine_cli "$e" ZSCORE "$dl" "$m7")"
  # now=140000: age 40000 >= 30000 -> removed (member + Hash).
  out=$(fcall "$e" pq_reap 2 "$dl" "$pfx" 140000 30000 100)
  expect_contains "expired reap reports removed" "removed" "$out"
  expect "removed from DLQ" "" "$(engine_cli "$e" ZSCORE "$dl" "$m7")"
  expect "message Hash deleted" "0" "$(engine_cli "$e" EXISTS "${pfx}7")"

  # --- Bounded by limit: 3 expired entries, limit=2 -> truncated, then drain ---
  q2="pq:{rb}"; pfx2="pq:{rb}:m:"; dl2="dlq:{rb}"
  engine_cli "$e" DEL "$q2" "$dl2" "${pfx2}1" "${pfx2}2" "${pfx2}3" >/dev/null
  for i in 1 2 3; do
    fcall "$e" pq_create 1 "${pfx2}$i" Priority 5 Payload "p$i" DeadLetteredAt 100000 >/dev/null
    engine_cli "$e" ZADD "$dl2" 5 "$(printf '%020d:%s' "$i" "$i")" >/dev/null
  done
  out=$(fcall "$e" pq_reap 2 "$dl2" "$pfx2" 200000 1000 2)
  expect_contains "bounded reap examined at most limit -> truncated" "truncated" "$out"
  expect "DLQ down to 1 after first bounded reap" "1" "$(engine_cli "$e" ZCARD "$dl2")"
  fcall "$e" pq_reap 2 "$dl2" "$pfx2" 200000 1000 2 >/dev/null
  expect "DLQ drained after second reap" "0" "$(engine_cli "$e" ZCARD "$dl2")"

  # --- Dangling DLQ member (Hash missing) is cleaned up ---
  q3="pq:{rd}"; pfx3="pq:{rd}:m:"; dl3="dlq:{rd}"
  engine_cli "$e" DEL "$q3" "$dl3" >/dev/null
  engine_cli "$e" ZADD "$dl3" 5 "$(printf '%020d:%s' 9 9)" >/dev/null   # member with no Hash
  out=$(fcall "$e" pq_reap 2 "$dl3" "$pfx3" 200000 1000 100)
  expect "dangling member cleaned from DLQ" "0" "$(engine_cli "$e" ZCARD "$dl3")"

  # --- Redrive clears DeadLetteredAt ---
  q4="pq:{rr}"; pfx4="pq:{rr}:m:"; dl4="dlq:{rr}"
  engine_cli "$e" DEL "$q4" "$dl4" "${pfx4}5" >/dev/null
  fcall "$e" pq_create 1 "${pfx4}5" Priority 5 Payload z DeadLetteredAt 100000 >/dev/null
  m5=$(printf '%020d:%s' 5 5)
  engine_cli "$e" ZADD "$dl4" 5 "$m5" >/dev/null
  fcall "$e" pq_redrive 3 "$dl4" "$q4" "${pfx4}5" "$m5" >/dev/null
  expect "redrive clears DeadLetteredAt to 0" "0" "$(engine_cli "$e" HGET "${pfx4}5" DeadLetteredAt)"
  expect "redriven message back in source" "5" "$(engine_cli "$e" ZSCORE "$q4" "$m5")"
done

finish
