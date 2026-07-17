---
description: "Task list for Feature 008 — Code-Quality Review & Refactor"
---

# Tasks: Code-Quality Review & Refactor (Lua + Bash + Java + Python)

**Input**: Design documents from `/specs/008-code-quality-refactor/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/frozen-surface.md, quickstart.md

**Tests**: No test tasks are authored. This is a **behaviour-preserving refactor** — the three existing
suites (`test_bash/`, `test_java/`, `test_python/`) are the frozen regression guard. "Verify" tasks
**run** them at their Feature 007 totals; they are never rewritten to change an expected value.

**Frozen totals (the guard):** Bash **832** assertions / 0 failed · Java **268** run / 10 skipped / 0 ·
Python **258** passed / 10 skipped / 0 — on **redis + valkey**, **standalone + cluster**.

**Organization**: Tasks are grouped by user story (US1 Lua library, US2 Bash, US3 Java, US4 Python) so
each is independently implementable and verifiable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4 (Setup/Foundational/Polish carry no story label)

---

## Phase 1: Setup & Baseline (Shared Infrastructure)

**Purpose**: Bring engines up and capture the two baselines the whole feature is measured against.

- [X] T001 Bring both engines up standalone **and** cluster: `test_bash/harness/docker_engines.sh up` then `test_bash/harness/docker_engines.sh cluster-up` (prerequisite for every suite run and the timing gate).
- [X] T002 Record the **regression baseline** (Bash run fresh = 832/0; Java 268/10-skip & Python 258/10-skip are the documented F007 baseline, re-confirmed post-refactor) — run `test_bash/run_all.sh`, `(cd test_java && mvn test)`, and `(cd test_python && . .venv/bin/activate && pytest -q)` on redis + valkey (standalone + cluster); confirm and note the frozen totals (Bash 832/0, Java 268/10/0, Python 258/10/0) in the feature dir as the guard reference.
- [X] T003 [P] Capture the **performance baseline** — save the merged Feature 007 library (`git show HEAD:src/functions/priority_queue.lua`) to a scratch path, and record the current static hot-global counts in `src/functions/priority_queue.lua` (`redis.call` 71, `redis.error_reply` 66, `tonumber` 40, `redis.status_reply` 10) as the "must-not-increase" reference.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The measurement helper the US1 performance gate depends on. Reuses existing clients only.

**⚠️ CRITICAL**: The US1 perf gate (T012) cannot run until this is complete.

- [X] T004 Create the timing-measurement helper `test_bash/harness/bench_pq.sh` — reuses `redis-cli` to `FUNCTION LOAD` a given library file and run a fixed hot-path workload (`pq_enqueue`→`pq_dequeue`→`pq_ack` cycle + representative `pq_read`/`pq_peek`/`pq_stats`/`pq_nack`), **N ≥ 1000** timed iterations after **≥ 100** warm-up iterations, reporting p50/p90 per engine and asserting `candidate_p50 ≤ baseline_p50 × 1.05` (5% band, env-overridable). No new dependency (redis-cli only).

**Checkpoint**: Baselines recorded and the perf harness exists — user-story work can begin.

---

## Phase 3: User Story 1 - Refactor & optimise the Lua library (Priority: P1) 🎯 MVP

**Goal**: Improve `src/functions/priority_queue.lua` on all three quality axes (readability, zero dead
code, performance) with **zero** change to the public `pq_*` surface, returns, flags, or `PQ` error
strings.

**Independent Test**: Reload the refactored library; all three suites stay green at frozen totals on both
engines and both topologies; `FUNCTION LIST` names/flags unchanged; the perf gate shows p50 no-regression.

> All Phase 3 edits are to the single file `src/functions/priority_queue.lua`, so they are **sequential**
> (not `[P]`). The frozen surface is defined in `contracts/frozen-surface.md`.

- [X] T005 [US1] Localise hot globals at the top of `src/functions/priority_queue.lua` (`local rcall = redis.call`, `rerr = redis.error_reply`, `rstatus = redis.status_reply`, `tonumber`, `tostring`, `sformat = string.format`, `ssub = string.sub`) and replace every reference, preserving semantics.
- [X] T006 [US1] (assessed: no genuine redundant redis.call — each fetches a distinct value; no change) Remove redundant `redis.call`s in `src/functions/priority_queue.lua` — reuse in-scope values (esp. `pq_dequeue` scan→acquire, `pq_peek` top-N loop, `pq_stats` breakdown loop, `pq_reap` delete loop); the per-function `redis.call` count MUST NOT increase vs the T003 baseline.
- [X] T007 [US1] (assessed: return arrays already built once; no change) Build each function's return array once (fill by index) in `src/functions/priority_queue.lua`; remove intermediate/discarded tables in the read/peek/stats shapes.
- [X] T008 [US1] (localization hoisted global lookups; loops already tight) Tighten scan loops in `src/functions/priority_queue.lua` — hoist invariants (field lists, localised calls, key prefixes) out of loop bodies.
- [X] T009 [US1] (assessed: naming/comments already clear + accurate; no churn warranted) Improve readability of `src/functions/priority_queue.lua` — extract/rename private helpers (`is_int`, `hash_tag`, `lease_available`, `is_visible`, `encode_field`, `parse_args`, `build_message`), consistent local naming, accurate/non-redundant comments; the registered `pq_*` surface, returns, flags, and `PQ` error strings stay byte-for-byte frozen.
- [X] T010 [US1] (dead-code scan: none found; only used locals added) Remove dead code in `src/functions/priority_queue.lua` — unused locals, unreachable branches, redundant computation, stale/commented-out code.
- [X] T011 [US1] Verify freeze — run `test_bash/harness/static_checks.sh` (green); reload the library and run all three suites on redis + valkey (standalone + cluster); confirm `FUNCTION LIST` names/flags unchanged and every suite at its frozen total (Bash 832/0, Java 268/10/0, Python 258/10/0).
- [X] T012 [US1] Run the **performance gate** — `test_bash/harness/bench_pq.sh` comparing the T003 baseline library vs the refactored one on redis + valkey; assert p50 no-regression (≤ ×1.05), record the delta, and confirm hot globals localised + per-function `redis.call` counts not increased.

**Checkpoint**: Library refactored, optimised, behaviour/contract frozen, perf gate green → **MVP shippable**.

---

## Phase 4: User Story 2 - Tidy the Bash reference suite (Priority: P2)

**Goal**: Readability + zero dead code in `test_bash/`, with aggressive shared helpers; expected values
and the 832-assertion total frozen.

**Independent Test**: `test_bash/run_all.sh` on both engines → 832 / 0 unchanged; cluster smoke passes.

- [X] T013 [US2] Consolidate shared assertion/setup/key-builder helpers into `test_bash/harness/load_and_call.sh` (dedupe `docker_engines.sh`/`static_checks.sh` where duplication is obvious) and update `test_bash/{contract,integration,unit}/*.sh` to use them.
- [X] T014 [US2] Remove dead code + stale comments and apply consistent naming across `test_bash/harness/*.sh` and `test_bash/{contract,integration,unit}/*.sh`; retain harness entrypoints; keep every expected value frozen.
- [X] T015 [US2] (Bash 832/0 preserved after dedup) Verify — `test_bash/run_all.sh` on redis + valkey → 832 assertions / 0 failed unchanged; run the cluster smoke per `quickstart.md`.

**Checkpoint**: Bash suite tidied; source-of-truth totals preserved.

---

## Phase 5: User Story 3 - Tidy the Java parity suite (Priority: P3)

**Goal**: Readability + zero dead code in `test_java/`, with aggressive dedup into a shared base class +
`support/`; 268 run / 10 skip frozen.

**Independent Test**: `(cd test_java && mvn test)` on both engines both topologies → 268 / 10 skip / 0.

- [X] T016 [US3] (chose Pq.connect() helper over base class — safer, same connect+load dedup) Add a shared abstract base test class `test_java/src/test/java/pq/support/PqTestBase.java` and expand `support/{Engines,Pq,Repo}.java` to absorb duplicated client wiring, the engine × topology provider, `FUNCTION LOAD`, and typed-reply assertions.
- [X] T017 [US3] (66/67 Pq.load lines removed; 1 preserved in FunctionFlagsTest which asserts load's return) Refactor the 36 classes in `test_java/src/test/java/pq/{contract,integration,unit}/` to extend `PqTestBase`; remove unused imports/locals/fields and stale/redundant comments; consistent naming; retain JUnit lifecycle + `@ParameterizedTest` sources. (Individual class files are independent → parallelizable among themselves once T016 lands.)
- [X] T018 [US3] Verify (268 run / 10 skipped / 0 failed, standalone + cluster) — `(cd test_java && mvn test)` on both engines in both topologies → 268 run / 10 skipped / 0 failed unchanged.

**Checkpoint**: Java suite tidied; totals preserved.

---

## Phase 6: User Story 4 - Tidy the Python parity suite (Priority: P4)

**Goal**: Readability + zero dead code in `test_python/`, with aggressive dedup into `conftest.py` +
`pqsupport.py`; 258 passed / 10 skip frozen.

**Independent Test**: `(cd test_python && pytest -q)` on both engines both topologies → 258 / 10 skip / 0.

- [X] T019 [US4] (assessed: suite already maximally deduped via conftest `client` fixture + pqsupport; nothing to add) Expand `test_python/conftest.py` fixtures and `test_python/pqsupport.py` helpers to absorb duplicated setup/client/assertion logic; use `@pytest.mark.parametrize` for repeated case tables.
- [X] T020 [US4] (dead-code scan: zero unused imports/locals; no change needed) Refactor the 36 modules in `test_python/{contract,integration,unit}/` to use the shared fixtures/helpers; remove unused imports/locals and stale/redundant comments; consistent naming; retain fixtures (used by name injection). (Individual modules are independent → parallelizable among themselves once T019 lands.)
- [X] T021 [US4] Verify (258 passed / 10 skipped / 0 failed, standalone + cluster) — `(cd test_python && pytest -q)` on both engines in both topologies → 258 passed / 10 skipped / 0 failed unchanged.

**Checkpoint**: Python suite tidied; totals preserved.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Whole-repo verification of the three goals and the constitution gates.

- [X] T022 [P] Re-verify documentation accuracy vs the refactored library — `README.md`, `docs/schema.md`, `docs/functions.md`; update only a genuinely drifted detail (expected: none, per FR-017).
- [X] T023 [P] (library: none; Bash: boilerplate removed; Java/Python: zero unused imports; framework symbols retained) Zero-unused-code sweep across all four codebases (grep-assisted review per `quickstart.md` §5); confirm framework symbols retained (pytest fixtures, JUnit lifecycle/sources, Bash entrypoints).
- [X] T024 [P] (pom.xml & requirements.txt unchanged; library require()=0) Confirm **no new dependency/tooling** — `test_java/pom.xml` and `test_python/requirements.txt` unchanged; library runtime deps still empty (`static_checks.sh`); `git diff` shows no added dependency or linter.
- [X] T025 Final regression sweep (Bash 832/0 · Java 268/10skip/0 · Python 258/10skip/0 · static gate green · perf gate no-regression · no new dependency) (Definition of Done) — all three suites at frozen totals (redis + valkey, standalone + cluster) + `test_bash/harness/static_checks.sh` + the `bench_pq.sh` perf gate, all green together per `quickstart.md`.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: T001 first (engines up); T002 needs T001; **T003 [P]** can run alongside T001/T002 (no engine needed).
- **Foundational (Phase 2)**: T004 after Setup — blocks the US1 perf gate (T012).
- **US1 (Phase 3)**: after Foundational — the MVP; do first.
- **US2 / US3 / US4 (Phases 4–6)**: each depends only on Foundational; they touch disjoint directories, so **all three run in parallel** with each other. Best sequenced after US1 so they verify the refactored library.
- **Polish (Phase 7)**: after all desired user stories; T025 last.

### Within each story

- **US1**: T005 → T006 → T007 → T008 → T009 → T010 → T011 → T012 (all same file → sequential).
- **US2**: T013 → T014 → T015.
- **US3**: T016 (base class) → T017 (36 classes, mutually [P]) → T018.
- **US4**: T019 (shared modules) → T020 (36 modules, mutually [P]) → T021.

### Parallel opportunities

- T003 ∥ T001/T002 (Setup).
- Whole phases **US2 ∥ US3 ∥ US4** (disjoint dirs) once US1 is done.
- Within US3/US4: the 36 per-language files are mutually [P] after their shared module (T016 / T019) lands.
- Polish **T022 ∥ T023 ∥ T024**; then T025.

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Phase 1 Setup & Baseline → 2. Phase 2 Foundational → 3. Phase 3 US1 (library refactor + optimise).
4. **STOP and VALIDATE**: suites green at frozen totals + perf gate green → the production artifact is
   improved and provably behaviour-frozen. Ship/demo.

### Incremental delivery

US1 (library) → US2 (Bash) → US3 (Java) → US4 (Python) → Polish. Each story is an independent increment
that keeps every suite green.

### Parallel team strategy

After US1, Developer A: US2 (Bash), Developer B: US3 (Java), Developer C: US4 (Python) — disjoint trees,
no cross-story conflicts.

---

## Notes

- [P] = different files, no dependency on an incomplete task.
- The library (US1) is the only production artifact and the only place goal 3 (performance) applies.
- Every "Verify" task asserts the **frozen totals** — a changed total means a behaviour/contract change
  and is a defect (see `contracts/frozen-surface.md`).
- No new dependency, linter, or benchmark framework is introduced; the only added measurement is
  `bench_pq.sh` (redis-cli only), per the clarified performance gate.
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
