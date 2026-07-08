# Research: Dequeue

Phase 0 decisions for Feature 003. Each records the decision, why, and the alternatives
rejected. Findings were grounded by parallel sub-agents against the existing library
(`src/functions/message_format.lua`, `docs/`, `specs/002-enqueue/`), the constitution + static
gate, and authoritative Redis/Valkey documentation, engine source, and the Valkey test suite.

## Decision 1 — Two-phase lease (acquire → settle), not one blocking function

**Decision**: Realise "dequeue that blocks until the consumer succeeds/fails" as two atomic
calls with the lease held between them: `msgfmt_dequeue` (acquire) then `msgfmt_ack` /
`msgfmt_nack` (settle). The block and the success/error branch live in the client wrapper.

**Rationale**: A Redis/Valkey function runs atomically on a single thread and **cannot block**
for external work — the server would freeze for all clients. Verified: blocking commands
(`BLPOP` etc.) inside a function are forced non-blocking (they return immediately via
`CLIENT_DENY_BLOCKING`). So a function can neither wait for the consumer nor be resumed later.
Splitting acquire from settle is the only faithful realisation; each half is a complete,
single-round-trip atomic operation (Principle VI), and the split is a semantic necessity
(external processing), not an avoidable multi-round-trip design.

**Alternatives rejected**: (a) A single function that blocks during processing — impossible
(above). (b) `BLPOP`-style wait for arrival — the spec requires immediate return when nothing is
available, and blocking is disabled in functions anyway.

## Decision 2 — Availability = `DirtyBit=0` OR expired lease; caller-supplied visibility timeout

**Decision**: Acquire selects the front message whose `DirtyBit=0`, **or** whose `DirtyBit=1`
but `now − ReadDateTime ≥ timeout` (an expired lease it reclaims). `now` and `timeout` (ms) are
supplied by the caller via `ARGV`.

**Rationale**: The user chose "visibility timeout + fencing now" so a consumer crash after
acquire but before settle cannot strand a message forever. Reclaiming an expired lease is a plain
arithmetic test on the existing `ReadDateTime` field; no new structure is needed. `timeout` is
required to be a positive integer so a freshly-granted lease (`now − ReadDateTime = 0`) is never
immediately reclaimable.

**Alternatives rejected**: Deferring reclaim (accept stuck `DirtyBit=1`) — rejected by the user
for this slice. A background reaper — needs an external scheduler; folding reclaim into acquire is
self-contained and deterministic.

## Decision 3 — Fencing token = `ReadAttempts` captured at lease grant

**Decision**: Acquire returns the post-increment `ReadAttempts` as the fencing token. `ack`/`nack`
require the supplied token to equal the message's current `ReadAttempts` (and `DirtyBit=1`) before
acting.

**Rationale**: `ReadAttempts` increments on every grant (initial acquire and every reclaim), so it
uniquely identifies a lease generation for a given message. If consumer A's lease expires and B
reclaims it, B's grant makes `ReadAttempts` differ from A's token; A's late `ack`/`nack` then fails
the fence check and cannot delete or release the message B now holds. Combined with the `DirtyBit=1`
precondition, it also rejects settling a released message. No separate token field is needed.

**Alternatives rejected**: `ReadDateTime` as the token — two grants within the same millisecond
could collide. A random/UUID lease id — needs a new field and non-determinism. A monotonic counter
in the queue — extra state; `ReadAttempts` already exists and carries the right semantics.

## Decision 4 — Acquire addresses the selected message by `KEYS[2] .. id` (Principle IV amended)

**Decision**: Acquire receives `KEYS[1]` = queue Sorted Set and `KEYS[2]` = a message-key
**prefix** (both caller-declared, same hash tag). For each candidate member it derives
`id` (the member text after the first `:`) and forms the message Hash key as `KEYS[2] .. id`.
This required amending constitution Principle IV (1.2.0 → 2.0.0) to permit appending a runtime
suffix to a declared, hash-tagged prefix.

