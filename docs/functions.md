# `message_format` — Function Reference

Developer reference for every function in `src/functions/message_format.lua`.
The library loads with `FUNCTION LOAD` under the name **`message_format`** and runs
unmodified on Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB.

A *message* is a single Hash with five fields. Keys are supplied via `KEYS[]`; the one
sanctioned exception is `msgfmt_dequeue`, which appends the runtime message `id` to a
caller-supplied, co-located key prefix (`KEYS[2] .. id`) to reach a message it selects at
runtime (constitution Principle IV, amended v2.0.0). Field/value pairs are supplied as a flat
`name value name value ...` `ARGV` list (any subset — omitted fields take defaults).

**Fields** (logical type / default / stored encoding):

| Field | Logical type | Default | Validation bound | Stored as |
|-------|--------------|---------|------------------|-----------|
| `ReadAttempts` | integer ≥ 0 | `0` | integer, `0 … 2^53` | decimal string |
| `DirtyBit` | boolean | `false` | `1`/`true`/`0`/`false` (case-insensitive) | `"0"` or `"1"` |
| `ReadDateTime` | integer ≥ 0 (epoch ms) | `0` | integer, `0 … 2^53` | decimal string |
| `Priority` | integer (lower = higher priority) | `1000` | integer, `-2^53 … 2^53` | decimal string |
| `Payload` | string | `""` | none (any value accepted) | `tostring(value)` |

`2^53` is `MAX_SAFE_INT = 9007199254740992`, the exact-integer ceiling for Lua doubles.

## Error convention

Two layers produce error text, and the prefix is applied in exactly one place:

- **Registered (public) functions** return failures via
  `redis.error_reply("MSGFMT <CODE>: <detail>")` and successes via
  `redis.status_reply(...)`. Codes raised *directly* inside a public function
  (`EKEYS`, `EID`, `ESEQ`, `EEXISTS`, `EMALFORMED`, `EQDUP`, and the dequeue/settle codes
  `ENOW`, `ETMO`, `ESCAN`, `ETAG`, `ENOTLEASED`, `EFENCED`) are written with the full
  `MSGFMT ` prefix inline.
- **Local helper functions** never call `redis.error_reply`. On failure they return
  `(nil, "<CODE>: <detail>")` — a **bare** string with no `MSGFMT ` prefix. The calling
  public function prepends it: `redis.error_reply('MSGFMT ' .. err)`. This is how
  `EARGS`, `EFIELD`, `EDUP`, and `EINVAL` reach the client.

So an `EFIELD` seen by a client (`MSGFMT EFIELD: Color`) originated as the bare
`"EFIELD: Color"` inside `parse_args`, and `msgfmt_create` / `msgfmt_enqueue` /
`msgfmt_validate` added the `MSGFMT ` prefix.

---

## Public functions (FCALL-able)

### `msgfmt_ack` — acknowledge (delete) a processed message

- **Purpose**: on successful processing, remove a leased message entirely — its queue member
  and its stored Hash — in one atomic call.
- **Write / callability**: **WRITE** (registered with no flags). Call via `FCALL`; not
  callable via `FCALL_RO`.
- **Inputs**: `KEYS[1]` = priority-queue **Sorted Set**; `KEYS[2]` = message **Hash**
  (`<prefix><id>`, known from the acquire handle). `ARGV[1]` = `member` (the full queue member
  from the handle, for `ZREM`); `ARGV[2]` = `token` (the fencing token — the `ReadAttempts`
  value returned by `msgfmt_dequeue`).
- **Behaviour** (fail-before-write): if `KEYS[2]` is absent → idempotent `NOOP`; if it is not a
  hash or is missing lease fields → `EMALFORMED`; if `DirtyBit ≠ 1` → `ENOTLEASED`; if
  `ReadAttempts ≠ token` → `EFENCED`; otherwise `ZREM KEYS[1] member` then `DEL KEYS[2]`.
