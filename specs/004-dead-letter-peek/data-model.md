# Phase 1 Data Model: Dead-Letter Handling and Peek

No new persistent structures and no new message fields. Feature 004 adds one new **role** for an
existing structure (a Sorted Set used as a dead-letter queue) and new **transitions** over the
existing five-field message Hash. All reused entities are unchanged from Features 001–003.

## Entities

### Message (reused, Feature 001) — a Hash

The five fields, unchanged: `ReadAttempts` (int ≥ 0), `DirtyBit` (`"0"`/`"1"`), `ReadDateTime`
(int ≥ 0 epoch ms), `Priority` (int), `Payload` (string). Feature 004 touches only:

- **Dead-letter**: does **not** modify the Hash at all (index-only move).
- **Redrive**: sets `ReadAttempts = "0"` and `DirtyBit = "0"`; **retains** `ReadDateTime` and
  `Priority` and `Payload`.

The Hash key never changes and is never relocated.

### Source Queue (reused, Feature 002/003) — a Sorted Set

One logical queue: score = the message's `Priority` (lower = higher priority), member =
`%020.0f:id` (zero-padded insertion sequence, `:`, id). The dequeue origin and the redrive
destination. Members leave it on ack (removed), dead-letter (moved to DLQ), or stay on nack.

### Dead-Letter Queue (DLQ) — a Sorted Set (new role)

Structurally identical to a source queue, holding messages that reached the delivery cap:

| Aspect | Value |
|--------|-------|
| Type | Sorted Set |
| Key | shares the source's hash tag, e.g. `dlq:{q1}` for source `pq:{q1}` |
| Score | the message's `Priority` (same as the source) |
| Member | the **verbatim** source member string (`%020.0f:id`) |
| Message Hash | unchanged, still at `<prefix>id` (never moved) |

Because the shape matches a source queue, the DLQ is itself peek-able and dequeue-able with the
same functions. Redrive moves a member out of it back to the source.

### Delivery cap (max-receive) — a caller-supplied argument

An integer threshold passed on the dead-letter-enabled dequeue. A message whose `ReadAttempts`
has reached the cap is dead-lettered the next time it is *available*, instead of being delivered.
Not persisted anywhere; supplied per call.

## Co-location (all entities)

Every key a single call touches shares one hash tag → one cluster slot:

```
pq:{q1}          # source queue Sorted Set
pq:{q1}:m:<id>   # message Hash  (prefix pq:{q1}:m:)
dlq:{q1}         # dead-letter queue Sorted Set (same tag "q1")
```

## Message lifecycle (state transitions added by Feature 004)

States are expressed over `DirtyBit` + membership in the source/DLQ Sorted Sets. New transitions
are marked **[004]**.

```
                 enqueue
                    │
                    ▼
             ┌─────────────┐   dequeue (lease)    ┌────────────┐
             │  AVAILABLE  │────────────────────▶ │ IN-FLIGHT  │
             │ in source,  │                      │ in source, │
             │ DirtyBit=0  │ ◀──────────────────  │ DirtyBit=1 │
             └─────────────┘        nack           └────────────┘
                    │  ▲                              │      │
                    │  │ redrive [004]                │ ack  │ lease expires
   dequeue with cap │  │ (reset RA=0, DB=0,           │      │ (now-RDT ≥ timeout)
   & RA ≥ cap [004] │  │  retain RDT)                 ▼      ▼
   (available only) │  │                          ┌────────┐ back to AVAILABLE
                    ▼  │                           │ DONE   │ (reclaimable)
             ┌─────────────┐                       │ removed│
             │DEAD-LETTERED│                       └────────┘
             │ in DLQ,     │
             │ Hash intact │
             └─────────────┘
```

Rules enforced by the transitions:

- **AVAILABLE → DEAD-LETTERED [004]** happens only when a candidate is *available* (`DirtyBit=0`,
  or an expired lease) **and** `ReadAttempts ≥ cap`. An **unexpired** in-flight message is never
  dead-lettered, regardless of `ReadAttempts` (no arrow from IN-FLIGHT to DEAD-LETTERED).
- **DEAD-LETTERED → AVAILABLE [004]** is redrive: the member moves DLQ→source and the Hash is reset
  (`ReadAttempts=0`, `DirtyBit=0`, `ReadDateTime` retained), so the message re-enters at its
  `Priority` position below the cap.
- **Peek [004]** observes any of these states without causing a transition (no mutation).

## Peek is a pure read (no transition)

`msgfmt_peek` reads the source or DLQ and the message Hashes and returns a snapshot; it performs no
write and causes no state change. Dangling members (member present, Hash missing) are **skipped**,
never removed (only the write path removes danglers).
