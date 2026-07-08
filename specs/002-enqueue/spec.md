# Feature Specification: Enqueue

**Feature Branch**: `002-enqueue`  
**Created**: 2026-07-06  
**Status**: Draft  
**Input**: User description: "Add the ENQUEUE capability to the priority queue. Enqueue places a message onto a caller-designated priority queue: it stores the message using the Feature 001 message format and records it in a priority-ordered index keyed by the message's Priority (lower value = higher priority) so a later dequeue can retrieve highest-priority-first. Storing the message and indexing it happen as one atomic server-side operation; on any failure nothing is written. Reuse Feature 001's validation and defaults. More specifications (dequeue, visibility, retry, dead-letter) will be added to this feature later."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enqueue a message and order it by priority (Priority: P1)

A producer (the calling client) places a new message onto a priority queue. They supply the queue's location, the message's location, a unique identifier for the message, an insertion sequence, and any subset of the five message attributes. In one operation the message is validated and stored (omitted attributes take their Feature 001 defaults) and recorded in the queue at a position determined by its Priority, so that a later retrieval can take the highest-priority message first. Messages of equal priority keep first-in-first-out order.

**Why this priority**: Enqueue is the core capability of this feature — without it there is no queue to speak of. It is the first behaviour that turns Feature 001's static message representation into an ordered queue, and it is the foundation every later behaviour (dequeue, visibility, retry) builds on. This story alone delivers a usable, testable priority-ordered queue that producers can add to.

**Independent Test**: Enqueue several messages with distinct Priority values (and some with equal Priority) onto one empty queue, then inspect the queue's ordering and each stored message. Confirm every message is stored with supplied values exact and omitted values defaulted, that the queue orders messages from highest to lowest priority (lowest to highest Priority value), and that equal-priority messages appear in insertion-sequence order. Fully verifiable end-to-end through enqueue-then-inspect.

**Acceptance Scenarios**:

1. **Given** an empty queue, **When** a message is enqueued supplying only Payload and Priority (plus its identifier and insertion sequence), **Then** the message is stored with that Payload and Priority and the other three attributes at their defaults, and it appears in the queue positioned according to its Priority.
2. **Given** a queue already holding messages of various priorities, **When** a message with a higher priority (lower Priority value) is enqueued, **Then** it is ordered ahead of every lower-priority message already in the queue.
3. **Given** two messages enqueued to the same queue with equal Priority, **When** both have been enqueued, **Then** the one with the earlier insertion sequence is ordered first (FIFO among equal priorities).
4. **Given** a valid enqueue request, **When** it completes successfully, **Then** both the stored message and the queue entry reflect the message as a single atomic result.
5. **Given** an enqueue supplying no message attributes at all (only identifier and insertion sequence), **When** it completes, **Then** the message is stored entirely with defaults (Priority 1000) and ordered at the default priority.

---

### User Story 2 - Reject invalid or conflicting enqueue requests without side effects (Priority: P2)

When a producer submits an enqueue that is invalid or would corrupt the queue — an invalid attribute value, an unknown attribute name, a message or queue location that already holds conflicting data or the wrong kind of data, or a message that is already present in the queue — the operation is rejected with a clear, structured error and nothing at all is written to either the message store or the queue. Existing data is never partially overwritten or left in an inconsistent state.

**Why this priority**: Enqueue writes to two related places at once (the message and the queue index), so a half-completed or silently-overwriting enqueue is worse than none — it corrupts the queue for every downstream consumer. Rejecting bad or conflicting input atomically protects queue integrity. It builds on the core enqueue (P1), so it is prioritised immediately after.

**Independent Test**: Attempt enqueues that (a) supply an invalid Priority, (b) supply an unknown attribute, (c) target a message location that already holds a message, (d) target a queue location holding a value that is not a priority-queue index, and (e) re-use an identifier/entry already present in the queue. Confirm each returns a structured error identifying the problem and that neither the message store nor the queue index is modified in any case.

**Acceptance Scenarios**:

