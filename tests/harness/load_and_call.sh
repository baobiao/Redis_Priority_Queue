#!/usr/bin/env bash
#
# Load-and-assert helper for the `message_format` library.
# Spec: specs/001-message-format/spec.md
#
# Sourced by the contract/integration/unit test scripts. Provides:
#   load_library <engine>          - FUNCTION LOAD REPLACE the library
#   fcall <engine> <args...>       - FCALL passthrough
#   fcall_ro <engine> <args...>    - FCALL_RO passthrough
#   expect <label> <expected> <actual>
#   expect_contains <label> <needle> <haystack>
#   finish                          - print summary, exit non-zero on failures

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HARNESS_DIR/docker_engines.sh"

LIB_PATH="${LIB_PATH:-$HARNESS_DIR/../../src/functions/message_format.lua}"

TESTS_RUN=0
TESTS_FAIL=0

load_library() {
  local engine="$1" name
  name="$(engine_name "$engine")"
  docker exec -i "$name" sh -lc \
    'if command -v redis-cli >/dev/null 2>&1; then redis-cli -x FUNCTION LOAD REPLACE; else valkey-cli -x FUNCTION LOAD REPLACE; fi' \
    < "$LIB_PATH" >/dev/null
}

fcall()    { local e="$1"; shift; engine_cli "$e" FCALL "$@"; }
fcall_ro() { local e="$1"; shift; engine_cli "$e" FCALL_RO "$@"; }

expect() { # <label> <expected> <actual>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok   : $1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "  FAIL : $1 -- expected [$2] got [$3]"
  fi
}

expect_contains() { # <label> <needle> <haystack>
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$3" in
    *"$2"*) echo "  ok   : $1" ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "  FAIL : $1 -- [$3] does not contain [$2]" ;;
  esac
}

finish() {
  echo "[$TESTS_RUN assertions, $TESTS_FAIL failed]"
  [ "$TESTS_FAIL" -eq 0 ]
}