- **Returns**: `redis.status_reply("OK")`, or `redis.status_reply("NOOP")` when already settled.
- **Commands used**: `EXISTS`, `TYPE`, `HMGET`, `ZREM`, `DEL`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
  | `MSGFMT EARGS: member and token required` | empty `member` or non-integer `token` |
  | `MSGFMT EMALFORMED: key is not a hash` | `KEYS[2]` exists, type ≠ `hash` |
  | `MSGFMT EMALFORMED: missing lease field` | `DirtyBit`/`ReadAttempts` absent |
  | `MSGFMT ENOTLEASED: message not in-flight` | `DirtyBit = 0` |
  | `MSGFMT EFENCED: lease superseded` | `ReadAttempts ≠ token` |

```
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:2 00000000000000000002:2 1  -> OK
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:2 00000000000000000002:2 1  -> NOOP   (idempotent retry)
```

### `msgfmt_create` — create & store a message

- **Purpose**: validate an optional set of field values, apply defaults for the rest,
  and store all five fields as one Hash.
- **Write / callability**: **WRITE** (registered with no flags). Call via `FCALL`; not
  callable via `FCALL_RO`.
- **Inputs**: `KEYS[1]` = message Hash key. `ARGV` = zero or more `field value` pairs.
- **Behaviour**: validates via `build_message` (parse → encode → defaults), then
  `HSET KEYS[1] <all five encoded fields>` in a single call. Nothing is stored on any
  validation failure (fail-before-write).
- **Returns**: `redis.status_reply("OK")`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly one key required` | `#KEYS ≠ 1` |
  | `MSGFMT EARGS: arguments must be name/value pairs` | odd `ARGV` count (from `parse_args`) |
  | `MSGFMT EFIELD: <name>` | unrecognised field name |
  | `MSGFMT EDUP: <name>` | field name supplied twice |
  | `MSGFMT EINVAL: <field>` | value fails per-field validation |

```
FCALL msgfmt_create 1 pq:{m1}                          -> OK   (all defaults)
FCALL msgfmt_create 1 pq:{m1} Payload "hello" Priority 5 -> OK
FCALL msgfmt_create 1 pq:{m1} ReadAttempts -1          -> MSGFMT EINVAL: ReadAttempts
FCALL msgfmt_create 1 pq:{m1} Color red               -> MSGFMT EFIELD: Color
```

### `msgfmt_dequeue` — acquire (lease) the front available message

- **Purpose**: select the highest-priority message that is not currently being processed,
  mark it in-flight, and return it for a consumer to work on.
- **Write / callability**: **WRITE** (registered with no flags). Call via `FCALL`.
- **Inputs**:
  - `KEYS[1]` = priority-queue **Sorted Set** (e.g. `pq:{q1}`).
  - `KEYS[2]` = message-key **prefix** (e.g. `pq:{q1}:m:`) — MUST carry the same hash tag as
    `KEYS[1]`. The message Hash for a given `id` is `KEYS[2] .. id`.
  - `ARGV[1]` = `now` — non-negative integer epoch ms.
  - `ARGV[2]` = `timeout` — positive integer, the visibility timeout in ms.
  - `ARGV[3]` = `max_scan` *(optional)* — non-negative integer; `0`/absent = unbounded.
- **Behaviour** (fail-before-write): validate keys/args and the shared hash tag; if `KEYS[1]`
  is absent return null, if present but not a `zset` → `EMALFORMED`. Walk the front ascending
  (`ZRANGE`, lowest score first, ties by member = FIFO). For each member derive `id` and read
  `mkey = KEYS[2] .. id`: a **dangling** member (Hash absent) is `ZREM`'d and skipped; a
  malformed candidate → `EMALFORMED`. A message is **available** when `DirtyBit=0`, or
  `DirtyBit=1` with `now − ReadDateTime ≥ timeout` (an expired lease it reclaims). On the first
  available message: `HINCRBY ReadAttempts 1`, `HSET DirtyBit 1 ReadDateTime now`, and return.
- **Score / lease**: the returned `ReadAttempts` is the **fencing token** for the settle call.
- **Returns**: on a hit, a flat array (like `msgfmt_read`):

