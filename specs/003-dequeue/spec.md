# Feature Specification: Dequeue

**Feature Branch**: `003-dequeue`  
**Created**: 2026-07-08  
**Status**: Draft  
**Input**: User description: "Feature 003 Dequeue — lease/consume the highest-priority available message from a priority-queue Sorted Set, mark it in-flight via DirtyBit, reclaim abandoned leases after a visibility timeout, and settle (ack/nack) the lease with fencing."

## Overview

Feature 002 lets a producer **enqueue** a message: store it as a Hash and index it in a
priority-queue **Sorted Set** (score = `Priority`, lower = higher priority; ties ordered
FIFO by a zero-padded insertion `sequence` inside the member). This feature lets a consumer
**dequeue**: retrieve the highest-priority message that is not currently being processed,
hold it as a **lease** while it works, and then **settle** the lease — deleting the message
on success or releasing it for redelivery on failure.

Because a Redis/Valkey function (`FCALL`) is atomic and single-threaded and cannot block
waiting for a client to finish work, the "blocking dequeue that unblocks on success/error"
is realised as **two phases** with the lease held between them:

- **Acquire** (`msgfmt_dequeue`): atomically pick the front available message, mark it
  in-flight (`DirtyBit=1`, `ReadDateTime=now`, `ReadAttempts+1`), and return its `Payload`
  plus a handle. Non-blocking: if nothing is available it returns a null reply immediately.
- **Settle** (`msgfmt_ack` / `msgfmt_nack`): after the consumer finishes, acknowledge
  (remove the message) or negatively-acknowledge (release it for redelivery).

The "block" and the success/error branch live in the consumer/client wrapper around these
calls. A **visibility timeout** lets a later acquire reclaim a lease abandoned by a crashed
consumer; a **fencing token** stops a revived consumer from settling a message that has
since been reacquired by someone else.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Acquire the highest-priority available message (Priority: P1) 🎯 MVP

A consumer asks a queue for work. It receives the highest-priority message that is not
already being processed by someone else, and that message is marked in-flight so no other
consumer picks it up concurrently. If nothing is available, the consumer is told so
immediately.

**Why this priority**: This is the core consume operation and the minimum viable slice — a
producer can enqueue (Feature 002) and now a consumer can retrieve work in priority order.

**Independent Test**: Enqueue several messages with distinct priorities (and some equal);
call acquire repeatedly and confirm messages come back in ascending-`Priority` order,
equal priorities in FIFO (insertion) order, each returned message shows `DirtyBit=1`,
`ReadAttempts=1`, `ReadDateTime` set to the supplied time, and the `Payload` is exact.
Acquire on an empty or all-in-flight queue returns a null reply, not an empty payload.

**Acceptance Scenarios**:

1. **Given** an empty queue, **When** acquire is called, **Then** it returns a null reply and writes nothing.
2. **Given** messages with priorities 5, 10, 10, 1, **When** acquire is called four times, **Then** they are returned in the order priority 1, 5, 10 (first-enqueued), 10 (second-enqueued).
3. **Given** an available message, **When** acquire selects it, **Then** in one atomic call its `DirtyBit` becomes 1, `ReadDateTime` becomes the supplied `now`, `ReadAttempts` increases by 1, and the reply contains the `Payload` and a handle.
4. **Given** a message already in-flight (DirtyBit=1, lease not expired), **When** acquire runs, **Then** that message is skipped and the next available message is returned.
5. **Given** two consumers acquire the same queue concurrently, **When** both calls run, **Then** they receive two different messages (never the same one).

---

### User Story 2 - Settle a lease: acknowledge or release (Priority: P2)

After processing, the consumer tells the queue the outcome. On success the message is
removed for good. On failure the message is released so it (or another consumer) can try
again, preserving the record that it was read (`ReadAttempts`, `ReadDateTime`).

**Why this priority**: Without settle, acquired messages would never be removed or retried;
this completes the consume lifecycle and makes the queue drain correctly.

