# Implementation Plan: DLQ Retention & Observability

**Branch**: `006-dlq-retention-observability` | **Date**: 2026-07-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/006-dlq-retention-observability/spec.md`

## Summary

Two operational capabilities added to the `message_format` library, reusing the message Hash and the
priority/dead-letter Sorted Sets:

- **Retention (US1)** — record when a message is dead-lettered in a new seventh Hash field
  **`DeadLetteredAt`** (epoch ms; default `0`), and add a bounded WRITE function **`msgfmt_reap`** that
  permanently removes DLQ entries older than a caller-supplied retention window (`ZREM` the member +
  `DEL` the Hash). Mechanism **A**: keeps Feature 004's DLQ **Priority-scored**, needs **no new
  command**, and preserves the deterministic caller-time model. `msgfmt_dequeue`'s dead-letter branch
  gains a single `HSET DeadLetteredAt=now`; `msgfmt_redrive` clears it (adds `DeadLetteredAt 0` to its
  reset); `msgfmt_read`/`msgfmt_peek` surface it (missing → `0`, back-compat).
- **Observability (US2)** — a new NO-WRITES function **`msgfmt_stats`** returning a flat map: always
  the cheap aggregates (`ZCARD` queue depth, `ZCARD` DLQ depth, front `Priority` via `ZRANGE 0 0
  WITHSCORES`); and, when a caller supplies a scan limit, a bounded front-scan breakdown
  (available / in-flight / not-yet-visible counts + `truncated`) and an approximate oldest-dead-letter
  age from the scanned DLQ prefix.

Both are bounded by caller-supplied limits (Principle VII), use only already-whitelisted commands, and
keep every key co-located under one hash tag. **No constitution change and no static-gate change.**

**Design limitation recorded (mechanism A):** because the DLQ stays Priority-ordered, a small fixed
`limit` reap examines the DLQ front *in Priority order*, so expired low-priority entries behind
unexpired high-priority ones are not reached by one small call; full draining requires the caller to
size `limit` to the DLQ depth (which `msgfmt_stats` reports) or page across calls. Accepted to avoid
changing Feature 004's DLQ ordering; a time-ordered DLQ variant is deferred.

Out of scope (later specs): source-queue TTL, automatic/scheduled reaping, a time-ordered DLQ,
time-series/historical metrics, per-priority histograms, push metrics.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded), deployed as the `message_format` Redis
Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua stdlib + `redis.*` only. No third-party modules. Reuses all
existing helpers (`is_int`, `hash_tag`, `lease_available`, `is_visible`, `build_message`/`encode_field`/
`parse_args`, `FIELDS`/`DEFAULTS`, `MAX_SAFE_INT`) and the member format / id-from-member parse
**Storage**: The message **Hash** (now seven fields) and the priority + dead-letter **Sorted Sets**
(both scored by `Priority`) — reused unchanged in shape. `DeadLetteredAt` lives only in the Hash; it
is not part of any score, so it does not affect ordering. No new key or structure
**Testing**: Test-first. Docker harness starts Redis 7.0+ and Valkey 7.2+, `FUNCTION LOAD`s the
library, asserts on `FCALL`/`FCALL_RO`, standalone + cluster
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, node-based Amazon ElastiCache
(7.x), single-region Amazon MemoryDB (7.x). (Pre-existing whole-library caveat: ElastiCache
**Serverless** and MemoryDB **Multi-Region** lack the `FUNCTION`/`FCALL` family; native TTL was
avoided partly because the TTL family is also absent on MemoryDB Multi-Region)
**Project Type**: Single library (server-side Lua function library) — extended in place
**Performance Goals**: `msgfmt_stats` cheap tier is O(1)/O(log N) (`ZCARD` + front `ZRANGE`); its
optional breakdown and `msgfmt_reap` are O(limit) reads, bounded by a caller-supplied limit; no
unbounded O(N) scan
**Constraints**: No server clock/random — `now`, retention, limits all caller-supplied (Principle VII;
static gate enforces). No new key; no new command. `msgfmt_reap` is a WRITE; `msgfmt_stats` is
`no-writes`/`FCALL_RO`. Every key co-located under one hash tag
**Scale/Scope**: One new field; two new functions (`msgfmt_reap`, `msgfmt_stats`); small edits to the
dead-letter branch, redrive reset, read, and peek. No signature change to create/enqueue/validate
(the field rides `build_message`)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — still PASS.*

Constitution version at plan time: **2.0.0**. **No amendment is required or made by this feature.**

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec at `specs/006-dlq-retention-observability/spec.md`; edited/new functions reference it in the library header. PASS |
| II | Minimal Dependencies | Only embedded Lua stdlib + `redis.*`; reuses existing helpers. No modules. PASS |
| III | Portability Across All Four Targets | **No new command.** Retention/stats use `ZCARD`, `ZRANGE`, `HMGET`/`HGET`, `ZREM`, `DEL` — all already used and common-supported. Native `PEXPIRE` TTL was rejected partly because it is unsupported on MemoryDB Multi-Region. PASS |
| IV | Cluster-Safe Key Access *(as amended, v2.0.0)* | `msgfmt_reap` takes the DLQ Sorted Set + a co-located message-key prefix (constructs `<prefix>id` for the sanctioned same-slot reason — the id is discovered by scanning the DLQ); `msgfmt_stats` takes the queue + prefix + optional DLQ, all sharing one hash tag. No cross-slot access. PASS |
| V | No Privileged/Admin Commands | Only Hash/Sorted-Set data commands. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Each function is one atomic `FCALL`; reap's per-member `ZREM`+`DEL` loop is all-or-nothing within the call. PASS |
| VII | Determinism, Flags, Non-Blocking | `now`/retention/limits caller-supplied; no server clock/random (static determinism scan stays green). `msgfmt_stats` registered `no-writes` + `FCALL_RO`; `msgfmt_reap` is a WRITE. Both bounded by a caller-supplied limit. PASS |
| VIII | Explicit Contracts & Error Handling | `contracts/functions.md` documents `KEYS[]`/`ARGV[]`/return/write for `msgfmt_reap` and `msgfmt_stats`, the new `DeadLetteredAt` field, and the dead-letter/redrive/read/peek changes; all failures structured; fail-before-write. PASS |
| IX | Tested on Every Target Engine and Mode | Docker harness asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster; tests written first; the whole Feature 001–005 suite re-run for regression. PASS |
| X | Documentation Currency | `README.md`, `docs/schema.md`, `docs/functions.md` updated to add the seventh field, `msgfmt_reap`, `msgfmt_stats`, and the dead-letter-stamp + redrive-reset changes. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD`, `FCALL`/`FCALL_RO`, no modules — satisfied.
**No unresolved violations; no Complexity Tracking entries (no waivers, no amendments).**

