# Contract: priority_queue library (renamed from message_format)

**Behaviour is identical to Feature 006** (`specs/006-dlq-retention-observability/contracts/functions.md`).
This contract records ONLY what the rename changes: the library name, the function names, and the
error-reply prefix. KEYS/ARGV, return shapes, decisions, and `no-writes` flags are unchanged and are the
source of truth in the Feature 006 contract + `docs/functions.md`.

## Library

- **File**: `src/functions/priority_queue.lua`
- **Shebang / registered library name**: `#!lua name=priority_queue`
- **Load**: `FUNCTION LOAD [REPLACE]` with the exact file bytes (identical across `redis-cli -x`,
  Jedis `functionLoadReplace(String)`, redis-py `function_load(code, replace=True)`). All three return
  the library name `priority_queue`.

## Functions (11)

| Function | Writes? | Callable via | KEYS / ARGV / returns |
|---|---|---|---|
| `pq_create` | write | `FCALL` | == Feature 006 `msgfmt_create` |
| `pq_read` | no-writes | `FCALL` / `FCALL_RO` | == `msgfmt_read` (7-field flat array) |
| `pq_validate` | no-writes | `FCALL` / `FCALL_RO` | == `msgfmt_validate` (`VALID` / `PQ EFIELD…`) |
| `pq_enqueue` | write | `FCALL` | == `msgfmt_enqueue` |
| `pq_dequeue` | write | `FCALL` | == `msgfmt_dequeue` |
| `pq_ack` | write | `FCALL` | == `msgfmt_ack` |
| `pq_nack` | write | `FCALL` | == `msgfmt_nack` |
| `pq_peek` | no-writes | `FCALL` / `FCALL_RO` | == `msgfmt_peek` |
| `pq_redrive` | write | `FCALL` | == `msgfmt_redrive` |
| `pq_reap` | write | `FCALL` | == `msgfmt_reap` |
| `pq_stats` | no-writes | `FCALL` / `FCALL_RO` | == `msgfmt_stats` |

- Invoking any **write** function via `FCALL_RO` MUST be rejected by the engine with the standard
  message `... Can not execute a script with write flag using *_ro command` (asserted in all three
  suites).

## Error replies

- **Convention (changed)**: `redis.error_reply("PQ <CODE>: <detail>")`. Only the leading token changed
  from `MSGFMT` to `PQ`.
- **Codes (unchanged)**: the same set and meaning as Feature 006 — e.g. `EFIELD` (unknown/invalid field),
  `EMALFORMED` (wrong-type / corrupt hash), `ENOTFOUND`, `EWRONGTYPE`, `EARGS`, plus any others already
  emitted by the library. Detail text is unchanged.
- **Success/status replies (unchanged)**: `OK`, `NOOP`, `VALID`, `NOTFOUND` (simple strings); numeric
  fields returned as RESP integers; payload/id/member as bulk strings; multi-field results as flat
  arrays (RESP map-style), never RESP3 map types.

## Client-observable equivalence (parity contract)

For identical KEYS/ARGV, every client MUST observe identical results apart from the renamed tokens:

| Aspect | redis-cli (Bash) | Jedis (Java) | redis-py (Python) |
|---|---|---|---|
| status reply | `OK`/`VALID`/`NOOP`/`NOTFOUND` | `String` | `str` (`decode_responses=True`) |
| numeric field | text (e.g. `0`) | `Long` (e.g. `0L`) | `int` (e.g. `0`) |
| bulk field | text | `String` | `str` |
| array reply | flat lines | `List<Object>` | `list` |
| error reply | stderr `PQ E…` | `JedisDataException`, message contains `PQ E…` | `ResponseError`, `str(e)` contains `PQ E…` |
| FCALL_RO on write fn | error text | `JedisDataException` | `ResponseError` |

**Parity trap**: numeric fields are RESP integers — Java/Python assertions MUST compare typed values
(`Long`/`int`), NOT the Bash string form (`"0"`).
