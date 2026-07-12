# Phase 0 Research: DLQ Retention & Observability

Grounded by parallel sub-agents against the post-005 code, live Redis/Valkey Function semantics, and
constitution v2.0.0 + the static gate.

## Decision 1 — Retention mechanism A: `DeadLetteredAt` field + bounded `msgfmt_reap`

**Decision**: Record the dead-letter moment in a new seventh Hash field `DeadLetteredAt` (epoch ms,
default `0`), stamped by `msgfmt_dequeue`'s dead-letter branch. A new bounded WRITE `msgfmt_reap`
examines up to a caller-supplied `limit` of DLQ front members and permanently removes those with
`DeadLetteredAt ≤ now − retention` (`ZREM` the member + `DEL` the Hash), cleaning dangling members.

**Rationale**: Needs **no new command** (reap reuses the existing bounded `ZRANGE` front-read +
`ZREM`/`DEL`); keeps Feature 004's DLQ **Priority-scored** so the DLQ stays dequeue/peek-able exactly
as today; preserves the deterministic **caller-supplied-time** model; portable to all target engines.
Consistent with Feature 005's "add a field" pattern.

**Alternatives rejected**:
- **(B) Time-scored DLQ + range reap** (`ZRANGE BYSCORE`): cheaper, oldest-first, guaranteed-progress
  bounded reap, and a naturally time-ordered DLQ — but it **changes Feature 004's DLQ `score=Priority`**
  (DLQ dequeue/peek would become time-ordered), a behavioural change. Deferred.
- **(C) Native `PEXPIRE` TTL**: least code (auto-expiry, no reap) — but expiry is **server-clock-driven**
  (breaks the caller-time model, untestable via `now`, counters change spontaneously), needs `PEXPIRE`
  whitelisted, the determinism static-scan would **not** catch the server-clock coupling, and the TTL
  family is **unsupported on MemoryDB Multi-Region** (a portability regression). Rejected.

**Accepted limitation of A**: the DLQ is Priority-ordered, so a small fixed-`limit` reap examines the
front in Priority order and cannot reach expired low-priority entries behind unexpired high-priority
ones. Full draining requires the caller to size `limit` to the DLQ depth (from `msgfmt_stats`) or page.
This is why retention and observability ship together.

## Decision 2 — Dead-letter now stamps `DeadLetteredAt` (a small change to Feature 004's move)

**Decision**: `msgfmt_dequeue`'s dead-letter branch, which today is index-only (`ZREM` source + `ZADD`
dlq, Hash untouched), gains one write: `HSET mkey DeadLetteredAt <now>`. It still does not re-lease or
touch other fields.

**Rationale**: Retention needs a per-message dead-letter timestamp; the branch already has `mkey` and
the validated `now` in scope, and `string.format('%.0f', now)` is the encoding already used for lease
stamps. Minimal, local change.

## Decision 3 — Reap removes both member and Hash; bounded; reports counts

**Decision**: For each expired member, reap issues `ZREM` (DLQ) **+** `DEL` (Hash) — retention means
permanently gone (distinct from dead-lettering, which keeps the Hash). Reap is bounded by a
caller-supplied `limit` (examines at most `limit` front members) and returns a flat map
`{removed, scanned, truncated}` so the caller can loop/size. Dangling members (Hash missing) are
`ZREM`'d and counted (cleanup). Cutoff is `DeadLetteredAt ≤ now − retention`; `retention = 0` expires
everything dead-lettered at/before `now`.

**Rationale**: Bounded per call (Principle VII); atomic per call (Principle VI); the `ZREM`+`DEL`
across same-tag keys is sound under effects replication (grounding confirmed).

## Decision 4 — Redrive clears `DeadLetteredAt`; read/peek surface it; back-compat missing→0

**Decision**: `msgfmt_redrive` adds `DeadLetteredAt 0` to its reset `HSET` (a redriven message is no
longer dead-lettered). `msgfmt_read` returns `DeadLetteredAt` (a missing value → `0`, the six original
fields stay strictly required); `msgfmt_peek` includes it in each record (missing → `0`).

**Rationale**: A redriven message must not look "old" to a later reap. Missing→0 keeps every message
stored by Features 001–005 readable with no migration (same pattern as `VisibleAt` in Feature 005).

## Decision 5 — Observability: cheap aggregates + optional bounded breakdown; approximate age

**Decision**: A single NO-WRITES `msgfmt_stats` (registered `no-writes`, `FCALL_RO`-callable) returns a
flat map. **Cheap tier (always)**: queue depth (`ZCARD`), DLQ depth (`ZCARD`, when a DLQ key is given),
and the front message's `Priority` (`ZRANGE 0 0 WITHSCORES`) — all O(1)/O(log N), no per-message reads.
**Bounded tier (when a scan limit is supplied)**: scan the front `max_scan` of the source queue and
classify each as available / in-flight (leased, unexpired) / not-yet-visible (delayed) via the shared
`lease_available` + `is_visible` helpers, returning counts + a `truncated` flag; and an approximate
oldest-dead-letter age from the scanned DLQ prefix.

**Rationale**: `ZCARD` gives depth in O(1), but per-state counts require O(N) Hash reads — so the
breakdown is bounded by a caller limit (Principle VII). Reusing `lease_available`/`is_visible` keeps
the classification identical to how dequeue/peek judge messages.

**Age is approximate under mechanism A**: because the DLQ is Priority-ordered, the true minimum
`DeadLetteredAt` is not at a known position; stats reports the minimum over the *scanned* DLQ prefix,
flagged bounded/approximate. (A time-ordered DLQ would make oldest-age exact and cheap — a point in
B's favour, but B was not chosen.)

## Decision 6 — No new command; no constitution change; no static-gate change

**Decision**: Ship on constitution **v2.0.0**, static gate unchanged.

**Rationale / grounding**: (a) `ZCARD` and `ZRANGE` are already whitelisted; reap/stats also use
`HMGET`/`HGET`/`ZREM`/`DEL` (all present) — **no new command**, so no whitelist change. (b) No principle
caps the message-schema field count; `DeadLetteredAt` is a Principle VIII contract change requiring only
the Principle X docs update (Feature 005 precedent). (c) Bounded loops satisfy Principle VI (single
round trip) and VII (bounded). (d) The determinism scan only greps for `redis.call('TIME')` /
`math.random`; reap/stats use neither. (e) `ZREMRANGEBYSCORE` was considered for reap but **cannot
cascade to the Hash `DEL`** (it returns a count, not members), so it is not used; `PEXPIRE` is not used
(see Decision 1). New error codes (e.g. `ERET`, `ELIMIT` for reap args) are reply strings, not commands,
so they need no gate change.

## Cross-cutting note — pre-existing platform caveat

ElastiCache **Serverless** and MemoryDB **Multi-Region** lack the `FUNCTION`/`FCALL` family; the library
targets self-hosted Redis/Valkey, node-based ElastiCache (7.x), and single-region MemoryDB (7.x). The
TTL family is additionally absent on MemoryDB Multi-Region — reinforcing the rejection of native TTL.
Unchanged by this feature.
