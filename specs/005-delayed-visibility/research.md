# Phase 0 Research: Delayed Visibility

Feature 005 adds a caller-supplied not-before time (`VisibleAt`) so a message can be scheduled for
future delivery or released with a retry-backoff delay. Decisions below were grounded by parallel
sub-agents against the current post-004 code, live Redis/Valkey Function semantics, and constitution
v2.0.0 + the static gate.

## Decision 1 — Design A: `VisibleAt` field + skip-in-scan (not a scheduled ZSET)

**Decision**: Store the not-before time as a sixth message-Hash field `VisibleAt` (epoch ms, default
`0`). `msgfmt_dequeue`/`msgfmt_peek` skip a message while `now < VisibleAt`, in the same front scan
that already skips leased messages. No separate "scheduled" Sorted Set.

**Rationale**: Reuses the existing single-ZSET + Hash model and the exact skip mechanism the lease
already uses (`lease_available`). Needs no new key and no new command. Enqueue/create need no
signature change — `VisibleAt` flows through `build_message` as a normal field. Retry backoff (the
primary use) and modest scheduling are served directly.

**Alternatives rejected**: (B) a sibling `sched:{q}` Sorted Set scored by not-before with a promotion
step — scales better for very large volumes of long-delayed messages, but adds a promotion mechanism,
a fourth key on the dequeue path, and `ZRANGE BYSCORE`. More divergence for a benefit this queue does
not yet need. Deferred as a possible later variant.

**Accepted cost**: a not-yet-visible message at the front of the priority ZSET is scanned over on
every dequeue until it becomes visible — O(K), bounded by `max_scan`, identical to the treatment of
leased messages today.

## Decision 2 — Absolute `VisibleAt` epoch, not a relative delay

**Decision**: The caller supplies an **absolute** epoch-ms timestamp. Visibility is decided by
`msgfmt_dequeue`/`msgfmt_peek` comparing their existing `now` against the stored `VisibleAt`.

**Rationale**: Keeps `msgfmt_enqueue`/`msgfmt_create`/`msgfmt_nack` free of a `now` argument (only
the read/scan path, which already has `now`, needs it). Deterministic and replication-safe — the same
pattern `lease_available` already uses for `(now − ReadDateTime) ≥ timeout`. Callers compute backoff
(`now + delay`) client-side.

**Alternatives rejected**: a relative `delay` (SQS `DelaySeconds`-style) — more ergonomic but would
require passing `now` to enqueue/nack to compute `VisibleAt = now + delay` at set-time, enlarging
those signatures for no functional gain.

## Decision 3 — Settable at enqueue (scheduled) and at nack (retry backoff)

**Decision**: `VisibleAt` can be set (a) at enqueue/create, as a normal field value (scheduled
delivery), and (b) at nack, via a new **optional** trailing argument (retry backoff). A standalone
"defer an existing message" function is out of scope.

**Rationale**: These are the two core use cases and both reuse the single `VisibleAt` field + the
eligibility gate. Enqueue support is free (field path); nack support is one optional ARGV plus one
extra `HSET` field.

**Alternatives rejected**: nack-only (drops scheduled delivery) or enqueue-only (drops backoff) —
each omits a core use case. A dedicated `msgfmt_defer` — deferred; not needed for the two use cases.

## Decision 4 — Missing `VisibleAt` treated as `0` (immediately visible)

**Decision**: `msgfmt_read`, `msgfmt_dequeue`, and `msgfmt_peek` treat an absent `VisibleAt` field as
`0`. `msgfmt_read`'s strict "all fields present else `EMALFORMED`" check is relaxed **for `VisibleAt`
only**; the five original fields stay required.

**Rationale / grounding**: `msgfmt_read` currently loops `for idx = 1, 5` and returns
`EMALFORMED: missing field <F>` if any of the five is absent (HMGET → `false`). A message written by
Features 001–004 has no `VisibleAt`, so without this coalesce every such message would fail to read
and would be undeliverable. Coalescing `false → 0` makes the sixth field fully backward-compatible
with no data migration.

**Alternatives rejected**: requiring all messages to carry `VisibleAt` (breaks existing data); a
schema-version field + migration (heavyweight for a still-in-development library).

## Decision 5 — Redrive resets `VisibleAt` to 0

**Decision**: `msgfmt_redrive` adds `VisibleAt = 0` to its existing reset (`ReadAttempts = 0`,
`DirtyBit = 0`), so a redriven message is immediately deliverable.

**Rationale**: Redrive means "make this message processable again now". A preserved future
`VisibleAt` would make the redriven message invisible — surprising and rarely intended. Resetting is
consistent with redrive already resetting the other delivery-state fields.

**Alternatives rejected**: preserve `VisibleAt` — only useful for a niche redrive-with-delay, and
achievable later via a separate mechanism if ever needed.

## Decision 6 — Shared `is_visible` helper; eligibility = lease-available AND visible

**Decision**: Add a file-local predicate `is_visible(visibleat, now)` returning
`(tonumber(visibleat) or 0) <= now`. `msgfmt_dequeue` and `msgfmt_peek` single mode select the first
member for which `lease_available(...)` **and** `is_visible(...)` are both true.

**Rationale**: Mirrors the shared `lease_available` helper so dequeue and single-mode peek agree
exactly on what is deliverable (the same reason Feature 004 extracted `lease_available`). The
`or 0` coalesces a missing/nil `VisibleAt` to immediately-visible.

## Decision 7 — Dead-letter and ordering composition (no extra logic)

**Decision**: The Feature 004 dead-letter cap check already runs **after** the availability gate
(`if <eligible> then if ReadAttempts ≥ cap then …`). Adding the `is_visible` clause to that gate
means a not-yet-visible over-cap message is simply skipped — not dead-lettered — until it is visible.
`VisibleAt` is never part of any Sorted Set score, so priority/FIFO ordering among visible messages
is unchanged.

**Rationale**: The eligibility gate is the single point that governs both leasing and dead-lettering,
so the correct composition falls out for free.

## Decision 8 — No new command; no constitution change; no static-gate change

**Decision**: Ship on constitution **v2.0.0** with no amendment, and the static gate unchanged.

**Rationale / grounding**: (a) The not-before gate reads `VisibleAt` via the existing `HMGET`/`HGET`,
compares it to the caller's `now` in Lua, and sets it via `HSET` — all already whitelisted; no new
command. (b) No principle closes the message schema at five fields; adding `VisibleAt` is a
documented contract change (Principle VIII) requiring only the mandatory docs update (Principle X) —
not an amendment. (c) The determinism scan fires only on `redis.call('TIME')` / `math.random`; a
`now`-vs-`VisibleAt` comparison uses neither. (d) The gate scans the whole library file, so the
edited functions are covered automatically. `EVIS` (new nack error) is a reply string, not a command,
so it needs no gate change.

## Cross-cutting note — pre-existing platform caveat

Amazon ElastiCache **Serverless** does not offer the `FUNCTION`/`FCALL`/`FCALL_RO` family; the
library targets self-hosted Redis/Valkey, node-based ElastiCache (7.x), and MemoryDB (7.x). This is a
property of the whole library, unchanged by Feature 005.
