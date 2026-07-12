#!/usr/bin/env bash
# [US3] Unit: pq_redrive input validation + fail-before-write. Bad key count /
# empty member / tag mismatch, and a dangling or malformed message Hash -> the
# correct PQ E... results; nothing is written on any failure. Spec: FR-013..017.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== redrive validation on: $e =="
  load_library "$e"
  q="pq:{uv}"; pfx="pq:{uv}:m:"; dl="dlq:{uv}"
  engine_cli "$e" DEL "$q" "$dl" "${pfx}X" "${pfx}Y" >/dev/null

  # Bad key count.
  out=$(fcall "$e" pq_redrive 2 "$dl" "$q" "m" 2>&1 || true)
  expect_contains "2 keys -> EKEYS" "EKEYS" "$out"

  # Empty member.
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}X" "" 2>&1 || true)
  expect_contains "empty member -> EARGS" "EARGS" "$out"

  # Tag mismatch.
  out=$(fcall "$e" pq_redrive 3 "dlq:{uv}" "pq:{nope}" "pq:{uv}:m:X" "anything" 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Dangling DLQ member: present in the DLQ but its message Hash is missing.
  mX=$(printf '%020d:%s' 1 X)
  engine_cli "$e" ZADD "$dl" 5 "$mX" >/dev/null
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}X" "$mX" 2>&1 || true)
  expect_contains "dangling DLQ member -> EMALFORMED" "EMALFORMED" "$out"
  expect "no write: X still in the DLQ" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mX")"
  expect "no write: X not added to the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mX")"

  # Malformed message Hash: member in DLQ, Hash key holds a non-hash value.
  mY=$(printf '%020d:%s' 2 Y)
  engine_cli "$e" ZADD "$dl" 5 "$mY" >/dev/null
  engine_cli "$e" SET "${pfx}Y" "corrupt" >/dev/null
  out=$(fcall "$e" pq_redrive 3 "$dl" "$q" "${pfx}Y" "$mY" 2>&1 || true)
  expect_contains "non-hash message -> EMALFORMED" "EMALFORMED" "$out"
  expect "no write: Y still in the DLQ" "5" "$(engine_cli "$e" ZSCORE "$dl" "$mY")"
  expect "no write: Y not added to the source" "" "$(engine_cli "$e" ZSCORE "$q" "$mY")"
done

finish
