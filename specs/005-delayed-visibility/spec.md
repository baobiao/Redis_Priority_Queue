# Feature Specification: Delayed Visibility (Scheduled Delivery & Retry Backoff)

**Feature Branch**: `005-delayed-visibility`
**Created**: 2026-07-12
**Status**: Draft
**Input**: User description: "Feature 005 Delayed Visibility — a caller-supplied not-before time makes a message non-deliverable until it arrives, enabling scheduled delivery (enqueue for the future) and retry backoff (release a failed message invisible for a backoff period)."

## Overview

Every message in the queue today is deliverable the instant it is available. This feature adds a
**not-before time** so a message can be held back — present in the queue but skipped by consumers —
until a caller-specified moment. It enables two things:

- **Scheduled delivery**: enqueue a message that becomes deliverable only at a future time.
- **Retry backoff**: when processing fails, release the message so it is redelivered only after a
  backoff delay (instead of immediately, as today).

The not-before time is a new message attribute, **`VisibleAt`** (an epoch-ms timestamp; default `0`
= immediately visible). A message is deliverable only when it is both lease-available (the Feature
003 rule) **and** `now ≥ VisibleAt`. All time is caller-supplied via arguments (deterministic; no
server clock), exactly as `now`/`timeout` already are.

**Terminology — two distinct concepts, do not conflate:**

- The Feature 003 **lease "visibility timeout"** governs an *in-flight* message (`DirtyBit=1`): it
  becomes available again after `now − ReadDateTime ≥ timeout`. **Unchanged by this feature.**
- This feature's **"delayed visibility" / not-before time (`VisibleAt`)** governs an *available*
  message (`DirtyBit=0`): it is not deliverable until `now ≥ VisibleAt`.

`VisibleAt` gates *eligibility* only; it never changes priority ordering. Among deliverable
messages, order is unchanged — ascending `Priority`, then FIFO by member.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Schedule a message for future delivery (Priority: P1) 🎯 MVP

A producer enqueues a message that must not be processed until a future time (a reminder, a
deferred job, a rate-limited action). Until that time, consumers skip the message entirely; once the
time arrives, it is delivered exactly as any other message, in its correct priority position.

**Why this priority**: This is the foundational capability — the not-before eligibility gate in
dequeue/peek — and is independently useful (scheduled jobs) even without the retry-backoff path.

**Independent Test**: Enqueue a message with a future `VisibleAt`; dequeue with `now` before it and
confirm the message is skipped (null / next message returned); dequeue with `now` at or after it and
confirm the message is delivered normally with its priority/FIFO position intact.

**Acceptance Scenarios**:

1. **Given** a message enqueued with `VisibleAt` in the future, **When** `msgfmt_dequeue` runs with
   `now < VisibleAt`, **Then** the message is not leased (it is skipped; the next deliverable message,
   or null, is returned) and its fields are unchanged.
2. **Given** the same message, **When** `msgfmt_dequeue` runs with `now ≥ VisibleAt`, **Then** the
   message is leased and returned exactly as a normal message (lease fields set, handle returned).
3. **Given** a message enqueued with no `VisibleAt` (or `0`), **When** it is dequeued, **Then**
   behaviour is identical to Feature 002/003 (immediately visible).
4. **Given** several messages, some not-yet-visible and some visible, **When** dequeued, **Then**
   delivery order among the visible ones is unchanged (ascending `Priority`, then FIFO); a
   not-yet-visible high-priority message does not block a visible lower-priority one.
5. **Given** `now == VisibleAt`, **When** dequeued, **Then** the message is visible (`≥` comparison).

---

### User Story 2 - Release a failed message with a backoff delay (Priority: P2)

A consumer fails to process a leased message and wants it retried later, not immediately. It nacks
the message with a not-before time so the message becomes invisible for a backoff period and is only
redelivered once that period elapses — preventing a tight failure/redelivery loop.

**Why this priority**: Retry backoff is the highest-value operational use of not-before times; it
builds directly on US1's eligibility gate plus the existing nack path.

**Independent Test**: Lease a message, then nack it with a future `VisibleAt`; confirm it is not
redelivered while `now < VisibleAt` and is redelivered once `now ≥ VisibleAt`, with `ReadAttempts`
retained across the delay.