1. **Given** an enqueue request, **When** it supplies an invalid value for any message attribute (e.g. a non-integer Priority) or an unknown attribute name, **Then** it is rejected with a structured error naming the offending field and nothing is written to the message store or the queue.
2. **Given** a message location that already holds a message, **When** an enqueue targets that location, **Then** the request is rejected with a structured error and the existing message and the queue are left unchanged.
3. **Given** a queue location that holds a value that is not a priority-queue index, **When** an enqueue targets it, **Then** the request is rejected with a structured error and nothing is written.
4. **Given** a message already represented in the queue (the same queue entry), **When** an enqueue would add it again, **Then** the request is rejected with a structured error and the queue is unchanged.
5. **Given** any rejected enqueue, **When** the rejection occurs, **Then** both the message store and the queue index are exactly as they were before the call.

---

### User Story 3 - Adopt the feature from documentation alone (Priority: P3)

A Redis/Valkey developer who did not build this feature can, from the repository's documentation alone, understand what the library does, the message schema and the native data types it uses, and every function it exposes — and can set up their environment to load, use, modify, and test the library locally, without reading the source or the specs.

**Why this priority**: The enqueue capability (US1/US2) is only adoptable and maintainable by the wider team if it is documented. Documentation does not change runtime behaviour, so it follows the capability; but it is the deliverable that turns a working library into one others can use, and it establishes the documentation-currency expectation for all future work.

**Independent Test**: Hand the repository to a developer who has not seen the code. Using only the README they install the prerequisites and run the full test suite to a green result; using the schema documentation they can name every message field and which native types back the message and the queue; using the function documentation they can find every library function with its inputs, outputs, and errors.

**Acceptance Scenarios**:

1. **Given** the repository, **When** a developer opens the root README, **Then** they find what the library does, the prerequisites to install for local work, how to load and invoke the functions, and how to run the tests locally.
2. **Given** the schema documentation, **When** a developer reads it, **Then** they can identify every message field with its type, default, and encoding, and understand which native data types are used and how (the per-message store and the priority-ordered index — their keys, ordering value, membership, and co-location).
3. **Given** the function documentation, **When** a developer reads it, **Then** every function in the library source is documented — caller-invocable functions first, then internal helpers, alphabetical within each group — each with its purpose, inputs, outputs, and error results, and no test-only code is included.
4. **Given** a later change to the feature's behaviour, **When** that change is reviewed, **Then** the project's governance requires the affected documentation to be updated as part of the same change.

---

### Edge Cases

