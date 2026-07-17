# Feature Specification: Code-Quality Review & Refactor (Lua + Bash + Java + Python)

**Feature Branch**: `008-code-quality-refactor`  
**Created**: 2026-07-16  
**Status**: Draft  
**Input**: User description: "Review the previously generated code in Lua, Python, Bash, and Java. Review and update the code for (1) ease of reading and maintenance, (2) minimal or no unused lines of code, and (3) Lua code performance."

## Clarifications

### Session 2026-07-16

These decisions were fixed by the feature request and are recorded here so downstream planning is unambiguous:

- Q: Does this feature change any queue behaviour or public contract? → A: **No.** Zero behavioural change. The library name (`priority_queue`), the 11 registered `pq_*` function names, their `KEYS`/`ARGV` contracts, return shapes, `no-writes` flags, and the `PQ <CODE>: <detail>` error convention (**code and detail text**) are all frozen. Same spirit as Feature 007.
- Q: What is the regression guard for a pure refactor? → A: **The three existing suites.** They MUST stay green on redis + valkey, standalone + cluster, at their Feature 007 totals (Bash 832 assertions; Java 268 with 10 intentional standalone-only skips; Python 258 with 10 skips). Only their internal structure/readability may change — never expected values, never the set of scenarios covered.
- Q: How is the Lua performance goal (goal 3) verified and "done" defined? → A: **Measured timing gate.** A lightweight, repeatable timing measurement (a fixed representative `FCALL` workload, fixed iteration count, same host + engine before vs. after) is run and is a **pass/fail gate**: the refactored library MUST show **no execution-time regression** beyond a stated noise tolerance versus the Feature 007 baseline, and SHOULD show a measurable improvement. It reuses the **existing** clients/harness only — no new benchmark framework or dependency (Principle II) — alongside the structural best practices (localise hot globals, remove redundant `redis.call`/table rebuilds, tighten loops) whose command/round-trip counts never increase.
- Q: How aggressively should the three test suites (`test_bash`/`test_java`/`test_python`) be restructured? → A: **Aggressive dedup.** Actively extract shared base classes / fixtures / harness helpers and deduplicate across the suites for maximum DRY. The frozen coverage of FR-003 (per-suite assertion/case totals and the engine × topology matrix) is the absolute backstop — aggressive restructuring MUST NOT collapse distinct assertions or drop any engine/topology combination.
- Q: How are "zero unused code" and "zero behaviour change" proven? → A: **Green suites + review.** Behavioural equivalence is proven by the existing suites staying green at their frozen totals; dead code is found by manual/code review. **No new verification tooling** (no linters, no output-diff harness) is introduced — the only measurement added anywhere is the minimal timing step for the performance gate above.
- Q: How far does "refactor" reach into the Lua file? → A: **Internal only.** Private helper functions and internal structure MAY be renamed, extracted, reordered, or reformatted freely; the registered `pq_*` surface (names, args, returns, flags, error replies) is untouched.
- Q: Are the documentation and the historical specs touched? → A: **Docs only if a documented detail genuinely changes** — for a behaviour-preserving refactor they should be materially unchanged, but are re-verified for accuracy. Historical specs 001–007 are frozen point-in-time records and are not edited.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Refactor and optimise the Lua library (Priority: P1) 🎯 MVP

A maintainer reviews the single production artifact — `src/functions/priority_queue.lua` — and improves it along all three quality dimensions **at once**: it reads more clearly (consistent naming, extracted private helpers, accurate comments), carries **no dead code** (no unused locals, unreachable branches, or redundant work), and **runs faster** on the shard (hot globals localised, redundant `redis.call`/table rebuilds removed, loops tightened). Not one byte of observable behaviour changes: every `pq_*` function returns exactly what Feature 007 returned, for every input, on every engine and topology.

**Why this priority**: The library is the *only* deliverable of this project — the test suites merely verify it — and it is the hot path that blocks its shard while running. Improving it is the single most valuable outcome, and it is the only place goal 3 (Lua performance) applies. It is independently shippable: refactor the library, watch all three suites stay green, and the feature has already delivered its core value even if no test-suite tidy-up follows.

**Independent Test**: Load the refactored `priority_queue.lua` on redis and valkey (standalone + cluster) and run all three existing suites unchanged; confirm identical assertion/case totals with zero failures — the suites assert the observable replies (fields, values, `PQ` error code + detail, status strings), so green suites prove byte-for-byte equivalence (no separate output-diff harness is built, per the clarified verification). Inspect the file for localised globals, absence of dead code, and unchanged per-function command counts. Run the documented timing workload against both the refactored and Feature 007 libraries on the same host + engine and confirm no execution-time regression.

