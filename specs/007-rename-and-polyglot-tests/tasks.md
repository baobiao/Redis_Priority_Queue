---
description: "Task list for Feature 007 — Rename to priority_queue and Polyglot Test Parity"
---

# Tasks: Rename to priority_queue and Polyglot Test Parity

**Input**: Design documents from `/specs/007-rename-and-polyglot-tests/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md, quickstart.md

**Tests**: This feature *is* test infrastructure. For US1/US2 the Bash tests already exist and are
edited (behaviour frozen). For US3/US4 the Java/Python test suites ARE the deliverable — the library
behaviour predates them, so there is nothing to author test-first against; the suites mirror the
already-green Bash suite (the source of truth for expected values).

**Organization**: By user story. US1 (rename) is the MVP. US2 (relocate) follows. US3 (Java) and US4
(Python) are independent of each other and depend on the Foundational harness change + US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1 / US2 / US3 / US4 (Setup/Foundational/Polish carry no story label)

---

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Create repo-root `engines.env` with `REDIS_IMAGE=redis:7.4`, `VALKEY_IMAGE=valkey/valkey:8.0`, `REDIS_PORT=7379`, `VALKEY_PORT=7380`, `REDIS_CLUSTER_PORT=7381`, `VALKEY_CLUSTER_PORT=7382` (all env-overridable; KEY=VALUE so Bash/Java-Properties/Python can all read it)
- [x] T002 [P] Update `.gitignore`: add `test_java/target/`, `**/__pycache__/`, `.pytest_cache/`, `test_python/.venv/` (the `tests/.artifacts/` → `test_bash/.artifacts/` line is handled in US2/T014)

---

## Phase 2: Foundational (Blocking prerequisites for the polyglot suites)

**⚠️ Blocks US3 + US4 only.** US1/US2 (the Bash-world rename + relocate) do NOT depend on this phase.
Note: `docker_engines.sh` is also edited by US1 (container names) and moved by US2 — edit it
sequentially; the final state must include both the pq-* names and the port publishing.

- [x] T003 In `docker_engines.sh`, source the shared constants from `"$HERE/../../engines.env"` (repo root; resolves correctly both before and after the `tests/`→`test_bash/` move — env still overrides), and publish standalone ports: `docker run … -p "${REDIS_PORT}:6379"` for redis and `-p "${VALKEY_PORT}:6379"` for valkey. Additive — the existing `docker exec` path (`engine_cli`, `load_library`) is untouched so the Bash suite stays green.
- [x] T004 In `docker_engines.sh` cluster bring-up, publish each engine's cluster data port and start the node with `--cluster-announce-ip 127.0.0.1 --cluster-announce-port "${REDIS_CLUSTER_PORT}"` (redis) / `"${VALKEY_CLUSTER_PORT}"` (valkey), plus a published + announced bus port (data `+10000`), so `CLUSTER SLOTS` advertises a host-reachable address for `JedisCluster`/`RedisCluster`. Single node still owns all 16384 slots. **(Primary technical risk — validate early: `redis-cli -p ${REDIS_CLUSTER_PORT} cluster slots` from the host must show `127.0.0.1`.)**

**Checkpoint**: `docker_engines.sh up` / `cluster-up` expose host-reachable ports; Bash suite unaffected.

---

## Phase 3: User Story 1 — Full rename to priority_queue (Priority: P1) 🎯 MVP

**Goal**: The library and every current (non-folder) reference speak `priority_queue` / `pq_*` / `PQ …`,
with zero behavioural change.

**Independent Test**: Load `priority_queue.lua` on both engines; `FUNCTION LIST` shows library
`priority_queue` + 11 `pq_*`; the Bash suite (still under `tests/`) passes with `pq_`/`PQ`; static gate
green on `priority_queue.lua`.

- [x] T005 [US1] `git mv src/functions/message_format.lua src/functions/priority_queue.lua`
- [x] T006 [US1] In `src/functions/priority_queue.lua`: shebang → `#!lua name=priority_queue`; header comment; all 11 `redis.register_function` names `msgfmt_*` → `pq_*`; all internal function definitions + call sites `msgfmt_*` → `pq_*`; every `redis.error_reply("MSGFMT <CODE>: …")` → `"PQ <CODE>: …"`. **Preserve every existing error CODE and detail string verbatim** — only the leading `MSGFMT`→`PQ` token changes. No other logic changes.
- [x] T007 [US1] Update harness library/name references: `tests/harness/load_and_call.sh` LIB_PATH default → `priority_queue.lua` (+ header comment); `tests/harness/static_checks.sh` LIB default → `priority_queue.lua` (+ de-`msgfmt` comments); `tests/harness/docker_engines.sh` header + container names/env defaults `msgfmt-*` → `pq-*`; `tests/run_all.sh` header comment
- [x] T008 [P] [US1] `git mv` Bash test filenames `test_msgfmt_*` → `test_pq_*` across `tests/contract/`, `tests/integration/`, `tests/unit/` (keep `test_function_flags.sh`) — 35 files renamed
- [x] T009 [US1] Update Bash test CONTENT (all suites): `FCALL`/`FCALL_RO msgfmt_*` → `pq_*`; `MSGFMT` assertions → `PQ`; in `tests/contract/test_function_flags.sh` the library-name assertion `message_format` → `priority_queue`; any `msgfmt` in labels/comments
- [x] T010 [P] [US1] Update developer docs `README.md`, `docs/schema.md`, `docs/functions.md`: library file path, library name, all `msgfmt_*` → `pq_*`, `MSGFMT` → `PQ` (Principle X)
- [x] T011 [P] [US1] Sweep remaining current-code references: confirm `CLAUDE.md` and `.specify/feature.json` carry no `msgfmt`/`message_format`; fix any other non-historical match a `grep -rIn message_format\|msgfmt\|MSGFMT` (excluding `specs/001-006`) surfaces
- [x] T012 [US1] Verify US1: `tests/harness/docker_engines.sh up`; load `priority_queue.lua`; `FUNCTION LIST` shows `priority_queue` + `pq_*`; run `tests/run_all.sh` on redis+valkey → same assertion total (832), 0 failed; `tests/harness/static_checks.sh` green

