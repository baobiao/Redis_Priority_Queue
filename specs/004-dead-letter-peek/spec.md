# Feature Specification: Dead-Letter Handling and Peek

**Feature Branch**: `004-dead-letter-peek`
**Created**: 2026-07-11
**Status**: Draft
**Input**: User description: "Feature 004 Dead-Letter Handling and Peek — dead-letter poison messages at dequeue (SQS-style max-receive cap), a non-destructive peek, and a single-message redrive from the dead-letter queue back to the source."

## Overview

Feature 003 gave a consumer a two-phase lease: `msgfmt_dequeue` leases the highest-priority
available message, and `msgfmt_ack` / `msgfmt_nack` settle it. But a message that always fails
is nack'd (or its lease expires) and redelivered **without bound** — a *poison* message sits at
the front of its priority band and is handed out forever, and its `ReadAttempts` climbs with no
consequence. There is also no way to look at a queue without consuming from it.

This feature closes both gaps, reusing the existing `message_format` library, its five-field
message Hash, and the priority-queue Sorted Set unchanged:

- **Dead-letter handling (US1)** — `msgfmt_dequeue` gains an optional maximum-delivery cap and an
  optional dead-letter queue. When it reaches an *available* message whose delivery count has
  already reached the cap, it moves that message aside to the dead-letter queue instead of
  leasing it, and continues scanning for a genuinely-deliverable message. Poison messages stop
  circulating; the hot path stays otherwise identical to Feature 003.
- **Non-destructive peek (US2)** — a new read-only `msgfmt_peek` inspects a queue without leasing
  or mutating anything. It answers either "what would dequeue hand out next?" (single, lease-aware)
  or "show me the front N entries and their state" (a top-N observability view). It works on any
  queue of this shape — a source queue or a dead-letter queue.
- **Redrive (US3)** — a new `msgfmt_redrive` moves one message from the dead-letter queue back to
  its source queue and resets its delivery state so it can be reprocessed from a clean slate.

The **dead-letter queue (DLQ)** is simply another priority-queue Sorted Set that shares the source
queue's hash tag (e.g. source `pq:{q1}`, DLQ `dlq:{q1}`). Dead-lettering and redrive move only the
**index** — one Sorted Set member — between the two sets; the message Hash never moves. Because the
DLQ has the identical shape (score = `Priority`, verbatim member), it is itself peek-able and even
dequeue-able with the same tools.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dead-letter poison messages at dequeue (Priority: P1) 🎯 MVP

A consumer processes a queue in a loop. Some messages can never succeed (malformed payload, a
downstream that always rejects them). The operator sets a maximum-delivery cap and points the
consumer at a dead-letter queue. Once a message has been delivered the capped number of times and
still comes back, the very next dequeue that reaches it must set it aside into the dead-letter queue
rather than hand it out again — so the poison message stops blocking its priority band and stops
wasting consumer effort, while good messages keep flowing.

**Why this priority**: This is the reliability gap Feature 003 explicitly left open (unbounded
redelivery of poison messages). It is the core value of this feature and is independently useful
even without peek or redrive.

**Independent Test**: Enqueue a message and repeatedly dequeue-then-nack it (or let its lease expire)
until its delivery count reaches the cap; supply the DLQ key and cap on the next dequeue and confirm
the message is moved to the DLQ (present there, absent from the source) and that the dequeue returns
the next deliverable message (or null) rather than the poison one. Confirm that omitting the DLQ key
and cap reproduces Feature 003 behaviour exactly.

**Acceptance Scenarios**:

1. **Given** a source queue whose front message has `ReadAttempts` = cap and `DirtyBit` = 0 (available),
   and a DLQ key + cap supplied, **When** `msgfmt_dequeue` is called, **Then** that message is moved to
   the DLQ (removed from the source, added to the DLQ with its `Priority` as score and its member
   string unchanged) and the call returns the next available message below the cap, or null if none.
2. **Given** a front message with `ReadAttempts` = cap but currently in-flight with an **unexpired**
   lease (`DirtyBit` = 1, `now − ReadDateTime < timeout`), **When** `msgfmt_dequeue` is called, **Then**
   the message is left untouched (not dead-lettered, not leased) and the scan continues past it.