```
["id", <id>, "member", <member>, "ReadAttempts", <int token>,
 "ReadDateTime", <int now>, "Priority", <int>, "Payload", <bytes>]
```

  When nothing is available (empty or all in-flight, within `max_scan`) it returns a **null**
  reply — distinct from a hit whose `Payload` is an empty string.
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
  | `MSGFMT EMALFORMED: message <mkey> is not a hash` | an inspected candidate is not a hash |
  | `MSGFMT EMALFORMED: message <mkey> missing lease field` | a candidate lacks `DirtyBit`/`ReadDateTime`/`ReadAttempts` |

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","2","member","00000000000000000002:2","ReadAttempts",1,
      "ReadDateTime",1000,"Priority",5,"Payload","high"]
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000   (empty/all-in-flight) -> (nil)
```

### `msgfmt_enqueue` — create a message and index it onto a priority queue

- **Purpose**: atomically store a message Hash and add one member to a priority-queue
  Sorted Set, scored by the message's `Priority`.
- **Write / callability**: **WRITE** (registered with no flags). Call via `FCALL`.
- **Inputs**:
  - `KEYS[1]` = priority-queue **Sorted Set** key.
  - `KEYS[2]` = message **Hash** key. Must be co-located with `KEYS[1]` in the same
    cluster slot via a shared hash tag (e.g. `pq:{q1}` and `pq:{q1}:m:42`).
  - `ARGV[1]` = `id` — non-empty message identifier.
  - `ARGV[2]` = `sequence` — non-negative integer `0 … 2^53`; breaks priority ties (FIFO).
  - `ARGV[3..]` = optional `field value` pairs (same set/defaults as `msgfmt_create`).
- **Behaviour** (fail-before-write — nothing is written unless every check passes):
  1. Require exactly two keys.
  2. Reject empty/missing `id`; reject non-integer / negative / `> 2^53` `sequence`.
  3. Build the message from `ARGV[3..]` via `build_message` (same errors as create).
  4. Preconditions: `EXISTS KEYS[2]` must be false; if `KEYS[1]` exists it must be a
     `zset`; the computed member must not already be present.
  5. Write in one call: `HSET KEYS[2] <fields>` then `ZADD KEYS[1] <Priority> <member>`.
- **Score / member**: score = the message's integer `Priority` (from the encoded field
  list; never packed). `member = string.format('%020.0f', sequence) .. ':' .. id` — a
  20-digit zero-padded sequence, a colon, then the id. Fixed-width padding makes
  byte-lexicographic member order equal FIFO order among equal scores.
- **Returns**: `redis.status_reply("OK")`.
- **Commands used**: `EXISTS`, `TYPE`, `ZSCORE`, `HSET`, `ZADD`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly two keys required` | `#KEYS ≠ 2` |
  | `MSGFMT EID: id must be a non-empty string` | `ARGV[1]` missing or empty |
  | `MSGFMT ESEQ: sequence must be a non-negative integer` | `ARGV[2]` missing / non-integer / `< 0` / `> 2^53` |
  | `MSGFMT EARGS: arguments must be name/value pairs` | odd field/value count (reused) |
  | `MSGFMT EFIELD: <name>` | unknown field name (reused) |
  | `MSGFMT EDUP: <name>` | duplicate field name (reused) |
  | `MSGFMT EINVAL: <field>` | invalid field value (reused) |
  | `MSGFMT EEXISTS: message location occupied` | `KEYS[2]` already exists |
  | `MSGFMT EMALFORMED: queue is not a sorted set` | `KEYS[1]` exists with a non-`zset` type |
  | `MSGFMT EQDUP: already enqueued` | member already present in `KEYS[1]` |

```
FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:42 42 1 Payload "order-42" Priority 5
  -> OK   (stores Hash at pq:{q1}:m:42; adds member "00000000000000000001:42" scored 5)
re-run same call        -> MSGFMT EEXISTS: message location occupied
... pq:{q1}:m:9 9 -1     -> MSGFMT ESEQ: sequence must be a non-negative integer
... pq:{q1}:m:9 9 2 Priority foo -> MSGFMT EINVAL: Priority   (nothing written)
```

### `msgfmt_nack` — release a lease for redelivery

- **Purpose**: on failed processing, release a leased message so it becomes available again at
  its original position, preserving the record that it was read.