**Acceptance Scenarios**:

1. **Given** the refactored library, **When** it is loaded with `FUNCTION LOAD`, **Then** `FUNCTION LIST` reports library name `priority_queue` with exactly the 11 functions `pq_create`, `pq_read`, `pq_validate`, `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`, `pq_peek`, `pq_redrive`, `pq_reap`, `pq_stats`, and the same `no-writes` flags as before.
2. **Given** identical inputs, **When** any `pq_*` function is called, **Then** the returned fields, order, values, and any `PQ E…` error reply (**code and detail text**) are byte-for-byte identical to the Feature 007 output.
3. **Given** the refactored file, **When** it is inspected, **Then** hot globals (`redis.call`, `redis.error_reply`, `tonumber`, `string.format`, …) are bound to locals, there are no unused locals or unreachable branches, and the number of `redis.call` invocations per function is unchanged or lower — never higher.
4. **Given** the static portability/determinism gate, **When** it runs against the refactored file, **Then** it passes unchanged (restricted-command scan, hardcoded-literal-key scan, determinism scan, command whitelist, and `require`/dependency scan), with the runtime dependency set still empty. (The `no-writes`/`FCALL_RO` guarantee is verified at runtime — via `FUNCTION LIST` flags and the suites asserting write functions are rejected under `FCALL_RO` — see Scenario 1, not the static gate.)
5. **Given** the documented timing workload, **When** it is run against the refactored library and the Feature 007 baseline on the same host + engine, **Then** the refactored library shows no execution-time regression beyond the stated noise tolerance (and ideally a measurable improvement).

---

### User Story 2 - Tidy the Bash reference suite (Priority: P2)

A maintainer reviews `test_bash/` (the source-of-truth suite) for readability and dead code: consistent naming, shared harness helpers instead of copy-pasted blocks, accurate comments, and removal of unused variables and unreachable code — **without changing any expected value or dropping any assertion**. The suite keeps its 832-assertion total and stays green.

**Why this priority**: The Bash suite is the reference the Java and Python suites mirror; keeping it the trustworthy, readable source of truth comes before tidying its siblings. It is independently deliverable and testable.

**Independent Test**: Run `test_bash/run_all.sh` on redis and valkey (plus the cluster smoke) and confirm the **same 832-assertion total** with zero failures after the tidy-up.

**Acceptance Scenarios**:

1. **Given** the tidied Bash suite, **When** `run_all.sh` runs on both engines, **Then** the assertion total and pass/fail counts equal the Feature 007 baseline (832 / 0).
2. **Given** the tidied harness (`docker_engines.sh`, `load_and_call.sh`, `static_checks.sh`), **When** a suite `source`s a relative harness path, **Then** it still resolves and the static gate still finds `src/functions/priority_queue.lua`.
3. **Given** the tidied suite, **When** it is inspected, **Then** no unused shell variable or unreachable branch remains, and shared setup logic is factored into harness helpers rather than duplicated per file.

---

### User Story 3 - Tidy the Java parity suite (Priority: P3)

A maintainer reviews `test_java/` for readability and dead code: consistent naming, shared `support/` base classes/helpers instead of duplication, removal of unused imports/locals/fields — while every mirrored case, its expected values, and the engine × topology parameterization are preserved. `mvn test` keeps its 268-test result (10 standalone-only skips) and stays green.

**Why this priority**: Applies the same quality bar to the first polyglot suite; independent of the Python tidy-up and of the library refactor.

**Independent Test**: With the engines up, run `mvn test` in `test_java/` on both engines in both topologies and confirm the same test/skip totals with zero failures.

**Acceptance Scenarios**:

1. **Given** the tidied Java suite, **When** `mvn test` runs, **Then** the executed test count, skip count, and pass/fail equal the Feature 007 baseline (268 run, 10 skipped, 0 failed).
2. **Given** the tidied suite, **When** it is compiled and inspected, **Then** there are no unused imports, locals, or private fields/methods, and duplicated client/assertion logic is consolidated into `support/` helpers.
3. **Given** framework-driven symbols (JUnit lifecycle methods, `@ParameterizedTest` argument sources), **When** dead-code removal is applied, **Then** these are retained (they are not "unused"), and the engine × topology matrix is unchanged.