**Acceptance Scenarios**:

1. **Given** a leased message, **When** it is nacked with a future `VisibleAt`, **Then** `DirtyBit`
   returns to `0`, `VisibleAt` is set, and `ReadDateTime`/`ReadAttempts` are retained.
2. **Given** that nacked message, **When** `msgfmt_dequeue` runs with `now < VisibleAt`, **Then** it
   is skipped (not redelivered).
3. **Given** that nacked message, **When** `msgfmt_dequeue` runs with `now ≥ VisibleAt`, **Then** it
   is redelivered (leased again, `ReadAttempts` incremented from the retained value).
4. **Given** a nack with no `VisibleAt` argument, **When** it runs, **Then** behaviour is identical
   to Feature 003 (released and immediately available; `VisibleAt` unchanged).
5. **Given** fencing, **When** a nack (with or without a delay) is attempted with a stale token,
   **Then** it is rejected (`EFENCED`) and nothing changes.

---

### User Story 3 - Observe and reset not-before state (Priority: P3)

An operator inspects messages and expects to see each message's not-before time, and expects the
delayed-visibility behaviour to compose correctly with peek, read, dead-letter, and redrive.

**Why this priority**: Rounds out the feature — observability and correct composition with the
existing functions. Depends on US1/US2 being in place.

**Independent Test**: Read a scheduled message and confirm `VisibleAt` is reported; peek a queue
containing not-yet-visible messages and confirm single-mode skips them while top-N reports them with
their `VisibleAt`; redrive a dead-lettered message and confirm its `VisibleAt` is reset to `0`.

**Acceptance Scenarios**:

1. **Given** a message with a `VisibleAt`, **When** `msgfmt_read` runs, **Then** the returned shape
   includes `VisibleAt` with its stored value.
2. **Given** a pre-existing message stored before this feature (no `VisibleAt` field), **When**
   `msgfmt_read` / `msgfmt_dequeue` / `msgfmt_peek` run, **Then** they treat it as `VisibleAt = 0`
   (immediately visible) and do **not** error.
3. **Given** a queue with not-yet-visible messages, **When** `msgfmt_peek` runs in single mode,
   **Then** it returns the front *visible* deliverable message (skipping not-yet-visible ones),
   matching what `msgfmt_dequeue` would lease; **When** it runs in top-N mode, **Then** it lists the
   front members regardless of visibility, each annotated with `VisibleAt`.
4. **Given** a message that is over the dead-letter cap but not yet visible, **When** `msgfmt_dequeue`
   runs, **Then** it is **not** dead-lettered until it becomes visible and available.
5. **Given** a dead-lettered message with a `VisibleAt`, **When** `msgfmt_redrive` runs, **Then** its
   `VisibleAt` is reset to `0` (immediately visible), alongside `ReadAttempts=0` and `DirtyBit=0`.

---

### Edge Cases

- **`VisibleAt` absent / `0` / in the past** → immediately visible (the default; fully backward
  compatible with Features 001–004).
- **`VisibleAt` in the future** → skipped by `msgfmt_dequeue` and by `msgfmt_peek` single mode until
  `now ≥ VisibleAt`; such a message still counts against `max_scan` (it is scanned over, like a
  leased message).
- **Backward compatibility** → a message stored before this feature has no `VisibleAt` field;
  `msgfmt_read`, `msgfmt_dequeue`, and `msgfmt_peek` MUST treat a missing `VisibleAt` as `0`
  (immediately visible) and MUST NOT return `EMALFORMED` for its absence.
- **Interaction with the lease** → eligibility = lease-available (Feature 003 rule) **AND**
  `now ≥ VisibleAt`. A leased, unexpired message stays in-flight regardless of `VisibleAt`. A nack
  may set a future `VisibleAt` (delayed retry).
- **Interaction with dead-letter (Feature 004)** → dead-lettering is a delivery-time action, so a
  message that is over the cap but not yet visible is **not** dead-lettered until it is both visible
  and available (the cap check happens only after the eligibility gate passes).
