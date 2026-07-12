#!/usr/bin/env bash
# [US1] Integration: concurrent consumers never receive the same message. A
# leased (un-expired) message is skipped; two acquires return distinct messages.
# Spec: FR-003, SC-003.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dequeue concurrency on: $e =="
  load_library "$e"

  q="pq:{n1}"; pfx="pq:{n1}:m:"
  engine_cli "$e" DEL "$q" "${pfx}m1" "${pfx}m2" >/dev/null

  # Single available message: first acquire gets it, second finds nothing (leased).
  fcall "$e" pq_enqueue 2 "$q" "${pfx}m1" m1 1 Priority 5 Payload p1 >/dev/null
  d1=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "consumer 1 gets the only message" "p1" "$d1"
  d2=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect "consumer 2 gets null (message leased, not expired)" "" "$d2"

  # Add a second message: consumer 2 now gets the new one, not the leased m1.
  fcall "$e" pq_enqueue 2 "$q" "${pfx}m2" m2 2 Priority 5 Payload p2 >/dev/null
  d3=$(fcall "$e" pq_dequeue 2 "$q" "$pfx" 1000 30000)
  expect_contains "consumer 2 gets the distinct second message" "p2" "$d3"
  case "$d3" in
    *p1*) TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1));
          echo "  FAIL : second consumer must not re-receive the leased message" ;;
    *)    TESTS_RUN=$((TESTS_RUN + 1)); echo "  ok   : leased message not re-delivered concurrently" ;;
  esac
done

finish