---

### User Story 4 - Tidy the Python parity suite (Priority: P4)

A maintainer reviews `test_python/` for readability and dead code: consistent naming, shared `conftest.py`/support helpers instead of duplication, removal of unused imports/locals — while every mirrored case, its expected values, and the fixtures' engine × topology parameterization are preserved. `pytest` keeps its 258-passed result (10 skips) and stays green.

**Why this priority**: Completes the same quality bar across the third suite; independent of the others.

**Independent Test**: With the engines up, run `pytest` in `test_python/` on both engines in both topologies and confirm the same passed/skipped totals with zero failures.

**Acceptance Scenarios**:

1. **Given** the tidied Python suite, **When** `pytest` runs, **Then** passed/skipped/failed equal the Feature 007 baseline (258 passed, 10 skipped, 0 failed).
2. **Given** the tidied suite, **When** it is inspected/linted, **Then** there are no unused imports or locals, and duplicated client/assertion logic is consolidated into `conftest.py` or a support module.
3. **Given** pytest "magic" symbols (fixtures consumed by name injection, `parametrize` params), **When** dead-code removal is applied, **Then** these are retained and the engine × topology matrix is unchanged.

---

### Edge Cases

- **Readability edit silently changes the contract**: an innocent reword of a `PQ E…` error's *detail text*, a field name, or a status reply would break the frozen suites. Error replies (**code and detail**), field names/order, and status strings are part of the frozen contract — the suites MUST catch any drift.
- **A "global" that must not be localised**: `KEYS`, `ARGV`, and `redis` itself must keep their semantics; localisation is limited to genuinely repeated global *lookups* (e.g. `local rcall = redis.call`) and must be semantically identical.
- **A local that only *looks* unused**: values captured by a closure, used only on an error path, or referenced later must not be removed; removal is proven safe by the green suites, not by eyeballing.
- **Framework "magic" is not dead code**: pytest fixtures (used by name injection), JUnit lifecycle/`@ParameterizedTest` source methods, and Bash harness entrypoints appear unreferenced but MUST be retained.
- **Aggressive dedup erodes coverage**: the chosen aggressive consolidation of duplicated test logic into shared base classes/fixtures/helpers must not reduce the number of engine × topology combinations exercised, nor collapse two distinct assertions into one — the frozen per-suite totals (FR-003) are the backstop.
- **Helper extraction breaks cluster co-location**: any extracted key-building helper in the suites must preserve hash-tag co-location, or cluster mode will raise `CROSSSLOT`.
- **Formatting touches a load-bearing line**: reformatting `priority_queue.lua` must not alter the `#!lua name=priority_queue` shebang or the exact tokens the library-name/flag assertions check.
- **Performance vs. readability conflict**: when a micro-optimisation would obscure the code, behaviour-freeze is absolute and clarity is preferred — an optimisation is applied only when it is behaviour-neutral and either improves or does not harm readability, or its gain is substantial and documented.
- **Command-count creep**: an optimisation that *adds* a `redis.call` (or a round trip) to "simplify" logic violates Principle VI and is rejected, even if it reads better.
- **Fail-before-write preserved**: reordering work inside a write function must keep every validation ahead of the first write, so any error still leaves nothing written.

## Requirements *(mandatory)*

### Functional Requirements

**Behaviour & contract freeze (cross-cutting invariant)**

- **FR-001**: The runtime behaviour of every `pq_*` function MUST be unchanged — `KEYS`/`ARGV` contract, field set and order, priority/score encoding, return shapes, decision logic, and every error reply (**`PQ` code and detail text**) MUST be byte-for-byte identical to the Feature 007 library. No new command, field, argument, or behaviour is introduced.
- **FR-002**: The public contract MUST be frozen: the library name `priority_queue`, the shebang `#!lua name=priority_queue`, the 11 registered `pq_*` function names, their `no-writes` flags and `FCALL_RO`-callability, and the `PQ <CODE>: <detail>` error convention MUST NOT change.
- **FR-003**: The three existing suites remain the regression guard: each MUST retain its Feature 007 assertion/case coverage and totals (Bash 832 assertions / 0 failed; Java 268 run / 10 skipped / 0 failed; Python 258 passed / 10 skipped / 0 failed). Refactoring a suite MAY change only its internal structure and readability — never an expected value, never the set of scenarios covered, never a per-suite total.