- **Interaction with redrive (Feature 004)** → redrive resets `VisibleAt` to `0` (the redriven
  message is immediately deliverable), alongside the existing `ReadAttempts=0` / `DirtyBit=0` reset.
- **Peek top-N** reports not-yet-visible members (for observability) and includes each member's
  `VisibleAt`; single mode honours `VisibleAt`.
- **Ordering** → `VisibleAt` does not affect `Priority`/FIFO ordering among visible messages.
- **Invalid `VisibleAt`** → a non-integer / negative / `> 2^53` value is rejected with a structured
  error (via field validation at enqueue/create, and via a dedicated check at nack); nothing is
  written (fail-before-write).
- **Boundary** → `VisibleAt` at `0` and at `2^53`; `now == VisibleAt` is visible.
- **Determinism** → `VisibleAt` (and `now`) are caller-supplied; no server clock or randomness.

## Requirements *(mandatory)*

### Functional Requirements

**Schema & eligibility (foundational, US1)**

- **FR-001**: The message schema MUST gain a sixth field **`VisibleAt`** — a non-negative integer
  epoch-ms timestamp, default `0`, validated `0 … 2^53` and stored like the other integer fields.
- **FR-002**: A message MUST be considered **deliverable** only when it is lease-available (the
  Feature 003 rule: `DirtyBit=0`, or `DirtyBit=1` with an expired lease) **and** `now ≥ VisibleAt`.
- **FR-003**: `msgfmt_dequeue` MUST skip a not-yet-visible message (`now < VisibleAt`) and continue
  its front scan, exactly as it skips an unexpired leased message; a skipped message counts against
  `max_scan`.
- **FR-004**: `VisibleAt` MUST NOT affect delivery order among visible messages (ordering stays
  ascending `Priority`, then FIFO by member).

**Backward compatibility (US1/US3)**

- **FR-005**: `msgfmt_read`, `msgfmt_dequeue`, and `msgfmt_peek` MUST treat a **missing** `VisibleAt`
  field (a message stored before this feature) as `0` (immediately visible) and MUST NOT return
  `EMALFORMED` for its absence.
- **FR-006**: `msgfmt_read` MUST include `VisibleAt` in its returned shape.

**Scheduled delivery (US1)**

- **FR-007**: A producer MUST be able to set `VisibleAt` when creating/enqueuing a message (as a
  normal field value); a future `VisibleAt` schedules the message for later delivery with no other
  behavioural change.

**Retry backoff (US2)**

- **FR-008**: `msgfmt_nack` MUST accept an **optional** not-before time; when supplied, it sets the
  message's `VisibleAt` (in addition to clearing `DirtyBit`), retaining `ReadDateTime`/`ReadAttempts`,
  so the message is redelivered only once `now ≥ VisibleAt`.
- **FR-009**: `msgfmt_nack` with no not-before argument MUST behave exactly as Feature 003 (release
  and leave `VisibleAt` unchanged); fencing (`EFENCED`) and idempotent `NOOP` semantics are unchanged.
- **FR-010**: An invalid not-before value supplied to `msgfmt_nack` MUST be rejected with a structured
  error and MUST NOT modify the message (fail-before-write).

**Observability & composition (US3)**

