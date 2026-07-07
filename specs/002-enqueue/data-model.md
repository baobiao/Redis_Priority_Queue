# Phase 1 Data Model: Enqueue

This feature adds a **priority-queue index** over the messages defined in Feature 001. It
introduces no new message fields; it reuses the Feature 001 **Message** entity unchanged and
adds two new concepts: the **Priority Queue** (a Sorted Set) and the **Queue Entry** (one
member of that Sorted Set).

## Entity: Message (reused from Feature 001 — unchanged)

A single queue message stored as one Redis/Valkey **Hash** at a caller-supplied key
(`KEYS[2]` for enqueue). Five closed fields with the exact defaults, encodings, and
validation defined in `specs/001-message-format/data-model.md`:

| Field | Logical type | Default | Stored as | Role in enqueue |
|-------|--------------|---------|-----------|-----------------|
| `ReadAttempts` | Integer ≥ 0 | `0` | decimal string | stored as-is |
| `DirtyBit` | Boolean | `false` | `"0"`/`"1"` | stored as-is |
| `ReadDateTime` | Integer ≥ 0 (epoch ms) | `0` | decimal string | stored as-is |
| `Priority` | Integer | `1000` | decimal string | **becomes the Sorted Set score** |
| `Payload` | String | `""` | raw byte string | stored as-is |

Enqueue builds and validates the message with Feature 001's `build_message` (defaults applied
for omitted fields; unknown/duplicate/invalid inputs rejected identically to `msgfmt_create`).

## Entity: Priority Queue (new)

A single logical priority queue, stored as one Redis/Valkey **Sorted Set** at a
caller-supplied key (`KEYS[1]`). It holds one member per currently-enqueued message.

- **Ordering**: ascending by **score = message `Priority`** (lower value = higher priority ⇒
  front of the queue); ties broken by member byte order (see Queue Entry) = insertion order.
- **Key**: always caller-supplied via `KEYS[1]`; never computed/derived/hardcoded. Must be
  co-located with the message Hash key (`KEYS[2]`) in the same cluster slot via a shared hash
  tag (e.g. `pq:{q1}` alongside `pq:{q1}:m:42`).
- **Cardinality**: one Sorted Set = one logical queue. Multiple queues are simply different
  caller-supplied keys.

## Entity: Queue Entry (new)

The representation of one enqueued message within the Priority Queue — a single Sorted Set
member with a score.

| Part | Value | Notes |
|------|-------|-------|
| **score** | the message's integer `Priority` | pure integer; never packed with the sequence (double-precision, exact ≤ 2^53) |
| **member** | `<zero-padded sequence> ":" <id>` | fixed-width (e.g. 20-digit) zero-padded caller-supplied `sequence`, then `":"`, then the caller-supplied unique `id` |

- **`id`** — caller-supplied, unique, non-empty; identifies the message within the queue.
- **`sequence`** — caller-supplied, non-negative integer (validated `≥ 0`, `≤ 2^53`, integer),
  monotonically increasing per queue; its fixed-width zero-padded form makes lexicographic
  member order equal insertion order, giving FIFO among equal priorities.
- **Uniqueness**: the full member string is unique per entry; enqueuing a member that already
  exists is rejected as a duplicate (Decision 4).

## Enqueue inputs (contract summary; full contract in `contracts/functions.md`)

- `KEYS[1]` = priority-queue Sorted Set key; `KEYS[2]` = message Hash key (same slot).
- `ARGV[1]` = `id`; `ARGV[2]` = `sequence`; `ARGV[3..]` = zero or more `field value` pairs
  (the Feature 001 message attributes; any subset).

## Lifecycle / state

This feature defines only **enqueue** (create-and-index). There is no removal or mutation yet.
A message/queue location, from enqueue's perspective, is one of:

- **message key absent, queue key absent-or-Sorted-Set, member absent** → enqueue proceeds:
  `HSET` the message + `ZADD` the member (single atomic result).
- **message key already present (any type)** → rejected `EEXISTS` (occupied/duplicate); nothing written.
- **queue key present but not a Sorted Set** → rejected `EMALFORMED` (wrong type); nothing written.
- **member already present in the queue** → rejected (already enqueued); nothing written.

Removal, priority-ordered pop, re-prioritisation, and mutation of `ReadAttempts`/`DirtyBit`/
`ReadDateTime` are deferred to later specifications of this feature.