**Checkpoint**: Library renamed end-to-end; Bash suite green on `pq_`/`PQ` (still under `tests/`).

---

## Phase 4: User Story 2 — Relocate the Bash suite to test_bash/ (Priority: P2)

**Goal**: `tests/` → `test_bash/`, structure preserved, every suite green, all path references updated.

**Independent Test**: `test_bash/run_all.sh` passes on both engines with the same assertion total; no
stale `tests/` path resolves in current code/docs/config.

- [x] T013 [US2] `git mv tests test_bash` (preserves internal structure + history)
- [x] T014 [US2] Update `tests/` path references: `README.md` (lines ~250,253,256,259,262,265,280) and any `docs/**` mentions → `test_bash/`; **`.claude/settings.local.json` — fully update all 9 allowlist entries (lines 10–14,20,21,28,29) `tests/…` → `test_bash/…`, INCLUDING the line-28 `test_msgfmt_*` filenames → `test_pq_*` (renamed in T008)**; `.gitignore` `tests/.artifacts/` → `test_bash/.artifacts/`. (`run_all.sh` globs + harness `source`/LIB paths are relative → no change.)
- [x] T015 [US2] Verify US2: `test_bash/run_all.sh` on redis+valkey → same total (832), 0 failed; confirm relative `source` (`…/../harness/load_and_call.sh`) and static-gate LIB default resolve from the new location

**Checkpoint**: Bash world fully renamed + relocated + green.

---

## Phase 5: User Story 3 — Java parity suite (Priority: P3)

**Goal**: `mvn test` under `test_java/` mirrors every Bash suite 1-to-1 against both engines, standalone
+ cluster, via Jedis.

**Independent Test**: With the harness up (ports), `mvn test` passes on redis+valkey (standalone +
cluster); typed replies, `PQ E…` errors, FCALL_RO-on-write rejection, and cluster no-`CROSSSLOT` all
assert correctly.

**Depends on**: Phase 2 (ports/announce), US1 (`pq_*` names), T001 (`engines.env`).

- [x] T016 [US3] Create `test_java/pom.xml`: Java 25 (`<release>25`), JUnit Jupiter 5.13.x, Jedis 7.1.0, `maven-compiler-plugin` ≥ 3.14.0, `maven-surefire-plugin` 3.5.x
- [x] T017 [US3] Create `test_java/src/test/java/pq/support/`: `Engines` (load `../engines.env` via `java.util.Properties`; expose redis/valkey host:port for standalone + cluster), `Clients` (JedisPooled standalone; JedisCluster cluster), `Library` (`functionLoadReplace` of `src/functions/priority_queue.lua`), `Expect` helpers, and an engine×topology `@MethodSource`/parameterization used by all classes
- [x] T018 [P] [US3] Contract classes (11) in `pq/contract/` per the parity table (incl. `FunctionFlagsTest` asserting library name `priority_queue`, 11 `pq_*`, `no-writes` flags, FCALL_RO-on-write rejection)
- [x] T019 [P] [US3] Integration classes (16) in `pq/integration/` per the parity table
- [x] T020 [P] [US3] Unit classes (9) in `pq/unit/` per the parity table (assert numeric fields as `Long`, not `"0"`; `PQ E…` via `JedisDataException.getMessage()`)
- [x] T021 [US3] Verify US3: `cd test_java && mvn test` green on redis+valkey, standalone + cluster; case coverage matches the Bash counterparts per the parity table

**Checkpoint**: Java client proves identical behaviour on both engines + cluster.

---

## Phase 6: User Story 4 — Python parity suite (Priority: P4)

**Goal**: `pytest` under `test_python/` mirrors every Bash suite 1-to-1 against both engines, standalone
+ cluster, via redis-py. Independent of US3.

