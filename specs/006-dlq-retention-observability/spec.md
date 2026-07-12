# Feature Specification: DLQ Retention & Observability

**Feature Branch**: `006-dlq-retention-observability`
**Created**: 2026-07-12
**Status**: Draft
**Input**: User description: "Feature 006 DLQ Retention and Observability — age out dead-lettered messages after a retention window, and a read-only stats function reporting aggregate queue state."

## Overview

Two operational capabilities, added to the existing `message_format` library and reusing its
message Hash, priority Sorted Set, and dead-letter queue unchanged in shape:

- **Dead-letter retention (US1)** — a dead-lettered message that has sat in the dead-letter queue
  (DLQ) longer than a caller-supplied retention window is permanently removed (both its DLQ index
  member and its message Hash), so the DLQ does not grow without bound. To know a message's age, the
  moment it is dead-lettered is now recorded in a new message field, **`DeadLetteredAt`** (epoch ms;
  default `0`). A new bounded function **`msgfmt_reap`** removes expired entries; the caller supplies
  `now`, the retention window, and a per-call limit (bounded execution).
- **Observability (US2)** — a new read-only function **`msgfmt_stats`** reports aggregate queue
  state without consuming: always the cheap aggregates (queue depth, DLQ depth, the front message's
  Priority), and — when the caller asks for it with a scan limit — a bounded breakdown of the front
  by state (available / in-flight / not-yet-visible) plus an approximate oldest-dead-letter age.

Both keep the library's invariants: **all time is caller-supplied** (`now`, retention window — no
server clock, no randomness); **every scan is bounded** by a caller-supplied limit (a function
blocks its shard, so unbounded O(N) scans are forbidden); all keys are co-located under one hash tag.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Age out old dead-lettered messages (Priority: P1) 🎯 MVP

An operator runs a dead-letter queue and does not want it to grow forever. They periodically reap:
any message dead-lettered longer ago than the retention window is permanently deleted (index member
+ message Hash). Messages still within the window are kept. The reap is bounded per call so it never
stalls the server; the operator loops (or sizes the per-call limit to the DLQ depth reported by
stats) to drain fully.

**Why this priority**: Unbounded DLQ growth is the operational gap; retention closes it. It is the
core value and is independently useful without the stats function.

**Independent Test**: Dead-letter several messages, advance `now` past the retention window for some
of them, run `msgfmt_reap`; confirm the expired ones are gone (absent from the DLQ and their Hashes
deleted) while the within-window ones remain, and that the call removes at most `limit` and reports
how many it removed.

**Acceptance Scenarios**:

1. **Given** a message dead-lettered at time `T`, **When** `msgfmt_reap` runs with `now − T ≥ retention`,
   **Then** the message is removed from the DLQ and its message Hash is deleted, and the call reports
   it among those removed.
2. **Given** a message dead-lettered at time `T`, **When** `msgfmt_reap` runs with `now − T < retention`,
   **Then** the message is left intact in the DLQ.
3. **Given** a dead-letter move, **When** it happens, **Then** the message's `DeadLetteredAt` is set to
   the caller's `now` (so its age can later be measured); dead-lettering otherwise still moves only the
   index and leaves the other fields untouched.
4. **Given** more expired entries than the per-call `limit`, **When** `msgfmt_reap` runs, **Then** it
   removes at most `limit` and reports that more may remain, so the caller can loop.
5. **Given** a redriven message (returned from the DLQ to the source), **When** it is inspected,
   **Then** its `DeadLetteredAt` has been reset to `0` (it is no longer dead-lettered), alongside the
   existing `ReadAttempts=0` / `DirtyBit=0` / `VisibleAt=0` reset.
6. **Given** a DLQ member whose message Hash is missing (dangling), **When** `msgfmt_reap` encounters
   it, **Then** it removes the dangling member and counts it as reaped (cleanup).

---

### User Story 2 - See queue state without consuming (Priority: P2)

An operator or a monitoring probe wants aggregate numbers — how deep is the queue, how deep is the
DLQ, what is the highest-priority waiting message, and (affordably) how many messages are available
vs in-flight vs waiting for their scheduled time — without leasing or removing anything.

**Why this priority**: Observability is valuable on its own and complements retention (the DLQ depth
tells the operator how hard to reap). Independent of US1.

