# Phase 1 Contracts: Enqueue Function

This feature **extends the existing `message_format` library** (`src/functions/message_format.lua`)
with one new function, `msgfmt_enqueue`. The Feature 001 functions (`msgfmt_create`,
`msgfmt_read`, `msgfmt_validate`) are unchanged. Each contract states `KEYS[]`, `ARGV[]`,
return shape, flags, and write status (Principle VIII).

Conventions (inherited from Feature 001):
- All keys passed via `KEYS[]`; never computed internally (Principle IV).
- Field/value pairs use the same flat `name value name value ...` format as `msgfmt_create`.
- Errors via `redis.error_reply("MSGFMT <CODE>: <detail>")`; success via `redis.status_reply(...)`.
- Reused field validation surfaces the **identical** errors as `msgfmt_create`
  (`MSGFMT EARGS` / `EFIELD` / `EDUP` / `EINVAL`), because it calls the same routine.

---

## `msgfmt_enqueue` — create a message and enqueue it onto a priority queue

- **Write**: YES (no flags).
- **KEYS[1]**: the priority-queue **Sorted Set** key.
- **KEYS[2]**: the message **Hash** key. MUST be co-located with `KEYS[1]` in the same cluster
  slot via a shared hash tag (e.g. `pq:{q1}` and `pq:{q1}:m:42`).
- **ARGV[1]**: `id` — caller-supplied, unique, non-empty message identifier.
- **ARGV[2]**: `sequence` — caller-supplied, non-negative integer (`≥ 0`, `≤ 2^53`),
  monotonically increasing per queue; breaks priority ties (FIFO).
- **ARGV[3..]**: zero or more `field value` pairs (`ReadAttempts`, `DirtyBit`, `ReadDateTime`,
  `Priority`, `Payload`). Omitted fields take Feature 001 defaults; `Priority` default `1000`.
- **Behaviour** (fail-before-write — nothing is written unless every check passes):
  1. If `#KEYS ≠ 2` → `MSGFMT EKEYS: exactly two keys required`.
  2. If `id` is missing/empty → `MSGFMT EID: id must be a non-empty string`.
     If `sequence` is missing / not an integer / negative / `> 2^53` →
     `MSGFMT ESEQ: sequence must be a non-negative integer`.
  3. Build the message from `ARGV[3..]` via Feature 001's `build_message`: reject odd pair
     count (`MSGFMT EARGS`), unknown field (`MSGFMT EFIELD: <name>`), duplicate field
     (`MSGFMT EDUP: <name>`), or invalid value (`MSGFMT EINVAL: <field>`). Nothing stored.
  4. Preconditions:
     - If `EXISTS KEYS[2]` (message location occupied) →
       `MSGFMT EEXISTS: message location occupied`.
     - If `KEYS[1]` exists and `TYPE KEYS[1] ≠ zset` →
       `MSGFMT EMALFORMED: queue is not a sorted set`.
     - Compute `member = <zero-padded sequence> ":" <id>`. If `ZSCORE KEYS[1] member` is
       non-nil → `MSGFMT EQDUP: already enqueued`.
  5. Write, in one server-side call: `HSET KEYS[2]` all five encoded fields (from step 3),
     then `ZADD KEYS[1] <Priority> member`, where the score is the message's integer
     `Priority` (supplied or default).
  6. **Returns**: `redis.status_reply("OK")`.
- **Score / member**: score = the message's `Priority` (pure integer, never packed);
  member = fixed-width zero-padded `sequence` + `":"` + `id` (byte-lexicographic order = FIFO
  among equal priorities).
- **Contract examples**:
  - `FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:42 42 1 Payload "order-42" Priority 5`
    → stores the message at `pq:{q1}:m:42` (Priority=5, other fields default) and adds member
    `00000000000000000001:42` scored `5` to `pq:{q1}`; returns `OK`.
  - Re-running the same call → `MSGFMT EEXISTS: message location occupied` (nothing changed).
  - `FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 -1` → `MSGFMT ESEQ: ...` (negative sequence).
  - `FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 2 Priority foo` → `MSGFMT EINVAL: Priority`
    (nothing written to either structure).
  - `FCALL msgfmt_enqueue 1 pq:{q1}` → `MSGFMT EKEYS: exactly two keys required`.

---

## Error / status catalogue for `msgfmt_enqueue`

| Reply | Kind | Trigger |
|-------|------|---------|
| `OK` | status | message stored and enqueued |
| `MSGFMT EKEYS: exactly two keys required` | error | `#KEYS ≠ 2` |
| `MSGFMT EID: id must be a non-empty string` | error | `ARGV[1]` missing/empty |
| `MSGFMT ESEQ: sequence must be a non-negative integer` | error | `ARGV[2]` missing / non-integer / `< 0` / `> 2^53` |
| `MSGFMT EARGS: arguments must be name/value pairs` | error | odd number of field/value args (reused) |
| `MSGFMT EFIELD: <name>` | error | unknown field name (reused) |
| `MSGFMT EDUP: <name>` | error | duplicate field name (reused) |
| `MSGFMT EINVAL: <field>` | error | invalid field value (reused) |
| `MSGFMT EEXISTS: message location occupied` | error | `KEYS[2]` already exists |
| `MSGFMT EMALFORMED: queue is not a sorted set` | error | `KEYS[1]` exists with wrong type |
| `MSGFMT EQDUP: already enqueued` | error | member already present in `KEYS[1]` |

(`EARGS`/`EFIELD`/`EDUP`/`EINVAL` are byte-identical to `msgfmt_create`; new codes are
`EKEYS` — reused concept, two-key variant — plus `EID`, `ESEQ`, `EEXISTS`, `EQDUP`, and the
`EMALFORMED` wrong-type reply reused from `msgfmt_read`.)

---

## Cross-cutting contract guarantees

- Completes in a single `FCALL` (Principle VI, FR-001/FR-014).
- Touches only `KEYS[1]` and `KEYS[2]`; computes no key names; both keys must be same-slot
  (Principle IV, FR-007).
- Uses only `HSET`, `EXISTS`, `TYPE`, `ZSCORE`, `ZADD` — all on the common-supported list for
  all four targets (Principle III); the static gate whitelist is extended accordingly.
- Deterministic: score and member derive solely from `ARGV` (`id`, `sequence`, `Priority`); no
  server-side time/counter/random (Principle VII, FR-015).
- No admin/privileged commands (Principle V).
- Structured `MSGFMT E...` error replies; no uncaught Lua errors on validated paths; on any
  rejection nothing is written to either structure (Principle VIII, FR-012/FR-013).
