# Feature Specification: Message Format

**Feature Branch**: `001-message-format`  
**Created**: 2026-06-07  
**Status**: Draft  
**Input**: User description: "Define the message format to represent each message in the queue. Each message has fields: Integer ReadAttempts (default 0), Boolean DirtyBit (default false), Long ReadDateTime (default 0), Integer Priority (default 1000), String Payload (default empty string)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create a message with defaults and explicit values (Priority: P1)

A queue operator (the calling client) needs to create a new message in the store. They supply a target location for the message and any subset of the five message attributes. Attributes they omit are filled in with the standard default values, so a message can always be created even with no attribute values supplied. The created message is stored so it can later be read back exactly as stored.

**Why this priority**: Creating a well-formed message is the foundational capability of the entire queue. Without a reliable, defaulted, validated message representation, no later queue behaviour (enqueue, ordering, retry, dequeue) can exist. This story alone delivers a usable, testable message store.

**Independent Test**: Create a message supplying no attributes and confirm it is stored with ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, Payload="". Then create another supplying all five attributes and confirm each is stored as given. Both are verifiable end-to-end through a single create-then-read cycle.

**Acceptance Scenarios**:

1. **Given** an empty target location, **When** a message is created with no attribute values supplied, **Then** the message is stored with ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, and Payload="".
2. **Given** an empty target location, **When** a message is created supplying all five attributes with valid values, **Then** the message is stored with exactly those values.
3. **Given** an empty target location, **When** a message is created supplying only Payload and Priority, **Then** Payload and Priority are stored as given and the other three fields take their defaults.

---

### User Story 2 - Read a message back into a well-defined shape (Priority: P1)

A client needs to retrieve a previously stored message and receive all five attributes in a predictable, typed shape — numbers as numbers, the boolean as a true/false value, and the payload as a string — regardless of how the data is encoded in storage. Reading a message MUST NOT modify it.

**Why this priority**: A stored message is only useful if it can be read back faithfully and unambiguously. Read is the necessary counterpart to create and is required to verify every other behaviour. It is read-only and therefore safe to call freely.

**Independent Test**: Create a message with known values, read it back, and confirm every field matches the created values with the correct type (e.g. DirtyBit returns as a true/false value, not the string "1"). Confirm the stored message is unchanged after the read.

**Acceptance Scenarios**:

1. **Given** a stored message, **When** it is read, **Then** all five attributes are returned with their correct logical types and values.
2. **Given** a stored message, **When** it is read, **Then** the stored message is left unchanged (read does not write).
3. **Given** a target location that holds no message, **When** a read is attempted, **Then** the caller receives a clear "not found" indication rather than a partial or malformed message.

---

### User Story 3 - Reject invalid attribute values (Priority: P2)

When a client supplies an attribute value that is not valid for its field (wrong type or out of the allowed range), the create operation MUST reject the request with a clear, structured error instead of silently storing or coercing a bad value. Omitted fields are still allowed (they take defaults); only *supplied-but-invalid* values are rejected.

**Why this priority**: Validation protects every downstream consumer from corrupt messages. It is essential for correctness but builds on the create capability (P1), so it is prioritised immediately after the core create/read cycle.

**Independent Test**: Attempt to create messages with a non-integer ReadAttempts, a negative ReadAttempts, a non-boolean DirtyBit, a non-numeric Priority, and a non-string Payload. Confirm each attempt returns a structured error identifying the offending field and that no message is stored.

**Acceptance Scenarios**:

1. **Given** a create request, **When** ReadAttempts is supplied as a non-integer or negative value, **Then** the request is rejected with a structured error naming ReadAttempts and no message is stored.
2. **Given** a create request, **When** DirtyBit is supplied as a value that is neither true nor false, **Then** the request is rejected with a structured error naming DirtyBit.
3. **Given** a create request, **When** Priority or ReadDateTime is supplied as a non-numeric or out-of-range value, **Then** the request is rejected with a structured error naming the offending field.

---

### Edge Cases