**Goal 1 — Ease of reading & maintenance (all four codebases)**

- **FR-004**: Naming MUST be made consistent within each codebase following one documented convention per language; misleading or cryptic identifiers MUST be improved.
- **FR-005**: Duplicated multi-line logic MUST be **actively consolidated and deduplicated** into shared helpers, maximising reuse — Lua private helpers; Bash harness helpers; Java `support/` base classes/helpers; Python `conftest.py` fixtures/support module — provided every change is behaviour-preserving and the frozen suite coverage (FR-003) is fully retained.
- **FR-006**: Comments MUST be accurate and non-redundant: stale or misleading comments removed, a concise contract comment retained/added for each registered `pq_*` function, and comments that merely restate the code removed.
- **FR-007**: Internal (non-public) structure MAY be reorganised for clarity — private Lua helpers renamed/extracted/reordered; test files re-sectioned — provided the frozen public contract (FR-002) and the frozen suite coverage (FR-003) are untouched.

**Goal 2 — Minimal / no unused code (all four codebases)**

- **FR-008**: All dead code MUST be removed across `priority_queue.lua`, `test_bash/`, `test_java/`, and `test_python/`: unused local variables, unused private/helper functions, unused imports (Java/Python), unreachable branches, redundant computations, and commented-out code.
- **FR-009**: Dead-code removal MUST NOT drop any executed assertion, scenario, or engine × topology combination (guaranteed by FR-003), and MUST retain framework-driven symbols that only appear unused (pytest fixtures, JUnit lifecycle/parameterized-source methods, Bash harness entrypoints).

**Goal 3 — Lua performance (library only)**

- **FR-010**: Frequently-referenced globals (e.g. `redis.call`, `redis.error_reply`, `redis.status_reply`, `tonumber`, `tostring`, `string.format`, `string.sub`) MUST be bound to locals to avoid repeated global-table lookups, where doing so does not harm clarity.
- **FR-011**: Redundant work MUST be eliminated: no repeated `redis.call` for a value already in scope, no rebuilding a table that can be built once, and per-iteration allocations in loops reduced where feasible.
- **FR-012**: Every optimisation MUST preserve atomicity and the single round trip (Principle VI): the per-function command set and count MUST NOT increase, no client round trip may be added, and `no-writes` flags / replication determinism (Principle VII) MUST be unchanged. Fail-before-write ordering MUST be preserved.
- **FR-013**: A lightweight, repeatable timing measurement — a fixed representative `FCALL` workload at a fixed iteration count, run on the same host + engine before and after — MUST be used as a **pass/fail gate**: the refactored library MUST show no execution-time regression beyond a stated noise tolerance versus the Feature 007 baseline, and SHOULD show a measurable improvement. The measurement MUST reuse only the existing clients/harness (no new benchmark framework or dependency).
- **FR-014**: Every optimisation MUST preserve portability (Principle III): only commands/options available on all four targets, no engine-specific construct introduced.

**Governance / constitution**

- **FR-015**: The library's runtime dependency set MUST remain empty (only `redis.*` + the Lua standard library) — Principle II — and no new test dependency, linter, or framework is added to satisfy this feature (the performance-timing gate of FR-013 reuses the existing clients/harness).
- **FR-016**: The static portability/determinism gate and all constitution static checks MUST continue to pass unchanged (restricted-command scan per Principle V, hardcoded-literal-key scan per Principle IV, determinism scan — no `TIME`/`math.random` — per Principle VII, `require`/dependency scan per Principle II, and the command whitelist). The `no-writes`/`FCALL_RO` guarantee (Principle VII) is verified at **runtime** — `FUNCTION LIST` flags unchanged and the suites assert write functions are rejected under `FCALL_RO` — not by the static gate.
- **FR-017**: Documentation currency (Principle X): if any refactor changes a documented detail — it should not, for a behaviour-preserving change — then `README.md`, `docs/schema.md`, and `docs/functions.md` MUST be updated in the same feature; otherwise they MUST be re-verified as accurate and left unchanged.

### Key Entities *(include if feature involves data)*