**Independent Test**: Populate a queue with a mix of available, leased, and not-yet-visible messages
and a DLQ; call `msgfmt_stats` and confirm the cheap aggregates (queue depth, DLQ depth, front
Priority) are exact, and that a bounded breakdown (with a scan limit) returns state counts over the
scanned prefix with a truncated indicator when the queue is larger than the limit — mutating nothing.

**Acceptance Scenarios**:

1. **Given** any queue, **When** `msgfmt_stats` is called, **Then** it returns the total queue depth
   and (when a DLQ key is given) the DLQ depth, computed cheaply, and the front message's Priority
   (or an empty indicator when the queue is empty), and performs no write.
2. **Given** a scan limit, **When** `msgfmt_stats` is called, **Then** it additionally returns a
   breakdown of the scanned front by state — available, in-flight (leased, unexpired), and
   not-yet-visible (delayed) — with a truncated flag set when the queue exceeds the scan limit.
3. **Given** a scan limit and a DLQ, **When** `msgfmt_stats` is called, **Then** it also reports an
   (approximate) oldest-dead-letter age computed from the scanned DLQ prefix, flagged as bounded.
4. **Given** `msgfmt_stats` runs, **When** it executes, **Then** it is callable via the read-only
   entry point and never writes (it does not clean dangling members).
5. **Given** an empty queue and no DLQ, **When** `msgfmt_stats` is called, **Then** it returns zero
   depths and an empty front indicator without error.

---

### Edge Cases

**Retention / reap (US1)**

- **Empty DLQ** → reap removes nothing and reports zero.
- **Retention window of `0`** → every message already dead-lettered at or before `now` is expired and
  eligible for removal.
- **Dangling DLQ member** (message Hash missing) → reap removes the member and counts it (cleanup);
  it does not error.
- **Not-yet-expired entry** → left intact.
- **Bounded by `limit`** → reap examines at most `limit` DLQ members per call, removes the expired
  ones among them, and reports the count removed, the count examined, and whether the DLQ still holds
  more members than were examined (truncated).
- **Priority-ordering caveat (mechanism A)** → the DLQ is Priority-ordered (unchanged from Feature
  004), so reap examines the front `limit` members *in Priority order*, not age order. Expired
  low-priority entries sitting behind unexpired high-priority ones are not reached by a small
  fixed-`limit` reap. To guarantee full draining, the caller sizes `limit` to cover the DLQ (using the
  DLQ depth reported by `msgfmt_stats`) or pages over successive reaps. This is an accepted limitation
  of keeping the DLQ Priority-ordered; a time-ordered DLQ (deferred) would drain oldest-first with a
  small fixed limit.
- **Reap removes BOTH** the DLQ member and the message Hash (retention = permanently gone), distinct
  from dead-lettering, which keeps the Hash.
- **Legacy DLQ member** dead-lettered before this feature (no `DeadLetteredAt` → treated as `0`) →
  appears infinitely old and is removed by any reap with a non-negative window; acceptable (it is
  genuinely old), documented for awareness.

**Dead-letter timestamp**

- **Redrive clears it** → a redriven message's `DeadLetteredAt` is reset to `0`; a message
  dead-lettered again later gets a fresh `DeadLetteredAt`.
- **Back-compat** → a message stored before this feature has no `DeadLetteredAt`; readers treat a
  missing value as `0` and never error (the six pre-existing fields remain as they were).

**Observability (US2)**

- **Empty queue / empty DLQ** → zero depths; empty front-Priority indicator.
- **Queue larger than the scan limit** → the breakdown counts are of the scanned prefix, with a
  truncated flag; the cheap depths remain exact (from cardinality, not the scan).
- **Dangling member during the breakdown scan** → counted as such or skipped (defined), and **never
  removed** (stats is read-only).
- **Age with no timestamp** → when no scanned DLQ member carries a `DeadLetteredAt` (all `0`), the age
  is reported as `0` / not-applicable.

**Cross-cutting**

- **Determinism** → `now`, retention window, and all scan limits are caller-supplied; no server clock
  or randomness.
- **Cluster** → reap (DLQ + message Hashes) and stats (queue + DLQ + message Hashes) keep every key
  co-located under one shared hash tag; no `CROSSSLOT`.
