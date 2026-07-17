#!/usr/bin/env bash
# [US1] Contract test for pq_dequeue: KEYS/ARGV shape, handle vs null reply,
# EKEYS on wrong key count, and write-flag (rejected under FCALL_RO).
# Spec: FR-001/005/006/020; contracts/functions.md.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

suite() {
  local e="$1"
  echo "== dequeue contract on: $e =="
  engine_cli "$e" DEL "pq:{c1}" "pq:{c1}:m:x" >/dev/null

  # Empty queue -> null reply (empty output).
  out=$(fcall "$e" pq_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000)
  expect "empty queue returns null" "" "$out"

  # Enqueue one, then acquire -> the handle carries id/member/ReadAttempts/Payload.
  fcall "$e" pq_enqueue 2 "pq:{c1}" "pq:{c1}:m:x" x 1 Payload hello Priority 5 >/dev/null
  out=$(fcall "$e" pq_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000)
  expect_contains "handle carries id" "x" "$out"
  expect_contains "handle carries member" "$(printf '%020d:%s' 1 x)" "$out"
  expect_contains "handle carries ReadAttempts label" "ReadAttempts" "$out"
  expect_contains "handle carries Payload value" "hello" "$out"

  # Wrong key count -> EKEYS.
  out=$(fcall "$e" pq_dequeue 1 "pq:{c1}" 1000 30000 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"

  # Write function: must be rejected under FCALL_RO.
  out=$(fcall_ro "$e" pq_dequeue 2 "pq:{c1}" "pq:{c1}:m:" 1000 30000 2>&1 || true)
  expect_contains "dequeue rejected via FCALL_RO" "Can not execute a script with write flag using *_ro command" "$out"

  # --- Feature 004 dead-letter mode: optional KEYS[3]=DLQ + trailing cap ARGV ---
  engine_cli "$e" DEL "pq:{c1}" "pq:{c1}:m:x" "dlq:{c1}" >/dev/null
  fcall "$e" pq_enqueue 2 "pq:{c1}" "pq:{c1}:m:x" x 1 Payload hello Priority 5 >/dev/null

  # 3-key call with a valid cap: below-cap message is leased and returned as usual.
  out=$(fcall "$e" pq_dequeue 3 "pq:{c1}" "pq:{c1}:m:" "dlq:{c1}" 1000 30000 0 5)
  expect_contains "3-key dead-letter call still returns a handle" "hello" "$out"

  # Too many keys -> EKEYS.
  out=$(fcall "$e" pq_dequeue 4 "pq:{c1}" "pq:{c1}:m:" "dlq:{c1}" "x:{c1}" 1000 30000 2>&1 || true)
  expect_contains "four keys -> EKEYS" "EKEYS" "$out"

  # Dead-letter mode with a missing/invalid cap -> ECAP.
  out=$(fcall "$e" pq_dequeue 3 "pq:{c1}" "pq:{c1}:m:" "dlq:{c1}" 1000 30000 2>&1 || true)
  expect_contains "missing cap -> ECAP" "ECAP" "$out"
  out=$(fcall "$e" pq_dequeue 3 "pq:{c1}" "pq:{c1}:m:" "dlq:{c1}" 1000 30000 0 0 2>&1 || true)
  expect_contains "cap<1 -> ECAP" "ECAP" "$out"

  # DLQ key not sharing the source hash tag -> ETAG.
  out=$(fcall "$e" pq_dequeue 3 "pq:{c1}" "pq:{c1}:m:" "dlq:{other}" 1000 30000 0 5 2>&1 || true)
  expect_contains "DLQ tag mismatch -> ETAG" "ETAG" "$out"

  # DLQ key holding a non-sorted-set value -> EMALFORMED.
  engine_cli "$e" DEL "dlq:{c1}" >/dev/null
  engine_cli "$e" SET "dlq:{c1}" "not-a-zset" >/dev/null
  out=$(fcall "$e" pq_dequeue 3 "pq:{c1}" "pq:{c1}:m:" "dlq:{c1}" 1000 30000 0 5 2>&1 || true)
  expect_contains "non-zset DLQ -> EMALFORMED" "EMALFORMED" "$out"
  engine_cli "$e" DEL "dlq:{c1}" >/dev/null
}

run_suite suite
