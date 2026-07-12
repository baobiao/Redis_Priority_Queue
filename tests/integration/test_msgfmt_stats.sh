#!/usr/bin/env bash
# [US2] Integration: msgfmt_stats. Exact depths + front Priority (cheap tier); a
# bounded breakdown classifies the scanned front as available / in-flight /
# delayed with a truncated flag; an approximate oldest-dead-letter age; and it
# mutates nothing. Spec: FR-008..011, SC-005/006.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== stats on: $e =="
  load_library "$e"

  q="pq:{st}"; pfx="pq:{st}:m:"; dl="dlq:{st}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}A" "${pfx}B" "${pfx}C" "${pfx}D" >/dev/null
  # A available (pri5), B available (pri10), C delayed (VisibleAt future), D will be leased.
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}A" A 1 Priority 5  Payload a >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}B" B 2 Priority 10 Payload b >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}C" C 3 Priority 10 Payload c VisibleAt 999999 >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}D" D 4 Priority 20 Payload d >/dev/null
  # Lease D by dequeuing at now=1000 (A is front; to lease D specifically, dequeue 3x?). Simpler:
  # dequeue once leases the front deliverable (A). That makes A in-flight; B available; C delayed; D available.
  fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null   # leases A (front, available)

  # --- Cheap tier: exact depths + front Priority ---
  out=$(fcall_ro "$e" msgfmt_stats 3 "$q" "$pfx" "$dl" 2000 30000)
  expect_contains "cheap: depth reported" "depth" "$out"
  expect_contains "cheap: queue depth = 4" "4" "$out"
  expect_contains "cheap: front_priority label" "front_priority" "$out"

  # --- Bounded breakdown: A in-flight, B available, C delayed, D available ---
  out=$(fcall_ro "$e" msgfmt_stats 3 "$q" "$pfx" "$dl" 2000 30000 100)
  expect_contains "breakdown: available label" "available" "$out"
  expect_contains "breakdown: in_flight label" "in_flight" "$out"
  expect_contains "breakdown: delayed label" "delayed" "$out"
  expect_contains "breakdown: truncated label" "truncated" "$out"
  # exact counts: available=2 (B,D), in_flight=1 (A), delayed=1 (C)
  case "$out" in *available*2*) echo "  ok   : available=2 (B,D)"; TESTS_RUN=$((TESTS_RUN+1)) ;; *) echo "  FAIL : available count"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)) ;; esac

  # --- No mutation: A still leased (DirtyBit=1), others untouched ---
  expect "stats did not mutate A (DirtyBit=1)" "1" "$(engine_cli "$e" HGET "${pfx}A" DirtyBit)"
  expect "stats did not mutate C VisibleAt" "999999" "$(engine_cli "$e" HGET "${pfx}C" VisibleAt)"

  # --- Truncated flag when depth > max_scan ---
  out=$(fcall_ro "$e" msgfmt_stats 3 "$q" "$pfx" "$dl" 2000 30000 2)
  case "$out" in *truncated*1*) echo "  ok   : truncated=1 when depth>max_scan"; TESTS_RUN=$((TESTS_RUN+1)) ;; *) echo "  FAIL : truncated flag"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)) ;; esac

  # --- Approximate oldest-dead-letter age from the scanned DLQ prefix ---
  engine_cli "$e" DEL "${pfx}X" >/dev/null
  fcall "$e" msgfmt_create 1 "${pfx}X" Priority 5 Payload x DeadLetteredAt 1000 >/dev/null
  engine_cli "$e" ZADD "$dl" 5 "$(printf '%020d:%s' 9 X)" >/dev/null
  out=$(fcall_ro "$e" msgfmt_stats 3 "$q" "$pfx" "$dl" 5000 30000 100)
  expect_contains "age: oldest_dead_letter_age label" "oldest_dead_letter_age" "$out"
  # age = now(5000) - DeadLetteredAt(1000) = 4000
  case "$out" in *oldest_dead_letter_age*4000*) echo "  ok   : oldest age = 4000"; TESTS_RUN=$((TESTS_RUN+1)) ;; *) echo "  FAIL : oldest age"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)) ;; esac

  # --- Empty queue: zero depths, front_priority -1 ---
  eq="pq:{se}"; epfx="pq:{se}:m:"
  engine_cli "$e" DEL "$eq" >/dev/null
  out=$(fcall_ro "$e" msgfmt_stats 2 "$eq" "$epfx" 1000 30000)
  expect_contains "empty queue: depth 0" "0" "$out"
  expect_contains "empty queue: front_priority -1" "-1" "$out"
done

finish
