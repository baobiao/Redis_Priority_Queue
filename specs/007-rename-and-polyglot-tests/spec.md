# Feature Specification: Rename to priority_queue and Polyglot Test Parity

**Feature Branch**: `007-rename-and-polyglot-tests`  
**Created**: 2026-07-12  
**Status**: Draft  
**Input**: User description: "Rename the Lua library `message_format` → `priority_queue` (full depth: file + library name + `msgfmt_*` → `pq_*` functions + `MSGFMT` → `PQ` error prefix), rename `tests/` → `test_bash/`, and create 1-to-1 equivalent test suites in Java 25 + Jedis + Maven (`test_java/`) and Python 3 + redis-py (`test_python/`). No change to queue behaviour."

## Clarifications

### Session 2026-07-12

- Q: How far does the rename go? → A: **Full rename (depth c)**. Rename the file to `priority_queue.lua`, the shebang to `#!lua name=priority_queue`, every function `msgfmt_*` → `pq_*`, and every error-reply prefix `MSGFMT ` → `PQ `. Error **codes** (`EFIELD`, `EMALFORMED`, `ENOTFOUND`, `EWRONGTYPE`, …) and all detail text/semantics are **unchanged**; only the leading namespace token changes.
- Q: How do the Java and Python suites obtain engines, given the Bash harness publishes no TCP ports? → A: **Shared port-published containers (option B)**. The Docker harness is modified to publish TCP host ports; all three languages connect over `localhost:<port>`. Java/Python do **not** use Testcontainers. This couples the Java/Python suites to the harness being started first.
- Q: Do the Java/Python suites cover cluster mode? → A: **Yes — all three languages cover cluster** (standalone + single-shard all-slots cluster), asserting hash-tag co-location and absence of `CROSSSLOT`.
- Q: Single top-level runner or native tools? → A: **Native tools only**. `test_bash/run_all.sh`, `mvn test`, and `pytest` are each run independently; no orchestrator script is required.
- Q: Stack versions? → A: Java 25 + Maven + JUnit 5 (5.13.x) + Jedis 7.1.0 (with `maven-compiler-plugin` ≥ 3.14.0 and `maven-surefire-plugin` 3.5.x for JDK 25 class-file v69); Python 3.11+ + pytest + redis-py 5.x. Engine pins stay `redis:7.4` and `valkey/valkey:8.0`.
- Q: Are historical specs 001–006 rewritten? → A: **No** — they are point-in-time records and are excluded from the rename and from the "zero stale references" grep sweep.
- Q: Constitution change needed? → A: **No.** Principle II scopes dependencies to the **library** runtime (still zero); Java/Maven/Jedis and Python/redis-py are TEST-ONLY tooling. Principle IX ("tested on every engine") is language-agnostic and already satisfied; multi-client parity is an additive test practice it permits. Recorded in the plan's Constitution Check.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rename the library to priority_queue (Priority: P1)

A maintainer renames the single Lua Functions library from `message_format` to `priority_queue`
end-to-end so the artifact's name reflects what it is (a priority queue), with **no change to queue
behaviour**. The file becomes `src/functions/priority_queue.lua`, the loaded library name becomes
`priority_queue`, every function is `pq_*` instead of `msgfmt_*`, and every error reply leads with
`PQ ` instead of `MSGFMT `. Every reference across current code, developer documentation, the test
harness, `CLAUDE.md`, and `.specify/feature.json` is updated in lock-step, and a repo-wide grep proves
nothing stale remains (outside the frozen historical specs 001–006).

**Why this priority**: This is the headline change and the prerequisite for everything else — the
relocated Bash suite and the two new suites all load `priority_queue.lua`, call `pq_*`, and assert on
`PQ ` errors. Nothing else can be verified until the rename is coherent.

**Independent Test**: Load the renamed library on both engines, run the (relocated) Bash suite, and
confirm the same total assertion count as before the rename with zero failures; run the grep sweep and
confirm zero stale tokens outside historical specs.

**Acceptance Scenarios**:

1. **Given** the renamed library, **When** it is loaded with `FUNCTION LOAD`, **Then** `FUNCTION LIST`
   reports library name `priority_queue` and functions `pq_create`, `pq_read`, `pq_validate`,
   `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`, `pq_peek`, `pq_redrive`, `pq_reap`, `pq_stats`.
