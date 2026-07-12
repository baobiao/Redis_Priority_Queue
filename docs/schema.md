# Message Schema & Native Data Types

Developer reference for the on-server data model of this priority-queue library.
Audience: Redis/Valkey developers integrating with the `message_format` library.

The library uses exactly **two native data types**:

- a **Hash** per message (`msgfmt_create`, `msgfmt_read`, `msgfmt_enqueue`, `msgfmt_dequeue`,
  `msgfmt_ack`, `msgfmt_nack`; `msgfmt_validate` checks field values only and touches no key);
- a **Sorted Set (ZSET)** per priority queue (`msgfmt_enqueue`, `msgfmt_dequeue`, `msgfmt_ack`).

Every key is caller-supplied via `KEYS[]`, with one sanctioned exception: `msgfmt_dequeue`
appends the runtime message `id` to a caller-supplied, co-located key prefix (`KEYS[2] .. id`)
to reach the message it selects at runtime (constitution Principle IV, amended v2.0.0).

Source of truth: `src/functions/message_format.lua`. All values below are what the
Lua actually encodes/validates — not aspirational.

Shared constant: `MAX_SAFE_INT = 9007199254740992` (`2^53`) — the largest integer a Lua
number (an IEEE-754 double) represents exactly. It bounds every integer field.

**Integer-ness** (used by several rules below): a supplied value is accepted as an integer
when `tonumber(value)` returns a finite number `n` (not `nil`, not `NaN`, not `±inf`) **and**
`math.floor(n) == n`.

---

## 1. The Message — a Redis/Valkey Hash

One message is stored as a single **Hash** at a **caller-supplied key**
(`KEYS[1]` for `msgfmt_create`/`msgfmt_read`; `KEYS[2]` for `msgfmt_enqueue`). One Hash =
one message. The field set is **closed**: exactly these seven fields, one Hash field each.
Supplying any other field name, a duplicate name, or an odd `name value` count is rejected
and nothing is stored (fail-before-write).

| Field | Logical type | Default | Stored encoding (Hash field value) | Validation rule |
|-------|--------------|---------|-------------------------------------|-----------------|
| `ReadAttempts` | Integer ≥ 0 | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |
| `DirtyBit` | Boolean | `false` | `"0"` (false) / `"1"` (true) | token ∈ {`0`,`1`,`true`,`false`}, case-insensitive |
| `ReadDateTime` | Integer ≥ 0 (Unix epoch ms) | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |
| `Priority` | Integer | `1000` | decimal string via `%.0f`, e.g. `"1000"` | integer, `\|n\| ≤ 2^53` (`-2^53 ≤ n ≤ 2^53`) |
| `Payload` | String | `""` | raw byte string, stored as-is | any byte string (always valid, incl. empty) |
| `VisibleAt` | Integer ≥ 0 (Unix epoch ms) | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |
| `DeadLetteredAt` | Integer ≥ 0 (Unix epoch ms) | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |

Semantics:

- `ReadDateTime` `0` = **never read**.
- `DirtyBit` marks a message in-flight / modified. Accepted input tokens are lower-cased
  before comparison; anything outside the four-token set is `EINVAL: DirtyBit`.
- **`Priority`: lower value = higher priority.** `Priority` is signed (unlike the two
  non-negative counters); default `1000`.
- **`VisibleAt` `0` = immediately visible** (no not-before). See §3a — it is the delayed-visibility
  gate, distinct from the lease visibility timeout.
- **`DeadLetteredAt` `0` = not dead-lettered.** Set to the caller's `now` when `msgfmt_dequeue` moves
  a message to the dead-letter queue; the retention reaper (§4a) ages entries out by it; `msgfmt_redrive`
  resets it to `0`.
- Omitted fields take their default; the message is always written with **all seven** fields.
- **Back-compat**: `VisibleAt` was added in Feature 005 and `DeadLetteredAt` in Feature 006. A message
  stored by an earlier feature lacks those fields; readers treat a **missing `VisibleAt` / `DeadLetteredAt`
  as `0`** and never error on their absence, so no migration is needed. The five original fields remain
  strictly required.

