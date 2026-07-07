---
description: "Task list for Enqueue feature implementation"
---

# Tasks: Enqueue

**Input**: Design documents from `/specs/002-enqueue/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis 7.0+ and Valkey 7.2+ engines (standalone + cluster), so test tasks are required, not optional.

**Organization**: Tasks are grouped by user story (US1 enqueue + ordering, US2 reject invalid/conflicting). The enqueue logic is a new function added to the single existing library file `src/functions/message_format.lua`; implementation tasks that edit that file are therefore sequential (no `[P]`), while test files (separate paths) are parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 (maps to spec.md user stories)
- Exact file paths included in each task

## Path Conventions

Single-library layout (from plan.md), reused from Feature 001: production code in `src/functions/`, tests in `tests/` with `harness/`, `contract/`, `integration/`, `unit/` subfolders.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Reuse the existing skeleton from Feature 001; this feature extends it rather than scaffolding anew

- [X] T001 Verify the Feature 001 single-library layout and Docker harness are present and reusable — `src/functions/message_format.lua`, `tests/harness/docker_engines.sh`, `tests/harness/load_and_call.sh`, and `tests/{contract,integration,unit}/` — and confirm no new scaffolding is required (enqueue extends the existing `message_format` library)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Ready the shared library file and the static portability gate for the Sorted Set commands this feature introduces

**⚠️ CRITICAL**: No user story implementation should land until this phase is complete (the function must be registered before tests can load/call it; the portability gate must permit the new commands)

- [X] T002 Extend `tests/harness/static_checks.sh`: (a) add `ZADD`, `ZSCORE`, `ZCARD`, `ZRANGE` to the allowed-command whitelist and update the computed/hardcoded-key regex so the enqueue `member`/score construction and the `KEYS[2]` access are not falsely flagged, while still rejecting admin/off-list commands and genuinely computed keys (Constitution Principles III, IV, V); and (b) add a determinism scan that fails on non-deterministic sources in the library body — `redis.call('TIME'…)`, `math.random`, `redis.random` — to enforce FR-015 / Principle VII. Confirm each added command is on the common-supported list for Redis 7.0+, Valkey 7.2+, ElastiCache, MemoryDB
- [X] T003 Add the `msgfmt_enqueue` registration + stub to `src/functions/message_format.lua` as a **write** function (no flags), with a header comment referencing `specs/002-enqueue/spec.md` (Principle I); leave `msgfmt_create`, `msgfmt_read`, `msgfmt_validate` unchanged

**Checkpoint**: The library registers `msgfmt_enqueue` and loads; the static gate allows the feature's Sorted Set commands — user story work can begin

---

## Phase 3: User Story 1 - Enqueue a message and order it by priority (Priority: P1) 🎯 MVP

**Goal**: A producer can enqueue a message onto a caller-designated queue in one atomic call — the message is stored (Feature 001 format, defaults applied) and indexed in a Sorted Set ordered by Priority (lower = higher priority), with equal priorities kept in insertion (FIFO) order.

**Independent Test**: Enqueue several messages with distinct `Priority` values (and some equal) onto one empty queue; confirm the Sorted Set orders them ascending by score (highest priority first), equal priorities appear in insertion-sequence order, and each stored message reads back (via `msgfmt_read`) with supplied values exact and omitted values defaulted.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T006)

- [X] T004 [P] [US1] Contract test for `msgfmt_enqueue` in `tests/contract/test_msgfmt_enqueue_contract.sh`: `KEYS[1]`=queue Sorted Set, `KEYS[2]`=message Hash (shared hash tag); `ARGV`=`id`, `sequence`, then optional `field value` pairs; returns `OK` on success; `MSGFMT EKEYS` when key count ≠ 2; and the function is a write (rejected under `FCALL_RO`)
- [X] T005 [P] [US1] Integration test in `tests/integration/test_msgfmt_enqueue_roundtrip.sh`: enqueue messages with distinct priorities and assert ascending score order (highest priority = lowest score at the front via `ZRANGE ... WITHSCORES`); include boundary/extreme Priority values (e.g. a large negative, `0`, and a value near 2^53) and assert they order correctly relative to the default 1000 (FR-016); enqueue equal-priority messages and assert FIFO by sequence (member byte order); read a stored message back with `msgfmt_read` and assert field fidelity; run across Redis & Valkey, standalone + cluster

### Implementation for User Story 1

- [X] T006 [US1] Implement the `msgfmt_enqueue` happy path in `src/functions/message_format.lua`: guard `#KEYS == 2` (`MSGFMT EKEYS`); validate `ARGV[1]` id is non-empty (`MSGFMT EID`) and `ARGV[2]` sequence is a non-negative integer ≤ 2^53 (`MSGFMT ESEQ`); reuse `build_message` on `ARGV[3..]` (re-prepending the `MSGFMT ` prefix to any returned `EARGS`/`EFIELD`/`EDUP`/`EINVAL`); compute `score` = the message's `Priority` and `member` = fixed-width zero-padded `sequence` + `":"` + `id`; `HSET` the five encoded fields at `KEYS[2]` and `ZADD KEYS[1] score member`; return `redis.status_reply("OK")` (depends on T003; same file — run after T003)