- **Out of scope** (later specs): source-queue message TTL/expiry (retention here is DLQ-only),
  automatic/scheduled reaping (the caller drives reap), a time-ordered DLQ variant, time-series or
  historical metrics, per-priority-band histograms, and push/streaming metrics.

## Requirements *(mandatory)*

### Functional Requirements

**Retention (US1)**

- **FR-001**: The message schema MUST gain a seventh field **`DeadLetteredAt`** (non-negative integer
  epoch ms, default `0`, validated `0 … 2^53`, stored like the other integer fields).
- **FR-002**: When `msgfmt_dequeue` dead-letters a message (moves it to the DLQ), it MUST record the
  caller's `now` in that message's `DeadLetteredAt`; it MUST otherwise still move only the index and
  leave the message's other fields unchanged.
- **FR-003**: The library MUST provide a `msgfmt_reap` function that removes dead-lettered messages
  whose age exceeds a caller-supplied retention window — i.e. `DeadLetteredAt ≤ now − retention` —
  by removing the DLQ index member **and** deleting the message Hash.
- **FR-004**: `msgfmt_reap` MUST be bounded by a caller-supplied per-call limit (it examines at most
  `limit` DLQ members) and MUST report how many it removed, how many it examined, and whether the DLQ
  still holds more members than it examined (so the caller can loop).
- **FR-005**: `msgfmt_reap` MUST remove a dangling DLQ member (one whose message Hash is missing) and
  count it (cleanup).
- **FR-006**: `msgfmt_redrive` MUST reset `DeadLetteredAt` to `0` (alongside the existing
  `ReadAttempts=0` / `DirtyBit=0` / `VisibleAt=0` reset).
- **FR-007**: `msgfmt_read` and `msgfmt_peek` MUST treat a missing `DeadLetteredAt` as `0` and MUST
  NOT error on its absence (back-compat); `msgfmt_read` MUST include `DeadLetteredAt` in its returned
  shape.

**Observability (US2)**

- **FR-008**: The library MUST provide a `msgfmt_stats` function that reports, cheaply and always,
  the total queue depth, the dead-letter-queue depth (when a DLQ key is supplied), and the front
  message's Priority (or an empty indicator for an empty queue) — using cardinality/front lookups,
  not a per-message scan.
- **FR-009**: When a caller supplies a scan limit, `msgfmt_stats` MUST additionally return a bounded
  breakdown of the scanned front by state — available, in-flight (leased, unexpired), and
  not-yet-visible (delayed) — and a truncated flag when the queue exceeds the scan limit.
- **FR-010**: When a scan limit and a DLQ key are supplied, `msgfmt_stats` MUST report an approximate
  oldest-dead-letter age (from the scanned DLQ prefix), flagged as bounded/approximate.
- **FR-011**: `msgfmt_stats` MUST perform **no writes** (registered read-only, callable via the
  read-only entry point) and MUST NOT remove dangling members.

**Cross-cutting**

- **FR-012**: All time and limits (`now`, retention window, scan limits) MUST be caller-supplied;
  neither function may read the server clock or use randomness.
- **FR-013**: `msgfmt_reap` and `msgfmt_stats` MUST require every key they touch (DLQ / queue Sorted
  Set and the message Hashes reached from a co-located prefix) to share one hash tag / one slot.
- **FR-014**: The feature MUST NOT use any command not already common-supported across the four
  target engines; reap and stats are expected to need **no new command** (cardinality, front/prefix
  reads, and member/hash removal are all already used).
- **FR-015**: Documentation (`README.md`, `docs/schema.md`, `docs/functions.md`) MUST be updated to
  add the `DeadLetteredAt` field, `msgfmt_reap`, `msgfmt_stats`, the dead-letter-stamp change, and the
  redrive reset change.

### Key Entities

- **Message** (reused, extended): gains a seventh field **`DeadLetteredAt`** (epoch ms, default `0` =
  not dead-lettered). All six existing fields unchanged.
- **Dead-Letter Queue** (reused, unchanged shape): a Priority-scored Sorted Set sharing the source's
  hash tag; retention removes members + their Hashes.
- **Retention window**: a caller-supplied age threshold (ms); a message with `DeadLetteredAt` older
  than `now − retention` is eligible for removal.
