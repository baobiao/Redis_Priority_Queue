---
description: "Task list for Dequeue feature implementation"
---

# Tasks: Dequeue

**Input**: Design documents from `/specs/003-dequeue/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md, and the
completed constitution amendment (Principle IV → v2.0.0)

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis
7.0+ and Valkey 7.2+ engines (standalone + cluster), so test tasks are required.

**Organization**: Grouped by user story (US1 acquire, US2 settle, US3 visibility+fencing, US4
reject-invalid). The three functions (`msgfmt_dequeue`, `msgfmt_ack`, `msgfmt_nack`) are added to
the single existing library file `src/functions/message_format.lua`; implementation tasks that
edit that file are therefore **sequential** (no `[P]`), while test files (separate paths) are
parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3 / US4 (maps to spec.md user stories)

## Path Conventions

Single-library layout reused from Features 001/002: production code in `src/functions/`, tests in
`tests/` with `harness/`, `contract/`, `integration/`, `unit/` subfolders; docs in `docs/` + root
`README.md`.

---

## Phase 1: Setup (Shared Infrastructure)

- [X] T001 Verify the reuse surface is present and unchanged: `src/functions/message_format.lua`
  (the `is_int` helper, `FIELDS`/`DEFAULTS`/`FIELD_SET`, `MAX_SAFE_INT`, the field encodings, and
  the `msgfmt_enqueue` member format `string.format('%020.0f', sequence) .. ':' .. id`), plus the
  Docker harness (`tests/harness/docker_engines.sh`, `load_and_call.sh`) and the
  `tests/{contract,integration,unit}/` layout. Confirm the constitution is at **v2.0.0** with the
  amended Principle IV. No new scaffolding required.

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: Must complete before any user-story implementation.

- [X] T002 Extend `tests/harness/static_checks.sh`: add `ZREM` and `HINCRBY` to the allowed-command
  whitelist (and to the literal-key-detection command list so a hardcoded literal key passed to
  either is still caught). Confirm the determinism scan (`TIME`/`math.random`) is unchanged and that
  a **variable-held** constructed key (`local mkey = KEYS[2] .. id; redis.call('HMGET', mkey, ...)`)
  is **not** flagged by the literal-key regex (it only catches a key argument beginning with a
  quote). Verify each new command is on the common-supported list for Redis 7.0+, Valkey 7.2+,
  ElastiCache, MemoryDB (Principles III, IV, V).
- [X] T003 In `src/functions/message_format.lua`: add a file-local hash-tag helper (extract the
  substring between the first `{` and the first following `}`), and register `msgfmt_dequeue`,
  `msgfmt_ack`, `msgfmt_nack` as **write** functions (no flags) with stub bodies; extend the header
  comment to reference `specs/003-dequeue/spec.md` (Principle I). Leave
  `msgfmt_create`/`read`/`validate`/`enqueue` unchanged.

**Checkpoint**: Library registers all three new functions and loads; the static gate permits the
new commands — user-story work can begin.

---

## Phase 3: User Story 1 - Acquire the highest-priority available message (Priority: P1) 🎯 MVP

**Goal**: A consumer retrieves the front available message in priority (then FIFO) order; it is
marked in-flight and returned with a handle; an empty/all-in-flight queue returns null.

**Independent Test**: Enqueue messages of distinct and equal priority; acquire repeatedly and
assert ascending-`Priority`, FIFO within a priority, `DirtyBit=1`/`ReadDateTime=now`/`ReadAttempts=1`
on each returned message, exact `Payload`, and null on empty.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T007)

- [X] T004 [P] [US1] Contract test in `tests/contract/test_msgfmt_dequeue_contract.sh`: `KEYS[1]`=queue,
  `KEYS[2]`=message-key prefix; `ARGV`=`now timeout [max_scan]`; returns the flat handle array on a
  hit and a null reply when empty; `MSGFMT EKEYS` on wrong key count; and the function is a WRITE
  (rejected under `FCALL_RO`).
- [X] T005 [P] [US1] Integration test in `tests/integration/test_msgfmt_dequeue_roundtrip.sh`: enqueue
  distinct priorities (incl. boundary values) and assert acquire returns ascending-`Priority`;
  enqueue equal priorities and assert FIFO by sequence; assert each returned message shows
  `DirtyBit=1`, `ReadDateTime=now`, `ReadAttempts=1` (verified via `msgfmt_read`) and exact `Payload`;
  assert empty/all-in-flight returns null (not an empty-string payload). Run on Redis & Valkey,
  standalone + cluster.
- [X] T006 [P] [US1] Concurrency test in `tests/integration/test_msgfmt_dequeue_concurrency.sh`: two
  successive acquires (simulating two consumers) on the same queue never return the same message; the
  first is skipped as in-flight by the second.

### Implementation for User Story 1

- [X] T007 [US1] Implement `msgfmt_dequeue` in `src/functions/message_format.lua`: guard `#KEYS==2`
  (`EKEYS`); validate `now` (`ENOW`), `timeout` (`ETMO`), optional `max_scan` (`ESCAN`); require
  `KEYS[1]`/`KEYS[2]` share one hash tag (`ETAG`); if `KEYS[1]` exists and is not a `zset`
  (`EMALFORMED`), else if absent return null; `ZRANGE KEYS[1] 0 -1` (bounded by `max_scan`), for each
  member derive `id` and `mkey=KEYS[2]..id`, skip+`ZREM` dangling members, error `EMALFORMED` on a
  malformed candidate, treat a message as **available** when `DirtyBit=0` **or**
  `now-ReadDateTime≥timeout`; on the first available message `HINCRBY ReadAttempts 1`,
  `HSET DirtyBit 1 ReadDateTime now`, and return the handle array (`id`, `member`, `ReadAttempts`,
  `ReadDateTime`, `Priority`, `Payload`); return null (`false`) if none found (depends on T003; same
  file). *Availability-by-expiry here also delivers the reclaim half of US3.*