3. **Given** a front message with `ReadAttempts` = cap and an **expired** lease, **When** `msgfmt_dequeue`
   is called, **Then** it is dead-lettered on this call (moved before any re-lease or increment).
4. **Given** no DLQ key and no cap supplied, **When** `msgfmt_dequeue` is called, **Then** it behaves
   exactly as Feature 003 — no message is ever dead-lettered — and its return shape is unchanged.
5. **Given** several front messages at/over the cap followed by one below the cap, **When**
   `msgfmt_dequeue` is called, **Then** all the over-cap available messages it scans are dead-lettered
   and the below-cap message is leased and returned.
6. **Given** dead-lettering occurs, **When** `msgfmt_dequeue` returns, **Then** the reply is the usual
   deliverable-message handle or null (the caller is not told how many messages were dead-lettered).

---

### User Story 2 - Inspect a queue without consuming (Priority: P2)

An operator or a monitoring tool needs to see what is in a queue — what would be delivered next, or
the state of the front entries (their priorities, delivery counts, in-flight status) — without
leasing, mutating, or consuming anything. This works identically on a source queue and on a
dead-letter queue.

**Why this priority**: Observability is valuable on its own and is a prerequisite for operating the
dead-letter queue (deciding what to redrive). It is fully independent of US1 and US3.

**Independent Test**: Enqueue a mix of messages (varying priority, some leased, some not); call
`msgfmt_peek` with no count and confirm it returns the same message a dequeue would select next
without changing any field; call it with a count and confirm it returns that many front entries in
priority-then-FIFO order with their lease fields, again mutating nothing (verify every field of every
inspected message is byte-for-byte unchanged afterward).

**Acceptance Scenarios**:

1. **Given** a non-empty queue, **When** `msgfmt_peek` is called with no count (or count = 1), **Then**
   it returns the single message that `msgfmt_dequeue` would next lease (lease-aware: the front message
   that is available), and no field of any message changes.
2. **Given** a queue where every front message is in-flight with an unexpired lease, **When**
   `msgfmt_peek` is called in single mode, **Then** it returns null (nothing deliverable) — distinct
   from returning a message with an empty payload.
3. **Given** a non-empty queue, **When** `msgfmt_peek` is called with count = N, **Then** it returns up
   to N front members in priority-then-FIFO order **regardless of lease state**, each annotated with
   its `DirtyBit`, `ReadAttempts`, `ReadDateTime`, `Priority`, and `Payload`.
4. **Given** a queue with fewer than N members, **When** `msgfmt_peek` is called with count = N, **Then**
   it returns all of them and does not error.
5. **Given** an empty (or absent) queue, **When** `msgfmt_peek` is called, **Then** it returns null in
   single mode and an empty list in top-N mode.
6. **Given** `msgfmt_peek` is invoked, **When** it runs, **Then** it is callable via the read-only entry
   point and performs no write of any kind.

---

### User Story 3 - Redrive a message from the dead-letter queue (Priority: P3)

After fixing the cause of failures, an operator wants a specific dead-lettered message reprocessed.
They redrive it: the message returns to its source queue at its priority position and is delivered
again from a clean delivery state, so it does not immediately dead-letter again.

**Why this priority**: Redrive completes the lifecycle but is only useful once messages are being
dead-lettered (US1) and are visible for selection (US2). It is the natural last slice.

**Independent Test**: Dead-letter a message (via US1), then `msgfmt_redrive` it by its identifier;
confirm it is removed from the DLQ, present again in the source at its `Priority` position, and that
its delivery count is reset to 0 and it is not in-flight — so a subsequent dequeue delivers it.

**Acceptance Scenarios**:

1. **Given** a message present in the DLQ, **When** `msgfmt_redrive` is called for it, **Then** it is
   removed from the DLQ and added to the source queue at score = its `Priority` with its member string
   unchanged, and the call reports success.
2. **Given** a redriven message, **When** it is inspected, **Then** `ReadAttempts` = 0 and `DirtyBit` = 0,
   while `ReadDateTime` retains its prior value (forensic record of the last processing time).
3. **Given** a redriven message, **When** the source queue is next dequeued, **Then** the message is
   delivered again (it is below any cap because its count was reset).
4. **Given** a member that is **not** present in the DLQ, **When** `msgfmt_redrive` is called for it,
   **Then** it reports a defined no-op / not-found result and changes nothing.
