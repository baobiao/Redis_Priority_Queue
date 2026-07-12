#!/usr/bin/env bash
#
# Convenience runner for the whole priority_queue test suite (Features 001 + 002).
# Not part of any feature's function library — a dev-workflow helper alongside the
# harness (docker_engines.sh, load_and_call.sh, static_checks.sh).
#
# Usage:
#   test_bash/run_all.sh                 # all suites on redis + valkey (standalone)
#   ENGINES=redis test_bash/run_all.sh   # single engine
#   test_bash/run_all.sh --no-static     # skip the static portability gate
#
# Brings the engines up once (idempotent; each suite also calls `up`), runs every
# contract/integration/unit suite, then the static gate. Exits non-zero if anything
# fails. Cluster mode is verified separately (see docker_engines.sh cluster-up).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE"
RUN_STATIC=1
[ "${1:-}" = "--no-static" ] && RUN_STATIC=0

export ENGINES="${ENGINES:-redis valkey}"

echo "== bringing up engines: $ENGINES =="
"$HERE/harness/docker_engines.sh" up >/dev/null

suites=$(find "$TESTS_DIR/contract" "$TESTS_DIR/integration" "$TESTS_DIR/unit" \
           -maxdepth 1 -name '*.sh' 2>/dev/null | sort)

total=0; failed=0; suites_failed=0
for t in $suites; do
  out=$(bash "$t" 2>&1); rc=$?
  summary=$(printf '%s\n' "$out" | grep -E '^\[' | tail -1)
  a=$(printf '%s' "$summary" | grep -Eo '[0-9]+ assertions' | grep -Eo '^[0-9]+'); a=${a:-0}
  f=$(printf '%s' "$summary" | grep -Eo '[0-9]+ failed'     | grep -Eo '^[0-9]+'); f=${f:-0}
  total=$((total + a)); failed=$((failed + f))
  if [ "$rc" -ne 0 ] || [ "$f" -ne 0 ]; then
    suites_failed=$((suites_failed + 1))
    printf 'FAIL  %-42s %s\n' "$(basename "$t")" "$summary"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/      /'
  else
    printf 'ok    %-42s %s\n' "$(basename "$t")" "$summary"
  fi
done

if [ "$RUN_STATIC" -eq 1 ]; then
  if bash "$HERE/harness/static_checks.sh" >/dev/null 2>&1; then
    printf 'ok    %-42s\n' "static_checks.sh"
  else
    printf 'FAIL  %-42s\n' "static_checks.sh"; suites_failed=$((suites_failed + 1))
    bash "$HERE/harness/static_checks.sh" || true
  fi
fi

echo "------------------------------------------------------------"
echo "TOTAL: $total assertions, $failed failed across ${ENGINES// /+}; $suites_failed suite(s) failed"
[ "$suites_failed" -eq 0 ] && [ "$failed" -eq 0 ]
