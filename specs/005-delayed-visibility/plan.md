# Implementation Plan: Delayed Visibility (Scheduled Delivery & Retry Backoff)

**Branch**: `005-delayed-visibility` | **Date**: 2026-07-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-delayed-visibility/spec.md`

## Summary

Add a caller-supplied **not-before time** to the `message_format` library so a message can be held
back until a future moment — enabling **scheduled delivery** (enqueue for later) and **retry
backoff** (nack a failure invisible for a delay). Realised as **Design A**: a sixth message-Hash
field **`VisibleAt`** (epoch ms; default `0` = immediately visible), plus a visibility gate in the
dequeue/peek front scan.

- **Schema**: add `VisibleAt` to `FIELDS`/`FIELD_SET`/`DEFAULTS` and the `encode_field` integer
  branch (validated `0 … 2^53`, stored `%.0f`, exactly like `ReadDateTime`). `build_message` and
  `parse_args` pick it up automatically → **`msgfmt_create` and `msgfmt_enqueue` need no signature
  change** (scheduled delivery is `msgfmt_enqueue … VisibleAt <epoch>`).
- **Eligibility**: a message is deliverable only when it is lease-available (Feature 003 rule) **and**
  `now ≥ VisibleAt`. A shared file-local helper `is_visible(visibleat, now)` is added and combined
  with `lease_available` at both the `msgfmt_dequeue` and `msgfmt_peek` selection sites, so they
  agree exactly. A not-yet-visible message is skipped in the front scan (counts against `max_scan`),
  just like an unexpired lease.
- **Back-compat**: `msgfmt_read`, `msgfmt_dequeue`, `msgfmt_peek` treat a **missing** `VisibleAt`
  (any message stored by Features 001–004) as `0`/immediately visible — coalesce `false → 0`, never
  `EMALFORMED`. `msgfmt_read`'s strict 5-field check is relaxed **for `VisibleAt` only**; the five
  original fields remain required. `msgfmt_read` returns `VisibleAt` as a sixth field.
- **Retry backoff**: `msgfmt_nack` gains an **optional** trailing `VisibleAt` argument (`ARGV[2]`);
  when present it is validated (`EVIS`) and set alongside `DirtyBit=0`, retaining
  `ReadDateTime`/`ReadAttempts`. Absent → exactly Feature 003.
- **Composition**: the Feature 004 dead-letter cap check already sits *after* the eligibility gate,
  so a not-yet-visible over-cap message is not dead-lettered until visible (no extra logic).
  `msgfmt_redrive` adds `VisibleAt 0` to its reset `HSET`. `msgfmt_peek` includes `VisibleAt` in each
  record; single mode honours it, top-N reports it.

All time is caller-supplied via ARGV (deterministic; no server clock). **No new command** (only the
existing `HSET`/`HMGET`/`HGET` + Lua arithmetic on `now`). **No constitution change** and **no
static-gate change** (grounded below).

Out of scope (later specs): recurring/cron schedules, per-message TTL/expiry, server-side
exponential-backoff computation, batch scheduling, and a scheduled-ZSET scalability variant.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded interpreter), deployed as the
`message_format` Redis Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua stdlib + the Redis/Valkey scripting API (`redis.*`) only. No
third-party modules. Reuses all existing helpers (`is_int`, `hash_tag`, `lease_available`,
`build_message`/`encode_field`/`parse_args`, `FIELDS`/`DEFAULTS`, `MAX_SAFE_INT`) and the member
format
**Storage**: The message **Hash** (now six fields) and the priority **Sorted Set** (score =
`Priority`) — both reused. `VisibleAt` lives in the Hash only; it is never part of any score, so it
does not affect ordering. No new key or structure
**Testing**: Test-first. Docker harness starts Redis 7.0+ and Valkey 7.2+ images, `FUNCTION LOAD`s
the library, and asserts on `FCALL`/`FCALL_RO` responses, standalone + cluster
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, node-based Amazon ElastiCache
(7.x), Amazon MemoryDB (7.x). (Pre-existing whole-library caveat: ElastiCache **Serverless** lacks
the `FUNCTION`/`FCALL` family; unchanged here)
**Project Type**: Single library (server-side Lua function library) — extended in place
**Performance Goals**: The visibility gate adds O(1) arithmetic per scanned member; a not-yet-visible
message is skipped like a leased one, so the dequeue/peek front scan stays O(K) bounded by
`max_scan`. All other functions unchanged
**Constraints**: No server clock/random — `VisibleAt`/`now` caller-supplied (Principle VII; static
gate enforces). No `KEYS[]` change, no new key, no new command. Adding a sixth field must remain
backward-compatible with stored 5-field messages
**Scale/Scope**: One new field; one small helper (`is_visible`); edits to read/dequeue/peek/nack/
redrive; enqueue/create/validate unchanged in signature (field flows through `build_message`)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — still PASS.*

Constitution version at plan time: **2.0.0**. **No amendment is required or made by this feature.**

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec at `specs/005-delayed-visibility/spec.md`; the edited functions reference it in the library header. PASS |
| II | Minimal Dependencies | Only embedded Lua stdlib + `redis.*`; reuses existing helpers; adds one tiny predicate `is_visible`. No modules/serialization. PASS |
| III | Portability Across All Four Targets | **No new command.** The not-before gate reads `VisibleAt` via the existing `HMGET`/`HGET` and compares against the caller's `now` in Lua; sets it via `HSET`. All already common to Redis 7.0+, Valkey 7.2+, node-based ElastiCache, MemoryDB. PASS |
| IV | Cluster-Safe Key Access *(as amended, v2.0.0)* | No `KEYS[]` change and no new key; every function's key access is exactly as Features 002–004. PASS |
| V | No Privileged/Admin Commands | Only Hash/Sorted-Set data commands. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Each function remains one atomic `FCALL`; the gate adds only in-call arithmetic. PASS |
| VII | Determinism, Flags, Non-Blocking | `VisibleAt` and `now` are caller-supplied; no server clock/random (static determinism scan stays green). `msgfmt_peek` stays `no-writes`; the write functions stay writes. Bounded scan. PASS |
| VIII | Explicit Contracts & Error Handling | `contracts/functions.md` documents the new `VisibleAt` field, the extended `msgfmt_nack` ARGV, the `msgfmt_read`/`msgfmt_peek` shape change, and the new `EVIS` error; all failures structured; fail-before-write. PASS |
| IX | Tested on Every Target Engine and Mode | Docker harness asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster; tests written first; the whole Feature 001–004 suite is re-run to prove the default (`VisibleAt=0`) path is unchanged. PASS |
| X | Documentation Currency | `README.md`, `docs/schema.md`, `docs/functions.md` are updated to add the sixth field, the not-before rule, scheduled delivery, retry backoff, and the peek/read/redrive changes — and to keep the lease "visibility timeout" distinct from delayed visibility. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD`, `FCALL`/`FCALL_RO`, no modules — satisfied.
**No unresolved violations; no Complexity Tracking entries (no waivers, no amendments).**

