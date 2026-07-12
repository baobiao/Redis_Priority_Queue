---
description: "Task list for DLQ Retention & Observability"
---

# Tasks: DLQ Retention & Observability

**Input**: Design documents from `/specs/006-dlq-retention-observability/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/functions.md

**Tests**: INCLUDED — Constitution Principle IX mandates a test-first discipline on real Redis 7.0+
and Valkey 7.2+ engines (standalone + cluster).

**Organization**: Grouped by user story — US1 DLQ retention (P1), US2 observability (P2). All edits
are in the single library file `src/functions/message_format.lua`, so implementation tasks are
**sequential** (no `[P]`); test files (separate paths) are parallelizable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency)
- **[Story]**: US1 / US2
- Exact file paths included

## Path Conventions

Single-library layout (from plan.md), reused from Features 001–005.

---

## Phase 1: Setup (Shared Infrastructure)

- [X] T001 Verify the existing single-library layout and Docker harness are present and reusable —
  `src/functions/message_format.lua` (fields, `encode_field`, `build_message`, `lease_available`,
  `is_visible`, `msgfmt_dequeue` dead-letter branch, `msgfmt_redrive`, `msgfmt_read`, `msgfmt_peek`),
  `tests/harness/*.sh`, `tests/{contract,integration,unit}/` — confirm no new scaffolding is required

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: Both user stories depend on the new field.

- [X] T002 In `src/functions/message_format.lua`: add `DeadLetteredAt` to `FIELDS` (appended last),
  `FIELD_SET`, and `DEFAULTS` (`DeadLetteredAt = '0'`); extend the `encode_field` integer branch so
  `DeadLetteredAt` validates `0 … 2^53` and stores `%.0f` (identical to `ReadDateTime`/`VisibleAt`).
  Confirm `build_message`/`parse_args` need no change (so `msgfmt_create`/`msgfmt_enqueue`/
  `msgfmt_validate` accept it as a normal field). Update the library header to reference
  `specs/006-dlq-retention-observability/spec.md`
- [X] T003 Confirm `tests/harness/static_checks.sh` needs **no** change: reap/stats use only
  already-whitelisted `ZCARD`/`ZRANGE`/`HMGET`/`HGET`/`ZREM`/`DEL`; no new command; the determinism
  scan still holds; the whole-file scan covers the new functions (Principles III, V, VII)

**Checkpoint**: `DeadLetteredAt` exists and validates/encodes; enqueue/create accept it — user-story work can begin.

---

## Phase 3: User Story 1 - Age out old dead-lettered messages (Priority: P1) 🎯 MVP

**Goal**: Dead-lettering stamps `DeadLetteredAt=now`; a bounded `msgfmt_reap` permanently removes DLQ
entries older than a caller-supplied retention window (member + Hash); `msgfmt_redrive` clears
`DeadLetteredAt`; `msgfmt_read`/`msgfmt_peek` surface it (missing → 0).

**Independent Test**: Dead-letter messages, advance `now` past the window for some, reap; expired ones
gone (DLQ member + Hash), within-window ones kept; reap bounded by `limit` and reports counts; a
redriven message has `DeadLetteredAt=0`.

### Tests for User Story 1 ⚠️ (write first, must FAIL before T008–T011)

- [X] T004 [P] [US1] Integration test `tests/integration/test_msgfmt_retention.sh`: dead-lettering
  stamps `DeadLetteredAt=now`; `msgfmt_reap` removes entries with `DeadLetteredAt ≤ now−retention`
  (member absent from DLQ + Hash deleted) and keeps within-window ones; a `limit` smaller than the
  expired set removes at most `limit` and reports `truncated`; a dangling DLQ member is cleaned and
  counted; a redriven message has `DeadLetteredAt=0`; across Redis & Valkey, standalone + cluster
- [X] T005 [P] [US1] Contract test `tests/contract/test_msgfmt_reap_contract.sh`: `KEYS[1]`=DLQ,
  `KEYS[2]`=prefix; `ARGV`=`now`,`retention`,`limit`; returns the `{removed,scanned,truncated}` map;
  `msgfmt_reap` is a **write** (rejected under `FCALL_RO`); assert `EKEYS`/`ENOW`/`ERET`/`ELIMIT`/`ETAG`
  and `EMALFORMED` (non-zset DLQ)
- [X] T006 [P] [US1] Unit test `tests/unit/test_msgfmt_reap_validation.sh`: invalid `now`/`retention`/
  `limit`, hash-tag mismatch, and a non-`zset` DLQ return the correct `MSGFMT E...` errors; assert
  nothing is written on any failure
- [X] T007 [P] [US1] Extend `tests/contract/test_msgfmt_read_contract.sh`: the read shape includes
  `DeadLetteredAt` as the final pair; a message missing only `DeadLetteredAt` reads as `0` (no error),
  while a message missing one of the five original fields still returns `EMALFORMED`

### Implementation for User Story 1

- [X] T008 [US1] In `src/functions/message_format.lua`, extend `msgfmt_dequeue`'s dead-letter branch:
  in addition to `ZREM` source + `ZADD` dlq, add `HSET <mkey> DeadLetteredAt <now>` (still no re-lease,
  no other field touched) (depends on T002; same file — sequential)
- [X] T009 [US1] Extend `msgfmt_redrive`'s reset `HSET` to also set `DeadLetteredAt 0` (depends on T002;
  same file — run after T008)
- [X] T010 [US1] Extend `msgfmt_read` (add `DeadLetteredAt` to the `HMGET` + returned shape, coalesce
  missing→0, keep the five original fields strictly required) and `msgfmt_peek` (add `DeadLetteredAt`
  to the record, missing→0) (depends on T002; same file — run after T009)
- [X] T011 [US1] Add `msgfmt_reap` (WRITE) to `src/functions/message_format.lua`: `KEYS[1]`=DLQ,
  `KEYS[2]`=prefix; validate `#KEYS==2`, `now` (`ENOW`), `retention` (`ERET`), `limit` (`ELIMIT`),
  co-location (`ETAG`); absent DLQ → `{removed:0,scanned:0,truncated:0}`, non-`zset` → `EMALFORMED`;
  `ZRANGE` the front up to `limit`, and for each member remove it (`ZREM` + `DEL` the Hash) when the
  Hash is missing (dangling cleanup) or `DeadLetteredAt ≤ now−retention`; return
  `{removed,scanned,truncated}` (`truncated` when `ZCARD > limit`); register as a plain WRITE
  (depends on T002, T004–T006; same file — run after T010)

**Checkpoint**: Retention works; dead-letter stamps the timestamp; redrive clears it — MVP usable.

---

## Phase 4: User Story 2 - See queue state without consuming (Priority: P2)

**Goal**: A read-only `msgfmt_stats` reports cheap depths + front Priority always, and an optional
bounded state breakdown (available / in-flight / delayed + truncated) + approximate oldest-dead-letter
age when a scan limit is given.

**Independent Test**: With a mix of available/leased/not-yet-visible messages and a DLQ, `msgfmt_stats`
returns exact depths + front Priority; a bounded breakdown returns state counts over the scanned prefix
with `truncated` when the queue exceeds the limit; nothing is mutated.

### Tests for User Story 2 ⚠️ (write first, must FAIL before T015)

- [X] T012 [P] [US2] Integration test `tests/integration/test_msgfmt_stats.sh`: exact `depth`/
  `dlq_depth` (independent of a scan) + `front_priority`; a bounded breakdown classifies the scanned
  front as available / in-flight / delayed with `truncated` set when depth > `max_scan`; an approximate
  `oldest_dead_letter_age` from the scanned DLQ prefix; every message field byte-for-byte unchanged
  after the call (no mutation); empty queue → zero depths; across Redis & Valkey
- [X] T013 [P] [US2] Contract test `tests/contract/test_msgfmt_stats_contract.sh`: `KEYS`=queue,
  prefix, optional DLQ; `ARGV`=`now`,`timeout`,optional `max_scan`; cheap-tier map shape; `msgfmt_stats`
  is **no-writes** (callable via `FCALL_RO`); assert `EKEYS`/`ENOW`/`ETMO`/`ESCAN`/`ETAG` and
  `EMALFORMED` (non-zset)
- [X] T014 [P] [US2] Unit test `tests/unit/test_msgfmt_stats_validation.sh`: invalid `now`/`timeout`/
  `max_scan`, hash-tag mismatch, and a non-`zset` queue return the correct `MSGFMT E...` errors; assert
  nothing is written (read-only)

### Implementation for User Story 2

- [X] T015 [US2] Add `msgfmt_stats` (NO-WRITES) to `src/functions/message_format.lua`: `KEYS[1]`=queue,
  `KEYS[2]`=prefix, optional `KEYS[3]`=DLQ; `ARGV`=`now`,`timeout`,optional `max_scan`; validate keys/
  args + co-location; cheap tier `depth`=`ZCARD KEYS[1]`, `dlq_depth`=`ZCARD KEYS[3]`, `front_priority`
  from `ZRANGE KEYS[1] 0 0 WITHSCORES`; when `max_scan>0`, scan the front and classify each via
  `lease_available`/`is_visible` (available/in_flight/delayed, skip+count dangling/malformed) with
  `truncated`, and (with a DLQ) an approximate `oldest_dead_letter_age` from the scanned DLQ prefix;
  return a flat map; register with `flags = { 'no-writes' }` (depends on T002, T012–T014; same file —
  run after T011)

**Checkpoint**: Aggregate queue state is observable read-only, cheaply and (optionally) with a bounded breakdown.

---

## Phase 5: Polish & Cross-Cutting Concerns

- [X] T016 [P] Run `tests/harness/static_checks.sh`; confirm green with no new whitelist entries and no
  `TIME`/`math.random` in the new functions (Principles III, V, VII; SC-008)
- [X] T017 [P] Update `docs/schema.md`: add the seventh field `DeadLetteredAt`; a DLQ-retention section
  (dead-letter stamp, reap semantics — member+Hash removal, bounded by `limit`, the Priority-order
  draining caveat) and the missing→0 back-compat note
- [X] T018 [P] Update `docs/functions.md`: add `msgfmt_reap` + `msgfmt_stats`; update `msgfmt_dequeue`
  (dead-letter stamp), `msgfmt_redrive` (reset adds `DeadLetteredAt 0`), and `msgfmt_read`/`msgfmt_peek`
  (the new field)
- [X] T019 [P] Update `README.md`: add retention (reap) and observability (stats) `redis-cli` examples
- [X] T020 Run `specs/006-dlq-retention-observability/quickstart.md` end-to-end on Redis 7.0+ and
  Valkey 7.2+ via the harness; confirm every documented output matches (depends on T008–T011, T015)
- [X] T021 Verify documentation consistency (Principle X): the `DeadLetteredAt` field, `msgfmt_reap`/
  `msgfmt_stats` `KEYS`/`ARGV`/return/errors, and the dead-letter/redrive/read/peek changes in
  `docs/schema.md`, `docs/functions.md`, and `README.md` match the implemented library and the
  contracts (depends on T017–T019)
- [X] T022 Run the full suite via `tests/run_all.sh` on redis + valkey (standalone) and a cluster-mode
  run (co-located shared-tag keys, no `CROSSSLOT`); confirm all green and that the entire Feature
  001–005 suite still passes unchanged (SC-004, SC-008)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories (the `DeadLetteredAt` field)
- **User Stories (Phase 3–4)**: depend on Foundational. Implementation tasks (T008 → T009 → T010 →
  T011 → T015) all edit the single library file and run **sequentially** in that order; each story's
  test files are independent `[P]`
- **Polish (Phase 5)**: after the code lands; T017–T019 are `[P]`; T020/T021/T022 after implementation + docs

### User Story Dependencies

- **US1 (P1)**: after Foundational. Independently testable — delivers retention (MVP).
- **US2 (P2)**: after Foundational; its impl (T015) edits the same file as US1's tasks, so it runs
  after T011. Independent of US1 behaviour otherwise, though its DLQ-depth output complements reap.

### Parallel Opportunities

- Test-authoring tasks marked `[P]` are in distinct files: (T004, T005, T006, T007), (T012, T013, T014).
- Documentation tasks T017, T018, T019 are `[P]`.
- Implementation tasks T008 / T009 / T010 / T011 / T015 are **NOT** parallel (single shared library file).

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup
2. Phase 2: Foundational (`DeadLetteredAt` field) — CRITICAL
3. Phase 3: US1 retention → validate dead-letter stamps + reap removes expired / keeps recent
4. **STOP and VALIDATE** — MVP bounds DLQ growth

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 retention → test → MVP
3. US2 observability → test → aggregate visibility (complements reap via DLQ depth)
4. Polish: static gate + docs + quickstart + full-suite/regression run

---

## Notes

- `[P]` = different files, no dependencies. The functions share one library file, so their
  implementation tasks are sequential by design (T008 → T009 → T010 → T011 → T015).
- Tests must FAIL before the corresponding implementation task (Principle IX, test-first).
- Tests run on Redis 7.0+ and Valkey 7.2+, standalone and cluster, via the Docker harness.
- **No constitution change and no static-gate change** for this feature (grounded in research.md).
- Mechanism-A reap examines the DLQ front in Priority order; full draining requires sizing `limit` to
  the DLQ depth (from `msgfmt_stats`) or paging — verified in the retention integration test.
- Commit after each task or logical group.
