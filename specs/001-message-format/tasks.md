---
description: "Task list for Message Format feature implementation"
---

# Tasks: Message Format

**Input**: Design documents from `/specs/001-message-format/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis 7.0+ and Valkey 7.2+ engines (standalone + cluster), so test tasks are required, not optional.

**Organization**: Tasks are grouped by user story (US1 create, US2 read, US3 validation). All three functions are registered in the single library file `src/functions/message_format.lua`; implementation tasks that edit that file are therefore sequential (no `[P]`), while test files (separate paths) are parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3 (maps to spec.md user stories)
- Exact file paths included in each task

## Path Conventions

Single-library layout (from plan.md): production code in `src/functions/`, tests in `tests/` with `harness/`, `contract/`, `integration/`, `unit/` subfolders.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repository skeleton for the function library and tests

- [x] T001 Create directory structure `src/functions/` and `tests/{harness,contract,integration,unit}/` at repository root per plan.md

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The Docker engine harness and the shared library skeleton + validation/encode helpers that ALL three functions depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete (every story's tests need the harness, and all three functions share the library file and helpers)

- [x] T002 Create the Docker engine harness `tests/harness/docker_engines.sh` that starts/stops official Redis 7.0+ and Valkey 7.2+ container images via the Docker CLI in both standalone and cluster mode (per Constitution Principle IX)
- [x] T003 [P] Create the load-and-assert helper `tests/harness/load_and_call.sh` that `FUNCTION LOAD REPLACE`s the library and runs `FCALL`/`FCALL_RO` with response assertions against a given container
- [x] T004 Create the Redis Functions library skeleton `src/functions/message_format.lua` with the `#!lua name=message_format` header and `redis.register_function` registrations (stubs) for `msgfmt_create`, `msgfmt_read` (flags `no-writes`), and `msgfmt_validate` (flags `no-writes`); include a header comment referencing `specs/001-message-format/spec.md` (Principle I)
- [x] T005 Implement the shared schema + encode/decode + validation helpers in `src/functions/message_format.lua`: the closed five-field set with defaults (ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, Payload=""), boolean 0/1 encoding, numeric decimal-string encoding, and per-field validators (integer-ness via `tonumber`+`floor`, ≥0 bounds, ≤2^53, DirtyBit token set) that return structured `MSGFMT E...` outcomes (depends on T004)

**Checkpoint**: Harness can start engines and load the library; shared helpers exist for all stories to build on

---

## Phase 3: User Story 1 - Create a message with defaults and explicit values (Priority: P1) 🎯 MVP

**Goal**: A caller can create a message at a caller-supplied key from any subset of the five attributes, with omitted fields taking documented defaults, stored as a single Hash.

**Independent Test**: `FCALL msgfmt_create 1 q:{m1}` stores all defaults; `FCALL msgfmt_create 1 q:{m2} Payload "x" Priority 5` stores those two and defaults the rest — verifiable by reading the Hash fields directly.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T008)

- [x] T006 [P] [US1] Contract test for `msgfmt_create` (KEYS[1], ARGV field/value pairs, returns `OK`, odd-arg `MSGFMT EARGS`) in `tests/contract/test_msgfmt_create_contract.sh`
- [x] T007 [P] [US1] Integration test for create-with-defaults and create-with-explicit-values across Redis & Valkey, standalone + cluster, in `tests/integration/test_msgfmt_create_roundtrip.sh`

### Implementation for User Story 1

- [x] T008 [US1] Implement `msgfmt_create` in `src/functions/message_format.lua`: parse `ARGV` field/value pairs, apply defaults for omitted fields, encode and `HSET` all five fields at `KEYS[1]` in one call, return `redis.status_reply("OK")` (depends on T005)

**Checkpoint**: Messages can be created with defaults and explicit values and verified by direct Hash inspection — MVP usable

---

## Phase 4: User Story 2 - Read a message back into a well-defined shape (Priority: P1)

**Goal**: A caller can read a stored message and receive all five attributes with correct logical types; read never writes; absent keys return a distinguishable NOTFOUND.

**Independent Test**: Create a known message, `FCALL_RO msgfmt_read 1 q:{m2}` returns the typed field array; reading an absent key returns `NOTFOUND`; the stored Hash is unchanged after read.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T011)

- [x] T009 [P] [US2] Contract test for `msgfmt_read` (no-writes flag present, `FCALL_RO`-callable, typed return array, `NOTFOUND` status, `MSGFMT EMALFORMED` on wrong-type/incomplete key) in `tests/contract/test_msgfmt_read_contract.sh`
- [x] T010 [P] [US2] Integration test for create→read round-trip type fidelity (DirtyBit as boolean/0-1, numeric fields, payload) and read-does-not-mutate, across engines and modes, in `tests/integration/test_msgfmt_read_roundtrip.sh`

### Implementation for User Story 2

- [x] T011 [US2] Implement `msgfmt_read` in `src/functions/message_format.lua`: registered with `no-writes`, return `NOTFOUND` when the key is absent, `MSGFMT EMALFORMED` when the key is not a Hash or is missing fields, otherwise decode all five fields to logical types and return the field/value array (depends on T005; same file as T008, run after)

**Checkpoint**: Create + read round-trip works with correct types on all target engines/modes