**Rationale**: The caller cannot pass the winning message's key literally — which message is at
the front is only known after the server scans. The user's design keeps availability in the
message Hash (`DirtyBit`), so acquire must read/mutate that Hash. Verified authoritatively: a
function may `redis.call` a key that shares a **declared** key's hash tag (same slot) even though
it was not itself declared — the cluster runtime check is purely slot-based, with no
declaration-membership lookup (confirmed in engine source and the Valkey cluster test). ElastiCache
requires ≥1 declared key (satisfied: `KEYS[1]`/`KEYS[2]`). Acquire validates the prefix and queue
share one tag (`ETAG`) so construction is always in-slot.

**Alternatives rejected**: **(B) Queue-scoped message store** (all state under caller-passed
co-tagged keys, no construction) — avoids the amendment but discards the clean one-Hash-per-message
schema and forces rewriting/duplicating `create`/`read`/`enqueue`; per-field `HINCRBY` on a
serialized blob is not possible. **(C) Peek + CAS-mark** (read-only peek returns candidates; client
CAS-marks the now-known key) — adds round trips + client retry under contention and repurposes
`DirtyBit` from the availability flag to queue-side tracking. Both are more disruptive than one
narrow, slot-safe construction.

**Caveat**: During cluster **resharding**, accessing a key not declared up front can transiently
fail (`TRYAGAIN`/`ASK`/"undeclared keys ... during rehashing"). This is a smart-client retry
signal, not a steady-state failure; documented in the contract.

## Decision 5 — `now`/`timeout` caller-supplied for determinism (though `TIME` is allowed)

**Decision**: Keep all time values caller-supplied via `ARGV`; the functions never read the server
clock or use randomness.

**Rationale**: Contrary to a common assumption, `redis.call('TIME')` and `math.random` **are**
permitted in functions (Redis 7.0+ uses effects-only replication, so the concrete writes replicate
safely — the canonical `my_hset` tutorial reads `TIME`). Nonetheless this library keeps time
caller-supplied for **consistency with enqueue** (which takes caller `id`/`sequence`), **fully
deterministic tests** (a test can assert exact `ReadDateTime`), and to preserve the existing static
gate that rejects `TIME`/random. This is a project convention, not a Redis limitation, and is
recorded as such.

**Alternatives rejected**: Reading `TIME` server-side — safe on-engine but breaks test determinism
and the current gate, and diverges from enqueue's caller-supplied model.

## Decision 6 — Front scan with `ZRANGE`; add `ZREM` and `HINCRBY`

**Decision**: Acquire reads the front in order with `ZRANGE key 0 -1` (ascending: lowest score
first, ties by member byte order) and stops at the first available message. Settle uses `ZREM`
(remove a member) and `DEL` (delete a Hash) for ack; `HSET` for nack; `HINCRBY` increments
`ReadAttempts` on acquire.

**Rationale**: `ZRANGE` is read-only, so peeking/skipping in-flight members does not disturb the
set. `ZPOPMIN` is unsuitable — it **removes** the popped member, but acquire must skip in-flight
members without removing them and must not remove the selected member (only `ack` removes). `ZREM`
and `HINCRBY` are core commands, identical across all four engines; `HINCRBY` on an absent field
defaults to 0. Only these two are new to the whitelist.

**Alternatives rejected**: `ZPOPMIN`/`ZPOPMIN count` — removes members prematurely. `ZRANGEBYSCORE`
with `LIMIT` — viable for paging but unnecessary; index-range `ZRANGE` plus an optional `max_scan`
bound suffices and avoids score-boundary edge cases.

## Decision 7 — nack retains the member; ack removes both structures atomically

**Decision**: `nack` only flips `DirtyBit` back to 0 on the message Hash (`KEYS[1]`) — the queue
member is never removed, so the message reappears at its original priority/sequence position.
`ack` removes the queue member (`ZREM KEYS[1] member`) **and** deletes the message Hash
(`DEL KEYS[2]`) in one atomic call.

**Rationale**: Matches the user's design (release keeps position and the modified
`ReadDateTime`/`ReadAttempts`; success deletes the message). Because the member persists from
enqueue until ack, availability is governed purely by the Hash `DirtyBit`/lease, and a released
message keeps its FIFO position. Atomic ack prevents a dangling member or an orphan Hash.

