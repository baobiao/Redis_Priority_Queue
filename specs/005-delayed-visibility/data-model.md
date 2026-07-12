# Phase 1 Data Model: Delayed Visibility

One new message field and one new eligibility rule. No new structures, no new keys, no score change.

## Entities

### Message (reused, extended) — a Hash

The message Hash gains a **sixth** field. The five existing fields are unchanged.

| Field | Logical type | Default | Stored encoding | Validation | New? |
|-------|--------------|---------|-----------------|------------|------|
| `ReadAttempts` | integer ≥ 0 | `0` | `%.0f` decimal string | `0 … 2^53` | |
| `DirtyBit` | boolean | `false` | `"0"` / `"1"` | token set | |
| `ReadDateTime` | integer ≥ 0 (epoch ms) | `0` | `%.0f` | `0 … 2^53` | |
| `Priority` | integer | `1000` | `%.0f` | `-2^53 … 2^53` | |
| `Payload` | string | `""` | raw | any | |
| **`VisibleAt`** | integer ≥ 0 (epoch ms) | **`0`** | `%.0f` | `0 … 2^53` | **✅ Feature 005** |

`VisibleAt = 0` (the default) means "immediately visible". `VisibleAt` validates and encodes exactly
like `ReadDateTime` (it joins that `encode_field` branch).

**Canonical field order** becomes `ReadAttempts, DirtyBit, ReadDateTime, Priority, Payload, VisibleAt`
(`VisibleAt` appended last so the existing HSET/read order for the first five is preserved).

**Backward compatibility**: a message stored by Features 001–004 has no `VisibleAt` field. Readers
(`msgfmt_read`, `msgfmt_dequeue`, `msgfmt_peek`) coalesce a missing `VisibleAt` (`HMGET` → `false`)
to `0` — immediately visible — and never raise `EMALFORMED` for its absence. The five original fields
remain strictly required.

### Not-before time (`VisibleAt`) — the eligibility gate

`VisibleAt` is the not-before boundary. It is stored **only in the Hash**; it is never part of a
Sorted Set score, so it does not affect ordering. It is distinct from the Feature 003 lease
"visibility timeout" (which governs reclaim of an in-flight message).

### Source Queue / Dead-Letter Queue (reused, unchanged)

Priority Sorted Sets scored by `Priority`, member `%020d:id`. Unchanged: `VisibleAt` does not touch
scores or members.

## Eligibility rule (the one behavioural change)

A message is **deliverable** iff:

```
lease_available(DirtyBit, ReadDateTime, now, timeout)   AND   now >= VisibleAt
```

where the second clause is the new `is_visible(VisibleAt, now)` predicate (a missing/`nil`
`VisibleAt` coalesces to `0`, i.e. visible). Applied identically in `msgfmt_dequeue` (to lease) and
`msgfmt_peek` single mode (to report the next deliverable).

## Where `VisibleAt` is written

| Function | Effect on `VisibleAt` |
|----------|-----------------------|
| `msgfmt_create` / `msgfmt_enqueue` | Set from the supplied field value (default `0`). **No signature change** — it is a normal field pair through `build_message`. |
| `msgfmt_nack` | **Optional** trailing argument: if supplied (validated, else `EVIS`), set alongside `DirtyBit=0` (retry backoff); if omitted, `VisibleAt` is left unchanged (Feature 003 behaviour). |
| `msgfmt_redrive` | Reset to `0` (immediately visible), with `ReadAttempts=0` / `DirtyBit=0`. |
| `msgfmt_dequeue` (lease) | Not modified when leasing — only read for the gate. |

## Message lifecycle (transition added by Feature 005)

`VisibleAt` adds a *pre-availability* gate; it does not add a new stored state, it delays the
`AVAILABLE → deliverable` transition:

```
enqueue(VisibleAt=T) ─▶ AVAILABLE-but-HIDDEN ──(now ≥ T)──▶ DELIVERABLE ──(dequeue)──▶ IN-FLIGHT
                                 ▲                                                        │
                                 └──────────── nack(VisibleAt=T2), now < T2 ──────────────┘
                                               (released, hidden again until T2)
```

- `AVAILABLE-but-HIDDEN` is `DirtyBit=0` with `now < VisibleAt` — present in the queue, skipped by
  consumers.
- `DELIVERABLE` is `DirtyBit=0` (or expired lease) with `now ≥ VisibleAt`.
- Dead-letter and redrive compose unchanged: the cap check runs only once a message is
  `DELIVERABLE`; redrive returns a message to `DELIVERABLE` (`VisibleAt=0`).
