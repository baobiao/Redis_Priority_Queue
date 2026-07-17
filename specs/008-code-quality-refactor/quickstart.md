# Quickstart: verifying the code-quality refactor

**No queue behaviour changes.** This shows how to prove the refactor is safe and meets all three goals.
The three suites are the regression guard; the timing step is the FR-013 performance gate.

## Prerequisites (unchanged from Feature 007)

- Docker (`redis:7.4`, `valkey/valkey:8.0` — pulled on first run)
- JDK 25 + Maven (for `test_java/`), Python 3.11+ (for `test_python/`)
- Pins + host ports from repo-root `engines.env` (all env-overridable)

## 1. Bring engines up (once)

```bash
test_bash/harness/docker_engines.sh up          # standalone redis + valkey (published ports)
test_bash/harness/docker_engines.sh cluster-up  # single-shard all-slots cluster per engine
```

## 2. Regression guard — the three suites at frozen totals (SC-001/002)

```bash
# Bash reference suite — expect the SAME baseline: 832 assertions, 0 failed
test_bash/run_all.sh

# Java — expect 268 run, 10 skipped, 0 failed (both engines, standalone + cluster)
( cd test_java && mvn test )

# Python — expect 258 passed, 10 skipped, 0 failed (both engines, standalone + cluster)
( cd test_python && . .venv/bin/activate && pytest -q )
```

Any change to an expected value, a `PQ` error detail string, or a per-suite total is a **behaviour
change** and fails the guard. Bash cluster remains a manual smoke; automated cluster parity is the
Java/Python suites (as in Feature 007).

## 3. Static portability/determinism gate (SC-006)

```bash
test_bash/harness/static_checks.sh   # no violations; LIB still src/functions/priority_queue.lua
```

Confirms statically: no restricted commands (Principle V), no hardcoded literal keys (Principle IV — the
computed `KEYS[n] .. id` form is sanctioned), determinism (no `TIME`/`math.random`, Principle VII), no
`require` / empty runtime dependency set (Principle II), and the command whitelist. The
`no-writes`/`FCALL_RO` guarantee is verified at **runtime** (via `FUNCTION LIST` flags and the suites),
not by this static gate.

## 4. Performance gate — measured, no-regression (SC-004, FR-013)

Compare the merged Feature 007 library against the refactored one on the **same host + engine**, using
only the existing clients (no new tooling). Median over **N ≥ 1000** timed iterations of the hot-path
workload after **≥ 100** warm-up iterations; **gate = refactored p50 ≤ baseline p50 × 1.05** per engine
(the 5% band is env-overridable), with an improvement expected.

```bash
# Sketch (the measurement script lives with the harness and reuses redis-cli/the suite clients):
#   1. git show HEAD:src/functions/priority_queue.lua > /tmp/pq_baseline.lua   # F007 baseline
#   2. FUNCTION LOAD each library; run the fixed enqueue→dequeue→ack (+read/peek/stats/nack) workload
#   3. discard warm-up, take p50/p90 for baseline vs refactored on redis and valkey
#   4. assert refactored_p50 <= baseline_p50 * 1.05  (no regression); report the delta
```

Also confirm statically that hot globals are localised and per-function `redis.call` counts did not rise:

```bash
grep -cE 'redis\.(call|error_reply|status_reply)' src/functions/priority_queue.lua   # references
grep -nE '^local +[A-Za-z_]+ *= *(redis|tonumber|tostring|string|table)' \
  src/functions/priority_queue.lua                                                   # localisations present
```

## 5. Dead-code review (SC-003)

No linter (Q3). Grep-assisted manual review — every symbol must have a second reference; every branch
reachable; framework symbols retained:

```bash
# Example: a local defined but never re-read is a candidate for removal (review each hit).
# (Repeat per file; retain pytest fixtures, JUnit lifecycle/@ParameterizedTest sources, Bash entrypoints.)
grep -nE '^\s*local\s+[A-Za-z_]+' src/functions/priority_queue.lua
```

## 6. Documentation currency (SC-007)

Re-verify `README.md`, `docs/schema.md`, `docs/functions.md` still match the library. For a
behaviour-preserving refactor they should need **no** change; update only a genuinely drifted detail.

## 7. Tear down

```bash
test_bash/harness/docker_engines.sh cluster-down
test_bash/harness/docker_engines.sh down
```

## Definition of done

All of: §2 three suites green at frozen totals (redis+valkey, standalone+cluster) · §3 static gate green ·
§4 timing p50 no-regression on both engines + globals localised + per-function `redis.call` count not
increased · §5 zero unused code · §6 docs accurate. No new dependency or tooling introduced.
