# Function Contracts: Delayed Visibility

Feature 005 adds the message field **`VisibleAt`** (epoch ms; default `0` = immediately visible) and
a not-before eligibility gate. This document specifies only the **deltas** to the existing library;
everything not mentioned is unchanged from Features 001–004. Conventions (keys via `KEYS[]`;
`MSGFMT <CODE>: <detail>` errors; RESP null vs empty payload) are inherited.

**Eligibility rule (new):** a message is deliverable iff
`lease_available(DirtyBit, ReadDateTime, now, timeout)` **and** `is_visible(VisibleAt, now)`, where
`is_visible(v, now)  ≡  (tonumber(v) or 0) <= now`. A missing/`nil` `VisibleAt` is treated as `0`.

---

## Schema delta — the `VisibleAt` field

- Added to `FIELDS` (appended last), `FIELD_SET`, and `DEFAULTS` (`VisibleAt = '0'`).
- `encode_field` validates it in the existing integer branch: `tonumber`, `is_int`, `0 … 2^53`,
  stored `string.format('%.0f', n)` — identical to `ReadAttempts`/`ReadDateTime`. An invalid value
  yields the bare `EINVAL: VisibleAt` (→ client sees `MSGFMT EINVAL: VisibleAt`).
- `build_message` / `parse_args` require no change (data-driven off `FIELDS`/`DEFAULTS`).

Consequently **`msgfmt_create` and `msgfmt_enqueue` gain `VisibleAt` for free** — supply it as a
normal `field value` pair; no `KEYS`/`ARGV`-shape change. `msgfmt_validate` likewise accepts it.

```
FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 9 Priority 5 Payload "later" VisibleAt 60000
  -> OK   (message 9 is not deliverable until now >= 60000)
FCALL msgfmt_create 1 q:{m1} VisibleAt -1     -> MSGFMT EINVAL: VisibleAt
```

---

## `msgfmt_dequeue` — eligibility delta (WRITE)

`KEYS`/`ARGV` **unchanged** (Feature 004: `KEYS[1]`=queue, `KEYS[2]`=prefix, optional `KEYS[3]`=DLQ;
`ARGV` `now`, `timeout`, `max_scan?`, `cap?`).

- The scan `HMGET` gains `VisibleAt` (coalesce `false → 0`).
- **Selection**: a candidate is chosen only when `lease_available(...)` **and**
  `is_visible(VisibleAt, now)`. A not-yet-visible message is skipped and the scan continues (it
  counts against `max_scan`), exactly like an unexpired lease.
- **Dead-letter composition**: the cap check is unchanged and still runs *after* the eligibility gate,
  so a not-yet-visible over-cap message is **not** dead-lettered until it becomes visible.
- Return shape unchanged (the handle does not add `VisibleAt`).

```
# message 9 has VisibleAt=60000
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 59999 30000   -> (nil)   (not yet visible; skipped)
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 60000 30000   -> ["id","9", ...]   (now visible)
```

---

## `msgfmt_read` — return-shape delta (NO-WRITES)

`KEYS`/`ARGV` unchanged. The `HMGET` gains `VisibleAt`; the strict "missing field → `EMALFORMED`"
check still covers the **five original** fields, but a **missing `VisibleAt` coalesces to `0`** (no
error — back-compat with pre-005 messages). The returned flat array gains a sixth pair:

```
["ReadAttempts", <int>, "DirtyBit", <0|1>, "ReadDateTime", <int>,
 "Priority", <int>, "Payload", <bytes>, "VisibleAt", <int>]
```

```
FCALL_RO msgfmt_read 1 pq:{q1}:m:9   -> [... ,"VisibleAt",60000]
FCALL_RO msgfmt_read 1 pq:{old}      -> [... ,"VisibleAt",0]   (message stored before Feature 005)
```

---

## `msgfmt_nack` — optional not-before delta (WRITE)

- `KEYS[1]` = message Hash (unchanged).
- `ARGV[1]` = `token` (unchanged). **`ARGV[2]` = `VisibleAt` (optional)** — a non-negative integer
  epoch ms.
- **Behaviour**: fencing/`NOOP`/`ENOTLEASED` unchanged. On success:
  - `ARGV[2]` absent → `HSET DirtyBit 0` (exactly Feature 003; `VisibleAt` untouched).
  - `ARGV[2]` present and valid → `HSET DirtyBit 0 VisibleAt <value>` (retry backoff), retaining
    `ReadDateTime`/`ReadAttempts`.
  - `ARGV[2]` present but invalid → `MSGFMT EVIS: visibleAt must be a non-negative integer`
    (fail-before-write; nothing changes).

```
FCALL msgfmt_nack 1 pq:{q1}:m:9 2                 -> OK    (released, immediately available; F003)
FCALL msgfmt_nack 1 pq:{q1}:m:9 2 90000           -> OK    (released; hidden until now >= 90000)
FCALL msgfmt_nack 1 pq:{q1}:m:9 2 -5              -> MSGFMT EVIS: visibleAt must be a non-negative integer
```

New error:

| Reply | Trigger |
|-------|---------|
| `MSGFMT EVIS: visibleAt must be a non-negative integer` | `ARGV[2]` present and non-integer / `< 0` / `> 2^53` |

---

## `msgfmt_peek` — record + single-mode delta (NO-WRITES)

`KEYS`/`ARGV` unchanged. The `HMGET` gains `VisibleAt` (coalesce `false → 0`).

- **Single mode** now returns the front message that is `lease_available` **and** `is_visible` — i.e.
  exactly what `msgfmt_dequeue` would lease for the same `now`; not-yet-visible messages are skipped.
- **Top-N mode** still reports the front members regardless of state (including not-yet-visible ones).
- Each **record gains `VisibleAt`**:

```
["id", <id>, "member", <member>, "DirtyBit", <0|1>, "ReadAttempts", <int>,
 "ReadDateTime", <int>, "Priority", <int>, "Payload", <bytes>, "VisibleAt", <int>]
```

```
FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 59999 30000      -> (nil)   (single: nothing visible yet)
FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 59999 30000 10   -> [[... ,"VisibleAt",60000]]   (top-N shows it)
```

---

## `msgfmt_redrive` — reset delta (WRITE)

`KEYS`/`ARGV` unchanged. The reset `HSET` gains `VisibleAt 0`:

```
HSET KEYS[3] ReadAttempts 0 DirtyBit 0 VisibleAt 0
```

so a redriven message is immediately deliverable. Everything else (guards, `NOOP`/`EQDUP`, move) is
unchanged.

---

## Cross-cutting guarantees

- **Determinism (Principle VII)**: `VisibleAt` and `now` are caller-supplied; no server clock/random.
  The determinism static scan is unaffected.
- **Portability (Principle III)**: no new command — only the existing `HSET`/`HMGET`/`HGET` plus Lua
  arithmetic. No static-gate change.
- **Cluster safety (Principle IV)**: no `KEYS[]` change and no new key; unchanged from Features 002–004.
- **Backward compatibility**: default `VisibleAt = 0` and the missing→0 coalesce make every Feature
  001–004 message and call behave exactly as before.
