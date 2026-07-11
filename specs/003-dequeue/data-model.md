# Data Model: Dequeue

Feature 003 introduces **no new keys or fields**. It adds *behaviour* over the Feature 001
message **Hash** and the Feature 002 priority-queue **Sorted Set**, using three of the existing
Hash fields to represent a **lease**.

## Entities

### Message (Hash) — reused from Feature 001

One Hash per message; five closed fields. Three of them carry lease state:

| Field | Role in dequeue | Encoding (unchanged) |
|-------|-----------------|----------------------|
| `ReadAttempts` | Delivery count; its value at lease grant is the **fencing token** | decimal string (`%.0f`) |
| `DirtyBit` | Lease flag: `1` = in-flight (leased), `0` = available | `"0"` / `"1"` |
| `ReadDateTime` | Lease start (caller `now`, epoch ms); drives timeout expiry | decimal string (`%.0f`) |
| `Priority` | Sort score (unchanged) | decimal string (`%.0f`) |
| `Payload` | Returned to the consumer on acquire | raw bytes |

The message Hash is stored at `<prefix><id>` where `<prefix>` is the caller's message-key
namespace (e.g. `pq:{q1}:m:`) carrying the queue's hash tag — the same key the caller used at
enqueue time.

### Priority Queue (Sorted Set) — reused from Feature 002

- **score** = `Priority` (lower = higher priority = front).
- **member** = `string.format('%020.0f', sequence) .. ':' .. id` (20-digit zero-padded sequence,
  `:`, then `id`). Byte order of equal-score members = FIFO by sequence.
- Holds **every** enqueued message — available and in-flight alike — from enqueue until **ack**.
  In-flight messages remain in the set but are skipped by acquire (unless their lease expired).

### Lease (derived state, not a stored entity)

A lease is the transient in-flight state of a message, expressed by its Hash fields:

- **Granted** by acquire: `DirtyBit 0→1`, `ReadDateTime = now`, `ReadAttempts += 1`.
- **Identity / generation**: the `ReadAttempts` value at grant (the fencing token). Each grant
  (initial or reclaim) yields a new, strictly greater token for that message.
- **Expiry**: a lease is expired (reclaimable) when `now − ReadDateTime ≥ timeout`.

### Handle (acquire's return)

What the client needs to settle the lease later:

```
[ 'id',           <id>,
  'member',       <"%020.0f:id">,
  'ReadAttempts', <int fence token>,
  'ReadDateTime', <int now>,
  'Priority',     <int>,
  'Payload',      <bytes> ]
```

`false` (RESP null) is returned instead when no message is available — distinct from a hit whose
`Payload` is an empty string.

## Lease lifecycle (state machine)

```
                    enqueue (Feature 002)
                          │
                          ▼
                  ┌───────────────┐
                  │   AVAILABLE   │  DirtyBit=0, member in ZSET
                  └───────────────┘
                          │  msgfmt_dequeue selects it:
                          │  DirtyBit=1, ReadDateTime=now, ReadAttempts+=1  (token = new ReadAttempts)
                          ▼
                  ┌───────────────┐
        ┌────────▶│    LEASED     │  DirtyBit=1, member still in ZSET (skipped by others)
        │         └───────────────┘
        │           │            │                         │
        │  nack     │  ack       │  lease expires          │  (consumer working)
        │  (fence   │  (fence    │  (now−ReadDateTime       │
        │   ok)     │   ok)      │   ≥ timeout)             │
        │           │            ▼                          │
        │           │     ┌──────────────┐                 │
        │           │     │ RECLAIMABLE  │  still DirtyBit=1 │
        │           │     └──────────────┘                 │
        │           │            │ next msgfmt_dequeue reclaims:
        │           │            │ ReadDateTime=now, ReadAttempts+=1 (new token; old token now stale)
        │           │            └────────────▶ LEASED (new holder)
        │           ▼
        │   ┌───────────────┐
        └───│    (release)  │ DirtyBit=0, ReadDateTime/ReadAttempts retained
            └───────────────┘
                    │
                    ▼   back to AVAILABLE (same position; may be redelivered)

  ack path ▶  ZREM member + DEL Hash  ▶  ┌──────────┐
                                         │ REMOVED  │  gone from queue and storage
                                         └──────────┘
```

## Transitions and guards

| Operation | Pre-state | Guard | Effect | Result |
|-----------|-----------|-------|--------|--------|
| `msgfmt_dequeue` | AVAILABLE or RECLAIMABLE at the front | inputs valid; tag match; not dangling/malformed | `DirtyBit=1`, `ReadDateTime=now`, `ReadAttempts+=1` | handle (array) |
| `msgfmt_dequeue` | none available within scan | — | nothing written | `false` (null) |
| `msgfmt_ack` | LEASED | `DirtyBit=1` **and** `ReadAttempts == token` | `ZREM member` + `DEL` Hash | `OK` |
| `msgfmt_nack` | LEASED | `DirtyBit=1` **and** `ReadAttempts == token` | `DirtyBit=0` (retain `ReadDateTime`/`ReadAttempts`) | `OK` |
| `msgfmt_ack`/`nack` | REMOVED (absent) | — | nothing written | `NOOP` (idempotent) |
| `msgfmt_ack`/`nack` | AVAILABLE (`DirtyBit=0`) | — | nothing written | `MSGFMT ENOTLEASED` |
| `msgfmt_ack`/`nack` | LEASED by another generation | `ReadAttempts != token` | nothing written | `MSGFMT EFENCED` |

## Invariants

- A member is present in the Sorted Set **iff** the message has been enqueued and not yet acked;
  its message Hash exists over the same interval (enqueue and ack are atomic on both structures).
- `DirtyBit=1` ⇒ the message is leased or reclaimable; `DirtyBit=0` ⇒ available.
- `ReadAttempts` is monotonically non-decreasing per message and increments exactly once per grant
  (initial acquire or reclaim); it never resets.
- At most one consumer holds a valid (un-expired, un-superseded) lease on a message at a time.
- Every key touched in one call shares the queue's hash tag ⇒ single slot ⇒ no `CROSSSLOT`.
- No write occurs on any validation/precondition failure (fail-before-write).
