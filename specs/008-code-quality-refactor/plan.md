# Implementation Plan: Code-Quality Review & Refactor (Lua + Bash + Java + Python)

**Branch**: `008-code-quality-refactor` | **Date**: 2026-07-16 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/008-code-quality-refactor/spec.md`

## Summary

A **behaviour-preserving** refactor with **zero change to queue behaviour or the public contract** (same
spirit as Feature 007). Four deliverables across three quality goals: (1) **Readability/maintainability**
across the one Lua library and the three test suites — consistent naming, extracted shared helpers,
accurate comments. (2) **Zero unused code** — remove dead locals, unreachable branches, redundant work,
stale comments, and unused imports in all four codebases. (3) **Lua performance** — optimise the
hot-path `src/functions/priority_queue.lua` (962 lines) by localising its currently-un-localised hot
globals (`redis.call` ×71, `redis.error_reply` ×66, `tonumber` ×40, `redis.status_reply` ×10 → local
upvalues), eliminating redundant `redis.call`/table work, and tightening loops — while the per-function
command count never increases and a **measured timing gate** shows no regression versus the Feature 007
baseline.

The three existing suites are the regression guard: they MUST stay green on **redis and valkey**, in
**standalone and cluster**, at their frozen Feature 007 totals — **Bash 832** assertions / 0 failed,
**Java 268** run / 10 skipped / 0 failed, **Python 258** passed / 10 skipped / 0 failed. Test-suite
restructuring is **aggressive** (expand `support/` + base classes in Java, `conftest.py`/`pqsupport.py`
fixtures in Python, sourced helpers in the Bash harness) with those frozen totals as the absolute
backstop. Equivalence and dead-code freedom are proven by **green suites + code review** — **no linters,
no output-diff harness, no new dependency** are introduced; the only measurement added anywhere is the
FR-013 timing step, which reuses the existing clients/harness.

## Technical Context

**Language/Version**: Lua 5.1 (library, refactored in place) · Bash (harness + suites) · **Java 25**
(test suite) · **Python 3.11+** (test suite) — all unchanged from Feature 007  
**Primary Dependencies**: Library — none beyond `redis.*` + the Lua standard library (**unchanged;
Principle II**). Test-only — Java: JUnit 5.13.x, Jedis 7.1.0, `maven-compiler-plugin` ≥ 3.14.0,
`maven-surefire-plugin` 3.5.x; Python: pytest, redis-py 5.x. **This feature adds no dependency**
(no linter, no benchmark framework).  
**Storage**: Redis 7.0+/`redis:7.4` and Valkey 7.2+/`valkey/valkey:8.0` (Hash + Sorted Set; unchanged)  
**Testing**: Bash harness (`docker exec`) + Java `mvn test` (TCP) + Python `pytest` (TCP), each against
both engines in standalone **and** cluster, at frozen totals; **plus** a lightweight timing measurement
(FR-013) reusing those same clients as the performance gate  
**Target Platform**: Self-hosted Redis 7.0+, Valkey 7.2+, Amazon ElastiCache, Amazon MemoryDB
(portability unchanged)  
**Project Type**: Server-side Lua Functions library + polyglot test harness (three parallel suites)  
**Performance Goals**: Convert 187+ hot global-table lookups in the library to local upvalues
(`redis.call`/`redis.error_reply`/`redis.status_reply`/`tonumber`), remove redundant `redis.call`/table
rebuilds, tighten loops; **per-function `redis.call` count never increases**; measured median execution
time shows **no regression** versus the Feature 007 baseline (within a stated noise tolerance),
improvement targeted  
**Constraints**: Zero behavioural/contract change; the three suites stay green at their frozen totals;
no new dependency or verification tooling; the timing gate reuses existing clients only; fail-before-write
ordering, atomicity (single round trip), `no-writes` flags, and hash-tag co-location all preserved  
**Scale/Scope**: 1 library file (962 lines — 11 registered `pq_*` functions, 7 private helpers
`is_int`/`hash_tag`/`lease_available`/`is_visible`/`encode_field`/`parse_args`/`build_message`, 4
constants) refactored in place · 36 Bash suites + 3 harness scripts · 36 Java classes +
`support/{Engines,Pq,Repo}` · 36 Python modules + `conftest.py` + `pqsupport.py` · docs re-verified
(README, `docs/schema.md`, `docs/functions.md`); historical specs 001–007 untouched

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution v2.0.0. **Result: PASS — no amendment required.**

| Principle | Assessment |
|---|---|
| I. SDD Mandatory | PASS — this refactor runs the full flow; every change traces to `specs/008`. |
| II. Minimal Dependencies | PASS — the library gains **no** dependency (behaviour frozen; `require` scan stays clean). The FR-013 timing gate reuses the existing clients/harness; **no linter or benchmark framework** is added (Q3). Complexity Tracking stays empty. |
| III. Portability | PASS — source stays identical across all four targets; optimisations are pure Lua (localising globals, removing redundant work) and introduce no command/option. Static portability gate stays green. |
| IV. Cluster-Safe Key Access | PASS — key handling is byte-for-byte unchanged, including the sanctioned `KEYS[n] .. id` construction in `pq_dequeue`/`pq_peek`. Aggressive test-suite dedup preserves hash-tag co-location (no new `CROSSSLOT`). |
| V. No Admin Commands | PASS — the command set is unchanged; the static restricted-command scan is unaffected. |
| VI. Atomicity / Single Round Trip | PASS / **reinforced** — FR-012 forbids increasing any function's `redis.call` count or adding a round trip; every optimisation is intra-function. |
| VII. Determinism / Flags | PASS — `no-writes` flags unchanged (`pq_read`/`pq_validate`/`pq_peek`/`pq_stats` stay `FCALL_RO`-callable); localising globals introduces no non-determinism. |
| VIII. Explicit Contracts | PASS — `KEYS`/`ARGV`/return shapes and every `PQ <CODE>: <detail>` reply (**code and detail text**) are frozen (FR-001/FR-002); recorded in `contracts/frozen-surface.md`. |
| IX. Tested on Every Engine and Mode | PASS / **reinforced** — all three suites keep passing on redis + valkey, standalone + cluster, at frozen totals; this is the refactor's safety net. **Test-first nuance**: no new library behaviour is introduced, so there is nothing to author test-first against — the already-green suites (authored test-first in 001–006, mirrored in 007) guard the change. Recorded, not a violation. |
| X. Documentation Currency | PASS — FR-017: `README.md`, `docs/schema.md`, `docs/functions.md` are re-verified; for a behaviour-preserving refactor they should be materially unchanged and are updated only if a documented detail genuinely changes. |

No violations → **Complexity Tracking is empty**. No `/speckit-constitution` run is required.

## Project Structure

### Documentation (this feature)

```text
specs/008-code-quality-refactor/
├── plan.md                  # This file
├── research.md              # Phase 0 output (perf best-practices, timing method, dedup patterns)
├── data-model.md            # Phase 1 output (frozen invariants + refactor target map + optimisation catalog)
├── quickstart.md            # Phase 1 output (how to verify: 3 suites + timing gate + dead-code review)
├── contracts/
│   └── frozen-surface.md    # Phase 1 output (the frozen public pq_* contract — the "do not change" spec)
├── checklists/
│   └── requirements.md      # Specification quality checklist (from /speckit-specify)
└── tasks.md                 # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/functions/
└── priority_queue.lua                  # REFACTORED IN PLACE — localise hot globals, extract/rename
                                         #   private helpers, remove dead code; public pq_* surface,
                                         #   returns, flags, and PQ errors byte-for-byte frozen