2. **Given** a validation failure (e.g. an unknown field), **When** the offending function is called,
   **Then** the error reply begins with `PQ EFIELD` (prefix `PQ`, code and detail unchanged from the
   pre-rename `MSGFMT EFIELD`).
3. **Given** the same inputs used in Feature 006's suite, **When** any `pq_*` function is called,
   **Then** the returned fields, ordering, and values are identical to the pre-rename output (behaviour
   is byte-for-byte equivalent apart from the renamed function/error tokens).
4. **Given** the whole repository, **When** grepping for `message_format`, `msgfmt`, or `MSGFMT`,
   **Then** the only matches are inside `specs/001-006/**` (intentionally preserved).

---

### User Story 2 - Relocate the Bash suite to test_bash/ (Priority: P2)

A maintainer renames the `tests/` directory to `test_bash/` to signal that these suites are written in
Bash (now that Java and Python siblings are arriving), preserving the internal structure
(`harness/`, `contract/`, `integration/`, `unit/`, `run_all.sh`) and keeping every suite green. All
path references — the harness library path, `run_all.sh` globs, the permission allowlist, `.gitignore`,
and any doc/spec mention of `tests/` — are updated, and the harness's relative `source` resolution still
works after the move.

**Why this priority**: A consistent, clearly-named Bash home is required before the Java/Python suites
are introduced alongside it, and it must remain the reference/source-of-truth for expected values.

**Independent Test**: Run `test_bash/run_all.sh` on both engines from the new location and confirm the
same assertion total and zero failures; confirm no lingering `tests/` path reference resolves anywhere
in current code/docs/config.

**Acceptance Scenarios**:

1. **Given** the relocated suite, **When** `test_bash/run_all.sh` runs on redis and valkey, **Then** it
   passes with the same assertion total as before the move.
2. **Given** the relocated harness, **When** a suite `source`s `../harness/load_and_call.sh` (relative),
   **Then** the path resolves and the static gate finds `src/functions/priority_queue.lua`.
3. **Given** the permission allowlist and `.gitignore`, **When** they are inspected, **Then** they
   reference `test_bash/` (not `tests/`).

---

### User Story 3 - Java parity suite (Priority: P3)

A Java developer runs `mvn test` under `test_java/` and gets a JUnit 5 suite that mirrors **every** Bash
suite (contract, integration, unit) 1-to-1 — the same scenarios, the same expected values, the same
coverage — loading `priority_queue.lua` via `FUNCTION LOAD` and exercising `FCALL`/`FCALL_RO` through
Jedis against **both** engines, standalone and cluster.

**Why this priority**: Proves the library behaves identically when driven by a real Java client, not
just the Bash/`docker exec` path — the first half of the polyglot-parity goal.

**Independent Test**: With the harness up (ports published), run `mvn test` in `test_java/` on redis and
valkey (standalone + cluster) and confirm all mirrored cases pass with coverage equivalent to their Bash
counterparts per the parity mapping table.

**Acceptance Scenarios**:

1. **Given** the published engine ports, **When** `mvn test` runs, **Then** each `test_bash/` suite has a
   corresponding Java test class covering the same cases, and all pass on both engines.
2. **Given** a function returning numeric fields (e.g. `pq_read`/`pq_dequeue`/`pq_stats`), **When** Jedis
   decodes the reply, **Then** integer fields are asserted as typed integers (`Long`) and bulk strings as
   `String` (the client-coercion parity trap is handled).
3. **Given** a validation failure, **When** the function is called, **Then** Jedis surfaces a
   `JedisDataException` whose message contains the `PQ E…` code; a write function invoked via `FCALL_RO`
   is likewise rejected.
4. **Given** cluster mode, **When** co-located hash-tag keys are used, **Then** operations succeed with no
   `CROSSSLOT` error, matching the Bash cluster behaviour.

---

### User Story 4 - Python parity suite (Priority: P4)

A Python developer runs `pytest` under `test_python/` and gets a suite that mirrors every Bash suite
1-to-1 using redis-py — same scenarios, expected values, and coverage — loading `priority_queue.lua` and
exercising `fcall`/`fcall_ro` against both engines, standalone and cluster.