- **Write / callability**: **WRITE** (registered with no flags). Call via `FCALL`.
- **Inputs**: `KEYS[1]` = message **Hash** (`<prefix><id>`). `ARGV[1]` = `token` (the fencing
  token). The queue member is **not** touched (it was never removed), so no queue key is needed.
- **Behaviour** (fail-before-write): if `KEYS[1]` is absent → idempotent `NOOP`; if not a hash /
  missing lease fields → `EMALFORMED`; if `DirtyBit ≠ 1` → `ENOTLEASED`; if `ReadAttempts ≠
  token` → `EFENCED`; otherwise `HSET KEYS[1] DirtyBit 0` (retaining `ReadDateTime` and
  `ReadAttempts`).
- **Returns**: `redis.status_reply("OK")`, or `redis.status_reply("NOOP")` when already settled.
- **Commands used**: `EXISTS`, `TYPE`, `HMGET`, `HSET`.
- **Errors**:

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EKEYS: exactly one key required` | `#KEYS ≠ 1` |
  | `MSGFMT EARGS: token required` | non-integer `token` |
  | `MSGFMT EMALFORMED: key is not a hash` | `KEYS[1]` exists, type ≠ `hash` |
  | `MSGFMT EMALFORMED: missing lease field` | `DirtyBit`/`ReadAttempts` absent |
  | `MSGFMT ENOTLEASED: message not in-flight` | `DirtyBit = 0` |
  | `MSGFMT EFENCED: lease superseded` | `ReadAttempts ≠ token` |

```
FCALL msgfmt_nack 1 pq:{q1}:m:2 1   -> OK    (DirtyBit->0; available again; ReadAttempts kept)
FCALL msgfmt_nack 1 pq:{q1}:m:2 1   -> ENOTLEASED   (already released)
```

### `msgfmt_read` — read a message into a typed shape

- **Purpose**: fetch a stored message and decode its fields to logical types.
- **Write / callability**: **NO-WRITES** (registered with `flags = { 'no-writes' }`).
  Callable via `FCALL_RO` (and `FCALL`).
- **Inputs**: `KEYS[1]` = message Hash key. No `ARGV`.
- **Behaviour**: if the key is absent, return `NOTFOUND`; if it exists but is not a Hash
  or is missing any field, return `EMALFORMED`; otherwise `HMGET` all five fields and
  decode them.
- **Returns**: a flat, RESP map-style array of field/value pairs with decoded values:

```
["ReadAttempts", <int>,
 "DirtyBit",     <0|1>,
 "ReadDateTime", <int>,
 "Priority",     <int>,
 "Payload",      <string>]
```

  **Why `DirtyBit` is integer `0`/`1`, not a Lua boolean**: RESP2 has no boolean type,
  and a Lua `false` serializes to a null reply — indistinguishable from a missing field.
  Returning integer `0`/`1` is unambiguous on every protocol version.
- **Errors / non-value replies**:

  | Reply | Kind | Trigger |
  |-------|------|---------|
  | `NOTFOUND` | status | key does not exist |
  | `MSGFMT EKEYS: exactly one key required` | error | `#KEYS ≠ 1` |
  | `MSGFMT EMALFORMED: key is not a hash` | error | key exists but `TYPE ≠ hash` |
  | `MSGFMT EMALFORMED: missing field <Field>` | error | a required field is absent (`HMGET` returned `false`) |

```
FCALL_RO msgfmt_read 1 pq:{m1}   (after default create)
  -> ["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",0,"Priority",1000,"Payload",""]
FCALL_RO msgfmt_read 1 pq:{absent}  -> NOTFOUND
```

### `msgfmt_validate` — validate candidate field values without storing

- **Purpose**: run the exact create-time validation over supplied field values and report
  the outcome, storing nothing (dry-run / reusable validation routine).
- **Write / callability**: **NO-WRITES** (registered with `flags = { 'no-writes' }`).
  Callable via `FCALL_RO` (and `FCALL`).
- **Inputs**: **no `KEYS`** — any keys passed are ignored and no key is accessed. `ARGV` =
  `field value` pairs (same format as `msgfmt_create`).
- **Behaviour**: calls `build_message(ARGV)` and discards the result; only the error is
  inspected. No Redis command runs.