**Checkpoint**: Messages can be enqueued and are correctly ordered by priority and FIFO within a priority, verifiable across engines/modes — MVP usable

---

## Phase 4: User Story 2 - Reject invalid or conflicting enqueue requests without side effects (Priority: P2)

**Goal**: Invalid input, wrong-type targets, an occupied message location, or an already-present queue entry are all rejected with a structured `MSGFMT E...` error, and on any failure nothing is written to either the message Hash or the queue Sorted Set (fail-before-write).

**Independent Test**: Attempt enqueues that supply an invalid field value, an unknown field, a bad id/sequence, a message location that already holds a message, a queue location holding a non-Sorted-Set value, and an already-enqueued member; confirm each returns the correct structured error and that neither the message Hash nor the queue Sorted Set is modified in any case.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T009)

- [X] T007 [P] [US2] Unit tests for input rejection in `tests/unit/test_msgfmt_enqueue_validation.sh`: empty id → `MSGFMT EID`; negative/non-integer/oversized sequence → `MSGFMT ESEQ`; invalid field value → `MSGFMT EINVAL: <field>`; unknown field → `MSGFMT EFIELD: <name>`; duplicate field → `MSGFMT EDUP: <name>`; odd field-pair count → `MSGFMT EARGS` — asserting in every case that the message Hash `KEYS[2]` is absent and the queue Sorted Set `KEYS[1]` is unchanged
- [X] T008 [P] [US2] State-conflict integration test in `tests/integration/test_msgfmt_enqueue_conflict.sh`: occupied message location → `MSGFMT EEXISTS`; wrong-type queue key (non-Sorted-Set) → `MSGFMT EMALFORMED`; already-present member (same id+sequence) → `MSGFMT EQDUP`; and after any such rejection assert atomic no-write (queue cardinality via `ZCARD` unchanged and the message Hash unchanged), across Redis & Valkey

### Implementation for User Story 2

- [X] T009 [US2] Extend `msgfmt_enqueue` in `src/functions/message_format.lua` with fail-before-write conflict guards, all evaluated before any `HSET`/`ZADD`: `EXISTS KEYS[2]` → `MSGFMT EEXISTS: message location occupied`; `TYPE KEYS[1]` present and ≠ `zset` → `MSGFMT EMALFORMED: queue is not a sorted set`; `ZSCORE KEYS[1] member` non-nil → `MSGFMT EQDUP: already enqueued`; ensure every rejection path writes nothing to either structure (depends on T006; same file — run after T006)

**Checkpoint**: All rejection and conflict paths return structured errors and never leave a partial write; enqueue is safe against duplicates and wrong-type targets

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Cross-engine verification, flag/portability gates, and traceability

- [X] T010 [P] Run `specs/002-enqueue/quickstart.md` end-to-end against Redis 7.0+ and Valkey 7.2+ via the harness and confirm every documented command output (ordering, FIFO, read-back, error cases) matches
- [X] T011 [P] Extend `tests/contract/test_function_flags.sh` to assert via `FUNCTION LIST` that `msgfmt_enqueue` carries **no** `no-writes` flag and that calling it via `FCALL_RO` is rejected (Principle VII)
- [X] T012 Run the extended `tests/harness/static_checks.sh` against `src/functions/message_format.lua` and confirm it passes with the Sorted Set commands allow-listed, still fails on admin/off-list commands and computed/hardcoded keys, that the determinism scan finds no `TIME`/random usage in `msgfmt_enqueue` (FR-015, Principle VII), and that `msgfmt_enqueue` accesses only `KEYS[1]`/`KEYS[2]` (Principles III, IV, V, VII; supports SC-007)
- [X] T013 [P] Add a cluster-mode run of the enqueue suite to the harness invocation / CI notes, confirming the two co-located keys (shared hash tag) produce no `CROSSSLOT` error (Principle IV, FR-007)
- [X] T014 [P] Confirm the `src/functions/message_format.lua` header references `specs/002-enqueue/spec.md`, that `specs/002-enqueue/contracts/functions.md` matches the implemented return shapes and error strings, and assert (by inspection/test) that every key access goes through `KEYS[1]`/`KEYS[2]` with no computed or hardcoded key names (FR-007, Principles I, IV & VIII traceability)

---

## Phase 6: Developer Documentation (US3)

**Purpose**: Ship developer-facing documentation (root `README.md` + `docs/`) so another Redis/Valkey developer can understand and use the library, and record the documentation-currency rule in the constitution. No runtime code changes.

**Independent Test**: A developer using only `README.md` installs the prerequisites and runs the suite to green; `docs/schema.md` names every message field and native type; `docs/functions.md` lists every function with its inputs/outputs/errors; the constitution contains the Documentation Currency principle.

**⚠️ No automated engine tests** (per direction): Principle IX's test-first rule does not apply to documentation-only work. Docs are validated by a consistency review (T019); the existing suite is re-run for regression only (T020).