- **Empty payload vs. omitted payload**: An explicitly supplied empty payload and an omitted payload both result in Payload="" — they are indistinguishable and both valid.
- **Boolean encoding round-trip**: DirtyBit stored in its encoded form (0/1) MUST read back as a logical true/false, never as the raw encoded token.
- **ReadDateTime = 0**: The default 0 is the sentinel for "never read" and is a valid stored value, not an error.
- **Large ReadDateTime**: A millisecond epoch timestamp far into the future MUST be stored and read back without loss of precision.
- **Priority boundaries**: Priority values both well below and well above the default 1000 (including the minimum and maximum integer values allowed) MUST be accepted and stored/read back faithfully. (Ordering by priority is out of scope for this feature; only acceptance and round-trip of boundary values are validated here.)
- **Partially populated target location**: If the target location already holds data that is not a complete, well-formed message, a read MUST surface a clear error rather than returning silently corrupted fields.
- **Extra/unknown attributes**: If the caller supplies an attribute name that is not one of the five defined fields, the request MUST be rejected with a structured error rather than storing the stray value.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST define a message as exactly five named attributes: ReadAttempts, DirtyBit, ReadDateTime, Priority, and Payload. No other attributes are part of the message.
- **FR-002**: The system MUST treat ReadAttempts as a non-negative integer with a default value of 0.
- **FR-003**: The system MUST treat DirtyBit as a boolean (true/false) with a default value of false.
- **FR-004**: The system MUST treat ReadDateTime as a non-negative integer representing Unix epoch milliseconds, with a default value of 0, where 0 denotes "never read".
- **FR-005**: The system MUST treat Priority as an integer with a default value of 1000, where a lower value denotes higher priority.
- **FR-006**: The system MUST treat Payload as a string with a default value of the empty string "".
- **FR-007**: The system MUST allow a message to be created from any subset of the five attributes, applying the documented default to every attribute the caller does not supply.
- **FR-008**: The system MUST persist a created message at a caller-designated target location so that it can be read back.
- **FR-009**: The system MUST provide a read operation that returns all five attributes of a stored message in a well-defined shape with correct logical types (numbers as numbers, DirtyBit as true/false, Payload as a string).
- **FR-010**: The read operation MUST NOT modify the stored message in any way (read-only).
- **FR-011**: The system MUST reject a create request that supplies an invalid value for any field — wrong type or out of allowed range — returning a structured error that identifies the offending field, and MUST NOT store a message in that case.
- **FR-012**: The system MUST reject a create request that supplies any attribute name outside the five defined fields, returning a structured error.
- **FR-013**: When a read targets a location that holds no message, the system MUST return a clear, distinguishable "not found" result rather than a partial or malformed message.
- **FR-014**: The boolean DirtyBit MUST round-trip without ambiguity: a value stored as false MUST read back as false and a value stored as true MUST read back as true.
- **FR-015**: Numeric fields (ReadAttempts, ReadDateTime, Priority) MUST round-trip without loss of value or precision for all values within their allowed ranges.
- **FR-016**: The target location for a message MUST be supplied by the caller; the system MUST NOT compute, derive, or hardcode the location itself.
- **FR-017**: Each create and read operation MUST complete as a single self-contained server-side call (no multi-step client interaction required to create or read one message).

### Key Entities *(include if feature involves data)*

- **Message**: The unit stored in the queue. Composed of five attributes:
  - **ReadAttempts** — non-negative integer; how many times the message has been read/attempted. Default 0.
  - **DirtyBit** — boolean; marks the message as modified/in-flight. Default false.
  - **ReadDateTime** — non-negative integer (Unix epoch milliseconds); when the message was last read, 0 = never. Default 0.
  - **Priority** — integer; ordering weight where lower = higher priority. Default 1000.
  - **Payload** — string; the application data the message carries. Default "".

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A message created with no supplied attributes reads back with all five documented default values, 100% of the time.
- **SC-002**: A message created with any combination of supplied and omitted attributes reads back with supplied values exactly as given and omitted values at their defaults, across all tested combinations.
- **SC-003**: 100% of read operations return all five fields with the correct logical type and leave the stored message byte-for-byte unchanged.
- **SC-004**: 100% of create requests carrying an invalid field value or an unknown attribute are rejected with a structured error that names the offending field, and no message is stored in those cases.
- **SC-005**: Every defined create and read operation completes in a single server-side call with no intermediate client round trips.
- **SC-006**: Create and read behave identically on the directly-testable engines (self-hosted Redis 7.0+ and self-hosted Valkey 7.2+) in both standalone and cluster mode, with zero behavioural differences observed in the test suite. Compatibility with the managed targets (ElastiCache, MemoryDB) is assured by using only commands/options on the common-supported list for all four platforms, verified by a static command-portability check rather than a live test (those services cannot be run as local containers).

## Assumptions

- **Scope is the message format only.** This feature covers creating, storing, reading, and validating a single message representation. Enqueue/dequeue, priority-ordered retrieval, retry/visibility logic, and any sorted-set or queue mechanics are explicitly out of scope and belong to later features. Priority ordering meaning (lower = higher) is documented here only so the field's semantics are unambiguous; no ordering operation is implemented in this feature.
- **The caller designates where each message lives** and passes that location in with every operation, consistent with the project's cluster-safe key-access rule. The feature never invents locations.
- **DirtyBit is encoded for storage** because the underlying store has no native boolean type; the encoding is an internal detail and callers always see a logical true/false.
- **ReadDateTime is interpreted as Unix epoch milliseconds.** The feature stores and returns the integer faithfully; it does not itself generate timestamps or interpret time zones.
- **Validation rejects supplied-but-invalid values and unknown attributes; it never rejects omitted fields** (omitted fields always take defaults).
- **A single message occupies a single caller-designated location**; this feature does not address relationships between multiple messages.
- **"Target location" means the caller-supplied storage key.** The spec uses the technology-agnostic term "target location"; in the design this is the key passed via `KEYS[]`. The two terms refer to the same thing.
- **A read-only validation capability is provided** so callers (and later features) can check candidate field values without storing a message. This supports FR-011/FR-012 (the same validation rules applied during create) and performs no writes and no key access.
