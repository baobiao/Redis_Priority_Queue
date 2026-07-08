# Function Contracts: Dequeue

Contracts for the three functions added to the `message_format` library by Feature 003. All
three are **WRITE** functions (registered with no flags; rejected under `FCALL_RO`). Errors use
the existing convention: registered functions reply `redis.error_reply("MSGFMT <CODE>: <detail>")`;
successes use `redis.status_reply(...)`. `MAX_SAFE_INT = 9007199254740992` (2^53).

Shared definitions:

- **Hash tag**: the substring between the first `{` and the first following `}` of a key. Two
  keys with the same tag hash to the same cluster slot.
- **member**: `string.format('%020.0f', sequence) .. ':' .. id` (Feature 002).
- **available**: a message with `DirtyBit=0`, **or** `DirtyBit=1` and `now − ReadDateTime ≥ timeout`.
- **fencing token**: the `ReadAttempts` value returned by acquire at lease grant.

---

## `msgfmt_dequeue` — acquire (lease) the front available message

- **Write / callability**: WRITE. Call via `FCALL`; rejected under `FCALL_RO`.
- **KEYS** (exactly 2):
  - `KEYS[1]` = priority-queue **Sorted Set** (e.g. `pq:{q1}`).
  - `KEYS[2]` = message-key **prefix** (e.g. `pq:{q1}:m:`) — MUST carry the same hash tag as
    `KEYS[1]`. The message Hash for a given `id` is `KEYS[2] .. id`.
- **ARGV**:
  - `ARGV[1]` = `now` — non-negative integer, `0 … 2^53` (epoch ms).
  - `ARGV[2]` = `timeout` — positive integer, `1 … 2^53` (visibility timeout, ms).
  - `ARGV[3]` = `max_scan` *(optional)* — non-negative integer; `0` or absent = unbounded. When
    positive, inspect at most this many front members before giving up.
- **Behaviour** (fail-before-write; no message mutation unless a message is selected):
  1. Require exactly two keys (`EKEYS`).
  2. Validate `now` (`ENOW`), `timeout` (`ETMO`), and `max_scan` if present (`ESCAN`).
  3. Require `KEYS[1]` and `KEYS[2]` to share one hash tag (`ETAG`).
  4. If `KEYS[1]` exists and is not a `zset` → `EMALFORMED`. If it is absent/empty → return null.
  5. Walk members ascending via `ZRANGE KEYS[1] 0 -1` (bounded by `max_scan`). For each member:
     derive `id` (text after the first `:`); `mkey = KEYS[2] .. id`.
     - `mkey` absent → **dangling**: `ZREM KEYS[1] member`; continue.
     - `mkey` not a hash, or missing `DirtyBit`/`ReadDateTime`/`ReadAttempts` → `EMALFORMED`.
     - available (per definition) → **select** it and stop; otherwise continue.
  6. On selection: `newRA = HINCRBY mkey ReadAttempts 1`; `HSET mkey DirtyBit 1 ReadDateTime <now>`;
     read `Priority` and `Payload`.
  7. No selection within scan → return null.
- **Returns**: on a hit, a flat array:

  ```
  [ 'id', <id>, 'member', <member>, 'ReadAttempts', <newRA>,
    'ReadDateTime', <now>, 'Priority', <int>, 'Payload', <bytes> ]
  ```

  `newRA` is the **fencing token**. On no available message, `false` (RESP **null**) — distinct
  from a hit whose `Payload` is `""`.
- **Commands used**: `EXISTS`, `TYPE`, `ZRANGE`, `HMGET`, `HINCRBY`, `HSET`, `ZREM`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
  | `MSGFMT ENOW: now must be a non-negative integer` | `ARGV[1]` missing / non-integer / `<0` / `>2^53` |
  | `MSGFMT ETMO: timeout must be a positive integer` | `ARGV[2]` missing / non-integer / `<1` / `>2^53` |
  | `MSGFMT ESCAN: max_scan must be a non-negative integer` | `ARGV[3]` present but invalid |
  | `MSGFMT ETAG: queue and message-key prefix must share one hash tag` | tags differ / either lacks a tag |
  | `MSGFMT EMALFORMED: queue is not a sorted set` | `KEYS[1]` exists, type ≠ `zset` |
  | `MSGFMT EMALFORMED: message <mkey> is not a hash` | an inspected candidate exists, type ≠ `hash` |
  | `MSGFMT EMALFORMED: message <mkey> missing field <F>` | an inspected candidate hash is missing a lease field |

```
# empty / all-in-flight queue
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000        -> (nil)

# hit (message id=42 at the front, first delivery)
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","42","member","00000000000000000007:42","ReadAttempts",1,
      "ReadDateTime",1000,"Priority",5,"Payload","order-42"]
```

---

## `msgfmt_ack` — acknowledge (delete) a processed message