- [X] T015 [P] [US3] Write `docs/schema.md`: document the message schema (the five Hash fields — ReadAttempts, DirtyBit, ReadDateTime, Priority, Payload — with logical type, default, and stored encoding) and the native data types and how they are used: the per-message **Hash** at `KEYS[2]`, and the priority-index **Sorted Set** at `KEYS[1]` with score = `Priority` (lower = higher priority) and member = fixed-width zero-padded `sequence` + `":"` + `id`; explain hash-tag co-location (same slot) and FIFO-within-priority ordering
- [X] T016 [P] [US3] Write `docs/functions.md`: document every function in `src/functions/message_format.lua` (excluding test scripts) — a first section of caller-invocable functions in alphabetical order (`msgfmt_create`, `msgfmt_enqueue`, `msgfmt_read`, `msgfmt_validate`), then a second section of local helpers in alphabetical order (`build_message`, `encode_field`, `is_int`, `parse_args`), each with purpose, inputs (`KEYS`/`ARGV` or parameters), outputs/return shape, and error results (the `MSGFMT E...` codes)
- [X] T017 [P] [US3] Write root `README.md`: what the library is and does; prerequisites to modify/test locally (a Docker runtime; a Redis/Valkey CLI — available inside the official container images; a POSIX `bash` shell); how to load the library (`FUNCTION LOAD`) and invoke the functions (`FCALL`/`FCALL_RO` examples); how to run the tests locally (`tests/run_all.sh`, individual `tests/**/*.sh` suites, and cluster mode via `tests/harness/docker_engines.sh cluster-up`); and links to `docs/schema.md` and `docs/functions.md`
- [X] T018 [P] [US3] Amend `.specify/memory/constitution.md`: add a new principle **Documentation Currency** (any feature change that affects documented behaviour MUST update the affected documentation in the same change; Check = review confirms docs updated with the code; Rationale = docs stay trustworthy), bump the version 1.1.0 → 1.2.0, update the Sync Impact Report header comment and the Last Amended date, and confirm no dependent template requires changes
- [X] T019 [US3] Verify documentation consistency across `docs/schema.md`, `docs/functions.md`, and `README.md`: every documented field/encoding, function, error code, native type, and test command matches the implemented `src/functions/message_format.lua` and the harness; nothing is documented that does not exist (depends on T015–T017)
- [X] T020 [US3] Re-run the full suite for regression via `tests/run_all.sh` on redis + valkey and confirm it is still green — documentation + constitution changes must not affect the result (depends on T018)

**Checkpoint**: README + docs/ published, constitution at v1.2.0, docs verified consistent against the code, suite still green

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories (registration + static gate)
- **User Stories (Phase 3–4)**: depend on Foundational
- **Polish (Phase 5)**: depends on US1–US2 complete
- **Developer Documentation (Phase 6, US3)**: depends on the implemented library (US1–US2); documentation-only (no engine tests). T015–T018 are parallel `[P]` (distinct files — schema.md, functions.md, README.md, constitution.md); T019 (consistency review) after T015–T017; T020 (regression re-run) after T018

### User Story Dependencies

- **US1 (P1)**: after Foundational. Independently testable — delivers the working, ordered enqueue (MVP).
- **US2 (P2)**: after Foundational; its implementation (T009) extends the same function body as US1 (T006), so sequence T006 → T009. US2's tests are independent files and can be authored anytime after Foundational.

### Within Each User Story

- Tests written first and must FAIL before the implementation task.
- Foundational stub (T003) before any function body.
- `msgfmt_enqueue` happy path (T006) → conflict guards (T009), because both edit `src/functions/message_format.lua`.

### Parallel Opportunities

- T002 and T003 touch different files (harness vs library) and can run in parallel.
- All test-authoring tasks marked [P] in different files can be written in parallel: (T004, T005), (T007, T008).
- Polish tasks T010, T011, T013, T014 are [P]; T012 runs the static gate and can run independently.
- Implementation tasks T006/T009 are NOT parallel (single shared library file).

---

## Parallel Example: User Story 1

```bash
# Author both US1 test files together (different paths):
Task: "Contract test for msgfmt_enqueue in tests/contract/test_msgfmt_enqueue_contract.sh"
Task: "Integration test for enqueue ordering/FIFO in tests/integration/test_msgfmt_enqueue_roundtrip.sh"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup (confirm reuse)
2. Phase 2: Foundational (static-gate extension + registration stub) — CRITICAL
3. Phase 3: US1 enqueue happy path → validate independently by enqueuing and inspecting order/FIFO and reading messages back
4. **STOP and VALIDATE**, then optionally demo

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 enqueue + ordering → test → demo (MVP)
3. US2 rejection/conflict/atomicity → test → demo
4. Polish: cross-engine quickstart + flag/portability gates + traceability

---

## Notes

- [P] = different files, no dependencies. The enqueue function shares one file with the Feature 001 functions, so its implementation tasks are sequential by design.
- The new function references the spec for Principle I traceability.
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness; both keys share a hash tag so the two-key call stays single-slot.
- Commit after each task or logical group.