**Checkpoint**: Messages can be acquired in priority/FIFO order and marked in-flight; MVP usable.

---

## Phase 4: User Story 2 - Settle a lease: acknowledge or release (Priority: P2)

**Goal**: `msgfmt_ack` removes a processed message (member + Hash); `msgfmt_nack` releases the lease
(`DirtyBit→0`, retaining `ReadDateTime`/`ReadAttempts`); both are fenced and idempotent.

**Independent Test**: Acquire, then ack → message gone and not re-acquirable; acquire another, then
nack → available again on next acquire with `ReadAttempts` retained; ack/nack on a non-leased message
→ `ENOTLEASED`; retry on an absent message → `NOOP`.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T009)

- [X] T008 [US2] Extend `tests/integration/test_msgfmt_dequeue_roundtrip.sh` (settle happy paths; sequential — same file as T005):
  after acquiring, `msgfmt_ack` removes the member (`ZCARD` decreases) and deletes the Hash
  (`msgfmt_read` → `NOTFOUND`) and a re-ack returns `NOOP`; after acquiring another, `msgfmt_nack`
  sets `DirtyBit=0` while `ReadDateTime`/`ReadAttempts` are retained and the next acquire returns it
  again with a higher `ReadAttempts`. Across Redis & Valkey.

### Implementation for User Story 2

- [X] T009 [US2] Implement `msgfmt_ack` and `msgfmt_nack` in `src/functions/message_format.lua`:
  `msgfmt_ack` guards `#KEYS==2` (`EKEYS`), requires non-empty `member` + integer `token` (`EARGS`),
  returns `NOOP` if `KEYS[2]` absent, `EMALFORMED` on wrong-type/missing-field, `ENOTLEASED` if
  `DirtyBit≠1`, `EFENCED` if `ReadAttempts≠token`, else `ZREM KEYS[1] member` + `DEL KEYS[2]` → `OK`.
  `msgfmt_nack` guards `#KEYS==1` (`EKEYS`), requires integer `token` (`EARGS`), returns `NOOP` if
  absent, `EMALFORMED`/`ENOTLEASED`/`EFENCED` as above, else `HSET KEYS[1] DirtyBit 0` → `OK`
  (retaining `ReadDateTime`/`ReadAttempts`) (depends on T007; same file). *The fencing checks here
  also deliver the fencing half of US3.*