5. **Given** a member already present in the **source** queue, **When** `msgfmt_redrive` is called for
   it, **Then** it is rejected (no duplicate index is created) and the source entry is left intact.

---

### Edge Cases

**Dead-letter (US1)**

- **DLQ key and/or cap omitted** → identical to Feature 003: no dead-lettering; the return shape is
  byte-for-byte the same. (Both must be present for dead-lettering to engage.)
- **DLQ key present but not a Sorted Set** → structured `EMALFORMED` error; nothing is moved.
- **DLQ key does not share the source's hash tag** → structured `ETAG` error (the co-location check is
  extended to the DLQ key); nothing is moved.
- **Over-cap but in-flight with an unexpired lease** → not dead-lettered (a message being processed is
  never moved out from under its consumer); the cap only applies once the message is available again.
- **Over-cap with an expired lease** → dead-lettered on this call, before any re-lease/increment.
- **Message already present in the DLQ** (e.g. a redriven message that failed again) → the move is a
  score/position update of the existing DLQ member (no duplicate); the source entry is removed.
- **Interaction with `max_scan`** → the scan still examines at most `max_scan` front members; any it
  dead-letters are among those examined (dead-lettering does not grant extra scan budget).
- **The message Hash is untouched on dead-letter** → a message dead-lettered while in an expired-lease
  state keeps its lease fields; because an expired lease counts as available, the DLQ entry remains
  peek-able and dequeue-able.

**Peek (US2)**

- **Empty or absent queue** → null (single mode) / empty list (top-N mode).
- **All front members in-flight and unexpired** → single mode returns null (nothing deliverable).
- **count greater than the queue size** → returns all members; no error.
- **Dangling member** (Sorted Set member whose message Hash is missing) → **skipped, never removed**
  (peek is read-only and must not `ZREM`; only the write path cleans up danglers).
- **Malformed message Hash** (wrong type or missing a lease field) → that member is skipped in top-N
  observability mode; in single mode a malformed candidate that would otherwise be selected yields a
  structured `EMALFORMED` error (consistent with dequeue).
- **now / timeout** are required for the lease-aware single mode; in top-N mode they are accepted but
  not used to filter (top-N reports raw state regardless of lease).

**Redrive (US3)**

- **Member not in the DLQ** → defined no-op / not-found result; nothing changes.
- **Member already in the source queue** → rejected; no duplicate index created.
- **Dangling DLQ member** (message Hash missing) → structured error; the reset cannot be applied to a
  missing Hash.
- **Reset semantics** → `ReadAttempts` = 0 and `DirtyBit` = 0; `ReadDateTime` is **retained**.

**Cross-cutting**

- **RESP null vs empty payload** — "nothing deliverable / not found" is a null (or defined status)
  reply, always distinct from a real message whose `Payload` is an empty string.
- **One source queue = one logical queue = one sibling DLQ**, and every related key (source ZSET, DLQ
  ZSET, message Hashes) shares a single hash tag so all live in one cluster slot.

## Requirements *(mandatory)*

### Functional Requirements

**Dead-letter (US1)**

- **FR-001**: `msgfmt_dequeue` MUST accept an **optional** dead-letter queue key and an **optional**
  maximum-delivery cap. When either is absent, `msgfmt_dequeue` MUST behave exactly as Feature 003
  (no dead-lettering) with an unchanged return shape.
- **FR-002**: When both the DLQ key and the cap are supplied, `msgfmt_dequeue`, while scanning the front
  of the source queue, MUST treat an **available** candidate (`DirtyBit` = 0, or `DirtyBit` = 1 with an
  expired lease) whose current `ReadAttempts` is **≥ cap** as poison: it MUST NOT lease it, MUST move it
  to the DLQ, and MUST continue scanning.
- **FR-003**: A candidate that is currently in-flight with an **unexpired** lease MUST NOT be dead-lettered,
  regardless of its `ReadAttempts`.
- **FR-004**: Dead-lettering MUST move only the index: remove the member from the source Sorted Set and add
  it to the DLQ Sorted Set with **score = the message's `Priority`** and the **member string preserved
  verbatim**. The message Hash MUST NOT be modified or moved during dead-lettering.
