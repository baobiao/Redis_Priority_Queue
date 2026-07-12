---
description: "Task list for Dead-Letter Handling and Peek"
---

# Tasks: Dead-Letter Handling and Peek

**Input**: Design documents from `/specs/004-dead-letter-peek/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis 7.0+
and Valkey 7.2+ engines (standalone + cluster), so test tasks are required.

**Organization**: Grouped by user story — US1 dead-letter at dequeue (P1), US2 non-destructive peek
(P2), US3 redrive (P3). The three functions live in the single existing library file
`src/functions/message_format.lua`; tasks that edit that file are therefore **sequential** (no `[P]`),
while test files (separate paths) are parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3 (maps to spec.md user stories)
- Exact file paths included in each task

## Path Conventions

Single-library layout (from plan.md), reused from Features 001–003: production code in
`src/functions/`, tests in `tests/` with `harness/`, `contract/`, `integration/`, `unit/` subfolders.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Reuse the existing skeleton from Features 001–003; this feature extends it.

- [X] T001 Verify the existing single-library layout and Docker harness are present and reusable —
  `src/functions/message_format.lua` (with `msgfmt_dequeue`/`ack`/`nack`, `hash_tag`, `is_int`,
  field encodings, member format), `tests/harness/docker_engines.sh`, `tests/harness/load_and_call.sh`,
  `tests/harness/static_checks.sh`, and `tests/{contract,integration,unit}/` — and confirm no new
  scaffolding is required (Feature 004 extends the existing `message_format` library)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Extract the shared availability predicate both dequeue and peek must agree on, and
confirm the static gate needs no change.

**⚠️ CRITICAL**: No user-story implementation should land until this phase is complete.

- [X] T002 Add a file-local helper `lease_available(dirtybit, readdatetime, now, timeout)` to
  `src/functions/message_format.lua` that returns the current Feature 003 availability rule
  (`dirtybit == '0'`, or `dirtybit == '1'` with `now − readdatetime >= timeout`), and refactor
  `msgfmt_dequeue`'s inline availability check (current lines ~356–364) to call it — a **no-behaviour-change**
  refactor so `msgfmt_peek` (US2) selects exactly what `msgfmt_dequeue` (US1) would. Confirm the
  existing Feature 003 dequeue suites still pass unchanged
- [X] T003 Confirm `tests/harness/static_checks.sh` requires **no** change: every command Feature 004
  uses (`ZADD`, `ZREM`, `ZSCORE`, `ZRANGE`, `HSET`, `HGET`, `HMGET`, `HINCRBY`, `EXISTS`, `TYPE`, `DEL`)
  is already on the `allowed` whitelist, the whole-file scan already covers new functions, and the
  determinism scan (no `TIME`/`math.random`) still holds (Principles III, V, VII)

**Checkpoint**: The shared availability helper exists and dequeue is unchanged in behaviour; the gate
is confirmed sufficient — user-story work can begin.

---

## Phase 3: User Story 1 - Dead-letter poison messages at dequeue (Priority: P1) 🎯 MVP

**Goal**: `msgfmt_dequeue` gains an optional DLQ key (`KEYS[3]`) and an optional max-delivery cap
(trailing `ARGV`); an available candidate whose `ReadAttempts ≥ cap` is moved to the DLQ instead of
being leased, and the scan continues. With the DLQ key/cap omitted, behaviour is exactly Feature 003.

**Independent Test**: Drive a message to the cap via dequeue→nack cycles; the next dead-letter-mode
dequeue moves it to the DLQ (present in DLQ at score=Priority with verbatim member, absent from source,
Hash untouched) and returns the next deliverable message (or null); omitting DLQ/cap reproduces
Feature 003 exactly.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T006)

- [X] T004 [P] [US1] Extend `tests/contract/test_msgfmt_dequeue_contract.sh`: the 2-key call is
  unchanged; a 3-key call adds `KEYS[3]` = DLQ and requires a trailing `cap` `ARGV`; assert `EKEYS`
  for a bad key count, `ECAP` for a missing/invalid cap in dead-letter mode, `ETAG` when the DLQ key's
  hash tag differs, and `EMALFORMED` when the DLQ key is not a sorted set
- [X] T005 [P] [US1] Integration test `tests/integration/test_msgfmt_deadletter.sh`: a front available
  message with `ReadAttempts ≥ cap` is moved to the DLQ (`ZSCORE` DLQ = its `Priority`, member verbatim,
  message Hash unchanged) and NOT returned; a below-cap message is leased and returned; an over-cap but
  **unexpired** in-flight message is left untouched; an over-cap **expired-lease** message is dead-lettered
  on that call; **a poison member already present in the DLQ is not duplicated (FR-005) — its DLQ score is
  updated in place and it is still removed from the source**; the dequeue reply is silent (Feature 003
  shape); omitting DLQ/cap reproduces Feature 003; run across Redis & Valkey, standalone + cluster
  (co-located `{tag}` source+DLQ+message keys)

### Implementation for User Story 1

- [X] T006 [US1] Extend `msgfmt_dequeue` in `src/functions/message_format.lua`: accept **2 or 3** keys
  (`EKEYS: two or three keys required`); when `KEYS[3]` is present, parse the required cap from the
  trailing `ARGV` (`ECAP` on missing/invalid), extend the co-location check to `KEYS[3]` (`ETAG`), and
  reject a non-`zset` `KEYS[3]` (`EMALFORMED`); in the scan, when in dead-letter mode and a candidate is
  available (via `lease_available`) with `ReadAttempts ≥ cap`, `ZREM` it from the source and `ZADD` it to
  the DLQ at score = its `Priority` with the member verbatim (plain `ZADD` updates in place if the member
  already exists → no duplicate, FR-005), then continue scanning (do not lease); leave the 2-key path and
  the return shape byte-for-byte Feature 003; update the header comment to reference
  `specs/004-dead-letter-peek/spec.md` (depends on T002; same file as T010/T014 — run sequentially)

**Checkpoint**: Poison messages are dead-lettered on receive; the no-DLQ path is unchanged — MVP usable.

---

## Phase 4: User Story 2 - Inspect a queue without consuming (Priority: P2)

**Goal**: A new read-only `msgfmt_peek` (registered `no-writes`, `FCALL_RO`-callable) returns either the
single lease-aware next-deliverable message (no/`1` count) or the front N members with their lease fields
(`count = N`), mutating nothing, on a source queue or a DLQ.

**Independent Test**: With a mix of leased and available messages, single-mode peek returns exactly what
a dequeue would next lease with no field changed; top-N returns N front members in priority-then-FIFO with
their lease fields; empty/all-leased → null / empty list; works identically on a DLQ.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T010)

- [X] T007 [P] [US2] Contract test `tests/contract/test_msgfmt_peek_contract.sh`: `KEYS[1]`=queue,
  `KEYS[2]`=prefix (shared tag); `ARGV` = `now`, `timeout`, optional `count`; single-mode returns a record
  array or null, top-N returns an array of record arrays; `msgfmt_peek` is a **no-writes** function
  (callable via `FCALL_RO`); assert `EKEYS`/`ENOW`/`ETMO`/`ECOUNT`/`ETAG`
- [X] T008 [P] [US2] Integration test `tests/integration/test_msgfmt_peek.sh`: single-mode result equals
  the message a subsequent `msgfmt_dequeue` leases, and every message field is byte-for-byte unchanged after
  peek; top-N returns the front members in priority-then-FIFO order each annotated with
  `DirtyBit`/`ReadAttempts`/`ReadDateTime`/`Priority`/`Payload`; **`count` greater than the queue size returns
  all members (no error)**; empty queue → null (single) / empty (top-N); all-leased-unexpired → null (single);
  a dangling member is skipped and never removed; peeking a DLQ works; across Redis & Valkey, standalone +
  cluster
- [X] T009 [P] [US2] Unit test `tests/unit/test_msgfmt_peek_validation.sh`: invalid `now`/`timeout`/`count`,
  hash-tag mismatch, and a non-`zset` queue return the correct `MSGFMT E...` errors; **a malformed message
  Hash yields `EMALFORMED` when it is the single-mode selected candidate but is skipped in top-N mode**;
  assert nothing is written in any case (read-only)

### Implementation for User Story 2

- [X] T010 [US2] Add `msgfmt_peek` to `src/functions/message_format.lua`, reusing `lease_available`,
  `hash_tag`, and the id-from-member parse: validate `#KEYS == 2`, `now`/`timeout`, optional `count`, and
  co-location; single mode (`count` absent or `1`) returns the first available message as a record array
  (no mutation) or null; top-N mode returns up to `count` front members regardless of lease state, each a
  record array, skipping dangling/malformed members (never `ZREM` — read-only); register it with
  `flags = { 'no-writes' }` (depends on T002, T007–T009; same file — run after T006)

