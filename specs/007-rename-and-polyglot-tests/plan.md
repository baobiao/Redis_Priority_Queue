# Implementation Plan: Rename to priority_queue and Polyglot Test Parity

**Branch**: `007-rename-and-polyglot-tests` | **Date**: 2026-07-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-rename-and-polyglot-tests/spec.md`

## Summary

Refactor + test-infrastructure feature with **no change to queue behaviour**. Four deliverables:
(1) **Full rename** of the single Lua Functions library `message_format` → `priority_queue`: file
`src/functions/priority_queue.lua`, shebang `#!lua name=priority_queue`, all 11 functions `msgfmt_*` →
`pq_*`, and every error prefix `MSGFMT ` → `PQ ` (codes/detail unchanged). (2) **Relocate** `tests/` →
`test_bash/`, keeping every suite green. (3) A **Java 25 + Maven + JUnit 5 + Jedis** suite under
`test_java/` mirroring every Bash suite 1-to-1. (4) A **Python 3.11+ + pytest + redis-py** suite under
`test_python/` doing the same. Engines are provisioned by the existing Docker harness, now **publishing
TCP ports** so the host-run Java/Python clients can connect; all three suites read the same engine image
pins and host ports from a single shared `engines.env`. Cluster mode is covered in all three languages.
The Bash suite is the source of truth for expected values; a repo-wide grep sweep proves zero stale
`message_format`/`msgfmt`/`MSGFMT`/`tests/` references outside the frozen historical specs 001–006.

## Technical Context

**Language/Version**: Lua 5.1 (library, unchanged) · Bash (existing harness) · **Java 25** (new) ·
**Python 3.11+** (new)  
**Primary Dependencies**: Library — none beyond `redis.*` + Lua stdlib (**unchanged; Principle II**).
Test-only — Java: JUnit 5.13.x, **Jedis 7.1.0**, `maven-compiler-plugin` ≥ 3.14.0, `maven-surefire-plugin`
3.5.x (required for JDK 25 class-file major v69). Python: pytest, **redis-py 5.x**. **No Testcontainers**
(engine provisioning is shared port-published containers).  
**Storage**: Redis 7.0+/`redis:7.4` and Valkey 7.2+/`valkey/valkey:8.0` (Hash + Sorted Set; unchanged)  
**Testing**: Bash harness (`docker exec`) + Java `mvn test` (TCP) + Python `pytest` (TCP), each against
both engines in standalone **and** cluster mode  
**Target Platform**: Self-hosted Redis 7.0+, Valkey 7.2+, Amazon ElastiCache, Amazon MemoryDB (library
portability unchanged)  
**Project Type**: Server-side Lua Functions library + polyglot test harness (three parallel suites)  
**Performance Goals**: N/A (no behavioural/perf change); the relocated Bash suite MUST retain its
pre-rename assertion total (832 assertions, 0 failed) as the regression guard  
**Constraints**: Zero behavioural change vs Feature 006 apart from renamed tokens; published host ports
MUST be env-overridable; single-node all-slots cluster MUST announce a host-reachable address so
`JedisCluster`/`RedisCluster` can discover it over mapped ports  
**Scale/Scope**: 1 library file · 36 Bash suites (11 contract + 16 integration + 9 unit) mirrored into
36 Java classes + 36 Python modules · 1 harness change (port publishing + container/name rename) · docs
(README, docs/schema.md, docs/functions.md, CLAUDE.md) + `.specify/feature.json`

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution v2.0.0. **Result: PASS — no amendment required** (grounded by a dedicated sub-agent).