- **FR-005**: If the poison member already exists in the DLQ, the operation MUST NOT create a duplicate
  (the existing DLQ member is retained/updated) and MUST still remove it from the source.
- **FR-006**: `msgfmt_dequeue` MUST remain **silent** about dead-lettering — its reply is the next
  deliverable message handle or a null reply, exactly as in Feature 003 (no count or list of dead-lettered
  messages is returned).
- **FR-007**: All keys `msgfmt_dequeue` touches in one call (source ZSET, message Hash, and — when supplied
  — DLQ ZSET) MUST resolve to one hash slot; the existing co-location check MUST be extended to reject a
  DLQ key that does not share the source's hash tag.

**Peek (US2)**

- **FR-008**: The library MUST provide a `msgfmt_peek` function that inspects a queue and performs **no
  writes**, is registered with the read-only flag, and is callable via the read-only entry point.
- **FR-009**: In **single mode** (no count, or count = 1), `msgfmt_peek` MUST return the same message that
  `msgfmt_dequeue` would next lease — the front available message (lease-aware: `DirtyBit` = 0 or an expired
  lease) — without leasing or mutating it; and MUST return null when nothing is deliverable.
- **FR-010**: In **top-N mode** (count = N ≥ 1), `msgfmt_peek` MUST return up to N front members in
  priority-then-FIFO order **regardless of lease state**, each annotated with `DirtyBit`, `ReadAttempts`,
  `ReadDateTime`, `Priority`, and `Payload`; and MUST return an empty result when the queue is empty.
- **FR-011**: `msgfmt_peek` MUST NOT remove dangling members (a member whose Hash is missing); it MUST skip
  them. It MUST work identically on a source queue and a dead-letter queue.
- **FR-012**: `msgfmt_peek` MUST distinguish "nothing to return" (null / empty list) from a real message
  whose `Payload` is an empty string.

**Redrive (US3)**

- **FR-013**: The library MUST provide a `msgfmt_redrive` function that moves one specified message from a
  dead-letter queue back to its source queue: remove the member from the DLQ and add it to the source with
  **score = the message's `Priority`** and the member string unchanged.
- **FR-014**: `msgfmt_redrive` MUST reset the redriven message's delivery state to `ReadAttempts` = 0 and
  `DirtyBit` = 0, and MUST retain the existing `ReadDateTime`.
- **FR-015**: `msgfmt_redrive` MUST report a defined no-op / not-found result when the member is absent from
  the DLQ, and MUST reject (no duplicate) when the member is already present in the source queue.
- **FR-016**: `msgfmt_redrive` MUST return a structured error when the target message Hash is missing
  (a dangling DLQ member) or malformed.
- **FR-017**: All keys `msgfmt_redrive` touches (DLQ ZSET, source ZSET, message Hash) MUST resolve to one
  hash slot via a shared hash tag.

**Cross-cutting**

- **FR-018**: The new/extended functions MUST be added to the existing `message_format` library and MUST
  reuse the established message schema, encodings, member format, `score = Priority` convention, and
  `MSGFMT <CODE>: <detail>` error convention.
- **FR-019**: Every value the functions depend on (the cap, `now`, `timeout`, `count`) MUST be supplied by
  the caller as arguments; the functions MUST NOT read the server clock or use randomness.
- **FR-020**: Every write in the extended dequeue and in redrive MUST be atomic and all-or-nothing (a
  single server-side call), consistent with the existing library.
- **FR-021**: Documentation (`README.md`, `docs/schema.md`, `docs/functions.md`) MUST be updated to cover
  the dead-letter queue concept, `msgfmt_peek`, `msgfmt_redrive`, and the extended `msgfmt_dequeue`
  signature, including success and failure examples.

### Key Entities

- **Dead-Letter Queue (DLQ)**: a priority-queue Sorted Set, structurally identical to a source queue,
  holding messages that reached the delivery cap. Shares the source queue's hash tag (e.g. `dlq:{q1}` for
  source `pq:{q1}`). Score = the message's `Priority`; member = the verbatim source member. Because it has
  the same shape, it is peek-able and dequeue-able with the same functions.
- **Message** (reused, Feature 001): the five-field Hash (`ReadAttempts`, `DirtyBit`, `ReadDateTime`,
  `Priority`, `Payload`). Dead-lettering never modifies it; redrive resets `ReadAttempts`/`DirtyBit` and
  retains `ReadDateTime`.
