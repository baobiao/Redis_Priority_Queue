# Phase 0 Research: Dead-Letter Handling and Peek

Feature 004 extends the `message_format` library with dead-letter handling, a non-destructive peek,
and a single-message redrive. All decisions below were grounded by parallel sub-agents against the
existing code, the live Redis/Valkey Function semantics, and constitution v2.0.0 + the static gate.

## Decision 1 — Dead-letter at dequeue (SQS-style max-receive cap)

**Decision**: Enforce the delivery cap **on the receive path** inside `msgfmt_dequeue`. When the
front scan reaches an *available* candidate (`DirtyBit=0`, or `DirtyBit=1` with an expired lease)
whose `ReadAttempts ≥ cap`, move it to the DLQ and keep scanning; never lease an over-cap message.

**Rationale**: Mirrors Amazon SQS `maxReceiveCount`. The check sits exactly where availability is
already computed, so a poison message is removed from circulation the instant it would next be
delivered — no separate sweeper, no reliance on the consumer calling `nack`. A crash-looping
consumer (lease expiry, never nacks) is still capped.

**Alternatives rejected**: *At nack* — misses lease-expiry redelivery and messages whose consumers
crash without nacking. *Both dequeue + nack* — two code paths that must agree on cap semantics, for
no coverage the receive-path check doesn't already give.

## Decision 2 — DLQ is a sibling Sorted Set; index-only move

**Decision**: The DLQ is a separate priority-queue **Sorted Set** sharing the source's hash tag
(`dlq:{q1}` for `pq:{q1}`). Dead-lettering removes the member from the source (`ZREM`) and adds it
to the DLQ (`ZADD`); the message **Hash is never moved or modified**. Redrive is the reverse move.

**Rationale**: The message Hash stays at its original key, so `msgfmt_read` and every other function
address it unchanged. Only one small member string relocates. Sharing the hash tag keeps source,
DLQ, and message Hash in one cluster slot, so the move is a legal single-slot multi-key operation.

**Alternatives rejected**: *Re-key the Hash under a DLQ prefix* (RENAME/COPY) — adds a command to
verify across four engines and move logic, for no benefit. *DLQ as a List or Stream* — diverges from
the uniform queue schema; peek/redrive tooling would differ.

## Decision 3 — DLQ member scored by `Priority`; member preserved verbatim

**Decision**: The DLQ member keeps **score = the message's `Priority`** and the **exact source
member string** (`%020.0f:id`). Redrive re-adds to the source at `score = Priority` as well.

**Rationale**: The DLQ is then structurally identical to a source queue, so `msgfmt_peek` — and even
`msgfmt_dequeue` — operate on it with no special-casing, and redrive is a clean structural reverse.
The verbatim member preserves the embedded insertion sequence, so FIFO-within-priority survives a
DLQ round trip.

**Alternatives rejected**: *Score by dead-letter timestamp* (time-ordered DLQ) — better for
"what failed most recently" forensics, but loses priority ordering inside the DLQ and makes the DLQ
structurally different from a source queue (peek/dequeue would show time order, not priority order).
The user chose priority ordering for uniform tooling.

## Decision 4 — Peek is one `no-writes` function with single + top-N modes

**Decision**: A single `msgfmt_peek` registered with `flags = { 'no-writes' }` (callable via
`FCALL_RO`). No `count` (or `count=1`) → the lease-aware "next deliverable" message (identical
selection to `msgfmt_dequeue`); `count=N` → up to N front members in priority-then-FIFO order
regardless of lease state, each annotated with `DirtyBit`/`ReadAttempts`/`ReadDateTime`/`Priority`/
`Payload`. `now`/`timeout` are required (single mode is lease-aware); top-N accepts but does not use
them to filter. Peek **skips** dangling members (never `ZREM` — it is read-only).

**Rationale**: One function, two clearly-separated jobs — "what's next?" vs "show me the head". A
shared front-selection helper guarantees single-mode peek and dequeue agree exactly. Grounding
confirmed a `no-writes` function may read a runtime-constructed same-slot key and remains
`FCALL_RO`-callable; it is rejected only if it lacks the flag or actually issues a write.

**Alternatives rejected**: *Two functions* (`peek_next` + `peek_head`) — more surface for one
cohesive capability. *A writing peek that cleans danglers* — would forfeit `no-writes`/`FCALL_RO`.

## Decision 5 — Redrive: single message by id; reset attempts; retain ReadDateTime

**Decision**: `msgfmt_redrive` moves one message (identified by its member) from the DLQ back to the
source and resets delivery state to `ReadAttempts=0`, `DirtyBit=0`, while **retaining `ReadDateTime`**.
No-op/not-found when the member is absent from the DLQ; rejected (no duplicate) when already in the
source.

**Rationale**: A reset `ReadAttempts` gives the message a full fresh run against the cap (otherwise it
would re-dead-letter immediately). Retaining `ReadDateTime` preserves a forensic record of when it was
last processed before dead-lettering. Single-message-by-id is the smallest composable, atomic unit; a
caller loops for bulk.