**Note on the seventh field (Principle VIII/X)**: adding `DeadLetteredAt` evolves the message schema.
No principle caps the field count, so this is a documented contract change (VIII) with the mandatory
docs update (X) — not an amendment (same precedent as Feature 005's `VisibleAt`). Back-compat for
stored six-field messages is handled by the missing→0 coalesce.

## Project Structure

### Documentation (this feature)

```text
specs/006-dlq-retention-observability/
├── plan.md              # This file (/speckit-plan)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── functions.md     # DeadLetteredAt field + msgfmt_reap + msgfmt_stats + dead-letter/redrive/read/peek deltas
├── checklists/
│   └── requirements.md  # Spec quality checklist (/speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/
└── functions/
    └── message_format.lua     # EXTENDED:
                               #  - add DeadLetteredAt to FIELDS/FIELD_SET/DEFAULTS + encode_field
                               #    integer branch (0..2^53, %.0f)
                               #  - msgfmt_dequeue dead-letter branch: add HSET DeadLetteredAt=now
                               #    (the move stops being purely index-only; still no re-lease)
                               #  - msgfmt_redrive: add 'DeadLetteredAt','0' to the reset HSET
                               #  - msgfmt_read: HMGET + return DeadLetteredAt (missing->0; keep the
                               #    six prior fields' handling)
                               #  - msgfmt_peek: add DeadLetteredAt to the record (missing->0)
                               #  - NEW msgfmt_reap (WRITE): bounded DLQ front scan; ZREM+DEL expired;
                               #    clean dangling members; return {removed, scanned, truncated}
                               #  - NEW msgfmt_stats (no-writes): ZCARD depths + front Priority; optional
                               #    bounded breakdown (available/in_flight/delayed + truncated) + approx
                               #    oldest-DLQ age; register with flags = { 'no-writes' }
                               #  (msgfmt_create/enqueue/validate: unchanged — field rides build_message)

docs/                          # UPDATED (Principle X)
├── schema.md                  #   add the seventh field; a DLQ-retention section (DeadLetteredAt, reap
│                              #   semantics, Priority-order caveat); note stats' cheap vs bounded tiers
└── functions.md               #   add msgfmt_reap + msgfmt_stats; update msgfmt_dequeue (stamp),
                               #   msgfmt_redrive (reset), msgfmt_read/msgfmt_peek (field)
README.md                      # UPDATED: retention (reap) + observability (stats) usage examples

tests/
├── run_all.sh                 # (existing) picks up new suites automatically
├── harness/                   # (existing) static gate UNCHANGED (no new command)
├── contract/
│   ├── test_msgfmt_reap_contract.sh    # NEW: KEYS/ARGV, return map, write-flag (FCALL_RO rejected), errors
│   ├── test_msgfmt_stats_contract.sh   # NEW: KEYS/ARGV, cheap map, no-writes (FCALL_RO works), errors
│   └── test_msgfmt_read_contract.sh    # EXTENDED: DeadLetteredAt in the read shape; missing->0
├── integration/
│   ├── test_msgfmt_retention.sh        # US1: dead-letter stamps DeadLetteredAt; reap removes expired
│   │                                   #   (member+hash) / keeps within-window; bounded+truncated;
│   │                                   #   dangling cleanup; redrive clears it; across engines + cluster
│   └── test_msgfmt_stats.sh            # US2: exact depths + front Priority; bounded breakdown counts +
│                                       #   truncated; approx oldest-DLQ age; no mutation; empty queue
└── unit/
    ├── test_msgfmt_reap_validation.sh  # bad now/retention/limit, tag mismatch, wrong-type -> errors; no write on failure
    └── test_msgfmt_stats_validation.sh # bad now/timeout/max_scan, tag mismatch, wrong-type -> errors; read-only
```

**Structure Decision**: Single-library layout, extended in place. `DeadLetteredAt` rides the existing
`build_message` field path (create/enqueue/validate untouched). `msgfmt_reap` reuses the
`msgfmt_dequeue`/`msgfmt_peek` scan idiom (bounded `ZRANGE` front + `<prefix>id` construction);
`msgfmt_stats` reuses `lease_available`/`is_visible` for its breakdown classification, mirroring peek.
Tests follow the three Spec-Kit categories and reuse the Docker harness; the full Feature 001–005 suite
is re-run for regression. The static gate is **unchanged** (no new command).

## Complexity Tracking

> No constitution violations and no amendments. Table intentionally empty.

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|--------------------------------------|
| — | — | — |