**Checkpoint**: The full acquire → process → settle lifecycle drains the queue correctly.

---

## Phase 5: User Story 3 - Reclaim messages abandoned by crashed consumers (Priority: P3)

**Goal**: An unsettled lease older than the visibility timeout is reclaimed by a later acquire; a
stale (superseded) handle can no longer settle the message (fencing).

**Independent Test**: Acquire at `now=T` with timeout `D`; acquire at `now<T+D` skips it; acquire at
`now≥T+D` reclaims it with a higher `ReadAttempts` and a new token; the original token can no longer
ack/nack (`EFENCED`).

### Tests for User Story 3 ⚠️ (write first, must FAIL before verifying against T007/T009)

- [X] T010 [P] [US3] Integration test in `tests/integration/test_msgfmt_dequeue_visibility.sh`: acquire
  a message at `now=T`, timeout `D`; assert an acquire at `now<T+D` does not return it (still leased);
  assert an acquire at `now≥T+D` reclaims it (`ReadDateTime` updated, `ReadAttempts` incremented
  again, new token); assert the original token now fails both `msgfmt_ack` and `msgfmt_nack` with
  `EFENCED` and leaves the reacquired lease untouched. Across Redis & Valkey, standalone + cluster.

**Note**: US3 requires no new implementation — expiry-based availability is built in T007 and the
fencing check in T009. T010 verifies both; if any gap is found, fix it in the respective function
(same file).

**Checkpoint**: Crashed-consumer messages recover after the timeout; stale settles are rejected.

---

## Phase 6: User Story 4 - Reject invalid or conflicting requests without side effects (Priority: P4)

**Goal**: All malformed inputs, wrong-type targets, tag mismatches, and non-leased/absent settles
return structured `MSGFMT E…` errors (or `NOOP`) with no writes.

**Independent Test**: Drive each rejection and assert the correct reply and that queue cardinality
(`ZCARD`) and every message Hash are unchanged.

### Tests for User Story 4 ⚠️ (write first, must FAIL before verifying against T007/T009)

- [X] T011 [P] [US4] Unit test in `tests/unit/test_msgfmt_dequeue_validation.sh`: for `msgfmt_dequeue`
  — wrong key count (`EKEYS`), bad `now` (`ENOW`), bad `timeout` (`ETMO`), bad `max_scan` (`ESCAN`),
  tag mismatch (`ETAG`), non-`zset` queue (`EMALFORMED`); for `msgfmt_ack`/`msgfmt_nack` — wrong key
  count (`EKEYS`), missing member/token (`EARGS`), non-leased message (`ENOTLEASED`), fence mismatch
  (`EFENCED`), absent message (`NOOP`), wrong-type/missing-field (`EMALFORMED`). In every failing
  case assert `ZCARD` and the target Hash are unchanged (fail-before-write).

**Note**: US4 requires no new implementation beyond the guards built in T007/T009; T011 verifies them.

**Checkpoint**: Every rejection path is structured and side-effect-free.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T012 [P] Run `specs/003-dequeue/quickstart.md` end-to-end via the harness on Redis 7.0+ and
  Valkey 7.2+ and confirm every documented output (ordering, ack/nack, null, timeout reclaim,
  fencing, error cases) matches.
- [X] T013 [P] Extend `tests/contract/test_function_flags.sh` to assert via `FUNCTION LIST` that
  `msgfmt_dequeue`, `msgfmt_ack`, and `msgfmt_nack` carry **no** `no-writes` flag and are rejected
  under `FCALL_RO` (Principle VII).
- [X] T014 Run the extended `tests/harness/static_checks.sh` against the library and confirm it
  passes: `ZREM`/`HINCRBY` allow-listed, admin/off-list commands still rejected, the determinism scan
  finds no `TIME`/random, and no hardcoded literal keys (Principles III, IV, V, VII; supports SC-011).