---

## Phase 5: User Story 3 - Reject invalid attribute values (Priority: P2)

**Goal**: Supplied-but-invalid values and unknown/duplicate attribute names are rejected with structured field-naming errors and nothing is stored; a standalone read-only validator exposes the same checks.

**Independent Test**: Create attempts with non-integer/negative ReadAttempts, non-boolean DirtyBit, non-numeric Priority/ReadDateTime, and an unknown field each return a `MSGFMT E...` error naming the field and store nothing; `FCALL_RO msgfmt_validate` mirrors those results.

### Tests for User Story 3 ⚠️ (write first, must FAIL before T014)

- [x] T012 [P] [US3] Unit tests for every validation rule (invalid ReadAttempts, DirtyBit, ReadDateTime, Priority; unknown field; duplicate field) asserting the correct `MSGFMT EINVAL/EFIELD/EDUP` reply and no stored Hash, in `tests/unit/test_msgfmt_validation.sh`
- [x] T013 [P] [US3] Contract test for `msgfmt_validate` (no KEYS, no-writes flag, `FCALL_RO`-callable, returns `VALID` or the matching `MSGFMT E...` error) in `tests/contract/test_msgfmt_validate_contract.sh`

### Implementation for User Story 3

- [x] T014 [US3] Implement `msgfmt_validate` and wire rejection into `msgfmt_create` in `src/functions/message_format.lua`: reject unknown field names (`MSGFMT EFIELD`), duplicates (`MSGFMT EDUP`), and invalid values (`MSGFMT EINVAL`) using the shared validators from T005, ensuring `msgfmt_create` stores nothing on any failure; `msgfmt_validate` returns `VALID` on success (depends on T005; same file as T008/T011, run after)

**Checkpoint**: All three functions implemented; invalid input is rejected consistently across create and validate

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Cross-engine verification and traceability

- [x] T015 [P] Run `quickstart.md` end-to-end against Redis 7.0+ and Valkey 7.2+ via the harness and confirm every documented command output matches
- [x] T016 Verify via `FUNCTION LIST` in a test that `msgfmt_read` and `msgfmt_validate` carry the `no-writes` flag and that `FCALL` (write) of `msgfmt_create` is rejected under `FCALL_RO` (Principle VII), in `tests/contract/test_function_flags.sh`
- [x] T017 [P] Add a cluster-mode run of the full suite (single-key operations confirm no `CROSSSLOT`) to `tests/harness/docker_engines.sh` invocation in CI notes
- [x] T018 [P] Confirm `src/functions/message_format.lua` header references the spec, that contracts in `specs/001-message-format/contracts/functions.md` match the implemented return shapes, and assert (by inspection/test) that every key access goes through `KEYS[]` with no computed or hardcoded key names (FR-016, Principle I, IV & VIII traceability)
- [x] T019 [P] Create a static-compliance scan `tests/harness/static_checks.sh` that scans `src/functions/message_format.lua` and fails on: restricted/admin commands (CONFIG, SAVE, BGSAVE, DEBUG, FLUSHALL, FLUSHDB, etc. — Principle V), computed/hardcoded key names (Principle IV), and any command/option not on the common-supported list for Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB (Principle III; supports SC-006 managed-target assurance)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories
- **User Stories (Phase 3–5)**: all depend on Foundational (T005 helpers + harness)
- **Polish (Phase 6)**: depends on US1–US3 complete

### User Story Dependencies

- **US1 (P1)**: after Foundational. Independently testable.
- **US2 (P1)**: after Foundational. Logically independent of US1, but T011 edits the same library file as T008 — sequence T008 → T011.
- **US3 (P2)**: after Foundational. T014 edits the same file — sequence after T008/T011. Validation reuses T005 helpers.

### Within Each User Story

- Tests written first and must FAIL before the implementation task.
- Shared helpers (T005) before any function body.
- `msgfmt_create` (T008) → `msgfmt_read` (T011) → `msgfmt_validate`/create-rejection (T014), because all three edit `src/functions/message_format.lua`.

### Parallel Opportunities

- T003 can run in parallel with T002.
- All test-authoring tasks marked [P] in different files can be written in parallel: (T006, T007), (T009, T010), (T012, T013).
- Polish tasks T015, T017, T018, T019 are [P]; T016 adds a test file and can also run independently.
- Implementation tasks T008/T011/T014 are NOT parallel (single shared library file).

---

## Parallel Example: User Story 1

```bash
# Author both US1 test files together (different paths):
Task: "Contract test for msgfmt_create in tests/contract/test_msgfmt_create_contract.sh"
Task: "Integration test for create round-trip in tests/integration/test_msgfmt_create_roundtrip.sh"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup
2. Phase 2: Foundational (harness + library skeleton + shared helpers) — CRITICAL
3. Phase 3: US1 create → validate independently by reading Hash fields
4. **STOP and VALIDATE**, then optionally demo

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 create → test → demo (MVP)
3. US2 read → test (full create/read round-trip) → demo
4. US3 validation → test → demo
5. Polish: cross-engine + flag + traceability checks

---

## Notes

- [P] = different files, no dependencies. The three function bodies share one file, so they are sequential by design.
- Every function file references the spec for Principle I traceability.
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness.
- Commit after each task or logical group.
