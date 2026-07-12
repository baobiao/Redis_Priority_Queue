#!/usr/bin/env bash
# [US2] Unit: nack's optional VisibleAt argument validation. An invalid ARGV[2]
# (non-integer / negative / >2^53) is rejected with MSGFMT EVIS and writes nothing
# (fail-before-write); a valid one is applied. Spec: FR-008/010.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== nack VisibleAt validation on: $e =="
  load_library "$e"

  q="pq:{nv}"; pfx="pq:{nv}:m:"
  engine_cli "$e" DEL "$q" "${pfx}1" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}1" 1 1 Priority 5 Payload w >/dev/null
  fcall "$e" msgfmt_dequeue 2 "$q" "$pfx" 1000 30000 >/dev/null   # lease (token=1, DirtyBit=1)

  # Invalid VisibleAt at nack -> EVIS, and the lease is untouched (still in-flight, VisibleAt still 0).
  # 9007199254740994 = 2^53+2 (the next representable integer above MAX_SAFE_INT; 2^53+1 is not
  # representable as a double and rounds down to 2^53, which is in range).
  for bad in -1 1.5 abc 9007199254740994; do
    out=$(fcall "$e" msgfmt_nack 1 "${pfx}1" 1 "$bad" 2>&1 || true)
    expect_contains "nack VisibleAt=$bad -> EVIS" "EVIS" "$out"
  done
  expect "no write on EVIS: still in-flight (DirtyBit=1)" "1" "$(engine_cli "$e" HGET "${pfx}1" DirtyBit)"
  expect "no write on EVIS: VisibleAt unchanged (0)"      "0" "$(engine_cli "$e" HGET "${pfx}1" VisibleAt)"

  # A valid VisibleAt is applied (released + hidden).
  out=$(fcall "$e" msgfmt_nack 1 "${pfx}1" 1 7000)
  expect "valid nack-with-delay returns OK" "OK" "$out"
  expect "DirtyBit cleared to 0" "0" "$(engine_cli "$e" HGET "${pfx}1" DirtyBit)"
  expect "VisibleAt applied (7000)" "7000" "$(engine_cli "$e" HGET "${pfx}1" VisibleAt)"
done

finish
