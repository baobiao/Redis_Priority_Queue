# Function Contracts: DLQ Retention & Observability

Feature 006 adds the message field **`DeadLetteredAt`** (epoch ms; default `0` = not dead-lettered) and
two functions — **`msgfmt_reap`** (WRITE) and **`msgfmt_stats`** (NO-WRITES). This document specifies
the **deltas** to the existing library; everything not mentioned is unchanged from Features 001–005.
Conventions (keys via `KEYS[]`; `MSGFMT <CODE>: <detail>` errors; RESP null vs empty; the sanctioned
`<prefix>id` construction for a runtime-discovered message key) are inherited.

---

## Schema delta — the `DeadLetteredAt` field

- Added to `FIELDS` (appended last), `FIELD_SET`, `DEFAULTS` (`DeadLetteredAt = '0'`), and the
  `encode_field` integer branch (validated `0 … 2^53`, stored `%.0f`). `build_message`/`parse_args`
  need no change → `msgfmt_create`/`msgfmt_enqueue`/`msgfmt_validate` accept it as a normal field.
- A missing `DeadLetteredAt` (a message stored before Feature 006) reads as `0`.

---

## `msgfmt_dequeue` — dead-letter stamp delta (WRITE)

`KEYS`/`ARGV` unchanged. The only change is in the **dead-letter branch**: when a candidate at/over the
cap is moved to the DLQ, in addition to `ZREM` (source) + `ZADD` (DLQ) it now sets the timestamp:

```
HSET <mkey> DeadLetteredAt <now>
```

The move is otherwise still index-preserving (verbatim member, DLQ `score = Priority`) and does not
re-lease or change other fields. Everything else about `msgfmt_dequeue` is unchanged.

---

## `msgfmt_redrive` — reset delta (WRITE)

`KEYS`/`ARGV` unchanged. The reset `HSET` gains `DeadLetteredAt 0`:

```
HSET KEYS[3] ReadAttempts 0 DirtyBit 0 VisibleAt 0 DeadLetteredAt 0
```

so a redriven message is no longer considered dead-lettered.

---

## `msgfmt_read` / `msgfmt_peek` — surface `DeadLetteredAt` (NO-WRITES)

Both add `DeadLetteredAt` to their `HMGET` and their returned record, coalescing a missing value to `0`
(the five original fields remain strictly required in `read`). `msgfmt_read`'s return grows to:

```
["ReadAttempts",<int>, "DirtyBit",<0|1>, "ReadDateTime",<int>, "Priority",<int>,
 "Payload",<bytes>, "VisibleAt",<int>, "DeadLetteredAt",<int>]
```

`msgfmt_peek` records gain a trailing `"DeadLetteredAt", <int>` pair. No behavioural change otherwise.

---

## `msgfmt_reap` — NEW (WRITE)

Permanently remove dead-lettered messages older than a retention window, bounded per call.

**KEYS**
- `KEYS[1]` = dead-letter **Sorted Set** (e.g. `dlq:{q1}`).
- `KEYS[2]` = message-key **prefix** (e.g. `pq:{q1}:m:`) — same hash tag as `KEYS[1]`. The message Hash
  for a member's `id` is `KEYS[2] .. id`.

**ARGV**
- `ARGV[1]` = `now` — non-negative integer epoch ms.
- `ARGV[2]` = `retention` — non-negative integer window (ms).
- `ARGV[3]` = `limit` — positive integer; the maximum number of DLQ front members to examine this call.

**Behaviour** (bounded, fail-before-write on validation):
1. `#KEYS == 2` else `EKEYS`. Validate `now` (`ENOW`), `retention` (`ERET`), `limit` (`ELIMIT`).
   Co-location `hash_tag(KEYS[1]) == hash_tag(KEYS[2])` else `ETAG`.
2. `KEYS[1]` absent → return `{removed 0, scanned 0, truncated 0}`. `KEYS[1]` not a `zset` → `EMALFORMED`.
3. Fetch the front up to `limit`: `ZRANGE KEYS[1] 0 limit-1`. For each member: derive `id`,
   `mkey = KEYS[2] .. id`:
   - Hash **missing** (dangling) → `ZREM KEYS[1] member`; count as removed.
   - Hash present: read `DeadLetteredAt`; if `DeadLetteredAt ≤ now − retention` (expired) →
     `ZREM KEYS[1] member` + `DEL mkey`; count as removed. Otherwise leave it.
4. Return the tally. `truncated = 1` when the DLQ still holds more members than were examined
   (`ZCARD > limit`), signalling the caller to loop / raise `limit`.

**Returns**: a flat map `["removed", <int>, "scanned", <int>, "truncated", <0|1>]`.

**Commands used**: `EXISTS`, `TYPE`, `ZRANGE`, `HGET` (or `HMGET`), `ZREM`, `DEL`, `ZCARD`.

**Errors**:

| Reply | Trigger |
|-------|---------|
| `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
| `MSGFMT ENOW: now must be a non-negative integer` | `ARGV[1]` invalid |
| `MSGFMT ERET: retention must be a non-negative integer` | `ARGV[2]` missing / non-integer / `<0` / `>2^53` |
| `MSGFMT ELIMIT: limit must be a positive integer` | `ARGV[3]` missing / non-integer / `<1` / `>2^53` |
| `MSGFMT ETAG: dead-letter queue and message-key prefix must share one hash tag` | tags differ / missing |
| `MSGFMT EMALFORMED: dead-letter queue is not a sorted set` | `KEYS[1]` exists, type ≠ `zset` |

```
FCALL msgfmt_reap 2 dlq:{q1} pq:{q1}:m: 100000 30000 500
  -> ["removed",7,"scanned",500,"truncated",1]   (removed 7 expired/dangling; DLQ still has >500)