**Alternatives rejected**: nack re-inserting the member — unnecessary (it was never removed) and
would reset FIFO position. ack removing only one structure — leaves inconsistency.

## Decision 8 — Idempotent, fenced, fail-before-write settle

**Decision**: `ack`/`nack` on an **absent** message return a defined `NOOP` status (idempotent,
safe to retry); on a present but non-in-flight message (`DirtyBit=0`) return `MSGFMT ENOTLEASED`;
on a fence mismatch return `MSGFMT EFENCED`; on a wrong-type/malformed Hash return
`MSGFMT EMALFORMED`. No structure is modified on any rejection.

**Rationale**: Networks retry; a duplicated ack after the message is gone must be harmless.
`ENOTLEASED` and `EFENCED` give precise diagnostics for double-settle and stale-lease races while
guaranteeing no side effects, satisfying the spec's "defined, safe reply" requirement.

**Alternatives rejected**: Erroring on absent (breaks idempotent retries). Silently succeeding on a
fence mismatch (would let a stale consumer corrupt another's lease).

## Decision 9 — Dangling members are skipped and opportunistically removed

**Decision**: If a scanned member's message Hash is absent (deleted out of band), acquire removes
the orphan member (`ZREM`) and continues scanning; it never errors on it.

**Rationale**: Enqueue (create+index) and ack (remove both) are atomic, so a dangling member does
not arise in normal operation — only from out-of-band deletion. Skipping keeps acquire robust;
opportunistic cleanup stops orphans from clogging the front. This is the only write acquire makes
before selecting, and it is safe/idempotent; all input validation still runs first.

**Alternatives rejected**: Erroring (a single orphan would wedge the queue). Leaving orphans
(scans degrade over time). A separate GC pass (extra machinery; cleanup here is free).

## Decision 10 — Return shape: field/value array + fence, or null for "nothing"

**Decision**: On a hit, acquire returns a flat `name,value,...` array: `id`, `member`,
`ReadAttempts` (the fence token), `ReadDateTime`, `Priority`, `Payload`. When nothing is available
it returns a Lua `false`, which serialises to a RESP null.

**Rationale**: The client needs the `id`/`member` to `ack`/`nack` and the fence token to be
accepted — `Payload` alone is insufficient. A RESP null for "no message" is unambiguously distinct
from a hit whose `Payload` is an empty string (a value inside the array), mirroring the
`DirtyBit`-as-integer reasoning already used by `msgfmt_read`.

**Alternatives rejected**: Returning only the payload (client cannot settle). Returning an empty
array for "nothing" (ambiguous vs. a hit). A nested/map reply (RESP2 has no map; a flat array
matches `msgfmt_read`).

## Decision 11 — Poison-message capping deferred

**Decision**: No maximum-`ReadAttempts` cap or dead-letter routing in this slice; a repeatedly
failing message is redelivered indefinitely, with `ReadAttempts` climbing.

**Rationale**: The user chose to defer. `ReadAttempts` already records the delivery count, so a
later dead-letter feature (out of scope) or an operator can act on it without any change here.

**Alternatives rejected**: Enforcing a cap now — adds a "parked" lifecycle state the user chose to
defer.

## Decision 12 — Static gate: add `ZREM`, `HINCRBY`; construction passes as a variable key

**Decision**: Extend `tests/harness/static_checks.sh` to allow-list `ZREM` and `HINCRBY`. The
runtime key construction (`KEYS[2] .. id`, passed as a Lua variable to `redis.call`) is not flagged
by the literal-key regex (which only catches a key argument that begins with a quote), so no
regex relaxation is required; the construction's legitimacy rests on the amended Principle IV and
review.

**Rationale**: Confirmed: the gate's literal-key check keys off "does the key argument start with a
string quote," so a variable-held constructed key already passes; only the command whitelist needs
the two additions. The gate scans the whole library file, so the new functions are covered
automatically, and the determinism scan (`TIME`/`math.random`) needs no change and must keep
passing.

**Alternatives rejected**: A regex that "blesses" one construction — not expressible in grep
(cannot distinguish sanctioned from arbitrary). A comment pragma — the gate strips comments before
scanning. Review + the amended principle govern the narrow construction instead.