- **First message onto an empty queue**: Enqueuing the first message MUST create the queue index and place the message in it; an empty/absent queue location is a normal starting state, not an error.
- **Equal priorities**: Multiple messages with identical Priority MUST be ordered by their caller-supplied insertion sequence (FIFO), not arbitrarily.
- **Priority boundaries**: Priority values at the extremes of the allowed integer range (well below and well above the default 1000) MUST be accepted and ordered correctly relative to other messages.
- **Duplicate enqueue**: Enqueuing a message whose location already holds a message, or whose entry is already present in the queue, MUST be rejected rather than silently overwriting or duplicating.
- **Wrong-type target**: If the queue location holds something that is not a priority-queue index, or the message location holds something that is not a message, the enqueue MUST be rejected with a clear error and write nothing.
- **Cross-location placement**: The queue location and the message location MUST be co-located so a single atomic operation can touch both; a request whose two locations cannot be served together MUST fail rather than partially apply.
- **Non-monotonic or reused sequence**: The caller is responsible for supplying a unique identifier and an increasing insertion sequence; a reused entry (same identifier + sequence already in the queue) is treated as a duplicate and rejected.
- **Atomic failure**: If any part of an enqueue cannot complete (validation, conflict, wrong type), the whole operation MUST fail with nothing written — never the message without the queue entry, or vice versa.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide an enqueue operation that, in a single self-contained server-side call, both stores a message and records it in a caller-designated priority queue.
- **FR-002**: Enqueue MUST accept any subset of the five Feature 001 message attributes (ReadAttempts, DirtyBit, ReadDateTime, Priority, Payload), applying the documented Feature 001 defaults to every omitted attribute and using the same validation rules as Feature 001.
- **FR-003**: Enqueue MUST store the message at a caller-designated message location; the system MUST NOT compute, derive, or hardcode that location.
- **FR-004**: Enqueue MUST record the message in a caller-designated queue at a position determined by the message's Priority, where a lower Priority value denotes higher priority (earlier retrieval).
- **FR-005**: Among messages of equal Priority, enqueue MUST preserve first-in-first-out order using a caller-supplied, monotonically increasing insertion sequence.
- **FR-006**: Enqueue MUST accept a caller-supplied unique identifier for the message, used to represent the message within the queue.
- **FR-007**: The queue location and the message location MUST both be supplied by the caller and MUST be co-located so the operation acts on them together as a single unit.
- **FR-008**: Enqueue MUST reject a request that supplies an invalid attribute value or an unknown attribute name, returning a structured error that identifies the offending field, and MUST write nothing to the message store or the queue.
- **FR-009**: Enqueue MUST reject a request when the target message location already holds a message, returning a structured error and leaving the existing message and the queue unchanged (no silent overwrite).
- **FR-010**: Enqueue MUST reject a request when the queue location or the message location holds data of the wrong kind, returning a structured error and writing nothing.
- **FR-011**: Enqueue MUST reject a request when the message is already represented in the queue (its entry already exists), returning a structured error and leaving the queue unchanged.
- **FR-012**: On any rejection, enqueue MUST leave both the message store and the queue index exactly as they were before the call (no partial writes).
- **FR-013**: On success, enqueue MUST result in both the stored message and its queue entry being present as a single atomic result — never one without the other.
- **FR-014**: Enqueue MUST complete as a single self-contained server-side call, with no multi-step client interaction required to enqueue one message.
- **FR-015**: Enqueue MUST NOT itself generate ordering-relevant values (the message identifier, the insertion sequence, or any timestamp); these MUST be supplied by the caller so the operation is deterministic.
- **FR-016**: Priority values across the full allowed integer range, including boundary values, MUST be accepted and ordered correctly relative to other enqueued messages.
- **FR-017**: Enqueue MUST behave identically across all supported target engines, using only capabilities available on every target (see Success Criteria SC-007).
- **FR-018**: The repository MUST provide a top-level README that states what the library does and how another developer uses it (loading the library and invoking its functions), lists the prerequisites required to modify or test it locally, and explains how to run the tests locally.
- **FR-019**: The repository MUST provide schema documentation describing the message representation in full — every field with its type, default, and stored encoding — and explaining which native data types the feature uses and how (the per-message store and the priority-ordered index, including how their keys, ordering value, membership, and co-location work).
- **FR-020**: The repository MUST provide function documentation covering every function defined in the library source, excluding test code: the caller-invocable (FCALL-able) functions first and the internal local helper functions second, each group ordered alphabetically, with each function documenting its purpose, inputs, outputs, and error results.
- **FR-021**: The documentation MUST accurately reflect the implemented behaviour (fields, functions, native types, commands, and how to run the tests); no documented element may describe something that does not exist in the library.
- **FR-022**: The project's constitution MUST include an enforceable requirement that documentation is kept current — any feature change that affects documented behaviour MUST update the affected documentation as part of the same change — checked at the same review gate as the other principles.

### Key Entities *(include if feature involves data)*

- **Message**: The unit placed on the queue, exactly as defined in Feature 001 — the five attributes ReadAttempts, DirtyBit, ReadDateTime, Priority, Payload, with their defaults and validation. Reused unchanged by this feature.
- **Priority Queue**: An ordered collection, at a caller-designated location, of the messages currently on one logical queue. Ordered primarily by Priority (lower = higher priority) and secondarily by insertion sequence (FIFO among equal priorities).
- **Queue Entry**: The representation of one message within the queue — the message's caller-supplied unique identifier together with its ordering key (its Priority and insertion sequence). One entry per enqueued message.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A message enqueued with any combination of supplied and omitted attributes is stored with supplied values exactly as given and omitted values at their Feature 001 defaults, across all tested combinations.
- **SC-002**: For any set of messages enqueued with distinct priorities, reading the queue order returns them strictly from highest to lowest priority (lowest to highest Priority value), 100% of the time.
- **SC-003**: For messages enqueued with equal priority, the queue order matches their insertion-sequence order (FIFO), 100% of the time.
- **SC-004**: 100% of enqueue requests carrying an invalid value, an unknown attribute, a wrong-type target, an already-occupied message location, or an already-present queue entry are rejected with a structured error, and in every such case neither the message store nor the queue index is modified.
- **SC-005**: Every enqueue completes in a single server-side call with no intermediate client round trips.
- **SC-006**: Every successful enqueue results in both the message being stored and its entry present in the queue; every failed enqueue results in neither — no observed case leaves one without the other.
- **SC-007**: Enqueue behaves identically on the directly-testable engines (self-hosted Redis 7.0+ and self-hosted Valkey 7.2+) in both standalone and cluster mode, with zero behavioural differences observed in the test suite. Compatibility with the managed targets (ElastiCache, MemoryDB) is assured by using only commands/options on the common-supported list for all four platforms, verified by the static command-portability check (extended to cover the queue-index commands this feature introduces).
- **SC-008**: A developer new to the repository, using only the README, can install the prerequisites and run the full test suite to a green result without consulting the source code or the specs.
- **SC-009**: The schema documentation covers 100% of the message fields and 100% of the native data types the feature uses, including how each type's keys, ordering value, and membership are structured.
- **SC-010**: The function documentation covers 100% of the library's non-test functions, grouped (caller-invocable first, then helpers) and alphabetically ordered within each group.
- **SC-011**: The constitution contains an enforceable documentation-currency rule that applies to every feature change.