FCALL msgfmt_reap 2 dlq:{q1} pq:{q1}:m: 100000 30000 500
  -> ["removed",0,"scanned",12,"truncated",0]     (12 remain, none expired; DLQ fully examined)
```

Note (Priority-order caveat): reap examines the front `limit` members **in Priority order**. To
guarantee draining all expired entries, size `limit` to the DLQ depth (from `msgfmt_stats`) or page.

---

## `msgfmt_stats` — NEW (NO-WRITES; `FCALL_RO`-callable)

Report aggregate queue state without consuming; cheap always, with an optional bounded breakdown.

**KEYS**
- `KEYS[1]` = source queue **Sorted Set**.
- `KEYS[2]` = message-key **prefix** (same hash tag) — used only when a breakdown scan is requested.
- `KEYS[3]` = dead-letter **Sorted Set** *(optional)* — same hash tag; enables `dlq_depth` and the
  approximate oldest-dead-letter age.

**ARGV**
- `ARGV[1]` = `now` — non-negative integer epoch ms (for age + in-flight/visible classification).
- `ARGV[2]` = `timeout` — positive integer (to classify an in-flight lease as expired vs unexpired).
- `ARGV[3]` = `max_scan` *(optional)* — non-negative integer; `0`/absent = cheap tier only.

**Behaviour** (no writes):
1. `#KEYS ∈ {2,3}` else `EKEYS`. Validate `now` (`ENOW`), `timeout` (`ETMO`), `max_scan` if present
   (`ESCAN`). Co-location across the given keys else `ETAG`. A non-`zset` `KEYS[1]`/`KEYS[3]` → `EMALFORMED`.
2. **Cheap tier (always)**: `depth = ZCARD KEYS[1]`; `dlq_depth = ZCARD KEYS[3]` (or `0`/absent when no
   DLQ key); `front_priority` = score from `ZRANGE KEYS[1] 0 0 WITHSCORES` (or an empty indicator when
   the queue is empty).
3. **Bounded tier (`max_scan > 0`)**: scan `ZRANGE KEYS[1] 0 max_scan-1`; for each member read its
   Hash and classify via `lease_available`/`is_visible` as exactly one of `available` /
   `in_flight` / `delayed`; a dangling/malformed member is skipped and counted as `skipped` (never
   removed). Set `truncated = 1` when `depth > max_scan`. When a DLQ key is present, also scan up to
   `max_scan` DLQ front members for the minimum `DeadLetteredAt` and report
   `oldest_dead_letter_age = now − thatMin` (with a flag that it is over the scanned prefix only).

**Returns**: a flat map. Cheap keys always present; breakdown keys present only when `max_scan > 0`:

```
["depth", <int>, "dlq_depth", <int>, "front_priority", <int|(-1 when empty)>,
 -- when max_scan > 0:
 "scanned", <int>, "truncated", <0|1>,
 "available", <int>, "in_flight", <int>, "delayed", <int>, "skipped", <int>,
 -- when max_scan > 0 and a DLQ key is given:
 "dlq_scanned", <int>, "oldest_dead_letter_age", <int>, "age_truncated", <0|1>]
```

**Commands used**: `ZCARD`, `ZRANGE`, `TYPE`, `EXISTS`, `HMGET`. **No writes** (registered `no-writes`).

**Errors**:

| Reply | Trigger |
|-------|---------|
| `MSGFMT EKEYS: two or three keys required` | `#KEYS` ∉ {2,3} |
| `MSGFMT ENOW: now must be a non-negative integer` | `ARGV[1]` invalid |
| `MSGFMT ETMO: timeout must be a positive integer` | `ARGV[2]` invalid |
| `MSGFMT ESCAN: max_scan must be a non-negative integer` | `ARGV[3]` present but invalid |
| `MSGFMT ETAG: keys must share one hash tag` | tags differ / missing |
| `MSGFMT EMALFORMED: queue is not a sorted set` | `KEYS[1]` exists, type ≠ `zset` |
| `MSGFMT EMALFORMED: dead-letter queue is not a sorted set` | `KEYS[3]` exists, type ≠ `zset` |

```
FCALL_RO msgfmt_stats 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000
  -> ["depth",42,"dlq_depth",3,"front_priority",5]                 (cheap tier)
FCALL_RO msgfmt_stats 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 100
  -> ["depth",42,"dlq_depth",3,"front_priority",5,"scanned",42,"truncated",0,
      "available",30,"in_flight",8,"delayed",4,"skipped",0,
      "dlq_scanned",3,"oldest_dead_letter_age",900,"age_truncated",0]
```

---

## Cross-cutting guarantees

- **Determinism (Principle VII)**: `now`, `retention`, `timeout`, `limit`, `max_scan` are all from
  `ARGV`; no server clock/random. `msgfmt_stats` is `no-writes` and `FCALL_RO`-callable; `msgfmt_reap`
  is a WRITE. Both bounded by a caller-supplied limit (Principle VI single round trip + VII bounded).
- **Portability (Principle III)**: no new command — only the existing `ZCARD`/`ZRANGE`/`HMGET`/`HGET`/
  `ZREM`/`DEL`. No static-gate change.
- **Cluster safety (Principle IV)**: every key in a call shares one hash tag → one slot.
- **Back-compat**: default `DeadLetteredAt = 0` and the missing→0 coalesce keep every Feature 001–005
  message and call behaving as before.