### Read decoding (round-trip)

`msgfmt_read` returns a flat `name value name value ...` array with each field decoded back to
its logical type:

- `ReadAttempts`, `ReadDateTime`, `Priority`, `VisibleAt`, `DeadLetteredAt` → numbers (`tonumber`); a
  missing `VisibleAt` (pre-005) or `DeadLetteredAt` (pre-006) decodes to `0`;
- `Payload` → the raw stored string;
- `DirtyBit` → **integer `0` or `1`, not a boolean**. RESP2 has no boolean type, and returning
  a Lua `false` would marshal to a nil/absent reply; the integer avoids that `false`→nil
  ambiguity. Treat `1` as true, `0` as false client-side.

A read of an absent key returns a `NOTFOUND` status; a non-Hash value or a Hash missing any of
the five fields returns a structured `MSGFMT EMALFORMED: ...` error (never a partial message).

---

## 2. The Priority Queue — a Redis/Valkey Sorted Set (ZSET)

One logical priority queue is a single **Sorted Set** at a **caller-supplied key**
(`KEYS[1]` for `msgfmt_enqueue`), holding one member per currently-enqueued message.
**One Sorted Set = one logical queue**; multiple queues are simply different caller keys.

- **Ordering**: ascending by score. **Lowest score = highest priority = front of the queue.**
- **score** = the message's integer `Priority` (the same value stored in the Hash).
- **member** = a fixed-width **20-digit zero-padded insertion sequence** + `":"` + the
  caller-supplied unique **`id`**, built as `string.format('%020.0f', sequence) .. ':' .. id`.

Example member for `sequence = 5`, `id = order-42`:

```
00000000000000000005:order-42
```

### Queue Entry (one Sorted Set member)

| Part | Value | Notes |
|------|-------|-------|
| **score** | message `Priority` (integer) | pure integer; **never** packed with the sequence |
| **member** | `<20-digit zero-padded sequence>:<id>` | `sequence` is a caller-supplied integer `0 ≤ s ≤ 2^53`, monotonically increasing per queue; `id` is caller-supplied, unique, non-empty |

The full member string is unique per entry; re-adding an existing member is rejected
(`MSGFMT EQDUP: already enqueued`).

### Why the sequence lives in the member, not the score

ZSET scores are **IEEE-754 doubles** — exact only up to `2^53`. If we packed both `Priority`
and a sequence into one numeric score, the composite would exceed `2^53` and lose precision,
silently corrupting order. Instead:

- **`Priority` alone is the score** (an exact integer within `±2^53`), and
- **FIFO ordering among equal priorities is broken by member byte order.** Because the sequence
  is zero-padded to a **fixed width**, lexicographic (byte) member order equals numeric sequence
  order, so equal-priority messages come out in insertion order. Redis/Valkey break score ties
  by member lexicographic order, which is exactly what this encoding relies on.

---

## 3. The Lease — in-flight state, visibility timeout, and fencing

`msgfmt_dequeue` does not remove a message from the queue; it **leases** it. The lease is
expressed entirely in three existing Hash fields — no new keys or fields:

