# Function Contracts: Dead-Letter Handling and Peek

Contracts for the functions added or extended by Feature 004, in the `message_format` library.
Conventions are inherited from Features 001–003: keys via `KEYS[]`; a message Hash reached from a
declared, hash-tagged prefix as `<prefix>id` (the sanctioned same-slot construction) **only** where
the id is not knowable in advance; failures as `redis.error_reply('MSGFMT <CODE>: <detail>')`;
"nothing" as a RESP null (`false`) distinct from an empty-string `Payload`. The member format
(`string.format('%020.0f', sequence) .. ':' .. id`) and `score = Priority` are unchanged.

`hash_tag(key)` returns the substring between the first `{` and the next `}` (nil if absent/empty).
The co-location guard requires every key in a call to share one non-nil tag.

---

## `msgfmt_dequeue` — EXTENDED (WRITE)

Backward-compatible extension of the Feature 003 function. Two call shapes:

- **Feature 003 (unchanged)** — 2 keys, no dead-lettering.
- **Dead-letter mode [004]** — 3 keys + a cap.

**KEYS**
- `KEYS[1]` = source priority-queue **Sorted Set** (e.g. `pq:{q1}`).
- `KEYS[2]` = message-key **prefix** (e.g. `pq:{q1}:m:`), same hash tag as `KEYS[1]`.
- `KEYS[3]` *(optional)* = dead-letter **Sorted Set** (e.g. `dlq:{q1}`), same hash tag. Presence of
  `KEYS[3]` selects dead-letter mode.

**ARGV**
- `ARGV[1]` = `now` — non-negative integer epoch ms.
- `ARGV[2]` = `timeout` — positive integer visibility timeout (ms).
- `ARGV[3]` *(optional)* = `max_scan` — non-negative integer; `0`/absent = unbounded. (To supply the
  cap, pass `max_scan` explicitly — `0` for unbounded — because arguments are positional.)
- `ARGV[4]` *(required in dead-letter mode)* = `cap` — positive integer maximum-delivery count.

**Behaviour** (fail-before-write):
1. `#KEYS == 2` → **exactly Feature 003** (no DLQ, cap not consulted). `#KEYS == 3` → dead-letter
   mode. Any other count → `EKEYS`.
2. Validate `now` (`ENOW`), `timeout` (`ETMO`), `max_scan` if present (`ESCAN`). In dead-letter mode
   validate `cap` present and a positive integer (`ECAP`).
3. Co-location: `hash_tag(KEYS[1]) == hash_tag(KEYS[2])`, and in dead-letter mode also `== hash_tag(KEYS[3])`; else `ETAG`.
4. `KEYS[1]` absent → null. `KEYS[1]` not a `zset` → `EMALFORMED`. In dead-letter mode, if `KEYS[3]`
   exists and is not a `zset` → `EMALFORMED`.
5. Walk the front (`ZRANGE KEYS[1] 0 stop`, `stop` from `max_scan`). For each member: derive `id`,
   read the Hash `<prefix>id`; a dangling member is `ZREM`'d and skipped; a malformed candidate →
   `EMALFORMED`. Determine availability (`DirtyBit=0`, or `DirtyBit=1` with `now − ReadDateTime ≥ timeout`).
   - **Not available** (unexpired lease) → skip (never dead-lettered even if over cap).
   - **Available and, in dead-letter mode, `ReadAttempts ≥ cap`** → **dead-letter**: `ZREM KEYS[1] member`
     then `ZADD KEYS[3] <Priority> member` (score = the message's `Priority`, member verbatim; the Hash
     is not touched); continue scanning.
   - **Available and below cap (or Feature 003 mode)** → lease it: `HINCRBY ReadAttempts 1`,
     `HSET DirtyBit 1 ReadDateTime now`, and return the handle.
6. No deliverable message within the scan → null.

**Returns**: **identical to Feature 003** — on a hit the flat handle array
`['id', <id>, 'member', <member>, 'ReadAttempts', <token>, 'ReadDateTime', <now>, 'Priority', <int>, 'Payload', <bytes>]`;
otherwise a null reply. Dead-lettering is **silent** (no count/list on the reply).

**Commands used**: `EXISTS`, `TYPE`, `ZRANGE`, `HMGET`, `HINCRBY`, `HSET`, `ZREM`, `ZADD`.

