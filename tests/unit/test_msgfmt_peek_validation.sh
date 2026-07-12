#!/usr/bin/env bash
# [US2] Unit: msgfmt_peek input validation and read-only malformed handling.
# Invalid now/timeout/count, tag mismatch, non-zset queue -> structured errors;
# a malformed message Hash errors in single mode but is skipped in top-N mode;
# nothing is ever written (peek is no-writes). Spec: FR-008..012.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harness/load_and_call.sh"

expect_absent() { # <label> <needle> <haystack>
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$3" in
    *"$2"*) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL : $1 -- [$3] unexpectedly contains [$2]" ;;
    *)      echo "  ok   : $1" ;;
  esac
}

ENGINES="${ENGINES:-redis valkey}"
up >/dev/null

for e in $ENGINES; do
  echo "== peek validation on: $e =="
  load_library "$e"
  q="pq:{pv}"; pfx="pq:{pv}:m:"
  engine_cli "$e" DEL "$q" "${pfx}a" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$q" "${pfx}a" a 1 Priority 5 Payload hi >/dev/null

  # now / timeout / count validation.
  for bad in "-1" "1.5" "abc"; do
    out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" "$bad" 30000 2>&1 || true)
    expect_contains "now=$bad -> ENOW" "ENOW" "$out"
  done
  for bad in "0" "-5" "x"; do
    out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 "$bad" 2>&1 || true)
    expect_contains "timeout=$bad -> ETMO" "ETMO" "$out"
  done
  for bad in "0" "-2" "1.5" "nope"; do
    out=$(fcall_ro "$e" msgfmt_peek 2 "$q" "$pfx" 1000 30000 "$bad" 2>&1 || true)
    expect_contains "count=$bad -> ECOUNT" "ECOUNT" "$out"
  done

  # Hash-tag mismatch.
  out=$(fcall_ro "$e" msgfmt_peek 2 "pq:{pv}" "pq:{nope}:m:" 1000 30000 2>&1 || true)
  expect_contains "tag mismatch -> ETAG" "ETAG" "$out"

  # Non-zset queue key.
  engine_cli "$e" DEL "str:{pv}" >/dev/null
  engine_cli "$e" SET "str:{pv}" "not-a-zset" >/dev/null
  out=$(fcall_ro "$e" msgfmt_peek 2 "str:{pv}" "str:{pv}:m:" 1000 30000 2>&1 || true)
  expect_contains "non-zset queue -> EMALFORMED" "EMALFORMED" "$out"

  # Malformed message Hash: single mode -> EMALFORMED; top-N -> skipped.
  mq="pq:{pvm}"; mpfx="pq:{pvm}:m:"
  engine_cli "$e" DEL "$mq" "${mpfx}bad" >/dev/null
  fcall "$e" msgfmt_enqueue 2 "$mq" "${mpfx}bad" bad 1 Priority 5 Payload x >/dev/null
  engine_cli "$e" DEL "${mpfx}bad" >/dev/null
  engine_cli "$e" SET "${mpfx}bad" "corrupt" >/dev/null      # member present, Hash is a string
  out=$(fcall_ro "$e" msgfmt_peek 2 "$mq" "$mpfx" 1000 30000 2>&1 || true)
  expect_contains "single-mode malformed candidate -> EMALFORMED" "EMALFORMED" "$out"
  out=$(fcall_ro "$e" msgfmt_peek 2 "$mq" "$mpfx" 1000 30000 5 2>&1 || true)
  expect_absent "top-N skips the malformed member (no error record)" "member" "$out"

  # No writes happened anywhere: the read-only queue member is still present.
  expect "peek wrote nothing (member intact)" "5" "$(engine_cli "$e" ZSCORE "$q" "$(printf '%020d:%s' 1 a)")"
done

finish