| Field | Role while leased |
|-------|-------------------|
| `DirtyBit` | `1` = in-flight (leased); `0` = available. Acquire sets `1`; `msgfmt_nack` resets to `0`; `msgfmt_ack` deletes the message. |
| `ReadDateTime` | The lease start (the caller's `now`, epoch ms). Drives timeout expiry. |
| `ReadAttempts` | Incremented on every grant (initial acquire and each reclaim). Its value at grant is the **fencing token**. |

**Availability**: `msgfmt_dequeue` returns the front message that is either `DirtyBit=0`, or
`DirtyBit=1` with an **expired** lease (`now − ReadDateTime ≥ timeout`, the caller-supplied
visibility timeout). A message stays in the Sorted Set from enqueue until `msgfmt_ack`; while
leased it remains a member but is skipped by other acquires until its lease expires.

**Visibility timeout**: if a consumer crashes after acquiring but before settling, the lease is
reclaimed by the next acquire once `timeout` has elapsed since `ReadDateTime`. Both `now` and
`timeout` are caller-supplied (deterministic; no server clock).

**Fencing token**: because every grant increments `ReadAttempts`, its value uniquely identifies
a lease generation. `msgfmt_ack` / `msgfmt_nack` proceed only when the message is in-flight
(`DirtyBit=1`) **and** its current `ReadAttempts` equals the token the caller holds; a stale
token (from a lease reclaimed by another consumer) is rejected with `EFENCED`, so a revived
crashed consumer cannot settle a message someone else now holds. Settling an already-removed
message is an idempotent `NOOP`; settling a non-leased message is `ENOTLEASED`.

**Lifecycle**: `AVAILABLE → (dequeue) LEASED → (ack) REMOVED`, or `LEASED → (nack) AVAILABLE`,
with `LEASED → (timeout) reclaimable`. `ReadAttempts` records how many times a message has been
delivered; when a dead-letter queue and a delivery cap are supplied (Feature 004, §4), an
available message whose `ReadAttempts` has reached the cap is moved to the dead-letter queue on
its next dequeue instead of being delivered again.

### 3a. Delayed visibility (not-before) — DISTINCT from the lease timeout

`VisibleAt` (Feature 005) is a **not-before time**: an otherwise-available message
(`DirtyBit=0`) is **not deliverable until `now ≥ VisibleAt`**. This is a **different concept** from
the lease "visibility timeout" above — do not conflate them:

| | Lease visibility timeout (Feature 003) | Delayed visibility / `VisibleAt` (Feature 005) |
|---|---|---|
| Governs | an **in-flight** message (`DirtyBit=1`) | an **available** message (`DirtyBit=0`) |
| Effect | reclaim the lease after `now − ReadDateTime ≥ timeout` | hold the message back until `now ≥ VisibleAt` |
| Set by | acquire stamps `ReadDateTime`; caller supplies `timeout` per dequeue | caller supplies `VisibleAt` (enqueue field, or nack backoff) |

**Deliverability**: `msgfmt_dequeue` (and `msgfmt_peek` single mode) select a message only when it is
lease-available **and** `now ≥ VisibleAt`. A not-yet-visible message is present in the queue but
skipped in the front scan (it counts against `max_scan`), exactly like an unexpired lease; it never
changes priority ordering (`VisibleAt` is in the Hash, never in a score). Two ways to set it:

- **Scheduled delivery**: enqueue with `VisibleAt <epoch>` (a normal field) → deliverable only later.
- **Retry backoff**: `msgfmt_nack <token> <VisibleAt>` releases the lease **and** hides the message
  until `now ≥ VisibleAt` (retaining `ReadDateTime`/`ReadAttempts`).

`msgfmt_redrive` resets `VisibleAt` to `0` (immediately visible). A not-yet-visible over-cap message
is **not** dead-lettered until it becomes visible (dead-lettering is a delivery-time action, gated by
deliverability). Times are caller-supplied (deterministic; no server clock).

## 4. The Dead-Letter Queue (DLQ) — poison-message handling

A **dead-letter queue** is just another priority-queue **Sorted Set**, structurally identical to a
source queue, that holds messages which reached a caller-supplied maximum-delivery **cap**. It
shares the source queue's hash tag (e.g. source `pq:{q1}`, DLQ `dlq:{q1}`).

- **Dead-lettering** happens inside `msgfmt_dequeue` when called with an optional DLQ key
  (`KEYS[3]`) and a `cap`: while scanning the front, an **available** message
  (`DirtyBit=0`, or an expired lease) whose `ReadAttempts ≥ cap` is **moved index-only** — removed
  from the source (`ZREM`) and added to the DLQ (`ZADD`) with **score = its `Priority`** and the
  **member string preserved verbatim**. The message **Hash is never modified or moved**. The scan
  then continues, so the consumer transparently receives the next deliverable message (or null); a
  message currently in-flight with an **unexpired** lease is never dead-lettered. Omitting the DLQ
  key/cap makes `msgfmt_dequeue` behave exactly as Feature 003.
- Because the DLQ has the identical shape (score = `Priority`, verbatim member, Hash in place), it
  is itself **peek-able and dequeue-able** with the same functions.
- **Redrive** (`msgfmt_redrive`) is the reverse move for one message: `ZREM` from the DLQ, `ZADD`
  back to the source at `score = Priority` (member verbatim), and reset the delivery state —
  `ReadAttempts = 0`, `DirtyBit = 0` — while **retaining `ReadDateTime`** (a forensic record of the
  last processing time). It is a `NOOP` if the member is not in the DLQ, and rejected (`EQDUP`) if
  the member is already in the source (no duplicate index).
- **Peek** (`msgfmt_peek`) is a read-only inspection of any such queue and never mutates or removes
  anything (it skips dangling members rather than cleaning them up).

Message-lifecycle transitions added here: `AVAILABLE → (dequeue, ReadAttempts ≥ cap) DEAD-LETTERED`
and `DEAD-LETTERED → (redrive) AVAILABLE`.

### 4a. Retention — ageing out the DLQ (Feature 006)

To keep the DLQ bounded, dead-lettering now records **when** a message was dead-lettered in the
`DeadLetteredAt` field (the caller's `now`, stamped by `msgfmt_dequeue`'s dead-letter move — the only
change to that otherwise index-only move). A message dead-lettered longer ago than a caller-supplied
**retention window** is permanently removed by **`msgfmt_reap`**:

- Reap examines up to a caller-supplied **`limit`** of DLQ members (bounded execution) and, for each
  whose `DeadLetteredAt ≤ now − retention`, removes **both** its DLQ member (`ZREM`) and its message
  Hash (`DEL`) — retention means *permanently gone*, unlike dead-lettering which keeps the Hash. A
  dangling member (Hash already missing) is cleaned up and counted. Reap returns
  `{removed, scanned, truncated}`.
- **Priority-order caveat**: the DLQ stays Priority-scored (Feature 004 unchanged), so reap walks the
  front *in Priority order*. A small fixed `limit` may not reach expired low-priority entries behind
  unexpired high-priority ones; to fully drain, size `limit` to the DLQ depth (from `msgfmt_stats`) or
  page. `now` and `retention` are caller-supplied (no server clock).
- **Redrive** clears `DeadLetteredAt` back to `0` (the message is no longer dead-lettered).

Transition added: `DEAD-LETTERED → (reap, now − DeadLetteredAt ≥ retention) REMOVED` (member + Hash gone).

### 4b. Observability — `msgfmt_stats` (Feature 006)

`msgfmt_stats` is a read-only (`no-writes`) snapshot of a queue, beyond `msgfmt_peek`'s head view:

- **Cheap tier (always)**: `depth` (`ZCARD` of the queue), `dlq_depth` (`ZCARD` of the DLQ, when given),
  and `front_priority` (the front member's score; `-1` when empty) — all O(1)/O(log N), no Hash reads.
- **Bounded tier (`max_scan > 0`)**: a bounded front scan classifying each message as `available` /
  `in_flight` (leased, unexpired) / `delayed` (not yet visible), with `skipped` (dangling/malformed) and
  a `truncated` flag when `depth > max_scan`; and — with a DLQ — an **approximate**
  `oldest_dead_letter_age` (`now − min DeadLetteredAt` over the *scanned* DLQ prefix; approximate
  because the DLQ is Priority-ordered, flagged by `age_truncated`).

`msgfmt_stats` never writes and never removes dangling members (that is reap's job).

## 5. Keys & Cluster Co-location

Every key is **caller-supplied via `KEYS[]`**. The library never hardcodes a key name; the one
sanctioned construction is appending the runtime `id` to a caller-supplied, co-located prefix —
done by `msgfmt_dequeue` and `msgfmt_peek` for a message discovered by scanning (whose id is not
knowable in advance). `msgfmt_redrive` addresses a message whose id the caller knows, so it takes
the message Hash key **literally**. `msgfmt_enqueue` takes two keys:

- `KEYS[1]` = the priority-queue **Sorted Set**;
- `KEYS[2]` = the message **Hash**.

`msgfmt_dequeue` in dead-letter mode adds `KEYS[3]` = the **dead-letter Sorted Set**, and
`msgfmt_redrive` takes the DLQ, the source queue, and the message Hash — in every case **all keys
in one call share a single hash tag**.

Because a single `FCALL` touches multiple keys, on a clustered deployment they **must hash to the
same slot**, which requires a **shared hash tag** — the substring between the first `{` and `}`
in each key. Only that substring is hashed, so two keys with the same tag always co-locate.

```
KEYS[1] = pq:{q1}          # the queue Sorted Set
KEYS[2] = pq:{q1}:m:42     # the message Hash   (same tag "q1" -> same slot)
KEYS[3] = dlq:{q1}         # the dead-letter Sorted Set (same tag "q1", dead-letter dequeue)
```

`msgfmt_dequeue` takes `KEYS[1]` = the queue Sorted Set and `KEYS[2]` = the message-key
**prefix** (e.g. `pq:{q1}:m:`), and reaches each candidate message at `KEYS[2] .. id`. It first
checks that the prefix (and, in dead-letter mode, the DLQ key `KEYS[3]`) carries the queue's hash
tag (else `MSGFMT ETAG`), so every constructed key — e.g. `pq:{q1}:m:42` — lands in the queue's
slot. `msgfmt_peek` takes the same queue + prefix and constructs keys read-only. `msgfmt_ack` and
`msgfmt_redrive` receive the specific message Hash directly in `KEYS[]`; `msgfmt_nack` receives
only the message Hash.

Amazon **ElastiCache** and **MemoryDB** always run in cluster mode and **reject cross-slot
multi-key access with a `CROSSSLOT` error**. Callers that omit or mismatch the hash tag
(e.g. `pq:{q1}` with `pq:{q2}:m:42`) will fail there. Use one shared tag per logical queue and
put every key for that queue (the Sorted Set, the message-key prefix, and all its message
Hashes) inside it. During slot **resharding**, a call touching the runtime-constructed key may
transiently return `TRYAGAIN`/`ASK`; clients should retry.

---

## 6. Portability

A **single, identical Lua source** (`src/functions/message_format.lua`) is designed to run
unmodified on:

- **Redis 7.0+**
- **Valkey 7.2+**
- **Amazon ElastiCache** (Redis- and Valkey-compatible)
- **Amazon MemoryDB**

To stay portable the library uses only **commonly-supported commands and options** across all
four targets. The full data model relies on just: `HSET`, `HGET`, `HMGET`, `HINCRBY`, `EXISTS`,
`TYPE`, `DEL`, `ZADD`, `ZSCORE`, `ZRANGE`, `ZREM`, and `ZCARD` — no engine-specific commands, options, or
admin/privileged commands, and no non-deterministic sources: score, member, the lease times
(`now`, `timeout`), the delivery `cap`, the peek `count`, the retention window, and the fencing token all derive from
`ARGV` or existing field values, never from server time, counters, or random. This keeps
behaviour identical whether running standalone or clustered. (Whole-library platform note: the
`FUNCTION`/`FCALL` family is available on self-hosted Redis/Valkey, node-based ElastiCache, and
MemoryDB 7.x, but **not** on ElastiCache Serverless.)