- **Returns**: `redis.status_reply("VALID")` when every supplied value validates and every
  field name is recognised.
- **Errors** (identical to `msgfmt_create`'s validation errors):

  | Reply | Trigger |
  |-------|---------|
  | `MSGFMT EARGS: arguments must be name/value pairs` | odd `ARGV` count |
  | `MSGFMT EFIELD: <name>` | unrecognised field name |
  | `MSGFMT EDUP: <name>` | duplicate field name |
  | `MSGFMT EINVAL: <field>` | value fails per-field validation |

---

## Local helper functions (internal)

These are file-local Lua functions (not registered, not client-callable). They return
Lua values, not `redis.error_reply` objects; on failure they yield `(nil, "<CODE>: <detail>")`
with no `MSGFMT ` prefix (the calling public function adds it).

### `build_message(args)` — encode a full field list with defaults

- **Purpose**: turn a flat `name value ...` list into the complete encoded HSET argument
  list, filling defaults for omitted fields. Shared by `msgfmt_create`, `msgfmt_enqueue`,
  and `msgfmt_validate`.
- **Parameters**: `args` — the flat `name value ...` list (`ARGV`, or `ARGV[3..]` for
  enqueue).
- **Behaviour**: calls `parse_args(args)`; for each of the five fields in canonical order,
  uses `encode_field` on the supplied value or falls back to `DEFAULTS[name]`; appends
  `name, stored` to the output.
- **Returns**:
  - success: a flat list `{ 'ReadAttempts', <enc>, 'DirtyBit', <enc>, 'ReadDateTime', <enc>,
    'Priority', <enc>, 'Payload', <enc> }` (ready to append after `HSET <key>`).
  - failure: `(nil, "<CODE>: detail>")` propagated unchanged from `parse_args` or
    `encode_field` — one of `EARGS`, `EFIELD`, `EDUP`, `EINVAL`.

### `encode_field(name, value)` — validate & encode one field

- **Purpose**: validate a single field's value and produce its stored string form.
- **Parameters**: `name` — field name; `value` — raw supplied value.
- **Behaviour**:
  - `ReadAttempts` / `ReadDateTime`: `tonumber`, require integer in `0 … 2^53`; store
    `string.format('%.0f', n)`.
  - `Priority`: `tonumber`, require integer in `-2^53 … 2^53`; store `string.format('%.0f', n)`.
  - `DirtyBit`: lowercased `tostring`; `"1"`/`"true"` → `"1"`, `"0"`/`"false"` → `"0"`.
  - `Payload`: `tostring(value)` (always valid).
- **Returns**:
  - success: `(encoded_string, nil)`.
  - failure: `(nil, "EINVAL: <field>")` for a bad numeric/`DirtyBit` value, or
    `(nil, "EFIELD: <name>")` for an unknown field name (defensive — unknown names are
    normally rejected earlier by `parse_args`).

### `is_int(n)` — finite integer-valued test

- **Purpose**: guard numeric validation against `nil`, `NaN`, `±inf`, and fractional values.
- **Parameters**: `n` — a number (or `nil`, e.g. from a failed `tonumber`).
- **Behaviour / returns**: returns the boolean
  `n ~= nil and n == n and n ~= math.huge and n ~= -math.huge and math.floor(n) == n` —
  i.e. `true` iff `n` is a non-nil, non-NaN, finite number equal to its own floor. No error
  string; pure predicate. Used by `encode_field` (numeric fields) and `msgfmt_enqueue`
  (`sequence`).

### `parse_args(args)` — parse the flat pair list into a map

- **Purpose**: convert the flat `name value name value ...` list into a `{name = value}`
  map while enforcing structural rules.
- **Parameters**: `args` — the flat pair list.
- **Behaviour**: rejects an odd element count; rejects any name not in the closed field set
  (`FIELD_SET`); rejects a name that appears more than once.
- **Returns**:
  - success: `(supplied_map, nil)` where `supplied_map[name] = value`.
  - failure: `(nil, "EARGS: arguments must be name/value pairs")` (odd count),
    `(nil, "EFIELD: <name>")` (unknown field), or `(nil, "EDUP: <name>")` (duplicate).