**Alternatives rejected**: *Reset `ReadDateTime` to 0* — cleaner "brand-new" look but discards useful
history (user chose retain). *Caller-supplied reset value* — extra arg for no clear need now.
*Retain `ReadAttempts`* — re-dead-letters immediately unless the cap is also raised (foot-gun).
*Batch / whole-DLQ redrive* — deferred (an unbounded single `FCALL` fights Principle VII bounding).

## Decision 6 — Redrive passes the message Hash literally; peek/dequeue construct it

**Decision**: `msgfmt_dequeue` and `msgfmt_peek` **construct** the message Hash key as
`KEYS[2] .. id` from ids they discover by scanning (the caller cannot know which message is at the
front). `msgfmt_redrive` operates on a message whose id the caller already holds, so it receives the
message Hash key **literally** in `KEYS[]` — no construction.

**Rationale**: Principle IV (v2.0.0) sanctions runtime construction *only when the exact key is not
knowable in advance*. Dequeue/peek meet that test; redrive does not, so it must pass the key literally.
This keeps redrive strictly within the un-amended letter of the principle.

## Decision 7 — No constitution change required

**Decision**: Ship on constitution **v2.0.0** with **no amendment**.

**Rationale**: The Principle IV amendment's permission — "A function MAY form a key by appending a
runtime-derived suffix to a … `KEYS[]` prefix … **only when** the exact target key cannot be known by
the caller in advance" — is gated on *knowability*, with **no write-vs-read qualifier**. So a
read-only `msgfmt_peek` constructing a scanned message key is covered, and the three-same-slot-key
dequeue (source + DLQ + message Hash) is covered (the only cross-key rule is same-slot; there is no
key-count limit). A purely cosmetic PATCH adding a read-only illustration would be optional, not
mandated — not taken.

**Alternatives rejected**: A PATCH bump to 2.0.1 to add a read-only example — unnecessary; the
normative text already governs the case.

## Decision 8 — No new commands; static gate unchanged; atomic move is sound

**Decision**: Use only already-whitelisted commands — dead-letter/redrive: `ZADD`, `ZREM`, `ZSCORE`,
`HSET`, `HGET`/`HMGET`; peek: `ZRANGE`, `HMGET`, `EXISTS`, `TYPE`. No change to
`tests/harness/static_checks.sh` (its `allowed` list already contains all ten, and it scans the whole
library file, so the new functions are covered automatically).

**Rationale / grounding**: (a) `ZREM src member` + `ZADD dst score member` in one `FCALL` is atomic
and all-or-nothing on replicas via effects replication; with `src`/`dst` sharing a hash tag it is a
legal single-slot operation. (b) Plain `ZADD` on an existing member updates its score and counts 0
added; **`ZADD … NX`** adds only if absent — used to guard against overwriting a member already in the
source on redrive. (c) `ZSCORE` returns nil/false when a member is absent — a clean membership guard.
(d) `ZRANGE key 0 N-1` returns lowest-score-first, ties broken lexicographically by member — the
existing FIFO ordering. All behave identically on Redis 7.0+, Valkey 7.2+, node-based ElastiCache,
MemoryDB.

## Decision 9 — Backward-compatible dequeue signature

**Decision**: Extend `msgfmt_dequeue` by **appending** an optional `KEYS[3]` (DLQ Sorted Set) and an
optional trailing `ARGV` cap after `now`/`timeout`/`max_scan`. Dead-lettering engages only when both
are present; otherwise the function is byte-for-byte Feature 003. The existing tag check is extended
to reject a `KEYS[3]` that does not share the source's tag (`ETAG`). A non-Sorted-Set `KEYS[3]` →
`EMALFORMED`.

**Rationale**: Preserves every existing 2-key/3-arg call unchanged (verified by re-running the whole
Feature 003 suite), while making dead-lettering purely opt-in.

**Alternatives rejected**: A separate `msgfmt_dequeue_dl` function — duplicates the scan/lease logic;
divergence risk. A required DLQ key — breaks Feature 003 callers.

## Decision 10 — Determinism preserved; dead-lettering is silent and bounded

**Decision**: `now`, `timeout`, `max_scan`, cap, and `count` are all caller-supplied via `ARGV`; no
server clock or randomness. `msgfmt_dequeue` returns exactly the Feature 003 shape (deliverable
handle or null) and says nothing about how many messages it dead-lettered. Dead-lettering happens
only to members within the `max_scan`-bounded front window (it does not grant extra scan budget).

**Rationale**: Keeps the static determinism scan green and the hot-path contract identical.
Observability of the DLQ is provided by `msgfmt_peek`, so an inline count would only complicate the
return shape. Bounding the work honours Principle VII.

## Cross-cutting note — pre-existing platform caveat

Amazon ElastiCache **Serverless** does not support the `FUNCTION`/`FCALL`/`FCALL_RO` family (only
`EVAL`/`EVAL_RO`). This library targets the Functions API, so it runs on self-hosted Redis/Valkey,
node-based ElastiCache (7.x), and MemoryDB (7.x). This is a property of the whole library, unchanged
by Feature 004, recorded here for completeness.