**Checkpoint**: A queue or DLQ can be inspected without side effects, in both modes.

---

## Phase 5: User Story 3 - Redrive a message from the dead-letter queue (Priority: P3)

**Goal**: A new `msgfmt_redrive` (WRITE) moves one message from a DLQ back to its source (score=`Priority`,
member verbatim) and resets delivery state — `ReadAttempts=0`, `DirtyBit=0`, `ReadDateTime` retained; no-op
when absent from the DLQ; rejected when already in the source.

**Independent Test**: Dead-letter a message, redrive it by its member; confirm it left the DLQ, re-entered
the source at its `Priority`, has `ReadAttempts=0`/`DirtyBit=0` with `ReadDateTime` retained, and is
redelivered on the next dequeue; a redrive of a member not in the DLQ is a `NOOP`; a member already in the
source is rejected with no duplicate.

### Tests for User Story 3 ⚠️ (write first, must FAIL before T014)

- [X] T011 [P] [US3] Contract test `tests/contract/test_msgfmt_redrive_contract.sh`: `KEYS` = DLQ, source,
  message Hash (all literal, shared tag); `ARGV[1]` = member; returns `OK` on a move and `NOOP` when the
  member is absent from the DLQ; `msgfmt_redrive` is a **write** (rejected under `FCALL_RO`); assert
  `EKEYS`/`EARGS`/`ETAG`