- **Source Queue** (reused, Feature 002/003): the priority-queue Sorted Set a message is enqueued to and
  dequeued from; the origin and redrive destination.
- **Delivery cap (max-receive)**: a caller-supplied threshold; a message whose `ReadAttempts` has reached it
  is dead-lettered on its next availability instead of being delivered.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A message that has reached the delivery cap is delivered **zero** further times once a DLQ and
  cap are in use — the next dequeue that reaches it moves it to the DLQ instead of returning it.
- **SC-002**: With the DLQ key and cap omitted, dequeue behaviour and return values are **identical** to
  Feature 003 (verified by the existing Feature 003 suite continuing to pass unchanged).
- **SC-003**: Dead-lettering never removes a message that is actively being processed (an unexpired lease):
  in 100% of cases an over-cap in-flight message survives until its lease expires.
- **SC-004**: `msgfmt_peek` changes **no** field of **any** inspected message — every field is byte-for-byte
  identical before and after — in 100% of peek calls, single or top-N.
- **SC-005**: `msgfmt_peek` in single mode returns exactly the message a subsequent dequeue would lease, for
  every queue state tested (available front, all-in-flight, empty).
- **SC-006**: A redriven message is delivered again on the next dequeue and, having a reset delivery count,
  is not immediately re-dead-lettered.
- **SC-007**: Redrive leaves no duplicate: after redrive the message exists in exactly one of {source, DLQ}
  (the source), never both.
- **SC-008**: The full test suite passes on both engines (Redis and Valkey), standalone and cluster, with
  the dead-letter/peek/redrive keys co-located by a shared hash tag and no `CROSSSLOT` error.
- **SC-009**: The static portability/determinism gate passes with no new whitelisted commands and no
  server-clock or randomness in the new code.

## Assumptions

- **No constitution change is required.** The v2.0.0 Principle IV amendment permits the sanctioned
  same-slot key construction "only when the exact target key cannot be known by the caller in advance" —
  a *knowability* condition, not a write-vs-read one — so it already covers a read-only `msgfmt_peek`
  constructing a message-Hash key from ids discovered by scanning, and a three-same-slot-key dequeue
  (source + DLQ + message Hash). An optional cosmetic PATCH could add a read-only illustration, but none
  is mandated. `msgfmt_redrive` operates on a message whose id the caller already knows, so its message
  Hash key is passed literally (knowable → no construction).
- **No new commands.** Dead-letter/redrive use `ZADD`/`ZREM`/`ZSCORE`/`HSET` (and `HGET`/`HMGET`); peek uses
  `ZRANGE`/`HMGET`/`EXISTS`/`TYPE`. All are already whitelisted by the static gate and are supported
  identically on Redis 7.0+, Valkey 7.2+, node-based ElastiCache (7.x), and MemoryDB (7.x).
- **Backward-compatible dequeue signature.** The DLQ key is appended as an optional additional key and the
  cap as an optional trailing argument, so existing Feature 003 dequeue calls are unaffected.
- **DLQ ordering.** The DLQ is scored by `Priority` (like a source queue), so it is uniformly peek-able and
  dequeue-able; it is not ordered by dead-letter time.
- **Redrive resets attempts but retains `ReadDateTime`** as a forensic record of the last processing time.
- **Dead-lettering is silent** on the dequeue reply; operators observe the DLQ via `msgfmt_peek`.
- **Platform caveat (pre-existing, whole-library):** Amazon ElastiCache **Serverless** does not support the
  `FUNCTION`/`FCALL`/`FCALL_RO` family; this library targets the Functions API and therefore runs on
  self-hosted Redis/Valkey, node-based ElastiCache (7.x), and MemoryDB (7.x). This is unchanged by this
  feature and is noted for completeness.
- **One logical queue** maps to one source Sorted Set with one sibling DLQ; all related keys share one hash
  tag, consistent with Features 002/003.
- The exact `KEYS`/`ARGV` wire layout for the extended `msgfmt_dequeue`, `msgfmt_peek`, and `msgfmt_redrive`
  is fixed in `contracts/functions.md` during planning; the spec fixes only the behaviour and guarantees.