**Independent Test**: Acquire a message; call ack and confirm it is gone from both the queue
index and storage and cannot be re-acquired. Separately acquire another message; call nack
and confirm it becomes available again on the next acquire with its `ReadAttempts` still
incremented and `ReadDateTime` retained. Confirm ack/nack on a message that is not currently
leased, or with a stale handle, is rejected without side effects.

**Acceptance Scenarios**:

1. **Given** a message acquired with a valid handle, **When** ack is called, **Then** the message is removed from the queue index and its storage is deleted, and a subsequent acquire never returns it.
2. **Given** a message acquired with a valid handle, **When** nack is called, **Then** its `DirtyBit` returns to 0 while `ReadDateTime` and `ReadAttempts` are retained, and the next acquire can return it again.
3. **Given** a message that is not in-flight (DirtyBit=0), **When** ack or nack is called, **Then** the call is rejected with a structured error and nothing changes.
4. **Given** an already-settled (absent) message, **When** ack or nack is retried, **Then** the call returns a defined, safe no-op reply (idempotent) and nothing changes.

---

### User Story 3 - Reclaim messages abandoned by crashed consumers (Priority: P3)

A consumer acquires a message and then dies (crash, network partition) without settling.
The message must not be stuck forever. After a caller-defined visibility timeout, the next
acquire treats the abandoned lease as available and hands the message to another consumer.
The crashed consumer, if it ever revives, must not be able to corrupt the new lease.

**Why this priority**: Turns the design from "safe only if consumers never crash" into a
reliable at-least-once queue. Depends on the lease fields established by US1/US2.

**Independent Test**: Acquire a message at time T with visibility timeout D. Before T+D,
another acquire skips it (still leased). At/after T+D, another acquire reclaims it, returns
it with a further-incremented `ReadAttempts` and a new handle. The original (stale) handle
can no longer ack or nack the message (fencing).

**Acceptance Scenarios**:

1. **Given** a message leased at `now=T` with timeout `D`, **When** acquire runs at `now < T+D`, **Then** the message is skipped as still in-flight.
2. **Given** the same message, **When** acquire runs at `now ≥ T+D`, **Then** the message is reclaimed: `ReadDateTime` becomes the new `now`, `ReadAttempts` increments again, and a new handle is returned.
3. **Given** a reclaimed message now held by consumer B, **When** the original consumer A settles with its old handle, **Then** the call is rejected by fencing and B's lease is untouched.

---

### User Story 4 - Reject invalid or conflicting requests without side effects (Priority: P4)

Malformed inputs, wrong-type targets, mis-located keys, and stale or non-leased settle
attempts are all rejected with a structured error, and on any failure nothing is written
to the queue index or any message.

**Why this priority**: Safety and diagnosability across all three operations; hardens the
feature but is not required to demonstrate the happy path.

**Independent Test**: Drive each rejection — wrong key count; non-integer/negative `now` or
`timeout`; empty key prefix; a prefix whose hash tag differs from the queue's; a queue key
holding a non-Sorted-Set; a message Hash of the wrong type or missing fields; a fencing
mismatch; a settle of a non-leased message — and confirm each returns the correct
`MSGFMT E…` error and leaves the queue cardinality and every message Hash unchanged.

**Acceptance Scenarios**:

1. **Given** a call with the wrong number of keys, **When** invoked, **Then** it returns `MSGFMT EKEYS` and writes nothing.
2. **Given** a `now` or `timeout` that is negative or non-integer, **When** acquire runs, **Then** it returns `MSGFMT ENOW` / `MSGFMT ETMO` and writes nothing.
3. **Given** a message-key prefix whose hash tag differs from the queue key's, **When** acquire runs, **Then** it returns `MSGFMT ETAG` and writes nothing.
4. **Given** a queue key that holds a non-Sorted-Set value, **When** acquire runs, **Then** it returns `MSGFMT EMALFORMED` and writes nothing.