**Why this priority**: Completes the polyglot-parity goal, proving identical behaviour from a third,
independent client stack.

**Independent Test**: With the harness up, run `pytest` in `test_python/` on redis and valkey (standalone
+ cluster) and confirm all mirrored cases pass with coverage equivalent to their Bash counterparts.

**Acceptance Scenarios**:

1. **Given** the published engine ports, **When** `pytest` runs, **Then** each `test_bash/` suite has a
   corresponding Python module covering the same cases, and all pass on both engines.
2. **Given** `decode_responses=True`, **When** a reply is read, **Then** status replies compare as
   `"OK"`/`"VALID"`/`"NOOP"`/`"NOTFOUND"`, integers as `int`, and payload/id as `str`.
3. **Given** a validation failure, **When** the function is called, **Then** redis-py raises a
   `ResponseError` whose message contains the `PQ E…` code; a write function invoked via `fcall_ro` is
   likewise rejected.
4. **Given** cluster mode, **When** co-located hash-tag keys are used, **Then** operations succeed with no
   `CROSSSLOT` error.

---

### Edge Cases

- **Missed reference after the rename**: a lingering `message_format` / `msgfmt` / `MSGFMT` token or old
  `tests/` path in a script, doc, config, or allowlist. The spec REQUIRES a repo-wide grep sweep proving
  zero stale references outside the frozen records (all `specs/**`, `.specify/templates/`, and the
  constitution's Sync-Impact comment). The relocate sweep MUST target the real test subpaths
  (`tests/harness|contract|integration|unit|run_all|.artifacts`) so it does not false-match the feature
  directory name `007-…-tests/` or generic template examples.
- **Relative source paths in the harness**: the suites `source` `"$(dirname …)/../harness/…"` and the
  static gate defaults its LIB to `$HERE/../../src/functions/…`. These MUST still resolve after moving
  `tests/` → `test_bash/` and renaming the library file (same directory depth is preserved).
- **Engine parity**: the Java and Python suites MUST assert against **both** engines (redis **and**
  valkey), matching the Bash `ENGINES` loop — not redis only.
- **Assertion / coverage parity**: each language suite covers the same cases as its Bash counterpart; a
  mapping table (`test_bash/*` ↔ `test_java/*` ↔ `test_python/*`) documents the correspondence.
- **Cluster mode**: covered in all three languages — co-located hash-tag keys, `cluster_state:ok`, no
  `CROSSSLOT` for single-key operations.
- **Client type-coercion divergence**: `pq_read`/`pq_dequeue`/`pq_peek`/`pq_stats`/`pq_reap` return
  numeric fields as RESP integers, which Jedis decodes to `Long` and redis-py to `int` (not `"0"`). Ports
  MUST assert on typed values, not the Bash string form.
- **Host port collisions**: published host ports MUST be overridable (env/shared constants) so a
  developer with a local redis on 6379 can still run all three suites.
- **Behaviour hash**: the rename changes only names/tokens, not the code's queue behaviour; the
  flags/contract assertions that check the **library name** are updated to `priority_queue`, and the
  static portability/determinism gate still passes unchanged except for its LIB default path.
- **Harness regression**: adding published ports MUST NOT break the existing `docker exec`-based Bash
  path (ports are additive; the Bash suite keeps executing via `docker exec`).

## Requirements *(mandatory)*

### Functional Requirements

**Rename (US1)**

- **FR-001**: The library file MUST be renamed `src/functions/message_format.lua` →
  `src/functions/priority_queue.lua`.
- **FR-002**: The library shebang MUST become `#!lua name=priority_queue`.
- **FR-003**: Every registered function MUST be renamed `msgfmt_*` → `pq_*`: `pq_create`, `pq_read`,
  `pq_validate`, `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`, `pq_peek`, `pq_redrive`, `pq_reap`,
  `pq_stats`.
- **FR-004**: Every error-reply prefix MUST change `MSGFMT ` → `PQ `. Error **codes** and all detail
  text/semantics MUST be unchanged (e.g. `MSGFMT EFIELD: unknown field 'x'` → `PQ EFIELD: unknown field
  'x'`).
- **FR-005**: The library's runtime behaviour MUST be unchanged: the KEYS/ARGV contract, field set and
  order, priority/score encoding, return shapes, and all decisions are byte-for-byte equivalent to
  Feature 006 output apart from the renamed function names and error prefix. No new commands, fields, or
  behaviours are introduced.
- **FR-006**: Every reference to the old file path, library name, function names, or error prefix in
  **current** artifacts MUST be updated: `README.md`, `docs/schema.md`, `docs/functions.md`,
  `CLAUDE.md`, `.specify/feature.json`, the test harness (library path, container names, comments), and
  any script that loads or names the library. Container/variable names carrying `msgfmt` (e.g.
  `msgfmt-redis`) MUST be renamed to a `pq`-consistent form.
- **FR-007**: A repo-wide grep sweep MUST return zero matches for `message_format`, `msgfmt`, or
  `MSGFMT` outside a defined set of **frozen records**: the entire `specs/**` tree (001–006 are
  historical; 007 legitimately documents the old→new rename mapping), the generic `.specify/templates/`,
  and the constitution's non-normative Sync-Impact comment (`.specify/memory/constitution.md`). All
  active code, docs, harness, and config MUST be clean.

**Relocate Bash suite (US2)**

- **FR-008**: The `tests/` directory MUST be renamed to `test_bash/`, preserving its internal structure
  (`harness/`, `contract/`, `integration/`, `unit/`, `run_all.sh`) with every suite green.
- **FR-009**: All references to the `tests/` path MUST be updated — `README.md`, `docs/**`,
  `.claude/settings.local.json` (permission allowlist), `.gitignore`, and `run_all.sh` globs — and the
  harness's relative `source`/LIB path resolution MUST still work after the move (verified by the suite
  passing).