- [X] T012 [P] [US3] Integration test `tests/integration/test_msgfmt_redrive.sh`: a DLQ member is moved to
  the source (`ZSCORE` source = `Priority`, gone from DLQ), its Hash becomes `ReadAttempts=0`/`DirtyBit=0`
  with `ReadDateTime` **retained**, and it is redelivered (below cap) on the next dequeue; redriving a member
  not in the DLQ returns `NOOP` and changes nothing; a member already in the source is rejected (`EQDUP`) with
  no duplicate index; across Redis & Valkey, standalone + cluster
- [X] T013 [P] [US3] Unit test `tests/unit/test_msgfmt_redrive_validation.sh`: bad key count / empty member /
  tag mismatch, and a dangling or malformed message Hash → the correct `MSGFMT E...` (`EMALFORMED`) results;
  assert nothing is written on any failure

### Implementation for User Story 3

- [X] T014 [US3] Add `msgfmt_redrive` to `src/functions/message_format.lua` as a **write** function: validate
  `#KEYS == 3`, non-empty `member`, and co-location; guard with `ZSCORE` — member absent from the DLQ →
  `NOOP`, member already in the source → `EQDUP`; require the message Hash present, a hash, and carrying
  `Priority` (`EMALFORMED`); then in one atomic call `ZREM` the DLQ member, `ZADD` the source at score =
  `Priority` with the member verbatim, and `HSET ReadAttempts 0 DirtyBit 0` (retain `ReadDateTime`); return
  `OK`; register as a plain WRITE (depends on T011–T013; same file — run after T010)

**Checkpoint**: The full enqueue → dequeue → ack/nack → dead-letter → peek → redrive lifecycle is complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Flag/portability gates, documentation currency (Principle X), and cross-engine verification.

- [X] T015 Extend `tests/contract/test_function_flags.sh`: assert via `FUNCTION LIST` that `msgfmt_peek`
  carries the `no-writes` flag and is callable via `FCALL_RO`, and that `msgfmt_redrive` does **not** carry
  `no-writes` and is rejected under `FCALL_RO` (Principle VII) (depends on T010, T014)
- [X] T016 [P] Run `tests/harness/static_checks.sh` against `src/functions/message_format.lua`; confirm it
  passes with no new whitelist entries, still rejects admin/off-list commands and hardcoded literal keys, and
  the determinism scan finds no `TIME`/`math.random` in the new functions (Principles III, IV, V, VII; SC-009)
