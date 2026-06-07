# Phase 0 Research: Message Format

All four originally-ambiguous decisions were resolved with the stakeholder before the spec was written; this document records them as formal decisions plus the supporting technical research. No `NEEDS CLARIFICATION` markers remain.

## Decision 1 — Storage representation: Redis Hash (one field per attribute)

- **Decision**: Store each message as a single Redis Hash at the caller-supplied key, with fields `ReadAttempts`, `DirtyBit`, `ReadDateTime`, `Priority`, `Payload`.
- **Rationale**:
  - Allows future features (retry, dirty-marking, read-timestamping) to mutate individual fields with `HSET`/`HINCRBY` without rewriting the Payload — important for a queue where Payload may be large.
  - Hash commands (`HSET`, `HGET`, `HGETALL`, `HMGET`, `HDEL`, `EXISTS`, `TYPE`) are available and unrestricted on all four targets (Redis, Valkey, ElastiCache, MemoryDB).
  - No serialization library needed, keeping the dependency surface minimal (Principle II).
- **Alternatives considered**:
  - *JSON string via `cjson`*: whole-message rewrite on any field change; pulls in a serialization step; harder partial updates. Rejected.
  - *MessagePack via `cmsgpack`*: compact but opaque/non-debuggable; same whole-message rewrite drawback. Rejected.

## Decision 2 — Priority ordering: lower value = higher priority

- **Decision**: A numerically lower `Priority` denotes higher priority; default 1000 sits mid-range.
- **Rationale**: Matches the common "nice value" convention and leaves headroom both above and below the default. Recorded now so the field's meaning is unambiguous for downstream ordering features.
- **Scope note**: This feature only stores/validates the integer; no ordering operation is implemented here.
- **Alternatives considered**: *Higher = higher priority* — equally workable but less conventional; rejected per stakeholder. *Defer entirely* — rejected because the field's documented meaning is cheap to fix now and avoids later ambiguity.

## Decision 3 — Validation: defaults for missing, structured error on invalid

- **Decision**: Missing fields receive documented defaults; a supplied value that is wrong-typed or out of range causes the create to fail with `redis.error_reply` naming the field, and nothing is stored. Unknown attribute names are also rejected.
- **Rationale**: Protects all downstream consumers from corrupt messages (Principle VIII) while keeping message creation ergonomic (callers supply only what they have).
- **Validation rules**:
  - `ReadAttempts`: integer, ≥ 0.
  - `DirtyBit`: boolean — accepted input tokens are `"0"`/`"1"`/`"true"`/`"false"` (case-insensitive); anything else is invalid.
  - `ReadDateTime`: integer, ≥ 0 (epoch ms).
  - `Priority`: integer (any 53-bit-safe value; no range restriction beyond integer-ness).
  - `Payload`: string (any byte string, including empty).
- **Alternatives considered**: *Silent coercion* — hides bugs, rejected. *Strict all-required* — harms ergonomics and contradicts the "default value" requirement, rejected.

## Decision 4 — ReadDateTime unit: Unix epoch milliseconds

- **Decision**: `ReadDateTime` is Unix epoch milliseconds; default/sentinel 0 = "never read".
- **Rationale**: Millisecond precision is standard for queue read-timestamps. Stored faithfully; the feature does not generate the timestamp itself (the caller passes it), preserving determinism for replication (Principle VII).
- **Precision note**: Lua 5.1 numbers are IEEE-754 doubles, exact for integers up to 2^53 (~9.0e15). Millisecond epoch values (~1.7e12 today) and any realistic future value stay far inside that bound, so no precision loss. Numbers are stored as their decimal string in the Hash and parsed back with `tonumber`.
- **Alternatives considered**: *Epoch seconds* — coarser, rejected. *Opaque integer* — loses shared meaning across features, rejected.

## Supporting research — Lua 5.1 / Redis Functions specifics

- **Boolean & integer encoding**: Redis Hash field values are byte strings. Booleans are encoded as `"0"`/`"1"`; integers as decimal strings via `tostring`/string formatting. On read, `"1"`/`"0"` map back to Lua `true`/`false`, and numeric strings are converted with `tonumber`. This guarantees the round-trip required by FR-014/FR-015.
- **Integer validation in Lua 5.1**: there is no integer type; integer-ness is checked by `tonumber(v)` succeeding, the value being finite, and `math.floor(n) == n`. Negativity and range checked numerically.
- **Function flags**: the reader and validator are registered with `flags = { 'no-writes' }` so they are callable via `FCALL_RO` (Principle VII). The writer carries no such flag.
- **`redis.setresp`/return shape**: functions return Lua tables. To give callers a predictable typed shape (Decision/ FR-009), the reader returns a flat array of `field, value` pairs (RESP map-style) or a status indicating "not found"; exact shape captured in `contracts/functions.md`.
- **Not-found semantics**: `HGETALL` on a missing key returns an empty result; the reader distinguishes this from a real message and returns a structured "not found" status reply (FR-013). `TYPE`/`EXISTS` may be used to disambiguate a key that holds a non-Hash value (edge case: partially populated / wrong-type location).
- **Command portability check**: `HSET`, `HGET`, `HGETALL`, `HMGET`, `HDEL`, `EXISTS`, `TYPE` are all on the common-supported list for Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB with no restricted options used.