**Errors** (adds to the Feature 003 set):

| Reply | Trigger |
|-------|---------|
| `MSGFMT EKEYS: two or three keys required` | `#KEYS` ∉ {2,3} |
| `MSGFMT ECAP: cap must be a positive integer` | dead-letter mode and `ARGV[4]` missing / non-integer / `< 1` / `> 2^53` |
| `MSGFMT ETAG: keys must share one hash tag` | `KEYS[3]` tag differs (or the existing 2-key mismatch) |
| `MSGFMT EMALFORMED: dead-letter queue is not a sorted set` | `KEYS[3]` exists, type ≠ `zset` |
| *(plus all Feature 003 dequeue errors: `ENOW`, `ETMO`, `ESCAN`, `ETAG`, `EMALFORMED …`)* | as before |

```
# Feature 003 call — unchanged
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","7","member","00000000000000000007:7","ReadAttempts",1,"ReadDateTime",1000,"Priority",5,"Payload","..."]

# Dead-letter mode: cap=5, DLQ supplied. A front message with ReadAttempts>=5 is moved to dlq:{q1};
# the next deliverable message is returned (or nil).
FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 0 5
  -> ["id","8", ... ,"Payload","..."]   (poison id=7 moved to DLQ silently)
```

---

## `msgfmt_peek` — NEW (NO-WRITES, `FCALL_RO`-callable)

Inspect a queue (source **or** DLQ) without leasing or mutating anything.

**KEYS**
- `KEYS[1]` = queue **Sorted Set** to inspect (a source queue or a DLQ).
- `KEYS[2]` = message-key **prefix**, same hash tag as `KEYS[1]`.

**ARGV**
- `ARGV[1]` = `now` — non-negative integer epoch ms (used by single mode for lease-awareness).
- `ARGV[2]` = `timeout` — positive integer (ms).
- `ARGV[3]` *(optional)* = `count` — positive integer. Absent or `1` → **single mode**; `N` → **top-N mode**.

**Behaviour** (no writes; fail-before-read-only-return):
1. `#KEYS == 2` else `EKEYS`. Validate `now` (`ENOW`), `timeout` (`ETMO`), `count` if present
   (`ECOUNT`). Co-location `hash_tag(KEYS[1]) == hash_tag(KEYS[2])` else `ETAG`.
2. `KEYS[1]` absent → single: null; top-N: empty array. `KEYS[1]` not a `zset` → `EMALFORMED`.
3. **Single mode**: walk the front; skip dangling members (do **not** `ZREM`); return the first
   **available** message (lease-aware, same rule as dequeue) as a record array, without mutation;
   null if none. A malformed Hash that would be the selected candidate → `EMALFORMED`.
4. **Top-N mode**: return up to `count` front members **regardless of lease state**, in
   priority-then-FIFO order, each as a record array; dangling/malformed members are **skipped**
   (best-effort observability); empty array if none.

**Returns**:
- Single mode: one **record array** on a hit, or null. A record is
  `['id', <id>, 'member', <member>, 'DirtyBit', <0|1>, 'ReadAttempts', <int>, 'ReadDateTime', <int>, 'Priority', <int>, 'Payload', <bytes>]`
  (current values — no fencing token, nothing incremented).
- Top-N mode: an **array of record arrays** (length `0 … count`).

**Commands used**: `EXISTS`, `TYPE`, `ZRANGE`, `HMGET`. **No writes** (registered `no-writes`).

**Errors**:

| Reply | Trigger |
|-------|---------|
| `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
| `MSGFMT ENOW: now must be a non-negative integer` | `ARGV[1]` invalid |
| `MSGFMT ETMO: timeout must be a positive integer` | `ARGV[2]` invalid |
| `MSGFMT ECOUNT: count must be a positive integer` | `ARGV[3]` present but invalid |
| `MSGFMT ETAG: queue and message-key prefix must share one hash tag` | tags differ / missing |
| `MSGFMT EMALFORMED: queue is not a sorted set` | `KEYS[1]` exists, type ≠ `zset` |
| `MSGFMT EMALFORMED: message <mkey> …` | single mode, the selected candidate's Hash is missing a lease field / not a hash |

```
FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","5","member","00000000000000000005:5","DirtyBit",0,"ReadAttempts",0,"ReadDateTime",0,"Priority",5,"Payload","..."]
FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 1000 30000 3
  -> [[...record...],[...record...],[...record...]]     (up to 3, priority-then-FIFO)
