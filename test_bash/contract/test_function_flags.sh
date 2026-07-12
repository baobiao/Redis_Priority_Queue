#!/usr/bin/env bash
# [Polish T016] Verify pq_read/pq_validate carry the no-writes flag and
# that the writer pq_create cannot be called via FCALL_RO. Principle VII.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== function flags on: $e =="
  load_library "$e"

  listing=$(engine_cli "$e" FUNCTION LIST WITHCODE 2>/dev/null || engine_cli "$e" FUNCTION LIST)
  expect_contains "library registered" "priority_queue" "$listing"
  expect_contains "no-writes flag present" "no-writes" "$listing"

  # Writer must be rejected under FCALL_RO (it has no no-writes flag).
  out=$(fcall_ro "$e" pq_create 1 "q:{flag}" 2>&1 || true)
  expect_contains "create rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # pq_enqueue is also a write and must be rejected under FCALL_RO (Feature 002).
  out=$(fcall_ro "$e" pq_enqueue 2 "pq:{flag}" "pq:{flag}:m:1" 1 1 2>&1 || true)
  expect_contains "enqueue rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # pq_dequeue / pq_ack / pq_nack are writes and must be rejected under FCALL_RO (Feature 003).
  out=$(fcall_ro "$e" pq_dequeue 2 "pq:{flag}" "pq:{flag}:m:" 1000 30000 2>&1 || true)
  expect_contains "dequeue rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
  out=$(fcall_ro "$e" pq_ack 2 "pq:{flag}" "pq:{flag}:m:1" "00000000000000000001:1" 1 2>&1 || true)
  expect_contains "ack rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
  out=$(fcall_ro "$e" pq_nack 1 "pq:{flag}:m:1" 1 2>&1 || true)
  expect_contains "nack rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # pq_redrive is a write and must be rejected under FCALL_RO (Feature 004).
  out=$(fcall_ro "$e" pq_redrive 3 "dlq:{flag}" "pq:{flag}" "pq:{flag}:m:1" "00000000000000000001:1" 2>&1 || true)
  expect_contains "redrive rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # pq_peek is registered no-writes and IS callable via FCALL_RO (Feature 004).
  engine_cli "$e" DEL "pq:{flag}" >/dev/null
  out=$(fcall_ro "$e" pq_peek 2 "pq:{flag}" "pq:{flag}:m:" 1000 30000 2>&1 || true)
  expect "peek callable via FCALL_RO (empty -> null)" "" "$out"

  # Reader works under the read-only command.
  engine_cli "$e" DEL "q:{flag}" >/dev/null
  fcall "$e" pq_create 1 "q:{flag}" >/dev/null
  out=$(fcall_ro "$e" pq_read 1 "q:{flag}")
  expect_contains "read works via FCALL_RO" "Priority" "$out"
done

finish