test_bash/                               # TIDIED — readability + dead code; aggressive shared helpers
├── harness/
│   ├── docker_engines.sh                # de-duplicated; behaviour of up/cluster-up/down unchanged
│   ├── load_and_call.sh                 # shared load/FCALL helpers consolidated
│   └── static_checks.sh                 # portability/determinism gate — still green, LIB unchanged
├── contract/ (11) integration/ (16) unit/ (9)   # shared assertion helpers; expected values FROZEN
└── run_all.sh                           # discovery unchanged (globs by dir); 832 assertions preserved

test_java/                               # TIDIED — Maven/JUnit 5/Jedis; aggressive dedup into support/
├── pom.xml                              # unchanged (no new dependency)
└── src/test/java/pq/
    ├── support/ {Engines,Pq,Repo}.java  # EXPANDED — shared base class(es)/helpers absorb duplication
    ├── contract/ (11) integration/ (16) unit/ (9)   # 268 run / 10 skip FROZEN; only structure changes

test_python/                             # TIDIED — pytest/redis-py; aggressive dedup into shared modules
├── requirements.txt                     # unchanged (no new dependency)
├── conftest.py                          # EXPANDED — shared fixtures/parametrize absorb duplication
├── pqsupport.py                         # EXPANDED — shared client/assertion helpers
└── contract/ (11) integration/ (16) unit/ (9)   # 258 passed / 10 skip FROZEN; only structure changes

docs/                                    # RE-VERIFIED (updated only if a documented detail changes)
├── schema.md
└── functions.md
README.md                                # RE-VERIFIED
engines.env                              # unchanged (pins + host ports)
```

**Structure Decision**: One library at `src/functions/priority_queue.lua`, refactored **in place** (no
file move, no rename — that was Feature 007). The three sibling test trees are tidied in place, pushing
duplicated logic **down** into the shared modules each already has (`test_bash/harness/`,
`test_java/.../support/`, `test_python/conftest.py`+`pqsupport.py`). No directory is added or renamed;
`engines.env` and the discovery globs are untouched, so the harness and runners work exactly as before.

## Complexity Tracking

> No Constitution Check violations — this table is intentionally empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none)    | —          | —                                    |
