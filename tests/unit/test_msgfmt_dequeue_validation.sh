#!/usr/bin/env bash
# [US4] Unit: input/precondition rejection for dequeue/ack/nack, and the
# fail-before-write guarantee. Runs standalone (ETAG is enforced by the function
# itself, independent of cluster slot checks).
# Spec: FR-008/011/012/016/017, SC-008.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== dequeue/ack/nack validation on: $e =="
  load_library "$e"

  q="pq:{u1}"; pfx="pq:{u1}:m:"
  engine_cli "$e" DEL "$q" "${pfx}y" "${pfx}z" >/dev/null

  # ----- msgfmt_dequeue input validation -----
  out=$(fcall "$e" msgfmt_dequeue 1 "$q" 1000 30000 2>&1 || true)
  expect_contains "dequeue wrong key count -> EKEYS" "EKEYS" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" -1 30000 2>&1 || true)
  expect_contains "negative now -> ENOW" "ENOW" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" abc 30000 2>&1 || true)
  expect_contains "non-numeric now -> ENOW" "ENOW" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 0 2>&1 || true)
  expect_contains "zero timeout -> ETMO" "ETMO" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 1.5 2>&1 || true)
  expect_contains "non-integer timeout -> ETMO" "ETMO" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 -1 2>&1 || true)
  expect_contains "negative max_scan -> ESCAN" "ESCAN" "$out"
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "pq:{u2}:m:" 1000 30000 2>&1 || true)
  expect_contains "prefix tag mismatch -> ETAG" "ETAG" "$out"

  # Non-sorted-set queue -> EMALFORMED (fail-before-write).
  engine_cli "$e" DEL "$q" >/dev/null
  engine_cli "$e" SET "$q" notazset >/dev/null
  out=$(fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 2>&1 || true)
  expect_contains "non-zset queue -> EMALFORMED" "EMALFORMED" "$out"
  engine_cli "$e" DEL "$q" >/dev/null

  # ----- Set up one enqueued (available) message y for settle checks -----
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}y" y 1 Priority 5 Payload py >/dev/null
  ymember="$(printf '%020d:%s' 1 y)"

  # ack on a not-in-flight message -> ENOTLEASED (nothing changes).
  out=$(fcall "$e" msgfmt_ack 2 "$q" "${pfx}y" "$ymember" 1 2>&1 || true)
  expect_contains "ack non-leased -> ENOTLEASED" "ENOTLEASED" "$out"
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}y" 1 2>&1 || true)
  expect_contains "nack non-leased -> ENOTLEASED" "ENOTLEASED" "$out"

  # ack/nack arg validation.
  out=$(fcall "$e" msgfmt_ack 1 "$q" "$ymember" 1 2>&1 || true)
  expect_contains "ack wrong key count -> EKEYS" "EKEYS" "$out"
  out=$(fcall "$e" msgfmt_ack 2 "$q" "${pfx}y" "" 1 2>&1 || true)
  expect_contains "ack empty member -> EARGS" "EARGS" "$out"
  out=$(fcall "$e" msgfmt_nack 2 "${pfx}y" "$q" 1 2>&1 || true)
  expect_contains "nack wrong key count -> EKEYS" "EKEYS" "$out"
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}y" abc 2>&1 || true)
  expect_contains "nack non-integer token -> EARGS" "EARGS" "$out"

  # Lease y, then a wrong token is fenced.
  fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null
  out=$(fcall "$e" msgfmt_ack 2 "$q" "${pfx}y" "$ymember" 999 2>&1 || true)
  expect_contains "ack wrong token -> EFENCED" "EFENCED" "$out"
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}y" 999 2>&1 || true)
  expect_contains "nack wrong token -> EFENCED" "EFENCED" "$out"

  # Settling an absent message -> idempotent NOOP.
  expect "ack absent -> NOOP" "NOOP" "$(fcall "$e" msgfmt_ack 2 "$q" "${pfx}absent" "$(printf '%020d:%s' 9 absent)" 1)"
  expect "nack absent -> NOOP" "NOOP" "$(fcall "$e" msgfmt_nack 1 "${pfx}absent" 1)"

  # Fail-before-write: y is still leased and unchanged, queue still holds 1 member.
  expect "y still in-flight (DirtyBit=1)" "1" "$(engine_cli "$e" HGET "${pfx}y" DirtyBit)"
  expect "y ReadAttempts unchanged (1)"   "1" "$(engine_cli "$e" HGET "${pfx}y" ReadAttempts)"
  expect "queue still has 1 member"       "1" "$(engine_cli "$e" ZCARD "$q")"
done

finish
