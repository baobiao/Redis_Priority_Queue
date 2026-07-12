#!/usr/bin/env bash
# [US2] Contract test for msgfmt_peek: KEYS/ARGV shape, single vs top-N return,
# no-writes (callable via FCALL_RO), and the EKEYS/ENOW/ETMO/ECOUNT/ETAG errors.
# Spec: FR-008..012; contracts/functions.md.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== peek contract on: $e =="
  load_library "$e"
  q="pq:{pc}"; pfx="pq:{pc}:m:"
  engine_cli "$e" DEL "$q" "${pfx}k" >/dev/null

  # Empty queue: single -> null.
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 30000)
  expect "empty single peek -> null" "" "$out"

  # Enqueue one, then peek (read-only) returns a record carrying id/member/Payload.
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}k" k 1 Payload hello Priority 5 >/dev/null
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 30000)
  expect_contains "single record carries id" "k" "$out"
  expect_contains "single record carries member" "$(printf '%020d:%s' 1 k)" "$out"
  expect_contains "single record carries Payload" "hello" "$out"
  expect_contains "single record carries DirtyBit label" "DirtyBit" "$out"

  # Top-N form is callable and returns the member.
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 30000 2)
  expect_contains "top-N returns the member" "hello" "$out"

  # Peek is no-writes: it also works under FCALL_RO (already used above) and did
  # not lease the message (still available at DirtyBit=0).
  expect "peek left the message unleased" "0" "$(engine_cli "$e" HGET "${pfx}k" DirtyBit)"

  # Error surface.
  out=$(fcall_ro "$e" msgfmt_peek 1 "$q" 1000 30000 2>&1 || true)
  expect_contains "wrong key count -> EKEYS" "EKEYS" "$out"
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" -1 30000 2>&1 || true)
  expect_contains "bad now -> ENOW" "ENOW" "$out"
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 0 2>&1 || true)
  expect_contains "bad timeout -> ETMO" "ETMO" "$out"
  out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 30000 0 2>&1 || true)
  expect_contains "bad count -> ECOUNT" "ECOUNT" "$out"
  out=$(fcall_ro "$e" msgfmt_peek 2 "pq:{pc}" "pq:{other}:m:" 1000 30000 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"
done

finish