**Note on the sixth field (Principle VIII/X)**: adding `VisibleAt` evolves the Feature 001 message
schema. No principle closes the schema at five fields, so this is not an amendment — it is a
documented contract change (Principle VIII) with the mandatory docs update (Principle X). The only
correctness risk, back-compat for stored 5-field messages, is handled by the missing→0 coalesce.

## Project Structure

### Documentation (this feature)

```text
specs/005-delayed-visibility/
├── plan.md              # This file (/speckit-plan)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── functions.md     # VisibleAt field + read/nack/peek/dequeue/redrive deltas + EVIS
├── checklists/
│   └── requirements.md  # Spec quality checklist (/speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
src/
└── functions/
    └── message_format.lua     # EXTENDED:
                               #  - add VisibleAt to FIELDS/FIELD_SET/DEFAULTS + encode_field
                               #    integer branch (0..2^53, %.0f)
                               #  - add local helper is_visible(visibleat, now)
                               #  - msgfmt_read: HMGET VisibleAt, coalesce missing->0, add to shape
                               #    (keep the 5 original fields strictly required)
                               #  - msgfmt_dequeue: add VisibleAt to the scan HMGET; deliverable =
                               #    lease_available AND is_visible; cap check stays after the gate
                               #  - msgfmt_peek: add VisibleAt to HMGET + record; single-mode gate
                               #    includes is_visible; top-N reports VisibleAt
                               #  - msgfmt_nack: optional ARGV[2]=VisibleAt (EVIS); set with DirtyBit=0
                               #  - msgfmt_redrive: add 'VisibleAt','0' to the reset HSET
                               #  (msgfmt_create/enqueue/validate: unchanged — field flows through
                               #   build_message)

docs/                          # UPDATED (Principle X)
├── schema.md                  #   add the sixth field; a "Delayed visibility (not-before)" section
│                              #   contrasting it with the lease visibility timeout; back-compat note
└── functions.md               #   update msgfmt_read (6th field), msgfmt_nack (optional VisibleAt +
                               #   EVIS), msgfmt_peek (record + single-mode gate), msgfmt_dequeue
                               #   (eligibility), msgfmt_redrive (reset); note create/enqueue accept it
README.md                      # UPDATED: scheduled-delivery + retry-backoff examples

tests/
├── run_all.sh                 # (existing) picks up new suites automatically
├── harness/                   # (existing) docker_engines.sh, load_and_call.sh, static_checks.sh
│                              #   static gate UNCHANGED (no new command)
├── contract/
│   ├── test_msgfmt_nack_contract.sh        # NEW or extend: optional VisibleAt arg, EVIS, F003 parity
│   ├── test_msgfmt_read_contract.sh        # EXTENDED: VisibleAt in the read shape; missing->0
│   └── test_msgfmt_peek_contract.sh        # EXTENDED: VisibleAt in the record
├── integration/
│   ├── test_msgfmt_scheduled.sh            # US1: future VisibleAt skipped before, delivered at/after;
│   │                                       #   ordering among visible unaffected; boundary now==VisibleAt
│   ├── test_msgfmt_retry_backoff.sh        # US2: nack with delay -> not redelivered until VisibleAt;
│   │                                       #   ReadAttempts retained; fencing intact
│   └── test_msgfmt_visibility_compose.sh   # US3: read shows VisibleAt; back-compat 5-field message;
│                                           #   peek single skips / top-N reports; dead-letter deferred
│                                           #   until visible; redrive resets VisibleAt=0
└── unit/
    ├── test_msgfmt_nack_visibleat_validation.sh  # bad VisibleAt at nack -> EVIS; nothing written
    └── test_msgfmt_visibleat_field_validation.sh # bad VisibleAt via create/validate -> EINVAL: VisibleAt
```

**Structure Decision**: Single-library layout, extended in place. The one shared new predicate
`is_visible` keeps `msgfmt_dequeue` and `msgfmt_peek` single-mode in exact agreement about what is
deliverable (mirroring how `lease_available` is already shared). Enqueue/create/validate are
untouched because `VisibleAt` rides the existing `build_message` field path. Tests follow the three
Spec-Kit categories and reuse the Docker harness; the full Feature 001–004 suite is re-run for the
default-path (`VisibleAt=0`) backward-compatibility guarantee. The static gate is **unchanged** (no
new command).

## Complexity Tracking

> No constitution violations and no amendments. Table intentionally empty.

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|--------------------------------------|
| — | — | — |
