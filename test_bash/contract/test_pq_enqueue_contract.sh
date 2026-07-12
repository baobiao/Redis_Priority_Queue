#!/usr/bin/env bash
# [US1] Contract test for pq_enqueue (KEYS/ARGV/return shape/flags).
# Spec: specs/002-enqueue/spec.md  Contract: specs/002-enqueue/contracts/functions.md
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== pq_enqueue contract on: $e =="
  load_library "$e"
  engine_cli "$e" DEL "pq:{c1}" "pq:{c1}:m:1" >/dev/null

  # KEYS[1]=queue Sorted Set, KEYS[2]=message Hash; ARGV = id, sequence, then field pairs.
  out=$(fcall "$e" pq_enqueue 2 "pq:{c1}" "pq:{c1}:m:1" 1 1 Payload hello Priority 5)
  expect "enqueue returns OK" "OK" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" pq_enqueue 1 "pq:{c1}" 1 1 2>&1 || true)
  expect_contains "one key -> EKEYS" "EKEYS" "$out"

  # pq_enqueue is a write function: rejected under the read-only command.
  engine_cli "$e" DEL "pq:{c3}" "pq:{c3}:m:1" >/dev/null
  out=$(fcall_ro "$e" pq_enqueue 2 "pq:{c3}" "pq:{c3}:m:1" 1 1 2>&1 || true)
  expect_contains "enqueue rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
done

finish
