#!/usr/bin/env bash
# [US1] Contract test for msgfmt_dequeue: KEYS/ARGV shape, handle vs null reply,
# EKEYS on wrong key count, and write-flag (rejected under FCALL_RO).
# Spec: FR-001/005/006/020; contracts/functions.md.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dequeue contract on: $e =="
  load_library "$e"
  engine_cli "$e" DEL "pq:{c1}" "pq:{c1}:m:x" >/dev/null

  # Empty queue -> null reply (empty output).
  out=$(fcall "$e" msgfmt_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000)
  expect "empty queue returns null" "" "$out"

  # Enqueue one, then acquire -> the handle carries id/member/ReadAttempts/Payload.
  fcall "$e" msgfmt_enqueue 2 "pq:{c1}" "pq:{c1}:m:x" x 1 Payload hello Priority 5 >/dev/null
  out=$(fcall "$e" msgfmt_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000)
  expect_contains "handle carries id" "x" "$out"
  expect_contains "handle carries member" "$(printf '%020d:%s' 1 x)" "$out"
  expect_contains "handle carries ReadAttempts label" "ReadAttempts" "$out"
  expect_contains "handle carries Payload value" "hello" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" msgfmt_dequeue 1 "pq:{c1}" 1000 30000 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"

  # Write function: must be rejected under FCALL_RO.
  out=$(fcall_ro "$e" msgfmt_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000 2>&1 || true)
  expect_contains "dequeue rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"
done

finish