- **Queue statistics**: a read-only snapshot — depths (cardinalities), front Priority, and an optional
  bounded state breakdown + approximate oldest-dead-letter age.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After reaping with retention window `R` and a sufficient limit, **zero** DLQ messages
  older than `R` remain, and every message younger than `R` is retained.
- **SC-002**: A dead-lettered message carries a `DeadLetteredAt` equal to the `now` supplied at
  dead-letter time, in 100% of dead-letter moves.
- **SC-003**: `msgfmt_reap` never removes more than its `limit` per call and reports the removed and
  remaining counts so a caller can drain the DLQ across successive calls.
- **SC-004**: Reap and the dead-letter timestamp change do not alter existing behaviour for any
  message that is never reaped (verified by the Feature 001–005 suites continuing to pass).
- **SC-005**: `msgfmt_stats` returns queue and DLQ depth in constant time (independent of queue size)
  and never mutates any message (every field byte-for-byte unchanged after a stats call).
- **SC-006**: A bounded `msgfmt_stats` breakdown over a queue larger than the scan limit returns
  counts of the scanned prefix with the truncated flag set, and the depths remain exact.
- **SC-007**: A redriven message has `DeadLetteredAt = 0`.
- **SC-008**: The full suite passes on Redis and Valkey, standalone and cluster, with co-located keys
  (no `CROSSSLOT`); the static portability/determinism gate passes with **no new commands** and no
  server clock/randomness.

## Assumptions

- **Retention mechanism A** (chosen over a time-scored DLQ or native TTL): record the dead-letter
  moment in a new `DeadLetteredAt` message field and remove expired entries with an explicit bounded
  `msgfmt_reap`. Rationale: needs **no new command** (reap uses the existing front-read + member/hash
  removal), keeps Feature 004's DLQ **Priority-scored** (so the DLQ stays dequeue/peek-able exactly as
  today), preserves the deterministic **caller-supplied-time** model, and is portable to all target
  engines. Trade-off accepted: reap examines the DLQ front in Priority order, so fully draining
  requires the caller to size `limit` to the DLQ depth (from `msgfmt_stats`) or page — a small fixed
  limit does not guarantee reaching expired low-priority entries. (A time-ordered DLQ would drain
  oldest-first but would change Feature 004's DLQ ordering; deferred. Native `PEXPIRE` TTL was
  rejected: it is server-clock-driven — breaking the caller-time model and untestable via `now` — and
  is unsupported on MemoryDB Multi-Region, a portability regression.)
- **No constitution change and no static-gate change** (grounded): no principle caps the message
  schema field count — adding `DeadLetteredAt` is a Principle VIII contract change with the Principle
  X docs update, like Feature 005; reap/stats use only already-whitelisted commands (`ZCARD`,
  `ZRANGE`, `HMGET`/`HGET`, `ZREM`, `DEL`) plus caller-supplied time; the determinism scan is
  unaffected. Bounded loops satisfy Principle VI (single round trip) and VII (bounded execution).
- **`msgfmt_reap` is a WRITE** (removes members + Hashes); **`msgfmt_stats` is `no-writes`** and
  callable via the read-only entry point.
- **Retention is DLQ-only**; source-queue message TTL is out of scope.
- **Redrive clears `DeadLetteredAt`** (a redriven message is no longer dead-lettered).
- **Observability age is approximate under mechanism A**: the oldest-dead-letter age is derived from
  the scanned DLQ prefix (the DLQ is Priority-ordered, so the true minimum `DeadLetteredAt` is not at
  a known position), and is flagged as bounded/approximate; depths and front Priority are exact.
- **Platform caveat (pre-existing, whole-library)**: Amazon ElastiCache **Serverless** lacks the
  `FUNCTION`/`FCALL` family, and MemoryDB **Multi-Region** additionally lacks it; the library targets
  self-hosted Redis/Valkey, node-based ElastiCache (7.x), and single-region MemoryDB (7.x). Unchanged
  by this feature (and a reason native TTL was avoided).
- These two capabilities ship as **one feature** (US1 retention, US2 observability); all related keys
  share one hash tag. Exact `KEYS`/`ARGV` layouts, return shapes, and the new error codes are fixed in
  `contracts/functions.md` at planning time.