- **Write / callability**: WRITE.
- **KEYS** (exactly 2):
  - `KEYS[1]` = priority-queue **Sorted Set**.
  - `KEYS[2]` = message **Hash** (`= <prefix><id>`, known to the client from the handle).
- **ARGV**:
  - `ARGV[1]` = `member` — the full queue member from the handle (for `ZREM`).
  - `ARGV[2]` = `token` — the fencing token (the `ReadAttempts` from acquire).
- **Behaviour** (fail-before-write):
  1. Require exactly two keys (`EKEYS`); non-empty `member` and integer `token` (`EARGS`).
  2. `KEYS[2]` absent → `NOOP` (idempotent; already settled).
  3. `KEYS[2]` not a hash, or missing `DirtyBit`/`ReadAttempts` → `EMALFORMED`.
  4. `DirtyBit ≠ 1` → `ENOTLEASED`.
  5. `ReadAttempts ≠ token` → `EFENCED`.
  6. `ZREM KEYS[1] member`; `DEL KEYS[2]`.
- **Returns**: `redis.status_reply("OK")` on success; `redis.status_reply("NOOP")` if already absent.
- **Commands used**: `EXISTS`, `TYPE`, `HMGET`, `ZREM`, `DEL`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
  | `MSGFMT EARGS: member and token required` | empty `member` or non-integer `token` |
  | `MSGFMT EMALFORMED: key is not a hash` | `KEYS[2]` exists, type ≠ `hash` |
  | `MSGFMT EMALFORMED: missing field <F>` | required lease field absent |
  | `MSGFMT ENOTLEASED: message not in-flight` | `DirtyBit = 0` |
  | `MSGFMT EFENCED: lease superseded` | `ReadAttempts ≠ token` |

```
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:42 00000000000000000007:42 1  -> OK
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:42 00000000000000000007:42 1  -> NOOP   (retry; already gone)
```

---

## `msgfmt_nack` — release a lease for redelivery

- **Write / callability**: WRITE.
- **KEYS** (exactly 1):
  - `KEYS[1]` = message **Hash** (`= <prefix><id>`). The queue member is not touched (it was never
    removed), so the queue key is not required.
- **ARGV**:
  - `ARGV[1]` = `token` — the fencing token.
- **Behaviour** (fail-before-write):
  1. Require exactly one key (`EKEYS`); integer `token` (`EARGS`).
  2. `KEYS[1]` absent → `NOOP` (idempotent).
  3. `KEYS[1]` not a hash, or missing `DirtyBit`/`ReadAttempts` → `EMALFORMED`.
  4. `DirtyBit ≠ 1` → `ENOTLEASED`.
  5. `ReadAttempts ≠ token` → `EFENCED`.
  6. `HSET KEYS[1] DirtyBit 0` (retain `ReadDateTime` and `ReadAttempts`).
- **Returns**: `redis.status_reply("OK")` on success; `redis.status_reply("NOOP")` if already absent.
- **Commands used**: `EXISTS`, `TYPE`, `HMGET`, `HSET`.
- **Errors**: same set as `msgfmt_ack` except `EKEYS` detail is `exactly one key required`.

```
FCALL msgfmt_nack 1 pq:{q1}:m:42 1   -> OK       (DirtyBit→0; ReadAttempts stays 1; available again)
FCALL msgfmt_nack 1 pq:{q1}:m:42 1   -> ENOTLEASED (already released)
```

---

## Cross-cutting guarantees

- **Determinism** (Principle VII): `now`, `timeout`, `max_scan`, `id`, `sequence`, `Priority` all
  come from the caller; no server clock or randomness. Effects replicate safely.
- **Cluster co-location** (Principle IV, amended): every key touched — `KEYS[1]`, `KEYS[2]`, and
  each constructed `KEYS[2] .. id` — shares one hash tag ⇒ one slot ⇒ no `CROSSSLOT`. Callers on a
  cluster MUST use one hash tag per logical queue for the queue key, the message-key prefix, and
  every message Hash. **Resharding caveat**: while a slot migrates, a call touching a
  runtime-constructed key may transiently return `TRYAGAIN`/`ASK`; clients should retry.
- **Atomicity** (Principle VI): each function is one `FCALL`; the lease spans acquire→settle only
  because the consumer's work is external. Correctness never depends on the client returning — an
  abandoned lease is reclaimed after `timeout`, and fencing protects the new holder.
- **Fail-before-write**: on any validation or precondition failure, neither the Sorted Set nor any
  Hash is modified. (Dangling-member `ZREM` during acquire's scan is safe cleanup performed only
  after all input validation has passed.)
- **Portability** (Principle III): only `EXISTS`, `TYPE`, `ZRANGE`, `HMGET`, `HINCRBY`, `HSET`,
  `ZREM`, `DEL` — all common to Redis 7.0+, Valkey 7.2+, ElastiCache, MemoryDB. Each call declares
  ≥1 key (ElastiCache requirement).
