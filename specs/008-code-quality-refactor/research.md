# Phase 0 Research: Code-Quality Review & Refactor

This feature introduces **no queue behaviour**. Research resolves *how* to refactor safely and *how* to
verify each of the three goals, given the clarified constraints (measured perf gate; aggressive test
dedup; green-suites-plus-review verification; no new tooling).

## R1. Lua-in-Redis performance techniques (goal 3)

- **Decision**: Apply four behaviour-neutral techniques to `priority_queue.lua`, in priority order:
  1. **Localise hot globals as upvalues** at the top of the file — `local rcall = redis.call`,
     `local rerr = redis.error_reply`, `local rstatus = redis.status_reply`, `local tonumber = tonumber`,
     `local tostring = tostring`, `local sformat = string.format`, `local ssub = string.sub`. The library
     currently localises **none** of these; measured static counts are `redis.call` ×71,
     `redis.error_reply` ×66, `tonumber` ×40, `redis.status_reply` ×10 (≈187 global-table lookups that
     become single upvalue lookups).
  2. **Remove redundant `redis.call`** — reuse a value already fetched in the same function instead of
     re-reading the key; hoist a repeated lookup out of a loop.
  3. **Avoid rebuilding tables** — build a result/return table once; pre-size or fill by index rather
     than repeatedly reconstructing; avoid intermediate tables that are immediately discarded.
  4. **Tighten loops** — hoist invariants, avoid per-iteration global lookups and allocations.
- **Rationale**: In the embedded Lua 5.1 interpreter a global reference is a hash lookup in `_G` (or the
  redis sandbox environment) on every access; binding it to a local turns each into a register/upvalue
  read — the single highest-yield, lowest-risk optimisation for a hot server-side script, and exactly the
  set of techniques the feature request named. All four are semantics-preserving.
- **Alternatives considered**:
  - *`redis.setresp(3)` / RESP3 tuning* — rejected: changes reply decoding, a behavioural/portability risk
    (Principle III/VIII) with no benefit here.
  - *Rewriting control flow for micro-gains* — rejected: risks readability (goal 1) and behaviour; the
    localisation + redundant-call removal captures the bulk of the win with far less risk.
  - *Caching across calls (module-level memo)* — rejected: a function instance is per-call; cross-call
    state would break determinism/replication (Principle VII).

## R2. Performance measurement — the FR-013 timing gate

- **Decision**: A **repeatable median-latency measurement over a fixed mixed workload**, reusing the
  existing clients (no new dependency):
  - **Workload**: a fixed script that exercises the hot path — a batch of `pq_enqueue` then a
    `pq_dequeue`→`pq_ack` cycle, plus representative `pq_read`/`pq_peek`/`pq_stats`/`pq_nack` calls —
    at a fixed iteration count (**N ≥ 1000** timed iterations after **≥ 100** discarded warm-up
    iterations).
  - **Environment**: same host, same container image, redis **and** valkey standalone; compare the
    **Feature 007 library** (`git show HEAD:src/functions/priority_queue.lua` / the merged baseline)
    against the refactored file, back-to-back.
  - **Statistic**: median (p50) wall-clock per iteration; report p50 and p90.
  - **Gate**: **no regression** — refactored p50 MUST be ≤ baseline p50 × **1.05** (a 5% noise band) on
    each engine; a measurable improvement is the **target** and expected given R1.
- **Rationale**: Median-over-N with warm-up is the standard way to get a stable number from a noisy
  micro-measurement without a benchmarking framework. The 5% band absorbs container/scheduler jitter so
  the gate fails only on a *real* regression, satisfying the user's "measured threshold gate / strictly
  no regression" choice without flakiness. Reusing the existing Bash/redis-cli (or a small pytest timing
  module) honours "no new tooling" (Q3) and Principle II.