**Independent Test**: With the harness up, `pytest` passes on redis+valkey (standalone + cluster); typed
replies, `PQ E…` `ResponseError`, `fcall_ro`-on-write rejection, and cluster assertions all hold.

**Depends on**: Phase 2 (ports/announce), US1 (`pq_*` names), T001 (`engines.env`).

- [x] T022 [US4] Create `test_python/requirements.txt` (`pytest`, `redis>=5`) and `pyproject.toml`/`pytest.ini` (test discovery over `contract/`, `integration/`, `unit/`)
- [x] T023 [US4] Create `test_python/conftest.py`: parse `../engines.env`; engine×topology fixtures yielding a connected client (`redis.Redis(decode_responses=True)` standalone; `redis.cluster.RedisCluster` cluster); load `src/functions/priority_queue.lua` via `function_load(code, replace=True)`; shared assert helpers
- [x] T024 [P] [US4] Contract modules (11) in `test_python/contract/` per the parity table (incl. `test_function_flags.py`)
- [x] T025 [P] [US4] Integration modules (16) in `test_python/integration/` per the parity table
- [x] T026 [P] [US4] Unit modules (9) in `test_python/unit/` per the parity table (assert `int`/`str`; `PQ E…` via `ResponseError`)
- [x] T027 [US4] Verify US4: `cd test_python && pip install -r requirements.txt && pytest -q` green on redis+valkey, standalone + cluster; coverage matches the Bash counterparts

**Checkpoint**: All three languages verify identical behaviour.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T028 [P] Update `README.md` to document all three suites and how to run each (`test_bash/run_all.sh`, `mvn test`, `pytest`) + the `engines.env`/ports model + harness-up-first requirement (Principle X); confirm `docs/schema.md` + `docs/functions.md` are fully de-`msgfmt`'d
- [x] T029 Run the repo-wide grep sweep (quickstart §6, both `EXCL`-filtered commands): confirm **zero** `message_format|msgfmt|MSGFMT` and **zero** real `tests/{harness,contract,integration,unit,run_all,.artifacts}` subpath matches outside the frozen records (all `specs/**`, `.specify/templates/`, constitution Sync-Impact comment); fix any straggler
- [x] T030 Run quickstart end-to-end and confirm all success criteria: SC-001 — `test_bash/run_all.sh` (standalone) on both engines = 832 assertions, 0 failed + static gate green, **plus a manual Bash cluster smoke** (`docker_engines.sh cluster-up` → load `priority_queue.lua` → one `pq_*` FCALL per engine, as cluster has always been Bash-manual, not part of `run_all.sh`); SC-002 — `mvn test` on both engines, standalone + cluster (automated); SC-003 — `pytest` on both engines, standalone + cluster (automated); SC-004 — grep sweep zero (T029); SC-005 — parity table 1-to-1; SC-006 — zero behavioural change vs Feature 006

---

## Dependencies & Execution Order

- **Setup (Phase 1)**: no dependencies; `engines.env` (T001) feeds Phase 2 + US3 + US4.
- **Foundational (Phase 2)**: depends on T001; **blocks US3 + US4 only** (NOT US1/US2).
- **US1 (Phase 3, P1)**: independent — the MVP. Touches library, harness names/paths, Bash test content + filenames, docs, feature.json.
- **US2 (Phase 4, P2)**: depends on US1 (renames content before the folder moves, so history is clean); could technically precede US1 but ordered per spec priority.
- **US3 (Phase 5, P3)**: depends on Phase 2 + US1 + T001. Independent of US4.
- **US4 (Phase 6, P4)**: depends on Phase 2 + US1 + T001. Independent of US3.
- **Polish (Phase 7)**: depends on all desired stories complete.

### Shared-file coupling (edit sequentially, not [P] across phases)

- `docker_engines.sh`: US1/T007 (names) + US2/T013 (move) + Phase 2/T003–T004 (ports/announce).
- `.gitignore`: Setup/T002 (Java/Python) + US2/T014 (artifacts path).
- `README.md`/`docs/**`: US1/T010 (tokens) + US2/T014 (paths) + Polish/T028 (run instructions).

### Parallel opportunities

- T002 ∥ T001-followups (Setup).
- Within US1: T008 (filename `git mv`) ∥ T010 (docs) ∥ T011 (feature.json/CLAUDE) — different files. T009 (test content) waits on T008 (renamed files).
- Within US3: T018 ∥ T019 ∥ T020 after T016–T017. Within US4: T024 ∥ T025 ∥ T026 after T022–T023.
- **US3 ∥ US4** entirely (different trees) once Phase 2 + US1 are done.

---

## Implementation Strategy

- **MVP** = Setup → US1 (rename). Validate the Bash suite green with `pq_`/`PQ` before anything else.
- **Increment 2** = US2 (relocate) → `test_bash/` green.
- **Increment 3** = Phase 2 (ports) → US3 (Java) and US4 (Python) in parallel.
- **Finish** = Polish (docs, grep sweep, full quickstart on both engines + cluster).
- The Bash suite's pre-rename total (832 assertions, 0 failed) is the regression guard throughout.
