#!/usr/bin/env bash
# [US2] Integration: retry backoff via nack with a future VisibleAt. A nacked
# message with a delay is not redelivered until now >= VisibleAt, then redelivered
# with ReadAttempts retained across the delay; a plain nack is unchanged (Feature
# 003 parity); fencing intact. Spec: FR-008/009, SC-004.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== retry backoff on: $e =="
  load_library "$e"

  q="pq:{bo}"; pfx="pq:{bo}:m:"
  engine_cli "$e" DEL "$q" "${pfx}1" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}1" 1 1 Priority 5 Payload work >/dev/null

  # Lease at now=1000 (ReadAttempts=1), then nack with a backoff to VisibleAt=5000.
  fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}1" 1 5000)
  expect "nack-with-delay returns OK" "OK" "$out"
  expect "released: DirtyBit=0"        "0"    "$(engine_cli "$e" HGET "${pfx}1" DirtyBit)"
  expect "VisibleAt set to 5000"       "5000" "$(engine_cli "$e" HGET "${pfx}1" VisibleAt)"
  expect "ReadAttempts retained (1)"   "1"    "$(engine_cli "$e" HGET "${pfx}1" ReadAttempts)"
  expect "ReadDateTime retained (1000)" "1000" "$(engine_cli "$e" HGET "${pfx}1" ReadDateTime)"

  # Before the backoff elapses -> not redelivered.
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 4999 30000)
  expect "not redelivered before VisibleAt -> null" "" "$out"

  # At/after the backoff -> redelivered, ReadAttempts incremented from the retained value.
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 5000 30000)
  expect_contains "redelivered at VisibleAt" "work" "$out"
  expect "ReadAttempts incremented to 2" "2" "$(engine_cli "$e" HGET "${pfx}1" ReadAttempts)"

  # A plain nack (no VisibleAt) is unchanged from Feature 003: immediately available.
  q="pq:{bp}"; pfx="pq:{bp}:m:"
  engine_cli "$e" DEL "$q" "${pfx}2" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}2" 2 1 Priority 5 Payload w2 >/dev/null
  fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null
  fcall "$e" msgfmt_nack 1 "${pfx}2" 1 >/dev/null           # no delay
  expect "plain nack leaves VisibleAt at default 0" "0" "$(engine_cli "$e" HGET "${pfx}2" VisibleAt)"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1001 30000)
  expect_contains "plain-nacked message immediately available (F003 parity)" "w2" "$out"

  # Fencing still applies to a nack-with-delay: a stale token is rejected.
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}2" 999 5000 2>&1 || true)
  expect_contains "stale token rejected (EFENCED) even with a delay" "EFENCED" "$out"
done

finish
