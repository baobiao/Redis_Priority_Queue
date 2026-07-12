---
description: "Task list for Delayed Visibility (Scheduled Delivery & Retry Backoff)"
---

# Tasks: Delayed Visibility (Scheduled Delivery & Retry Backoff)

**Input**: Design documents from `/specs/005-delayed-visibility/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis 7.0+
and Valkey 7.2+ engines (standalone + cluster).

**Organization**: Grouped by user story — US1 scheduled delivery (P1), US2 retry backoff (P2),
US3 observe & compose (P3). All edits are in the single library file
`src/functions/message_format.lua`, so implementation tasks are **sequential** (no `[P]`); test
files (separate paths) are parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency)
- **[Story]**: US1 / US2 / US3
- Exact file paths included

## Path Conventions

Single-library layout (from plan.md), reused from Features 001–004.

---

## Phase 1: Setup (Shared Infrastructure)

- [X] T001 Verify the existing single-library layout and Docker harness are present and reusable —
  `src/functions/message_format.lua` (fields `FIELDS`/`FIELD_SET`/`DEFAULTS`, `encode_field`,
  `build_message`, `parse_args`, `lease_available`, `msgfmt_read/dequeue/peek/nack/redrive`),
  `tests/harness/{docker_engines,load_and_call,static_checks}.sh`, and `tests/{contract,integration,unit}/`
  — confirm no new scaffolding is required (Feature 005 extends the existing library)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Add the `VisibleAt` field and the shared visibility predicate — every user story depends
on these. Confirm the static gate is unaffected.

**⚠️ CRITICAL**: No user-story implementation should land until this phase is complete.

- [X] T002 In `src/functions/message_format.lua`: add `VisibleAt` to `FIELDS` (appended last),
  `FIELD_SET`, and `DEFAULTS` (`VisibleAt = '0'`); extend the `encode_field` integer branch so
  `VisibleAt` validates as `0 … 2^53` and stores `%.0f` (identical to `ReadDateTime`); and add a
  file-local helper `is_visible(visibleat, now)` returning `(tonumber(visibleat) or 0) <= now` (a
  missing/`nil` value → immediately visible). Confirm `build_message`/`parse_args` pick the field up
  with no change, so `msgfmt_create`/`msgfmt_enqueue`/`msgfmt_validate` accept `VisibleAt` as a normal
  field with no signature change. Update the library header to reference `specs/005-delayed-visibility/spec.md`
- [X] T003 Confirm `tests/harness/static_checks.sh` needs **no** change: the not-before gate uses only
  `HSET`/`HMGET`/`HGET` (already whitelisted) plus Lua arithmetic on the caller's `now`; no new
  command; the determinism scan (no `TIME`/`math.random`) still holds; the whole-file scan covers the
  edited functions (Principles III, V, VII)

**Checkpoint**: `VisibleAt` exists and is validated/encoded; `is_visible` is available; enqueue/create
accept it — user-story work can begin.

---

## Phase 3: User Story 1 - Schedule a message for future delivery (Priority: P1) 🎯 MVP

**Goal**: A message enqueued with a future `VisibleAt` is skipped by `msgfmt_dequeue` until
`now ≥ VisibleAt`, then delivered normally in its priority/FIFO position. Omitting/`0` `VisibleAt` is
immediately visible (Feature 002/003 behaviour).

**Independent Test**: Enqueue with a future `VisibleAt`; dequeue before → skipped (null/next);
dequeue at/after → delivered; a `VisibleAt=0`/absent message behaves exactly as today.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T006)

- [X] T004 [P] [US1] Integration test `tests/integration/test_msgfmt_scheduled.sh`: a message with a
  future `VisibleAt` is not leased while `now < VisibleAt` (null / next message returned) and its
  fields are unchanged; at `now == VisibleAt` and `now > VisibleAt` it is leased normally; a
  not-yet-visible high-priority message does not block a visible lower-priority one (ordering among
  visible messages unchanged); a `VisibleAt=0`/omitted message is immediately visible; run across
  Redis & Valkey, standalone + cluster
- [X] T005 [P] [US1] Unit test `tests/unit/test_msgfmt_visibleat_field_validation.sh`: `msgfmt_create`,
  `msgfmt_validate`, and `msgfmt_enqueue` accept a valid `VisibleAt` and reject a non-integer /
  negative / `> 2^53` value with `MSGFMT EINVAL: VisibleAt`, writing nothing on failure

### Implementation for User Story 1

- [X] T006 [US1] Extend `msgfmt_dequeue` in `src/functions/message_format.lua`: add `VisibleAt` to the
  scan `HMGET` (coalesce a missing value to `0`); select a candidate only when `lease_available(...)`
  **and** `is_visible(VisibleAt, now)`; a not-yet-visible message is skipped and the scan continues
  (still bounded by `max_scan`). Leave the dead-letter cap check where it is (after the eligibility
  gate) so a not-yet-visible over-cap message is not dead-lettered; leave the return shape unchanged
  (depends on T002; same file as T010/T014 — run sequentially)

**Checkpoint**: Scheduled delivery works; the default (`VisibleAt=0`) path is unchanged — MVP usable.

---

## Phase 4: User Story 2 - Release a failed message with a backoff delay (Priority: P2)

**Goal**: `msgfmt_nack` gains an optional `VisibleAt`; when supplied it sets the not-before alongside
`DirtyBit=0` (retaining `ReadDateTime`/`ReadAttempts`), so the message is redelivered only once
`now ≥ VisibleAt`. Omitting it is exactly Feature 003.

**Independent Test**: Lease a message, nack with a future `VisibleAt`; not redelivered before it,
redelivered after it with `ReadAttempts` retained; a plain nack is unchanged; fencing intact.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T010)

- [X] T007 [P] [US2] Integration test `tests/integration/test_msgfmt_retry_backoff.sh`: nack with a
  future `VisibleAt` sets `DirtyBit=0` + `VisibleAt`, retaining `ReadDateTime`/`ReadAttempts`; the
  message is not redelivered while `now < VisibleAt` and is redelivered (with `ReadAttempts`
  incremented from the retained value) once `now ≥ VisibleAt`; a plain nack (no `VisibleAt`) is
  immediately available (Feature 003 parity); across Redis & Valkey
- [X] T008 [P] [US2] Unit test `tests/unit/test_msgfmt_nack_visibleat_validation.sh`: a nack with an
  invalid `VisibleAt` (`ARGV[2]` non-integer / negative / `> 2^53`) returns `MSGFMT EVIS: visibleAt
  must be a non-negative integer` and writes nothing (message unchanged)
- [X] T009 [P] [US2] Contract test `tests/contract/test_msgfmt_nack_contract.sh`: `KEYS[1]`=message
  Hash; `ARGV[1]`=token, optional `ARGV[2]`=`VisibleAt`; `OK`/`NOOP`/`ENOTLEASED`/`EFENCED` unchanged;
  the optional `VisibleAt` path and `EVIS`; `msgfmt_nack` is a **write** (rejected under `FCALL_RO`)

### Implementation for User Story 2

- [X] T010 [US2] Extend `msgfmt_nack` in `src/functions/message_format.lua`: accept optional
  `ARGV[2]` = `VisibleAt`; if present, validate as a non-negative integer `0 … 2^53` (`EVIS`,
  fail-before-write) and on success `HSET DirtyBit 0 VisibleAt <value>`; if absent, keep the existing
  `HSET DirtyBit 0` (leave `VisibleAt` untouched). Fencing/`NOOP`/`ENOTLEASED` unchanged (depends on
  T002; same file — run after T006)

**Checkpoint**: Retry backoff works; a plain nack is unchanged.

---

## Phase 5: User Story 3 - Observe and reset not-before state (Priority: P3)

**Goal**: `msgfmt_read` returns `VisibleAt` (missing → `0`); `msgfmt_peek` single mode honours it and
top-N reports it; `msgfmt_redrive` resets it to `0`. Dead-letter defers until visible (falls out of
T006).

**Independent Test**: Read a scheduled message → `VisibleAt` present; read a pre-005 5-field message →
`VisibleAt=0`, no error; peek single skips not-yet-visible while top-N reports it; redrive → `VisibleAt=0`.

### Tests for User Story 3 ⚠️ (write first, must FAIL before T014)

- [X] T011 [P] [US3] Integration test `tests/integration/test_msgfmt_visibility_compose.sh`:
  `msgfmt_read` includes `VisibleAt`; a message stored with only the five original fields reads (and
  dequeues) as `VisibleAt=0` with no `EMALFORMED` (back-compat); `msgfmt_peek` single mode skips a
  not-yet-visible front message while top-N lists it with its `VisibleAt`; a not-yet-visible over-cap
  message is dead-lettered only once visible; `msgfmt_redrive` resets `VisibleAt` to `0`; across
  Redis & Valkey
- [X] T012 [P] [US3] Extend `tests/contract/test_msgfmt_read_contract.sh`: the returned shape includes
  `VisibleAt` as the sixth pair with its stored value; a Hash missing only `VisibleAt` reads as `0`
  (no error), while a Hash missing one of the five original fields still returns `EMALFORMED`
- [X] T013 [P] [US3] Extend `tests/contract/test_msgfmt_peek_contract.sh`: each record (single and
  top-N) includes `VisibleAt`; single mode skips a not-yet-visible front message; top-N reports it

### Implementation for User Story 3

- [X] T014 [US3] In `src/functions/message_format.lua`: (a) `msgfmt_read` — add `VisibleAt` to the
  `HMGET`, coalesce a missing value to `0` (keep the five original fields strictly required), and
  append `VisibleAt` to the returned shape; (b) `msgfmt_peek` — add `VisibleAt` to the scan `HMGET`
  (missing → `0`) and to each record, and gate single mode on `lease_available(...) and
  is_visible(...)` (top-N still reports all); (c) `msgfmt_redrive` — add `VisibleAt 0` to the reset
  `HSET` (depends on T002; same file — run after T010)

**Checkpoint**: Read/peek expose `VisibleAt`, back-compat holds, redrive resets it — feature complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T015 [P] Run `tests/harness/static_checks.sh` against `src/functions/message_format.lua`;
  confirm green with no new whitelist entries and the determinism scan finding no `TIME`/`math.random`
  in the edited functions (Principles III, V, VII; SC-009)
- [X] T016 [P] Update `docs/schema.md`: add the sixth field `VisibleAt` (type/default/encoding/
  validation) to the message table; add a "Delayed visibility (not-before)" subsection that defines
  the `now ≥ VisibleAt` eligibility gate and **explicitly contrasts it with the Feature 003 lease
  visibility timeout**; document the missing→0 back-compat rule
- [X] T017 [P] Update `docs/functions.md`: `msgfmt_read` (sixth field + missing→0), `msgfmt_nack`
  (optional `VisibleAt` arg + `EVIS`), `msgfmt_peek` (record `VisibleAt` + single-mode gate),
  `msgfmt_dequeue` (eligibility now includes `VisibleAt`), `msgfmt_redrive` (reset adds `VisibleAt 0`),
  and note that `msgfmt_create`/`msgfmt_enqueue` accept `VisibleAt` as a field
- [X] T018 [P] Update `README.md`: add scheduled-delivery (enqueue with `VisibleAt`) and retry-backoff
  (nack with `VisibleAt`) `redis-cli` examples, keeping the lease timeout vs delayed-visibility
  distinction clear
- [X] T019 Run `specs/005-delayed-visibility/quickstart.md` end-to-end against Redis 7.0+ and Valkey
  7.2+ via the harness and confirm every documented output matches (depends on T006, T010, T014)
- [X] T020 Verify documentation consistency (Principle X): the `VisibleAt` field, the eligibility
  rule, `EVIS`, and every changed return/behaviour in `docs/schema.md`, `docs/functions.md`, and
  `README.md` match the implemented `src/functions/message_format.lua` and the contracts (depends on
  T016–T018)
- [X] T021 Run the full suite via `tests/run_all.sh` on redis + valkey (standalone) and a cluster-mode
  run (co-located shared-tag keys, no `CROSSSLOT`); confirm all green and that the entire Feature
  001–004 suite still passes unchanged (default `VisibleAt=0` path; SC-002, SC-009)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories (the `VisibleAt` field + `is_visible`)
- **User Stories (Phase 3–5)**: depend on Foundational. Implementation tasks (T006 → T010 → T014) all
  edit the single library file and run **sequentially** in that order; each story's test files are
  independent `[P]`
- **Polish (Phase 6)**: T015 after the code lands; T016–T018 are `[P]` (independent doc files);
  T019/T020/T021 after implementation + docs

### User Story Dependencies

- **US1 (P1)**: after Foundational. Independently testable — delivers scheduled delivery (MVP).
- **US2 (P2)**: after Foundational; its impl (T010) edits the same file as T006, so runs after T006.
  Independent of US1 behaviour otherwise.
- **US3 (P3)**: after Foundational; its impl (T014) edits the same file, runs after T010. Its
  dead-letter-defer assertion is most meaningful once US1's gate (T006) is in place.

### Parallel Opportunities

- Test-authoring tasks marked `[P]` are in distinct files: (T004, T005), (T007, T008, T009),
  (T011, T012, T013).
- Documentation tasks T016, T017, T018 are `[P]`.
- Implementation tasks T006 / T010 / T014 are **NOT** parallel (single shared library file).

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup (confirm reuse)
2. Phase 2: Foundational (`VisibleAt` field + `is_visible`; gate confirmation) — CRITICAL
3. Phase 3: US1 scheduled delivery → validate a future-dated message is skipped then delivered, and
   the default path is unchanged
4. **STOP and VALIDATE** — MVP delivers scheduled delivery

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 scheduled delivery → test → MVP
3. US2 retry backoff → test → the high-value operational win
4. US3 observe & compose → test → read/peek/redrive integration + back-compat
5. Polish: static gate + docs + quickstart + full-suite/regression run

---

## Notes

- `[P]` = different files, no dependencies. The functions share one library file, so their
  implementation tasks are sequential by design (T006 → T010 → T014).
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness.
- **No constitution change and no static-gate change** for this feature (grounded in research.md);
  `VisibleAt` is a documented schema/contract evolution requiring only the Principle X docs update.
- Commit after each task or logical group.