- **Lua Functions library (`src/functions/priority_queue.lua`)**: the sole production artifact and the only subject of goal 3. Internal structure is refactorable; the registered `pq_*` surface is frozen.
- **Bash reference suite (`test_bash/`)**: source-of-truth regression guard — `harness/`, `contract/`, `integration/`, `unit/`, `run_all.sh`. Structure refactorable; assertion semantics/count frozen (832).
- **Java parity suite (`test_java/`)**: Maven/JUnit 5/Jedis suite. Structure refactorable; case coverage and totals frozen (268 run / 10 skip).
- **Python parity suite (`test_python/`)**: pytest/redis-py suite. Structure refactorable; case coverage and totals frozen (258 passed / 10 skip).
- **Behaviour baseline**: the merged Feature 007 library output — the reference for byte-for-byte equivalence.
- **Constitution static gates**: the portability/determinism/restricted-command/key-construction checks that MUST stay green.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After the refactor, all three suites pass on redis **and** valkey, in standalone **and** cluster mode, at their exact Feature 007 totals — Bash 832 assertions / 0 failed; Java 268 run / 10 skipped / 0 failed; Python 258 passed / 10 skipped / 0 failed.
- **SC-002**: For identical inputs, every `pq_*` function returns byte-for-byte identical replies (fields, order, values, and `PQ` error code + detail text) to the Feature 007 library — zero behavioural change.
- **SC-003**: Zero unused code remains — no unused local, private function, import, unreachable branch, or redundant computation in any of the four codebases (verifiable by language-appropriate inspection), while all framework-driven symbols are retained.
- **SC-004**: In `priority_queue.lua`, hot globals are localised and the number of `redis.call` invocations per function is unchanged or lower than Feature 007 (never higher); **and** the timing measurement over the documented workload shows no execution-time regression versus the Feature 007 baseline beyond the stated noise tolerance — a measurable, repeatable pass/fail gate.
- **SC-005**: Duplicated multi-line logic blocks are consolidated — the count of copy-pasted setup/assertion blocks across each suite is reduced (ideally to zero) via shared helpers, with no loss of coverage.
- **SC-006**: The static portability/determinism gate and all constitution static checks pass unchanged, and the library's runtime dependency set remains empty.
- **SC-007**: Developer documentation (`README.md`, `docs/schema.md`, `docs/functions.md`) still accurately describes the library; a re-verification finds no drift introduced by the refactor.

## Assumptions

- **No behavioural or contract change** — this is a pure, behaviour-preserving refactor in the spirit of Feature 007; the frozen suites are the proof.
- **Error replies (code AND detail text) are part of the frozen contract**, because the suites assert on them; they are not eligible for "readability" edits.
- **Only internal/private symbols and structure are refactorable**; the 11 registered `pq_*` functions and their `KEYS`/`ARGV`/return/flags/error replies are frozen.
- **Lua performance is verified by a measured timing gate** — apply documented Lua-in-Redis best practices (localise hot globals, remove redundant `redis.call`/table rebuilds, tighten loops) so per-function command counts never increase, **and** run a lightweight, repeatable timing measurement (fixed workload + iteration count, same host + engine, before vs. after) that is a pass/fail gate: no regression beyond a stated noise tolerance, improvement targeted. The measurement reuses only the existing clients/harness — **no new benchmark framework or dependency is added** (Principle II).
- **Test-suite restructuring is aggressive** — shared base classes/fixtures/harness helpers are extracted and duplication is removed heavily across all three suites, with the frozen per-suite totals and engine × topology matrix (FR-003) as the absolute backstop.
- **No new verification tooling** — behavioural equivalence is proven by the existing suites at their frozen totals and dead code by manual review; no linters or output-diff harness are introduced (the only added measurement anywhere is the minimal performance-timing step of FR-013).
- **Test-framework "magic" symbols are not dead code**: pytest fixtures, JUnit lifecycle/parameterized-source methods, and Bash harness entrypoints are retained even when they appear unreferenced.
- **The Feature 007 baseline totals are the exact regression target**: Bash 832 assertions; Java 268 run with 10 intentional standalone-only skips (cross-slot `ETAG` checks); Python 258 passed with 10 skips.
- **When readability and micro-performance conflict**, behaviour-freeze is absolute and clarity is preferred unless a performance gain is substantial and documented.
- **No constitution change is expected** (a behaviour-preserving refactor already satisfies every principle); this is confirmed at the `/speckit-plan` Constitution Check gate.
- **Historical specs 001–007 are frozen** point-in-time records and are not edited by this feature.
- **Environment is unchanged from Feature 007**: Docker; JDK 25 toolchain; Python 3.11+; the shared `engines.env` pins (`redis:7.4`, `valkey/valkey:8.0`) and published host ports; engines brought up before the Java/Python suites run.