- [X] T015 [P] Add/confirm a cluster-mode run of the dequeue suites, asserting the queue key, the
  message-key prefix, and every constructed `KEYS[2]..id` are co-located (shared hash tag) with no
  `CROSSSLOT` (Principle IV as amended, FR-015).
- [X] T016 [P] Confirm the `message_format.lua` header references `specs/003-dequeue/spec.md`, that
  `contracts/functions.md` matches the implemented return shapes and error strings, and (by
  inspection/test) that acquire's only runtime-constructed key is `KEYS[2]..id` from the declared,
  hash-tagged prefix (Principles I, IV, VIII traceability).

---

## Phase 8: Developer Documentation (Principle X)

**⚠️ Documentation is updated in this same feature** (Principle X). No new engine tests; the suite is
re-run for regression only (T020).

- [X] T017 [P] Update `docs/functions.md`: add `msgfmt_dequeue`, `msgfmt_ack`, `msgfmt_nack` to the
  public (FCALL-able) section in alphabetical order, each with purpose, write status, `KEYS`/`ARGV`,
  return shape, and error table; add the new error codes (`ENOW`, `ETMO`, `ESCAN`, `ETAG`,
  `ENOTLEASED`, `EFENCED`, `NOOP`).
- [X] T018 [P] Update `docs/schema.md`: document the lease lifecycle over the existing Hash fields
  (`DirtyBit`/`ReadDateTime`/`ReadAttempts`), the visibility timeout, the fencing token, and the
  message-key prefix + `id` co-location convention used by dequeue.
- [X] T019 [P] Update root `README.md`: add dequeue/ack/nack to the usage section with `FCALL`
  examples and a short lease/visibility/fencing explanation; note the constitution is now v2.0.0.
- [X] T020 Verify documentation consistency across `docs/schema.md`, `docs/functions.md`, `README.md`,
  and the contracts (every field, function, error code, command, and native type matches the
  implemented library), then re-run the full suite via `tests/run_all.sh` on Redis + Valkey and
  confirm it is green (documentation/constitution changes cause no regression) (depends on
  T017–T019 and Phases 3–6).

**Checkpoint**: Docs updated (Principle X), constitution at v2.0.0, suite green on both engines.

---

## Dependencies & Execution Order

- **Setup (Phase 1)** → **Foundational (Phase 2)** blocks all user stories.
- **US1 (Phase 3)**: after Foundational; T007 (impl) after T004–T006 (tests) fail first. MVP.
- **US2 (Phase 4)**: after US1 (settle acts on acquired messages); T009 after T007 and after T008
  fails first. Same file as T007 ⇒ sequential.
- **US3 (Phase 5)** and **US4 (Phase 6)**: their behaviour is built into T007/T009; T010/T011 are
  written first and then verified against the implementation, fixing gaps in the same file if needed.
- **Polish (Phase 7)**: after US1–US4.
- **Documentation (Phase 8)**: after the library behaviour is final; T017–T019 are `[P]` (distinct
  files), T020 after them + full regression.

### Parallel Opportunities

- Test-authoring in different files is parallel: (T004, T005, T006), then (T010), (T011). T008
  extends the T005 file, so it is sequential after T005 (not parallel with it).
- Doc tasks T017, T018, T019 are `[P]` (distinct files) — draftable by parallel sub-agents.
- Implementation tasks T007 and T009 are **not** parallel (single shared library file).

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Setup + Foundational (static gate + stubs) — CRITICAL.
2. US1 acquire → validate by acquiring and inspecting order/FIFO/lease fields and null-on-empty.
3. **STOP and VALIDATE**, then optionally demo.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 acquire → test → demo (MVP).
3. US2 settle (ack/nack + fencing + idempotency) → test → demo.
4. US3 visibility reclaim + fencing → verify.
5. US4 rejection/atomicity → verify.
6. Polish (quickstart, flags, static gate, cluster, traceability) + Documentation (Principle X).

---

## Notes

- [P] = different files, no dependencies. The three functions share one file, so their
  implementation tasks are sequential by design.
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness; the queue
  key, the message-key prefix, and every constructed message key share one hash tag (single slot).
- Commit after each task or logical group.