- **Alternatives considered**:
  - *Require a fixed ≥X% speed-up as the gate* — rejected: an already-lean 962-line library may not have a
    large headroom on every function; a hard percentage would be arbitrary and could fail on noise.
    "No regression, improvement targeted" is the honest, defensible gate.
  - *`redis-benchmark`* — rejected: it does not drive `FCALL` with our argument shapes; a scripted loop
    over the real functions is more representative.
  - *A committed benchmark harness (spec option C)* — rejected by the clarify answer (measured gate, not a
    benchmark artifact) and by Principle II.

## R3. Proving "zero unused code" without linters (goal 2)

- **Decision**: **Green suites + targeted code review.** Reachability of library branches and test paths
  is already exercised by the frozen suites; a symbol that is truly unused is found by review
  (grep each `local`/private function/import for a second reference; confirm every branch is reachable).
  Framework-driven symbols (pytest fixtures used by name injection, JUnit lifecycle/`@ParameterizedTest`
  sources, Bash harness entrypoints) are **explicitly retained**.
- **Rationale**: The clarify answer (Q3) chose no new tooling. The suites give strong reachability
  evidence; a lint pass would add setup/CI and dev dependencies for marginal gain on a codebase this
  size. Grep-assisted review is sufficient and auditable.
- **Alternatives considered**:
  - *Add `luacheck`/`shellcheck`/`ruff`/`checkstyle`* (spec option B) — rejected by Q3; would add
    dev-tooling/CI wiring. May be reconsidered as a *separate* future feature if desired.

## R4. Aggressive test-suite deduplication patterns (goal 1, per language)

- **Decision**: Push duplication **down** into the shared module each suite already has, preserving the
  frozen totals and the engine × topology matrix:
  - **Bash**: extend `test_bash/harness/load_and_call.sh` with shared assertion/setup helpers
    (e.g. a single `expect`/`assert_field` and key-builder); keep `run_all.sh` discovery by directory.
  - **Java**: introduce a shared **abstract base test class** in `pq.support` (parameterised engine ×
    topology provider, common `FUNCTION LOAD`/`FCALL` helpers, typed-reply assertions) that the 36 classes
    extend; grow `support/{Engines,Pq,Repo}` rather than repeating client wiring per class.
  - **Python**: move repeated setup into `conftest.py` fixtures (engine × topology params already there)
    and grow `pqsupport.py` for shared client/assertion helpers; use `@pytest.mark.parametrize` for
    repeated case tables.
- **Rationale**: These modules already exist (`support/{Engines,Pq,Repo}.java`, `conftest.py`,
  `pqsupport.py`, `harness/load_and_call.sh`), so aggressive dedup is *expanding* an established pattern,
  not inventing structure — maximum DRY with minimum architectural churn.
- **Alternatives considered**:
  - *Conservative (spec option A)* — rejected by the clarify answer (aggressive dedup).
  - *A shared cross-language fixture generator* — rejected: over-engineering; each language keeps its
    idiomatic sharing mechanism, and the Bash suite stays the source of truth for expected values.

## R5. Proving "zero behaviour change" (the regression guard)

- **Decision**: Behavioural equivalence is proven by **all three suites staying green at their exact
  Feature 007 totals** (Bash 832 / 0; Java 268 run / 10 skip / 0; Python 258 passed / 10 skip / 0) on
  redis + valkey, standalone + cluster. Error replies (code **and** detail text), field set/order, and
  status strings are part of what the suites assert, so any drift fails them.
- **Rationale**: The suites were authored test-first across features 001–006 and mirrored 1-to-1 in 007;
  they are a comprehensive behavioural oracle. Q3 chose to rely on them plus review rather than add an
  output-diff harness.
- **Alternatives considered**:
  - *Snapshot + diff `FCALL` outputs of the F007 vs refactored library* (spec option C) — rejected by Q3;
    the frozen suites already assert the observable outputs.

## Resolved unknowns

All Technical Context items are concrete; no `NEEDS CLARIFICATION` remains. The only introduced number —
the **5% noise band** for the timing gate (R2) — is env-overridable in the measurement script and stated
in `quickstart.md`.