| Principle | Assessment |
|---|---|
| I. SDD Mandatory | PASS — this feature runs the full flow; renamed library still traces to a spec (`specs/007`). |
| II. Minimal Dependencies | PASS — the **library** gains no dependency (behaviour frozen; `require` scan still clean). Java/Maven/Jedis and Python/redis-py are **TEST-ONLY** tooling, outside Principle II's "third-party **Lua** dependency" scope. No Complexity Tracking entry needed. |
| III. Portability | PASS — library source unchanged; static portability gate passes with only its LIB default path updated to `priority_queue.lua`. |
| IV. Cluster-Safe Key Access | PASS — key handling unchanged; the new Java/Python suites additionally exercise cluster mode (co-located hash-tag keys, no `CROSSSLOT`), reinforcing the check. |
| V. No Admin Commands | PASS — function bodies unchanged; static restricted-command scan unchanged. |
| VI. Atomicity / Single Round Trip | PASS — each function is still one `FCALL`/`FCALL_RO`; renaming does not add round trips. |
| VII. Determinism / Flags | PASS — `no-writes` flags unchanged; read-only functions (`pq_read`/`pq_peek`/`pq_stats`) remain `FCALL_RO`-callable; the suites assert write-function rejection under `FCALL_RO`. |
| VIII. Explicit Contracts | PASS — contracts unchanged except renamed tokens; `contracts/functions.md` records the rename mapping and the `PQ <CODE>: <detail>` convention. |
| IX. Tested on Every Engine and Mode | PASS / **strengthened** — coverage expands from one client (Bash/`docker exec`) to three (Bash + Jedis + redis-py) across both engines and both topologies. The principle names "a Redis client" (language-agnostic); multi-client parity is additive. **Test-first nuance**: no new library behaviour is introduced, so there is nothing to author test-first against — the new suites mirror the already-green Bash suite (authored test-first in features 001–006) over frozen behaviour. Recorded, not a violation. |
| X. Documentation Currency | PASS / required — the rename changes documented function/library names, the error prefix, and how to run tests; `README.md`, `docs/schema.md`, `docs/functions.md`, and `CLAUDE.md` are updated in this same feature (FR-006). |

No violations → **Complexity Tracking is empty**. No `/speckit-constitution` run is required; this is
stated explicitly per the orchestration prompt.

## Project Structure

### Documentation (this feature)

```text
specs/007-rename-and-polyglot-tests/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (rename token map + suite/parity structure)
├── quickstart.md        # Phase 1 output (how to run all three suites + grep sweep)
├── contracts/
│   └── functions.md     # Phase 1 output (renamed function contracts + PQ error convention)
├── checklists/
│   └── requirements.md  # Specification quality checklist
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
engines.env                              # NEW — single source of engine image pins + host ports
                                         #       (KEY=VALUE; sourced by Bash, read by Java Properties + Python)

src/functions/
└── priority_queue.lua                   # RENAMED from message_format.lua (behaviour unchanged;
                                         #   shebang name=priority_queue; functions pq_*; errors "PQ …")

test_bash/                               # RENAMED from tests/ (structure preserved, suites green)
├── harness/
│   ├── docker_engines.sh                # + publish TCP ports (standalone + cluster-announce);
│   │                                    #   container names msgfmt-* → pq-*; comments de-msgfmt'd
│   ├── load_and_call.sh                 # LIB_PATH default → priority_queue.lua
│   └── static_checks.sh                 # LIB default → priority_queue.lua; comments updated
├── contract/       (11 *.sh)            # pq_* FCALL targets; PQ error assertions; lib-name assertion
├── integration/    (16 *.sh)
├── unit/           (9 *.sh)
└── run_all.sh                           # comment de-msgfmt'd; globs unchanged (HERE-relative)

test_java/                               # NEW — Maven project
├── pom.xml                              # Java 25; JUnit 5.13; Jedis 7.1; compiler 3.14; surefire 3.5
└── src/test/java/pq/
    ├── support/                         # Engines (params from engines.env), LibraryLoader, Expect helpers,
    │                                    #   standalone (JedisPooled) + cluster (JedisCluster) client factory
    ├── contract/       (11 *Test.java)
    ├── integration/    (16 *Test.java)
    └── unit/           (9 *Test.java)

test_python/                             # NEW — pytest project
├── requirements.txt                     # pytest; redis>=5
├── pyproject.toml (or pytest.ini)       # test discovery config
├── conftest.py                          # engine × topology fixtures (params from engines.env);
│                                        #   Redis / RedisCluster client factory; library loader
├── contract/       (11 test_*.py)
├── integration/    (16 test_*.py)
└── unit/           (9 test_*.py)
```

**Structure Decision**: One library at `src/functions/priority_queue.lua`; three sibling test trees
(`test_bash/`, `test_java/`, `test_python/`) that mirror one another by directory (`contract`/
`integration`/`unit`) and by file (parity mapping in `data-model.md`). A single repo-root `engines.env`
(KEY=VALUE) is the sole source of engine image pins and published host ports — sourced by
`docker_engines.sh`, loaded by Java via `java.util.Properties`, and parsed by Python's `conftest.py` — so
versions/ports never drift across the three suites. The Bash harness keeps its `docker exec` execution
path (ports are additive) so it stays green; Java/Python connect over `localhost:<port>` and therefore
require the harness to be brought up first.

## Complexity Tracking

> No Constitution Check violations — this table is intentionally empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none)    | —          | —                                    |