---

### Edge Cases

- **Consumer crash after acquire, before settle** → handled by US3: the lease expires after
  the visibility timeout and a later acquire reclaims the message. Fencing (US3/US4) prevents
  the revived consumer from settling the reacquired message.
- **Stale settle after reclaim** → rejected by the fencing token (`MSGFMT EFENCED`); no side
  effects. The fence is the `ReadAttempts` value captured at lease grant.
- **Double-settle** (ack/nack retried after the message is already gone) → defined idempotent
  no-op reply (`NOOP` status); nothing changes.
- **Settle of a non-leased message** (`DirtyBit=0`) → `MSGFMT ENOTLEASED`; no side effects.
- **Poison message** (always fails, is nack'd repeatedly) → **accepted for this slice**: the
  message returns to the front of its priority band and is redelivered indefinitely, with
  `ReadAttempts` climbing so a future dead-letter feature (out of scope) or an operator can
  observe it. No cap is enforced here.
- **Head-of-line effect**: a released high-priority message returns to its original position
  and may be retried before lower-priority work. Priority is **delivery order among available
  messages**, not a global processing-order guarantee.
- **Scan cost when the front is congested**: when the first K members are all in-flight,
  acquire inspects K members. An optional maximum-scan bound caps the work (returning "no
  message" if none is available within the bound); unbounded by default.
- **Dangling member** (a queue member whose message Hash is absent, e.g. deleted out of band)
  → acquire skips it and opportunistically removes the orphan member from the index; it never
  errors. (Acknowledgement removes the member and the Hash atomically, so ack never creates a
  dangling member.)
- **Empty vs. all-in-flight queue** → both return a null reply immediately (non-blocking);
  distinct from a returned empty-string `Payload`.
- **`id` containing brace characters** → the message key's hash slot is fixed by the first
  `{…}` tag in the caller-supplied prefix, so an `id` with braces cannot change the slot;
  co-location holds.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The library MUST provide a write function `msgfmt_dequeue` (acquire) that selects the front **available** message of a caller-designated priority-queue Sorted Set given as `KEYS[1]`.
- **FR-002**: "Front" MUST mean lowest score (`Priority`) first, ties broken by member byte order (the zero-padded `sequence`, i.e. FIFO) — identical to Feature 002 indexing.
- **FR-003**: A message MUST be considered **available** when its `DirtyBit=0`, **or** when its `DirtyBit=1` but the lease has expired (`now − ReadDateTime ≥ visibility timeout`).
- **FR-004**: On selecting a message, `msgfmt_dequeue` MUST atomically set `DirtyBit=1`, set `ReadDateTime` to the caller-supplied `now`, and increment `ReadAttempts` by 1 — all before returning, with no partial write on any failure.
- **FR-005**: `msgfmt_dequeue` MUST return the selected message's `Payload` plus a handle sufficient to settle it: the `id`, the full queue `member`, the `ReadAttempts` value (the fencing token), the `ReadDateTime`, and the `Priority`.
- **FR-006**: When no message is available, `msgfmt_dequeue` MUST return a null reply immediately (non-blocking) — distinguishable from a returned empty-string `Payload`.
- **FR-007**: `msgfmt_dequeue` MUST resolve each candidate message Hash key by appending the runtime `id` to a caller-supplied key **prefix** provided as `KEYS[2]`, which MUST carry the same hash tag as `KEYS[1]` so all touched keys share one slot.
- **FR-008**: `msgfmt_dequeue` MUST reject a prefix whose hash tag differs from the queue key's (`MSGFMT ETAG`) and write nothing.
- **FR-009**: The library MUST provide a write function `msgfmt_ack` that, given the queue Sorted Set (`KEYS[1]`) and the message Hash (`KEYS[2]`), the queue `member`, and the fencing token, removes the member from the index (`ZREM`) and deletes the message Hash (`DEL`) atomically, returning a success status.
- **FR-010**: The library MUST provide a write function `msgfmt_nack` that, given the message Hash (`KEYS[1]`) and the fencing token, sets `DirtyBit=0` while retaining `ReadDateTime` and `ReadAttempts`, returning a success status; the queue member MUST remain, so the message becomes available again at its original position.
- **FR-011**: `msgfmt_ack` and `msgfmt_nack` MUST be **fenced**: they proceed only when the target message is currently in-flight (`DirtyBit=1`) **and** its current `ReadAttempts` equals the supplied fencing token; a mismatch MUST return `MSGFMT EFENCED` with no side effects.
- **FR-012**: Settling a message that is not in-flight (`DirtyBit=0`) MUST return `MSGFMT ENOTLEASED` with no side effects; settling an absent (already-settled) message MUST return a defined idempotent `NOOP` status (safe for retries) with no side effects.
- **FR-013**: The current time (`now`) and the visibility `timeout` MUST be supplied by the caller via `ARGV`; the functions MUST NOT read the server clock or use randomness (project determinism convention; Principle VII).
- **FR-014**: All ordering- and time-relevant values (`id`, `sequence`, `now`, `timeout`, `Priority`) MUST originate from the caller so the write path is deterministic and replication-safe.
- **FR-015**: Every key a single call touches MUST hash to one slot; the queue key, the message-key prefix, and every constructed message Hash key MUST share one hash tag (Principle IV, as amended to permit appending a runtime suffix to a co-located, caller-declared prefix). Each call MUST declare at least one key.
- **FR-016**: Invalid inputs MUST be rejected with structured `MSGFMT E…` errors and **no writes** (fail-before-write): wrong key count (`EKEYS`); non-integer / negative / oversized `now` (`ENOW`) or `timeout` (`ETMO`); invalid `max_scan` (`ESCAN`); a message-key prefix that is empty or whose hash tag differs from the queue's (`ETAG`); missing/empty fencing token or member for settle (`EARGS`).
- **FR-017**: A queue key that exists but is not a Sorted Set MUST return `MSGFMT EMALFORMED`; a message Hash that exists but is not a Hash, or is missing any required field, MUST return `MSGFMT EMALFORMED`.
- **FR-018**: A dangling queue member (present in the index but with an absent message Hash) MUST NOT cause an error; `msgfmt_dequeue` MUST skip it and MAY remove the orphan member as it scans.
- **FR-019**: `msgfmt_dequeue` MUST accept an optional maximum-scan bound; when provided it inspects at most that many front members and returns a null reply if none within the bound is available; when absent it scans until an available message or the end of the queue.
- **FR-020**: The new functions MUST be added to the existing `message_format` library (function libraries are isolated) and MUST reuse the existing field set, encodings, error convention, and helpers; `msgfmt_dequeue`, `msgfmt_ack`, and `msgfmt_nack` MUST all be WRITE functions (rejected under `FCALL_RO`).
- **FR-021**: The static portability gate MUST allow the added commands (`ZRANGE` already present; add `ZREM`, `HINCRBY`), continue to reject admin/off-list commands and cross-slot access, and the determinism scan MUST still pass (no `TIME`/random in the new code).
- **FR-022**: Documentation (`README.md`, `docs/schema.md`, `docs/functions.md`) MUST be updated in the same change to describe dequeue/ack/nack, the lease lifecycle, the visibility timeout, and the fencing token (Principle X).
- **FR-023**: The functions MUST use only commands and options that behave identically on Redis 7.0+, Valkey 7.2+, Amazon ElastiCache, and Amazon MemoryDB; no admin/privileged commands, no third-party modules.

### Key Entities *(include if feature involves data)*

- **Priority Queue (Sorted Set)**: score = `Priority` (lower = higher priority); member = 20-digit zero-padded `sequence` + `":"` + `id`. Holds every enqueued message — both available and in-flight — until it is acknowledged. (Reused unchanged from Feature 002.)
- **Message (Hash)**: the five Feature 001 fields. `DirtyBit`, `ReadDateTime`, and `ReadAttempts` together encode lease state.
- **Lease**: the transient state of an in-flight message — `DirtyBit=1`, `ReadDateTime` = when the lease was granted, `ReadAttempts` = number of deliveries so far. A lease expires when `now − ReadDateTime ≥ visibility timeout`.
- **Handle**: what acquire returns to identify a lease for settling — `id`, `member`, fencing token (`ReadAttempts`), plus `Payload` and metadata.
- **Fencing token**: the `ReadAttempts` value captured at lease grant; monotonically increasing per message, so it uniquely identifies a lease generation and lets settle reject a superseded (stale) lease.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Given messages of distinct priority, repeated acquire returns them in ascending-`Priority` order (highest priority first) in 100% of cases.
- **SC-002**: Given equal-priority messages, acquire returns them in enqueue (FIFO) order in 100% of cases.
- **SC-003**: With multiple consumers acquiring the same queue concurrently, no available message is delivered to two consumers at once (zero double-delivery of an un-expired lease).
- **SC-004**: An acknowledged message is removed from the queue and is never returned by a later acquire.
- **SC-005**: A released (nack'd) message is returned again by a later acquire, retaining its incremented `ReadAttempts` and updated `ReadDateTime`.
- **SC-006**: A message whose lease is not settled within the visibility timeout is redelivered to another consumer once the timeout elapses.
- **SC-007**: A consumer whose lease expired and was reacquired by another consumer cannot acknowledge or release that message (fencing blocks it in 100% of cases).
- **SC-008**: On every invalid or conflicting request, the queue cardinality and all message contents are unchanged (no partial writes).
- **SC-009**: An empty or all-in-flight queue returns "no message" immediately, distinguishable from an empty-payload message.
- **SC-010**: The single, unmodified library loads and the full suite passes on Redis 7.0+ (7.4 tested) and Valkey 7.2+ (8.0 tested), standalone and cluster, with co-located keys and no `CROSSSLOT`.
- **SC-011**: The static portability + determinism gate passes for the extended library.

## Assumptions

- The caller supplies `now` (Unix epoch milliseconds), the visibility `timeout` (milliseconds, a positive integer), and the message-key **prefix** (which carries the queue's hash tag) on each acquire.
- Message Hashes are stored at `<prefix><id>` — the enqueue-time convention (`pq:{q1}:m:<id>` with prefix `pq:{q1}:m:`) — so acquire can resolve them; the prefix and queue key share one hash tag.
- **Determinism convention**: although Redis/Valkey functions may safely read `TIME` (functions use effects-only replication since 7.0), this library keeps all time and ordering values caller-supplied for consistency with enqueue, deterministic tests, and the existing static gate.
- The fencing token is the `ReadAttempts` value captured at lease grant (monotonic per message).
- Dangling queue members are skipped and opportunistically removed; they are not expected in normal operation (enqueue and ack are atomic).
- Poison-message capping and dead-letter routing are **out of scope** (unbounded redelivery is accepted; `ReadAttempts` remains observable for a future feature).
- **Out of scope** (candidates for later specs of Feature 003): a dead-letter queue, delayed/scheduled visibility, batch/multi-message dequeue, consumer-identity ownership tracking, and non-destructive peek.
- **Prerequisite**: implementation is gated on a constitution amendment to **Principle IV (Cluster-Safe Key Access)** permitting a function to append a runtime-derived suffix to a caller-declared, co-located key prefix (the only way acquire can address a message it discovers at runtime). This is a MAJOR change (redefinition of an existing principle) → constitution **1.2.0 → 2.0.0**; the static gate is updated accordingly. Lease/visibility/fencing semantics are documented at the feature level (spec, data model, contracts), not as a new constitution principle.
- One Sorted Set = one logical queue (as in Feature 002); multiple queues are simply different caller keys.
