#!/usr/bin/env bash
# [US3] Integration: visibility-timeout reclaim + fencing. An unsettled lease is
# skipped before the timeout and reclaimed after it; the original (stale) token can
# no longer ack/nack the reacquired message.
# Spec: FR-003/004/011, SC-006/007.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== dequeue visibility + fencing on: $e =="

  q="pq:{v1}"; pfx="pq:{v1}:m:"; member="$(printf '%020d:%s' 1 v)"
  engine_cli "$e" DEL "$q" "${pfx}v" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}v" v 1 Priority 5 Payload pv >/dev/null

  # Consumer A leases at now=1000, timeout=30000 (token = ReadAttempts = 1).
  d1=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "A acquires the message" "pv" "$d1"
  expect "A: ReadAttempts=1" "1"    "$(engine_cli "$e" HGET "${pfx}v" ReadAttempts)"
  expect "A: ReadDateTime=1000" "1000" "$(engine_cli "$e" HGET "${pfx}v" ReadDateTime)"

  # Before the timeout (now=5000, 5000-1000 < 30000): still leased, not returned.
  d2=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 5000 30000)
  expect "before timeout: not reclaimed (null)" "" "$d2"

  # At/after the timeout (now=31000, 31000-1000 = 30000 >= 30000): reclaimed by B.
  d3=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 31000 30000)
  expect_contains "after timeout: B reclaims the message" "pv" "$d3"
  expect "B: ReadAttempts incremented to 2" "2"     "$(engine_cli "$e" HGET "${pfx}v" ReadAttempts)"
  expect "B: ReadDateTime updated to 31000" "31000" "$(engine_cli "$e" HGET "${pfx}v" ReadDateTime)"

  # A's stale token (1) can no longer settle the reacquired message.
  out=$(fcall "$e" pq_ack 2 "$q" "${pfx}v" "$member" 1 2>&1 || true)
  expect_contains "stale ack rejected -> EFENCED" "EFENCED" "$out"
  out=$(fcall "$e" pq_nack 1 "${pfx}v" 1 2>&1 || true)
  expect_contains "stale nack rejected -> EFENCED" "EFENCED" "$out"
  # B's lease is untouched by the stale attempts.
  expect "message still present after stale settles" "1" "$(engine_cli "$e" EXISTS "${pfx}v")"
  expect "still in-flight (DirtyBit=1)" "1" "$(engine_cli "$e" HGET "${pfx}v" DirtyBit)"

  # B settles normally with the current token (2).
  out=$(fcall "$e" pq_ack 2 "$q" "${pfx}v" "$member" 2)
  expect "B ack with current token -> OK" "OK" "$out"
  expect "message removed after B ack" "0" "$(engine_cli "$e" EXISTS "${pfx}v")"
  expect "queue member removed after B ack" "0" "$(engine_cli "$e" ZCARD "$q")"
}

run_suite suite