- [X] T017 [P] Update `docs/schema.md`: add the dead-letter queue (sibling Sorted Set sharing the source hash
  tag, score = `Priority`, verbatim member, index-only move, Hash never relocated), the message-lifecycle
  transitions (dead-letter, redrive), and the redrive reset semantics (`ReadAttempts=0`/`DirtyBit=0`,
  `ReadDateTime` retained)
- [X] T018 [P] Update `docs/functions.md`: add `msgfmt_peek` and `msgfmt_redrive` to the public section in
  alphabetical order (purpose, `KEYS`/`ARGV`, return shape, error table, write/no-writes), and update
  `msgfmt_dequeue` with the optional `KEYS[3]` DLQ key + trailing cap and the dead-letter behaviour
- [X] T019 [P] Update `README.md`: add dead-letter usage (dequeue with DLQ + cap), peek (single + top-N), and
  redrive (`OK` and `NOOP`) `redis-cli` examples, plus a note that the DLQ is itself peek/dequeue-able
- [X] T020 Run `specs/004-dead-letter-peek/quickstart.md` end-to-end against Redis 7.0+ and Valkey 7.2+ via the
  harness and confirm every documented command output matches (depends on T006, T010, T014)
- [X] T021 Verify documentation consistency (Principle X): every documented `KEYS`/`ARGV`/return/error, the DLQ
  concept, and the redrive reset in `docs/schema.md`, `docs/functions.md`, and `README.md` match the
  implemented `src/functions/message_format.lua` and the contracts (depends on T017–T019)
- [X] T022 Run the full suite via `tests/run_all.sh` on redis + valkey (standalone) and a cluster-mode run of
  the new suites (co-located shared-tag source + DLQ + message keys, no `CROSSSLOT`); confirm all green and that
  the entire Feature 003 suite still passes unchanged (backward-compatibility guarantee; SC-002, SC-008)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories (the shared `lease_available` helper)
- **User Stories (Phase 3–5)**: depend on Foundational. Implementation tasks (T006 → T010 → T014) all edit the
  single library file and run **sequentially** in that order; each story's test files are independent `[P]`
- **Polish (Phase 6)**: T015 depends on T010+T014; T016 after the code lands; T017–T019 are `[P]` (independent
  doc files); T020/T021/T022 after implementation + docs

### User Story Dependencies

- **US1 (P1)**: after Foundational. Independently testable — delivers dead-lettering (MVP).
- **US2 (P2)**: after Foundational; peek reuses `lease_available`. Independent of US1's dead-letter logic, but
  its implementation (T010) edits the same file as T006, so it runs after T006.
- **US3 (P3)**: after Foundational; redrive is independent of US1/US2 behaviour, but T014 edits the same file,
  so it runs after T010. Its integration test is most meaningful once US1 can produce DLQ entries.

### Parallel Opportunities

- All test-authoring tasks marked `[P]` are in distinct files and can be written together: (T004, T005),
  (T007, T008, T009), (T011, T012, T013).
- Documentation tasks T017, T018, T019 are `[P]` (independent files).
- Implementation tasks T006 / T010 / T014 are **NOT** parallel (single shared library file).

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup (confirm reuse)
2. Phase 2: Foundational (`lease_available` extraction; gate confirmation) — CRITICAL
3. Phase 3: US1 dead-letter → validate by driving a message to the cap and confirming it moves to the DLQ while
   the no-DLQ path stays Feature-003-identical
4. **STOP and VALIDATE** — MVP closes the poison-message reliability gap

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 dead-letter → test → the reliability gap is closed (MVP)
3. US2 peek → test → observability (source and DLQ)
4. US3 redrive → test → full lifecycle
5. Polish: flags + static gate + docs + cross-engine quickstart + full-suite/regression run

---

## Notes

- `[P]` = different files, no dependencies. The three functions share one library file, so their
  implementation tasks are sequential by design (T006 → T010 → T014).
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness; source, DLQ, and
  message keys share one hash tag so every multi-key call stays single-slot.
- **No constitution change and no static-gate change** for this feature (grounded in research.md).
- Commit after each task or logical group.