- **FR-011**: `msgfmt_peek` single mode MUST honour `VisibleAt` (skip not-yet-visible messages,
  matching `msgfmt_dequeue`'s selection); top-N mode MUST report members regardless of visibility and
  MUST include `VisibleAt` in each record.
- **FR-012**: Dead-lettering MUST occur only for a message that is deliverable (visible and
  lease-available) and over the cap — a not-yet-visible over-cap message MUST NOT be dead-lettered
  until it becomes visible.
- **FR-013**: `msgfmt_redrive` MUST reset `VisibleAt` to `0` (immediately visible) alongside its
  existing `ReadAttempts=0` / `DirtyBit=0` reset.

**Cross-cutting**

- **FR-014**: All not-before values MUST be caller-supplied via arguments; functions MUST NOT read
  the server clock or use randomness (determinism / replication safety).
- **FR-015**: The feature MUST NOT change the `KEYS[]` of any function, introduce a new key, or use
  any command not already employed by the library (the not-before gate is a stored field plus
  arithmetic on the caller's `now`).
- **FR-016**: Documentation (`README.md`, `docs/schema.md`, `docs/functions.md`) MUST be updated to
  add the `VisibleAt` field, the not-before eligibility rule, scheduled delivery, retry backoff, and
  the peek/read/redrive changes — and MUST keep the lease "visibility timeout" clearly distinct from
  delayed visibility.

### Key Entities

- **Message** (reused, extended): the message Hash gains a sixth field, **`VisibleAt`** (epoch-ms
  integer, default `0` = immediately visible). All five existing fields are unchanged.
- **Not-before time (`VisibleAt`)**: the eligibility gate — a message is deliverable only at/after
  this time. Distinct from the lease visibility timeout (which governs in-flight reclaim).
- **Source Queue / DLQ** (reused, unchanged): Sorted Sets scored by `Priority`; `VisibleAt` lives in
  the message Hash, not in any score, so it never affects ordering.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A message with a future `VisibleAt` is delivered **zero** times before that time and is
  delivered normally at/after it, for every tested boundary (before, exactly at, after).
- **SC-002**: A message with no/`0`/past `VisibleAt` behaves **identically** to Features 002/003
  (verified by the existing suites continuing to pass unchanged).
- **SC-003**: A message stored with only the original five fields reads and dequeues without error
  after this feature, treated as immediately visible (no `EMALFORMED`).
- **SC-004**: A nacked-with-delay message is not redelivered before its `VisibleAt` and is redelivered
  after it, with `ReadAttempts` retained across the delay.
- **SC-005**: A not-yet-visible message never blocks delivery of a visible message of equal or lower
  priority (priority/FIFO order among visible messages is preserved).
- **SC-006**: `msgfmt_peek` single mode returns exactly the message `msgfmt_dequeue` would lease next
  given the same `now` (including skipping not-yet-visible messages); top-N reports `VisibleAt` for
  every member.
- **SC-007**: A not-yet-visible over-cap message is dead-lettered only once it becomes visible.
- **SC-008**: A redriven message has `VisibleAt = 0` and is immediately deliverable.
- **SC-009**: The full suite passes on Redis and Valkey, standalone and cluster; the static
  portability/determinism gate passes with **no new commands** and no server clock/randomness.

## Assumptions

- **Design A (VisibleAt field + skip-in-scan)** is chosen over a separate scheduled Sorted Set:
  it reuses the existing single-ZSET + Hash model and the front-scan skip mechanism, needs no new key
  or command, and leaves enqueue/create signatures unchanged (`VisibleAt` is just a field value). The
  accepted cost is an O(K) scan over not-yet-visible messages at the front, bounded by `max_scan` —
  the same characteristic the dequeue already has for leased messages. (A scheduled-ZSET design would
  scale better for very large volumes of long-delayed messages; deferred.)
- **Absolute `VisibleAt` epoch** (not a relative delay): the caller passes an absolute epoch-ms
  timestamp; the comparison uses `msgfmt_dequeue`'s existing `now`, so enqueue/nack need no `now`
  argument. Callers compute backoff (`now + delay`) client-side.
- **Not-before is settable at enqueue (scheduled delivery) and at nack (retry backoff)**; a standalone
  "defer an existing message" function is out of scope (deferred).
- **Missing `VisibleAt` is treated as `0`** so messages written by Features 001–004 keep working with
  no migration.
- **No constitution change and no static-gate change** (grounded): no principle closes the message
  schema at five fields; adding a sixth field triggers only the Principle X documentation update; the
  not-before gate uses only already-whitelisted commands (`HSET`/`HMGET`/`HGET`) plus caller-supplied
  time, so the determinism scan and whitelist are unaffected.
- **Platform caveat (pre-existing, whole-library)**: Amazon ElastiCache **Serverless** does not offer
  the `FUNCTION`/`FCALL` family; the library targets self-hosted Redis/Valkey, node-based ElastiCache
  (7.x), and MemoryDB (7.x). Unchanged by this feature.
- Out of scope (later specs): recurring/cron schedules, per-message TTL/expiry, server-side
  exponential-backoff computation, batch scheduling, and a scheduled-ZSET scalability variant.