**Shared engine provisioning (US3 + US4 foundation)**

- **FR-010**: The Docker engine harness MUST publish TCP host ports for the standalone redis and valkey
  engines **and** for the cluster nodes, so host-run clients connect over `localhost:<port>`. This MUST
  NOT break the existing `docker exec`-based Bash path (ports are additive).
- **FR-011**: Engine image pins (`redis:7.4`, `valkey/valkey:8.0`) and the published host ports MUST be
  defined in a single shared constants source consumed by all three language suites, to prevent version
  or port drift.

**Java parity suite (US3)**

- **FR-012**: A Java 25 + Maven + JUnit 5 + Jedis suite MUST exist under `test_java/` with a test class
  mirroring EACH Bash suite (every `contract/`, `integration/`, `unit/` file), asserting the same
  scenarios, expected values, and equivalent coverage.
- **FR-013**: The Java suite MUST load `priority_queue.lua` via `FUNCTION LOAD` (REPLACE) and exercise
  `FCALL`/`FCALL_RO`, asserting on typed replies (RESP integers as `Long`, bulk strings as `String`,
  arrays as `List`) and detecting error replies (`PQ E…`) as `JedisDataException` whose message contains
  the code; a write function invoked via `FCALL_RO` MUST be asserted rejected.
- **FR-014**: The Java suite MUST run against BOTH engines (redis and valkey) in BOTH topologies —
  standalone and cluster (via `JedisCluster`), asserting hash-tag co-location and no `CROSSSLOT`.

**Python parity suite (US4)**

- **FR-015**: A Python 3.11+ + pytest + redis-py suite MUST exist under `test_python/` with a module
  mirroring EACH Bash suite, asserting the same scenarios, expected values, and equivalent coverage.
- **FR-016**: The Python suite MUST load `priority_queue.lua` via `function_load` and exercise
  `fcall`/`fcall_ro` with `decode_responses=True`, asserting typed replies (`int`, `str`, `list`) and
  detecting error replies (`PQ E…`) as `ResponseError` whose message contains the code; a write function
  invoked via `fcall_ro` MUST be asserted rejected.
- **FR-017**: The Python suite MUST run against BOTH engines in BOTH topologies — standalone and cluster
  (via `RedisCluster`), asserting hash-tag co-location and no `CROSSSLOT`.

**Parity & governance**

- **FR-018**: A parity mapping table (`test_bash/*` ↔ `test_java/*` ↔ `test_python/*`) MUST be
  documented, and the three suites MUST cover equivalent cases and counts. The **Bash suite is the
  source of truth** for expected values.
