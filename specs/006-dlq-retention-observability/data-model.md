# Phase 1 Data Model: DLQ Retention & Observability

One new message field, two new functions, no new persistent structure. Reused entities are unchanged
from Features 001–005.

## Entities

### Message (reused, extended) — a Hash

Gains a **seventh** field. The six existing fields are unchanged.

| Field | Logical type | Default | Encoding | Validation | New? |
|-------|--------------|---------|----------|------------|------|
| `ReadAttempts` | integer ≥ 0 | `0` | `%.0f` | `0 … 2^53` | |
| `DirtyBit` | boolean | `false` | `"0"`/`"1"` | token set | |
| `ReadDateTime` | integer ≥ 0 (epoch ms) | `0` | `%.0f` | `0 … 2^53` | |
| `Priority` | integer | `1000` | `%.0f` | `-2^53 … 2^53` | |
| `Payload` | string | `""` | raw | any | |
| `VisibleAt` | integer ≥ 0 (epoch ms) | `0` | `%.0f` | `0 … 2^53` | |
| **`DeadLetteredAt`** | integer ≥ 0 (epoch ms) | **`0`** | `%.0f` | `0 … 2^53` | **✅ Feature 006** |

`DeadLetteredAt = 0` means "not dead-lettered / never". It validates and encodes exactly like
`ReadDateTime`/`VisibleAt` (joins that `encode_field` branch). Canonical field order becomes
`ReadAttempts, DirtyBit, ReadDateTime, Priority, Payload, VisibleAt, DeadLetteredAt` (appended last so
the stored/read order of the earlier fields is preserved).

**Back-compat**: a message stored before this feature has no `DeadLetteredAt`; readers coalesce a
missing value to `0` and never error. The six earlier fields remain as before (`msgfmt_read` keeps its
strict requirement on the five original fields; `VisibleAt` and `DeadLetteredAt` both tolerate
absence → `0`).

### Dead-Letter Queue (reused, unchanged shape)

A Priority-scored Sorted Set sharing the source's hash tag (`dlq:{q1}`), verbatim members. Feature 006
adds two lifecycle operations over it without changing its score or member format:
- **stamp**: on dead-letter, the message's `DeadLetteredAt` is set (the DLQ index is unchanged).
- **reap**: expired members are removed (member + Hash).

### Retention window — a caller-supplied argument

An age threshold in ms. A message is expired when `DeadLetteredAt ≤ now − retention`. Not persisted;
supplied per `msgfmt_reap` call along with `now` and a per-call `limit`.

### Queue statistics — a read-only snapshot (not persisted)

Produced by `msgfmt_stats`: depths (cardinalities), front `Priority`, and an optional bounded state
breakdown (available / in-flight / not-yet-visible counts + `truncated`) + an approximate
oldest-dead-letter age.

## Co-location (all entities)

Every key a call touches shares one hash tag → one slot:

```
pq:{q1}          # source queue Sorted Set
pq:{q1}:m:<id>   # message Hash  (prefix pq:{q1}:m:)
dlq:{q1}         # dead-letter queue Sorted Set (same tag)
```

- `msgfmt_reap`: DLQ Sorted Set + message-key prefix (constructs `<prefix>id` for members it scans).
- `msgfmt_stats`: source queue Sorted Set + message-key prefix (+ optional DLQ Sorted Set).

## Lifecycle transitions added by Feature 006

```
                      dequeue (ReadAttempts ≥ cap, deliverable)
   AVAILABLE ───────────────────────────────────────────────▶ DEAD-LETTERED
   (source)                                                    (in DLQ; Hash.DeadLetteredAt = now)  ── [006 stamp]
        ▲                                                          │        │
        │ redrive (reset RA/DirtyBit/VisibleAt/DeadLetteredAt=0)   │        │ reap (now − DeadLetteredAt ≥ retention) [006]
        └──────────────────────────────────────────────────────────┘        ▼
                                                                        REMOVED (ZREM member + DEL Hash — gone)
```

- **[006 stamp]** dead-lettering now records `DeadLetteredAt = now` (the only change to the Feature 004
  move; it remains index-only otherwise).
- **reap [006]** `DEAD-LETTERED → REMOVED` when the entry's age exceeds the retention window; removes
  both the DLQ member and the message Hash. Bounded per call.
- **redrive** (Feature 004, extended) now also clears `DeadLetteredAt` on the way back to `AVAILABLE`.
- **stats [006]** observes any state without causing a transition (read-only; never removes danglers).
