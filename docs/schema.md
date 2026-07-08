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
one message. The field set is **closed**: exactly these five fields, one Hash field each.
Supplying any other field name, a duplicate name, or an odd `name value` count is rejected
and nothing is stored (fail-before-write).

| Field | Logical type | Default | Stored encoding (Hash field value) | Validation rule |
|-------|--------------|---------|-------------------------------------|-----------------|
| `ReadAttempts` | Integer ≥ 0 | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |
| `DirtyBit` | Boolean | `false` | `"0"` (false) / `"1"` (true) | token ∈ {`0`,`1`,`true`,`false`}, case-insensitive |
| `ReadDateTime` | Integer ≥ 0 (Unix epoch ms) | `0` | decimal string via `%.0f`, e.g. `"0"` | integer, `0 ≤ n ≤ 2^53` |
| `Priority` | Integer | `1000` | decimal string via `%.0f`, e.g. `"1000"` | integer, `\|n\| ≤ 2^53` (`-2^53 ≤ n ≤ 2^53`) |
| `Payload` | String | `""` | raw byte string, stored as-is | any byte string (always valid, incl. empty) |

Semantics:

- `ReadDateTime` `0` = **never read**.
- `DirtyBit` marks a message in-flight / modified. Accepted input tokens are lower-cased
  before comparison; anything outside the four-token set is `EINVAL: DirtyBit`.
- **`Priority`: lower value = higher priority.** `Priority` is signed (unlike the two
  non-negative counters); default `1000`.
- Omitted fields take their default; the message is always written with **all five** fields.

### Read decoding (round-trip)

`msgfmt_read` returns a flat `name value name value ...` array with each field decoded back to
its logical type:

- `ReadAttempts`, `ReadDateTime`, `Priority` → numbers (`tonumber`);
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
delivered — the signal a future dead-letter feature would use (capping is out of scope here;
redelivery is currently unbounded).

## 4. Keys & Cluster Co-location

Every key is **caller-supplied via `KEYS[]`**. The library never hardcodes a key name; the one
sanctioned construction is `msgfmt_dequeue` appending the runtime `id` to a caller-supplied,
co-located prefix (see below). `msgfmt_enqueue` takes two keys:

- `KEYS[1]` = the priority-queue **Sorted Set**;
- `KEYS[2]` = the message **Hash**.

Because a single `FCALL` touches both keys, on a clustered deployment they **must hash to the
same slot**, which requires a **shared hash tag** — the substring between the first `{` and `}`
in each key. Only that substring is hashed, so two keys with the same tag always co-locate.

```
KEYS[1] = pq:{q1}          # the queue Sorted Set
KEYS[2] = pq:{q1}:m:42     # the message Hash  (same tag "q1" -> same slot)
```

`msgfmt_dequeue` takes `KEYS[1]` = the queue Sorted Set and `KEYS[2]` = the message-key
**prefix** (e.g. `pq:{q1}:m:`), and reaches each candidate message at `KEYS[2] .. id`. It first
checks that the prefix carries the queue's hash tag (else `MSGFMT ETAG`), so every constructed
key — e.g. `pq:{q1}:m:42` — lands in the queue's slot. `msgfmt_ack` receives the queue and the
specific message Hash directly in `KEYS[]`; `msgfmt_nack` receives only the message Hash.

Amazon **ElastiCache** and **MemoryDB** always run in cluster mode and **reject cross-slot
multi-key access with a `CROSSSLOT` error**. Callers that omit or mismatch the hash tag
(e.g. `pq:{q1}` with `pq:{q2}:m:42`) will fail there. Use one shared tag per logical queue and
put every key for that queue (the Sorted Set, the message-key prefix, and all its message
Hashes) inside it. During slot **resharding**, a call touching the runtime-constructed key may
transiently return `TRYAGAIN`/`ASK`; clients should retry.

---

## 5. Portability

A **single, identical Lua source** (`src/functions/message_format.lua`) is designed to run
unmodified on:

- **Redis 7.0+**
- **Valkey 7.2+**
- **Amazon ElastiCache** (Redis- and Valkey-compatible)
- **Amazon MemoryDB**

To stay portable the library uses only **commonly-supported commands and options** across all
four targets. The full data model relies on just: `HSET`, `HMGET`, `HINCRBY`, `EXISTS`, `TYPE`,
`DEL`, `ZADD`, `ZSCORE`, `ZRANGE`, and `ZREM` — no engine-specific commands, options, or
admin/privileged commands, and no non-deterministic sources: score, member, the lease times
(`now`, `timeout`), and the fencing token all derive from `ARGV` or existing field values,
never from server time, counters, or random. This keeps behaviour identical whether running
standalone or clustered.
