#!/usr/bin/env bash
# [US1] Unit: VisibleAt field validation through create/validate/enqueue. A valid
# VisibleAt is accepted; a non-integer / negative / >2^53 value is rejected with
# PQ EINVAL: VisibleAt, writing nothing. Spec: FR-001/007.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

MAX=9007199254740992  # 2^53

for e in $ENGINES; do
  echo "== VisibleAt field validation on: $e =="
  load_library "$e"

  # Valid values accepted (validate is no-writes; create stores).
  for v in 0 1 1000 "$MAX"; do
    out=$(fcall_ro "$e" pq_validate 0 VisibleAt "$v")
    expect "validate accepts VisibleAt=$v" "VALID" "$out"
  done

  # Invalid values rejected with EINVAL: VisibleAt. Note 9007199254740994 = 2^53+2,
  # the next integer representable as a double above MAX_SAFE_INT (2^53+1 is not
  # representable and would round down to 2^53, which is in range).
  for bad in -1 1.5 abc 9007199254740994; do
    out=$(fcall_ro "$e" pq_validate 0 VisibleAt "$bad" 2>&1 || true)
    expect_contains "validate rejects VisibleAt=$bad" "EINVAL: VisibleAt" "$out"
  done

  # create rejects a bad VisibleAt and writes nothing.
  engine_cli "$e" DEL "q:{vf}:m:1" >/dev/null
  out=$(fcall "$e" pq_create 1 "q:{vf}:m:1" Priority 5 VisibleAt -5 2>&1 || true)
  expect_contains "create rejects bad VisibleAt" "EINVAL: VisibleAt" "$out"
  expect "nothing written on create failure" "0" "$(engine_cli "$e" EXISTS "q:{vf}:m:1")"

  # enqueue rejects a bad VisibleAt and writes neither the Hash nor the queue member.
  engine_cli "$e" DEL "pq:{vf}" "pq:{vf}:m:1" >/dev/null
  out=$(fcall "$e" pq_enqueue 2 "pq:{vf}" "pq:{vf}:m:1" 1 1 Priority 5 VisibleAt notanum 2>&1 || true)
  expect_contains "enqueue rejects bad VisibleAt" "EINVAL: VisibleAt" "$out"
  expect "no message Hash written" "0" "$(engine_cli "$e" EXISTS "pq:{vf}:m:1")"
  expect "no queue member written" "0" "$(engine_cli "$e" ZCARD "pq:{vf}")"

  # A valid VisibleAt is stored and read back.
  engine_cli "$e" DEL "q:{vf}:m:2" >/dev/null
  fcall "$e" pq_create 1 "q:{vf}:m:2" Priority 5 VisibleAt 12345 >/dev/null
  expect "valid VisibleAt stored" "12345" "$(engine_cli "$e" HGET "q:{vf}:m:2" VisibleAt)"
done

finish