## Assumptions

- **Scope is enqueue only.** This feature covers storing a message and placing it into a priority-ordered queue in one atomic operation. Dequeue, priority-ordered retrieval/pop, peek, visibility timeout, acknowledgement, retry, and dead-letter handling are explicitly out of scope and will be added to this feature as later specifications.
- **This feature builds on Feature 001 and reuses it unchanged.** The five message attributes, their defaults, their storage encoding, and their validation are exactly as defined in Feature 001. The enqueue capability is added to the same server-side function library as the Feature 001 functions so it can reuse that validation directly (server-side function libraries are self-contained and cannot call across libraries); the library's name may be generalised during planning.
- **The caller designates both locations and they are co-located.** "Queue location" and "message location" are caller-supplied storage keys passed in with every call (the technology-agnostic terms used here map to the keys passed via `KEYS[]` in the design). They are co-located in the same cluster slot via a shared hash tag so a single atomic call can act on both; the feature never invents locations. This is consistent with Feature 001's cluster-safe key-access rule.
- **Ordering meaning follows Feature 001.** Lower Priority value = higher priority. The queue is ordered ascending by Priority so the highest-priority message is at the front; among equal priorities, the earlier insertion sequence is ordered first.
- **The caller supplies the identifier and insertion sequence; the feature does not generate them.** A unique message identifier and a monotonically increasing insertion sequence are provided by the caller (alongside the message attributes). This keeps enqueue deterministic for replication, consistent with Feature 001's decision that time-based/unique values are caller-supplied rather than generated server-side. The message's Priority (supplied or defaulted) determines its queue position; the insertion sequence only breaks ties.
- **Conflicts are rejected, not merged.** Following Feature 001's conservative validation stance, a message location that already holds a message, a wrong-type queue or message location, and an already-present queue entry are all rejected with a structured error that writes nothing — enqueue never silently overwrites or duplicates.
- **One queue location is one logical queue.** Each caller-supplied queue location represents a single logical priority queue; multiple queues are simply different caller-supplied locations. Messages relate to one another only through the queue they share; this feature does not address relationships beyond queue membership and ordering.
- **The static portability check will be extended.** The project's static command-portability gate currently permits only the Feature 001 (message-store) commands; it must be extended to permit the queue-index commands this feature introduces, so the portability gate (SC-007) continues to pass. Noted here for traceability; the exact command set is a design detail for planning.
- **Documentation layout.** The README lives at the repository root (the project's entry point; there is none today); the schema and function references live under `docs/` (`docs/schema.md`, `docs/functions.md`).
- **Function-doc ordering.** `functions.md` documents the caller-invocable (FCALL-able) functions first in alphabetical order, then the internal local helper functions in alphabetical order; test scripts are excluded.
- **Constitution amendment.** The documentation-currency requirement is added as a new constitution principle via a MINOR version bump (1.1.0 → 1.2.0); the amendment rides this feature's branch/PR.
- **Documentation-only increment.** This increment adds no library code and changes no runtime behaviour; per direction it requires no automated documentation tests, and the existing Docker suite is re-run only to confirm no regression.
- **Docs describe existing behaviour.** The documentation describes the already-implemented Feature 001 message format and Feature 002 enqueue capability; it introduces no new functional behaviour.