FCALL_RO msgfmt_peek 2 dlq:{q1} pq:{q1}:m: 1000 30000 10   (inspect the DLQ)
```

---

## `msgfmt_redrive` — NEW (WRITE)

Move one message from a DLQ back to its source and reset its delivery state.

**KEYS** (all passed **literally** — the caller knows the id, so no construction):
- `KEYS[1]` = dead-letter **Sorted Set** (source of the move).
- `KEYS[2]` = source priority-queue **Sorted Set** (destination).
- `KEYS[3]` = the message **Hash** (e.g. `pq:{q1}:m:7`).
- All three share one hash tag.

**ARGV**
- `ARGV[1]` = `member` — the exact DLQ member string to move (as seen in a DLQ peek).

**Behaviour** (fail-before-write; all guards before any write):
1. `#KEYS == 3` else `EKEYS`. `member` non-empty else `EARGS`. Co-location across all three keys
   else `ETAG`.
2. `ZSCORE KEYS[1] member` nil → member not in the DLQ → **`NOOP`** (idempotent; nothing changes).
3. `ZSCORE KEYS[2] member` non-nil → already in the source → **`EQDUP`** (no duplicate created).
4. `KEYS[3]` absent → `EMALFORMED` (dangling DLQ member). `KEYS[3]` not a hash, or missing `Priority`
   → `EMALFORMED`.
5. Write (one atomic call): `ZREM KEYS[1] member`; `ZADD KEYS[2] <Priority> member` (score read from
   the Hash); `HSET KEYS[3] ReadAttempts 0 DirtyBit 0` (**`ReadDateTime` retained**). Return `OK`.

**Returns**: `redis.status_reply('OK')` on a move; `redis.status_reply('NOOP')` when the member was
not in the DLQ.

**Commands used**: `ZSCORE`, `EXISTS`, `TYPE`, `HGET` (or `HMGET`), `ZREM`, `ZADD`, `HSET`.

**Errors**:

| Reply | Trigger |
|-------|---------|
| `MSGFMT EKEYS: exactly three keys required` | `#KEYS ≠ 3` |
| `MSGFMT EARGS: member required` | `ARGV[1]` missing/empty |
| `MSGFMT ETAG: keys must share one hash tag` | tags differ / missing |
| `MSGFMT EQDUP: already present in source queue` | `member` already in `KEYS[2]` |
| `MSGFMT EMALFORMED: message hash missing` | `KEYS[3]` absent (dangling DLQ member) |
| `MSGFMT EMALFORMED: key is not a hash` | `KEYS[3]` type ≠ hash |
| `MSGFMT EMALFORMED: missing field Priority` | `KEYS[3]` lacks `Priority` |

```
FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:7 00000000000000000007:7
  -> OK      (member leaves dlq:{q1}, re-added to pq:{q1} at its Priority;
              hash pq:{q1}:m:7 -> ReadAttempts=0, DirtyBit=0, ReadDateTime kept)
FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:7 00000000000000000007:7
  -> NOOP    (already redriven; no longer in the DLQ)
```

---

## Cross-cutting guarantees

- **Determinism (Principle VII)**: `now`, `timeout`, `max_scan`, `cap`, `count` are all from `ARGV`;
  no server clock or randomness. `msgfmt_peek` is `no-writes` and `FCALL_RO`-callable and issues only
  reads. `msgfmt_dequeue` and `msgfmt_redrive` are WRITEs.
- **Atomicity (Principle VI)**: each function is one `FCALL`; the dead-letter move (`ZREM`+`ZADD`)
  and the redrive move (`ZREM`+`ZADD`+`HSET`) are all-or-nothing within the call.
- **Cluster safety (Principle IV, v2.0.0)**: every key in a call shares one hash tag → one slot.
  Dequeue/peek construct `<prefix>id` for a message discovered at runtime (sanctioned); redrive takes
  the message Hash literally (id known → no construction).
- **Portability (Principle III)**: only already-common, already-whitelisted commands; no new gate
  entries. (Whole-library platform caveat: ElastiCache Serverless lacks the `FUNCTION` family.)
