#!/usr/bin/env bash
# [US3] Integration: VisibleAt composition. read exposes VisibleAt; a pre-005
# 5-field message reads/dequeues as VisibleAt=0 (no error); peek single skips a
# not-yet-visible front message while top-N reports it with VisibleAt; a
# not-yet-visible over-cap message is dead-lettered only once visible; redrive
# resets VisibleAt to 0. Spec: FR-005/006/011/012/013, SC-003/006/007/008.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

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
  echo "== visibility composition on: $e =="
  load_library "$e"

  # --- read exposes VisibleAt ---
  engine_cli "$e" DEL "q:{cm}:m:1" >/dev/null
  fcall "$e" pq_create 1 "q:{cm}:m:1" Priority 5 Payload hi VisibleAt 90000 >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{cm}:m:1")
  expect_contains "read includes VisibleAt label" "VisibleAt" "$out"
  expect_contains "read includes VisibleAt value" "90000" "$out"

  # --- Back-compat: a message stored with only the 5 original fields ---
  q="pq:{bc}"; pfx="pq:{bc}:m:"
  engine_cli "$e" DEL "$q" "${pfx}old" >/dev/null
  engine_cli "$e" HSET "${pfx}old" ReadAttempts 0 DirtyBit 0 ReadDateTime 0 Priority 5 Payload OLD >/dev/null
  mold=$(printf '%020d:%s' 1 old)
  engine_cli "$e" ZADD "$q" 5 "$mold" >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "${pfx}old")
  expect_contains "legacy 5-field message reads without error (Payload)" "OLD" "$out"
  expect_contains "legacy message reports VisibleAt=0" "VisibleAt" "$out"
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1 30000)
  expect_contains "legacy message is immediately visible (dequeued)" "OLD" "$out"

  # --- Peek: single skips not-yet-visible; top-N reports it with VisibleAt ---
  q="pq:{pv}"; pfx="pq:{pv}:m:"
  engine_cli "$e" DEL "$q" "${pfx}F" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}F" F 1 Priority 5 Payload PAY-F VisibleAt 8000 >/dev/null
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 7999 30000)
  expect "single peek skips not-yet-visible -> null" "" "$out"
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 7999 30000 10)
  expect_contains "top-N reports the not-yet-visible member" "PAY-F" "$out"
  expect_contains "top-N record carries VisibleAt" "8000" "$out"
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 8000 30000)
  expect_contains "single peek returns it once visible" "PAY-F" "$out"

  # --- Dead-letter deferred until visible ---
  q="pq:{dv}"; pfx="pq:{dv}:m:"; dl="dlq:{dv}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}M" >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}M" M 1 Priority 5 Payload PAY-M >/dev/null
  mM=$(printf '%020d:%s' 1 M)
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 1000 30000 0 1 >/dev/null   # RA 0<1 -> leased, RA=1
  fcall "$e" pq_nack 1 "${pfx}M" 1 5000 >/dev/null                     # RA=1(=cap), hidden until 5000
  out=$(fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 4999 30000 0 1)
  expect "over-cap but not-yet-visible -> null (not dead-lettered)" "" "$out"
  expect "M NOT dead-lettered while hidden" "" "$(engine_cli "$e" ZSCORE "$dl" "$mM")"
  expect "M still in the source while hidden" "5" "$(engine_cli "$e" ZSCORE "$q" "$mM")"
  fcall "$e" pq_dequeue 3 "$q" "$pfx" "$dl" 5000 30000 0 1 >/dev/null   # now visible + over cap -> DLQ
  expect "M dead-lettered once visible" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mM")"
  expect "M removed from the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mM")"

  # --- Redrive resets VisibleAt to 0 ---
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}M" "$mM")
  expect "redrive returns OK" "OK" "$out"
  expect "redrive reset VisibleAt to 0" "0" "$(engine_cli "$e" HGET "${pfx}M" VisibleAt)"
  out=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1 30000)
  expect_contains "redriven message is immediately deliverable" "PAY-M" "$out"
done

finish