- **FR-019**: The static portability/determinism gate MUST still pass with only its LIB default path
  updated to `priority_queue.lua`; the library's runtime dependency set remains empty (Principle II).
  Java/Maven/Jedis and Python/redis-py are TEST-ONLY tooling and MUST NOT be introduced as library
  runtime dependencies.
- **FR-020**: Each suite MUST be independently runnable by its native tool (`test_bash/run_all.sh`,
  `mvn test`, `pytest`); no single orchestrator is required (an optional convenience wrapper is out of
  scope).

### Key Entities *(include if feature involves data)*

- **Lua Functions library**: the single self-contained file, renamed to `priority_queue.lua`
  (`#!lua name=priority_queue`), exposing 11 `pq_*` functions. Behaviour identical to Feature 006.
- **Bash test suite (`test_bash/`)**: relocated reference suite — `harness/` (docker_engines,
  load_and_call, static_checks), `contract/` (11), `integration/` (16), `unit/` (9), `run_all.sh`.
  Source of truth for expected values.
- **Java test suite (`test_java/`)**: Maven project; JUnit 5 classes mirroring each Bash suite; Jedis
  client over published ports; parameterized across engines + topologies.
- **Python test suite (`test_python/`)**: pytest modules mirroring each Bash suite; redis-py client over
  published ports; parameterized across engines + topologies.
- **Shared engine constants**: single source of the two engine image pins and published host ports,
  consumed by all three suites.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After the rename, `test_bash/run_all.sh` passes on both engines with the **same total
  assertion count as the pre-rename baseline (832 assertions, 0 failed)** and the static gate green.
- **SC-002**: `mvn test` in `test_java/` passes on both engines in standalone and cluster topologies,
  with every Bash suite mirrored by a Java class and case coverage equivalent per the parity table.
- **SC-003**: `pytest` in `test_python/` passes on both engines in standalone and cluster topologies,
  with every Bash suite mirrored by a Python module and case coverage equivalent per the parity table.
- **SC-004**: A repo-wide grep for `message_format|msgfmt|MSGFMT` and for the old test-folder subpaths
  returns zero matches outside the frozen records (all `specs/**`, `.specify/templates/`, and the
  constitution's Sync-Impact comment).
- **SC-005**: All three suites assert identical expected values for identical scenarios (proven by the
  parity mapping table showing 1-to-1 case correspondence).
- **SC-006**: The library exhibits zero behavioural change: for identical inputs it returns results
  identical to Feature 006 apart from the renamed function names and `PQ` error prefix.

## Assumptions

- **Rename depth is full (option c)**; the error-reply namespace token becomes `PQ` (mapping the `pq_`
  function prefix); error codes and detail text are unchanged.
- **Engine provisioning is shared, port-published containers (option B)**; Testcontainers is NOT used.
  The Java/Python suites require the harness to be brought up first (`docker_engines.sh up`).
- **Cluster mode is covered by all three languages** (single-shard all-slots cluster, single-key
  operations, hash-tag co-location).
- **Native tools only**: no top-level orchestrator; each suite is run by `run_all.sh` / `mvn test` /
  `pytest`.
- **Historical specs 001–006 are frozen** point-in-time records — not rewritten, and excluded from the
  grep sweep.
- **Stacks**: Java 25 + Maven + JUnit 5 (5.13.x) + Jedis 7.1.0 (min 4.2.0 exposes `functionLoad`/`fcall`/
  `fcallReadonly`), with `maven-compiler-plugin` ≥ 3.14.0 and `maven-surefire-plugin` 3.5.x to support
  JDK 25's class-file major version 69; Python 3.11+ + pytest + redis-py 5.x (min 4.3.0 exposes
  `function_load`/`fcall`/`fcall_ro`).
- **Engine pins unchanged**: `redis:7.4` and `valkey/valkey:8.0`, overridable by env.
- **No constitution change required** (Principle II is library-runtime-scoped; Principle IX is
  language-agnostic and already satisfied; multi-client parity is additive). Recorded in the plan's
  Constitution Check.
- **Environment**: Docker, a JDK 25 toolchain, Python 3.11+, and network access to Maven Central / PyPI
  are available where the Java/Python suites run.
