#!/usr/bin/env bash
# [US2] Integration: non-destructive peek. Single mode returns exactly what
# dequeue would lease next and mutates nothing; top-N returns the front members
# regardless of lease state with their lease fields; count>size returns all;
# empty/all-leased -> null/empty; dangling members are skipped (never removed);
# peek works on a DLQ-shaped queue. Spec: FR-008..012, SC-004/005.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

# Local negative assertion (shared harness has only expect / expect_contains).
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
  echo "== peek on: $e =="
  load_library "$e"

  q="pq:{pk}"; pfx="pq:{pk}:m:"
  engine_cli "$e" DEL "$q" "${pfx}A" "${pfx}B" "${pfx}C" >/dev/null
  # Front order by (priority, seq): B(pri5), A(pri10,seq1), C(pri10,seq3).
  fcall "$e" pq_enqueue 2 "$q" "${pfx}A" A 1 Priority 10 Payload PAY-A >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}B" B 2 Priority 5  Payload PAY-B >/dev/null
  fcall "$e" pq_enqueue 2 "$q" "${pfx}C" C 3 Priority 10 Payload PAY-C >/dev/null

  # --- Single mode: returns the front deliverable (B), mutating nothing ---
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 1000 30000)
  expect_contains "single peek returns front message B" "PAY-B" "$out"
  expect_absent   "single peek returns only one record (no A)" "PAY-A" "$out"
  expect "peek did not mutate B ReadAttempts" "0" "$(engine_cli "$e" HGET "${pfx}B" ReadAttempts)"
  expect "peek did not mutate B DirtyBit"     "0" "$(engine_cli "$e" HGET "${pfx}B" DirtyBit)"
  expect "peek did not mutate B ReadDateTime" "0" "$(engine_cli "$e" HGET "${pfx}B" ReadDateTime)"

  # --- Single peek == the message a subsequent dequeue leases ---
  deq=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "dequeue leases the same message peek showed (B)" "PAY-B" "$deq"
  expect "dequeue DID mutate B (now in-flight)" "1" "$(engine_cli "$e" HGET "${pfx}B" DirtyBit)"

  # --- Top-N mode: front N regardless of lease state (B now in-flight) ---
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 2000 30000 3)
  expect_contains "top-N includes B (in-flight)" "PAY-B" "$out"
  expect_contains "top-N includes A" "PAY-A" "$out"
  expect_contains "top-N includes C" "PAY-C" "$out"

  # --- count greater than queue size returns all, no error ---
  out=$(fcall_ro "$e" pq_peek 2 "$q" "$pfx" 2000 30000 100)
  expect_contains "count>size returns all (A)" "PAY-A" "$out"
  expect_contains "count>size returns all (C)" "PAY-C" "$out"

  # --- Empty queue: single -> null, top-N -> empty ---
  eq="pq:{pke}"; epfx="pq:{pke}:m:"
  engine_cli "$e" DEL "$eq" >/dev/null
  out=$(fcall_ro "$e" pq_peek 2 "$eq" "$epfx" 1000 30000)
  expect "empty queue single peek -> null" "" "$out"
  out=$(fcall_ro "$e" pq_peek 2 "$eq" "$epfx" 1000 30000 5)
  expect_absent "empty queue top-N peek -> no records" "member" "$out"

  # --- All-leased/unexpired: single peek -> null (nothing deliverable) ---
  lq="pq:{pkl}"; lpfx="pq:{pkl}:m:"
  engine_cli "$e" DEL "$lq" "${lpfx}Z" >/dev/null
  fcall "$e" pq_enqueue 2 "$lq" "${lpfx}Z" Z 1 Priority 5 Payload PAY-Z >/dev/null
  fcall "$e" pq_dequeue 2 "$lq" "$lpfx" 1000 30000 >/dev/null   # lease Z (unexpired)
  out=$(fcall_ro "$e" pq_peek 2 "$lq" "$lpfx" 1001 30000)
  expect "all-leased single peek -> null" "" "$out"

  # --- Dangling member is skipped and never removed (read-only) ---
  dq="pq:{pkd}"; dpfx="pq:{pkd}:m:"
  engine_cli "$e" DEL "$dq" "${dpfx}D" >/dev/null
  fcall "$e" pq_enqueue 2 "$dq" "${dpfx}D" D 1 Priority 5 Payload PAY-D >/dev/null
  mD=$(printf '%020d:%s' 1 D)
  engine_cli "$e" DEL "${dpfx}D" >/dev/null                        # Hash gone -> dangling member
  out=$(fcall_ro "$e" pq_peek 2 "$dq" "$dpfx" 1000 30000 5)
  expect_absent "top-N skips the dangling member" "PAY-D" "$out"
  expect "peek did NOT remove the dangling member" "5" "$(engine_cli "$e" ZSCORE "$dq" "$mD")"

  # --- Peek works on a DLQ-shaped queue (same shape as a source queue) ---
  dl="dlq:{pk2}"; dlpfx="dlq:{pk2}:m:"
  engine_cli "$e" DEL "$dl" "${dlpfx}W" >/dev/null
  fcall "$e" pq_enqueue 2 "$dl" "${dlpfx}W" W 1 Priority 9 Payload PAY-W >/dev/null
  out=$(fcall_ro "$e" pq_peek 2 "$dl" "$dlpfx" 1000 30000)
  expect_contains "peek inspects a DLQ-shaped queue" "PAY-W" "$out"
done

finish
