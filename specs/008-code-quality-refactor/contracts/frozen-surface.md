# Frozen Public Surface (Contract) — Feature 008

For a behaviour-preserving refactor, the "contract" is the surface that MUST NOT change. This is the
authority for what the refactor may not touch; full prose is in `docs/functions.md` (unchanged). Any
deviation from the values below is a defect and MUST be caught by the frozen suites.

## Registration & flags (frozen)

- Library: `#!lua name=priority_queue`, loaded via `FUNCTION LOAD REPLACE`.
- Exactly **11** registered functions (below). `FUNCTION LIST` output (names, flags) is unchanged.
- **`no-writes`** (callable via `FCALL_RO`; write attempt under `FCALL_RO` MUST be rejected):
  `pq_read`, `pq_validate`, `pq_peek`, `pq_stats`.
- **Writes** (rejected under `FCALL_RO`): `pq_create`, `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`,
  `pq_redrive`, `pq_reap`.

## Function contracts (frozen KEYS / ARGV / return)

| Function | Write? | KEYS | ARGV (key args) | Return (shape) |
|---|---|---|---|---|
| `pq_create` | write | `1`: msg Hash | `[field value]…` | `OK` / `PQ E…` |
| `pq_read` | no-writes | `1`: msg Hash | — | 7-field array (typed) / `NOTFOUND` / `PQ EMALFORMED` |
| `pq_validate` | no-writes | `1`: msg Hash (or none) | `[field value]…` | `VALID` / `PQ EFIELD` |
| `pq_enqueue` | write | `1`: queue ZSET, `2`: msg Hash | `id`, `sequence`, `[field value]…` | `OK` / `PQ E…` |
| `pq_dequeue` | write | `1`: queue ZSET, `2`: msg-key prefix, [`3`: DLQ ZSET] | `now`, `timeout`, [`max_scan`, `cap`] | handle array / `(nil)` / `PQ E…` |
| `pq_ack` | write | `1`: queue ZSET, `2`: msg Hash | `member`, `token` | `OK` / `NOOP` / `PQ E…` |
| `pq_nack` | write | `1`: msg Hash | `token`, [`VisibleAt`] | `OK` / `NOOP` / `PQ E…` |
| `pq_peek` | no-writes | `1`: queue ZSET, `2`: msg-key prefix | `now`, `timeout`, [`count`] | handle / top-N array / `(nil)` / `PQ E…` |
| `pq_redrive` | write | `1`: DLQ ZSET, `2`: source ZSET, `3`: msg Hash | `member` | `OK` / `NOOP` / `PQ E…` |
| `pq_reap` | write | `1`: DLQ ZSET, `2`: msg-key prefix | `now`, `retention`, `limit` | `["removed",n,"scanned",n,"truncated",0|1]` / `PQ E…` |
| `pq_stats` | no-writes | `1`: queue ZSET, `2`: msg-key prefix, [`3`: DLQ ZSET] | `now`, `timeout`, [`max_scan`] | aggregates array / `PQ E…` |

Numeric fields return as RESP integers (Jedis `Long`, redis-py `int`); status replies are the literal
strings `OK` / `VALID` / `NOOP` / `NOTFOUND`.

## Error convention (frozen)

Every error is `PQ <CODE>: <detail>` — the leading token, the **code**, and the **detail text** are all
frozen. The library emits **21 distinct codes** (verified against `priority_queue.lua`): `EARGS`, `ECAP`,
`ECOUNT`, `EDUP`, `EEXISTS`, `EFENCED`, `EFIELD`, `EID`, `EINVAL`, `EKEYS`, `ELIMIT`, `EMALFORMED`,
`ENOTLEASED`, `ENOW`, `EQDUP`, `ERET`, `ESCAN`, `ESEQ`, `ETAG`, `ETMO`, `EVIS`. Note: `NOTFOUND` is a
**status reply** (`redis.status_reply('NOTFOUND')`), **not** a `PQ E…` error — there is no `ENOTFOUND`,
`EWRONGTYPE`, or `EARGV` code (wrong-type cases use `EMALFORMED`). A "readability" edit to any code or
detail string is a **contract change** and is out of scope.

## Sanctioned key construction (frozen; Principle IV)

`pq_dequeue` / `pq_peek` reach a runtime-discovered message by appending its `id` to the caller-supplied,
hash-tagged prefix `KEYS[n]` (e.g. `KEYS[2] .. id`). This construction, and the hash-tag co-location of
all keys, is preserved exactly — optimisations must not alter how keys are formed.

## What the refactor MAY change (for contrast)

Private helpers (`is_int`, `hash_tag`, `lease_available`, `is_visible`, `encode_field`, `parse_args`,
`build_message`) and any other **non-registered** internal structure — names, extraction, ordering,
local variable bindings (including localised globals), comments, and whitespace — are all refactorable,
provided the frozen surface above is byte-for-byte preserved.
