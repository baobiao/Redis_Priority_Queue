# Implementation Plan: Dead-Letter Handling and Peek

**Branch**: `004-dead-letter-peek` | **Date**: 2026-07-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-dead-letter-peek/spec.md`

## Summary

Close the poison-message gap Feature 003 left open and add queue observability, as **two new**
functions plus a **backward-compatible extension** of `msgfmt_dequeue`, all in the existing
`message_format` library:

- **`msgfmt_dequeue`** (extended, WRITE): gains an **optional** dead-letter queue key (`KEYS[3]`)
  and an **optional** maximum-delivery cap (trailing `ARGV`). While scanning the front, an
  **available** candidate (`DirtyBit=0`, or an expired lease) whose `ReadAttempts ≥ cap` is moved
  to the DLQ (`ZREM` source + `ZADD` DLQ, score = `Priority`, member verbatim) instead of being
  leased; the scan then continues. With `KEYS[3]`/cap absent, behaviour and return shape are
  **identical to Feature 003**. Dead-lettering is silent (no signal on the reply).
- **`msgfmt_peek`** (new, NO-WRITES, `FCALL_RO`-callable): inspects a queue without leasing or
  mutating. No `count` (or `count=1`) → the single lease-aware "next deliverable" message (what
  dequeue would pick); `count=N` → up to N front members in priority-then-FIFO order regardless
  of lease state, each annotated with its lease fields. Works on a source queue or a DLQ. Skips
  dangling members (never `ZREM` — it is read-only).
- **`msgfmt_redrive`** (new, WRITE): moves one message from a DLQ back to its source
  (`ZREM` DLQ + `ZADD` source, score = `Priority`, member verbatim) and resets delivery state —
  `ReadAttempts=0`, `DirtyBit=0`, **`ReadDateTime` retained**. No-op/not-found when the member is
  absent from the DLQ; rejected (no duplicate) when already present in the source.

The **DLQ** is just another priority-queue Sorted Set sharing the source's hash tag (`dlq:{q1}`
for `pq:{q1}`); only the one-member index moves between sets, the message Hash never moves. Because
the DLQ has identical shape (score = `Priority`, verbatim member), it is itself peek- and
dequeue-able. All values the functions need — `now`, `timeout`, `max_scan`, the cap, `count` — are
caller-supplied via `ARGV` (no server clock/random).

**No constitution change is required** (contrast Feature 003, which amended Principle IV). The
v2.0.0 Principle IV amendment is gated on *knowability*, not write-vs-read, so it already covers a
read-only `peek` constructing a message key from a scanned id and a three-same-slot-key dequeue;
`redrive` addresses a message whose id the caller knows, so its Hash key is passed **literally**.

Out of scope (later specs): delayed/scheduled visibility, batch/multi-message dequeue, batch or
whole-DLQ redrive, consumer-identity ownership, DLQ retention/TTL, metrics.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded interpreter), deployed as the
`message_format` Redis Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua standard library and the Redis/Valkey scripting API
(`redis.*`) only. No third-party modules. Reuses the existing Feature 001/002/003 helpers in the
same library (`is_int`, `hash_tag`, `FIELDS`, `MAX_SAFE_INT`, field encodings, the member format,
and the id-from-member parse)
**Storage**: The Feature 002 **Sorted Set** per queue (score = `Priority`, member = `%020.0f:id`)
and the Feature 001 **Hash** per message — both reused unchanged. The **DLQ** is a second Sorted
Set of the identical shape sharing the source's hash tag. Dead-letter/redrive move only the index
member between the two Sorted Sets; the message Hash is never relocated
**Testing**: Test-first. Docker harness starts official Redis 7.0+ and Valkey 7.2+ images,
`FUNCTION LOAD`s the library, and asserts on `FCALL`/`FCALL_RO` responses, standalone + cluster
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, node-based Amazon ElastiCache
(7.x), Amazon MemoryDB (7.x) — one identical Lua source across all. (Pre-existing, whole-library:
ElastiCache **Serverless** does not offer the `FUNCTION`/`FCALL` family; unchanged by this feature)
**Project Type**: Single library (server-side Lua function library) — extended, not new
**Performance Goals**: `msgfmt_redrive` is O(log N) (a couple of ZSET ops + a Hash write) in one
`FCALL`. `msgfmt_peek` single-mode and extended `msgfmt_dequeue` are one `FCALL` scanning the
front: O(K) reads where K = ineligible (leased, or over-cap being dead-lettered) members ahead of
the first result, bounded by the optional `max_scan`. `msgfmt_peek` top-N is O(N) reads
**Constraints**: No server clock or randomness — `now`, `timeout`, `max_scan`, cap, `count` all
caller-supplied (Principle VII; static gate enforces). Every key co-located in one slot via a
shared hash tag; the dequeue tag check is extended to `KEYS[3]` (DLQ). `msgfmt_peek` is `no-writes`
and `FCALL_RO`-callable; `msgfmt_dequeue`/`msgfmt_redrive` are WRITEs
**Scale/Scope**: Two new functions + one extended function; one DLQ Sorted Set per logical queue;
no new persistent structures or Hash fields; no new commands (all already whitelisted)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — still PASS.*

Constitution version at plan time: **2.0.0**. **No amendment is required or made by this feature.**

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec at `specs/004-dead-letter-peek/spec.md`; the new/extended functions reference it in the library header. PASS |
| II | Minimal Dependencies | Only embedded Lua stdlib + `redis.*`; reuses existing helpers (`is_int`, `hash_tag`, encodings, member format); no `require`, no modules, no serialization. PASS |
| III | Portability Across All Four Targets | **No new commands.** Dead-letter/redrive use `ZADD`/`ZREM`/`ZSCORE`/`HSET`/`HGET`(/`HMGET`); peek uses `ZRANGE`/`HMGET`/`EXISTS`/`TYPE` — all already in use and on the common-supported list for Redis 7.0+, Valkey 7.2+, node-based ElastiCache, MemoryDB, no platform-specific options. `ZADD` with `NX` (guard) and plain `ZADD` (score-update on re-add) behave identically on all four. PASS |
| IV | Cluster-Safe Key Access *(as amended, v2.0.0 — no further change)* | Extended `dequeue` takes `KEYS[1]` (source), `KEYS[2]` (message-key prefix), and optional `KEYS[3]` (DLQ), all caller-declared and sharing one hash tag; it forms each message key as `KEYS[2] .. id` (the already-sanctioned construction). `peek` takes `KEYS[1]` (queue) + `KEYS[2]` (prefix) and constructs `KEYS[2] .. id` **read-only** — covered by the amendment's *knowability* condition (not write-scoped). `redrive` addresses a message whose id the caller knows, so it takes DLQ, source, and the message Hash **all literally** in `KEYS[]` (no construction). The tag check is extended to `KEYS[3]`; cluster tests confirm no `CROSSSLOT`. PASS |
| V | No Privileged/Admin Commands | Only Hash/Sorted-Set data commands; none of `CONFIG`/`SAVE`/`DEBUG`/`FLUSHALL`/etc. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Each function is exactly one atomic `FCALL`. Dead-lettering (`ZREM`+`ZADD`) and redrive (`ZREM`+`ZADD`+`HSET`) are all-or-nothing within the call (effects replication). PASS |
| VII | Determinism, Flags, Non-Blocking | `dequeue`/`redrive` are WRITEs (no flags); `peek` is registered `no-writes` and is `FCALL_RO`-callable and issues only reads. No server clock/random — `now`, `timeout`, `max_scan`, cap, `count` from `ARGV`. Bounded — redrive O(log N); dequeue/peek front scan bounded by queue size and `max_scan`/`count`. PASS |
| VIII | Explicit Contracts & Error Handling | `contracts/functions.md` documents `KEYS[]`, `ARGV[]`, return shape, and write status for the extended dequeue and both new functions; all failures are structured `MSGFMT E...` replies; fail-before-write on every rejection. PASS |
| IX | Tested on Every Target Engine and Mode | Docker harness `FUNCTION LOAD`s the library and asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster (co-located source + DLQ + message keys); tests written first; the whole Feature 003 suite is re-run to prove the no-DLQ path is unchanged. PASS |
| X | Documentation Currency | `README.md`, `docs/schema.md`, and `docs/functions.md` are updated in this feature to add the DLQ concept, `msgfmt_peek`, `msgfmt_redrive`, and the extended `msgfmt_dequeue` signature, with success and failure examples. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD`, `FCALL`/`FCALL_RO`, no modules — all satisfied.
**No unresolved violations; no Complexity Tracking entries (no waivers, no amendments).**

## Project Structure

### Documentation (this feature)

```text
specs/004-dead-letter-peek/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── functions.md     # extended msgfmt_dequeue + msgfmt_peek + msgfmt_redrive contracts
├── checklists/
│   └── requirements.md  # Spec quality checklist (/speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
src/
└── functions/
    └── message_format.lua     # EXTENDED: add msgfmt_peek (no-writes) and msgfmt_redrive (write);
                               #   extend msgfmt_dequeue with optional KEYS[3]=DLQ + trailing cap
                               #   ARGV (backward compatible). Reuse is_int, hash_tag, the field
                               #   encodings, MAX_SAFE_INT, the member format, and the
                               #   id-from-member parse. A shared local helper selects the front
                               #   available candidate so dequeue and peek agree exactly

docs/                          # UPDATED (Principle X)
├── schema.md                  #   add the dead-letter queue (sibling ZSET, shared tag, score=Priority,
│                              #   verbatim member, index-only move) and the redrive reset semantics
└── functions.md               #   add msgfmt_peek + msgfmt_redrive (public section, alphabetical);
                               #   update msgfmt_dequeue with the optional DLQ key + cap
README.md                      # UPDATED: dead-letter usage, peek (both modes), redrive examples

tests/
├── run_all.sh                 # (existing) convenience runner; picks up new suites automatically
├── harness/
│   ├── docker_engines.sh      # (existing) start/stop Redis 7.0+ & Valkey 7.2+ (standalone + cluster)
│   ├── load_and_call.sh       # (existing) FUNCTION LOAD + FCALL/FCALL_RO assertions
│   └── static_checks.sh       # (unchanged) already allow-lists every command used; whole-file scan
│                              #   automatically covers the new functions; determinism scan unchanged
├── contract/
│   ├── test_msgfmt_peek_contract.sh      # KEYS/ARGV/return shape + no-writes flag (FCALL_RO works)
│   ├── test_msgfmt_redrive_contract.sh   # KEYS/ARGV/return + write flag (FCALL_RO rejected)
│   ├── test_msgfmt_dequeue_contract.sh   # EXTENDED: optional KEYS[3]/cap; 2-key call still valid
│   └── test_function_flags.sh            # EXTENDED: peek carries no-writes; redrive does not
├── integration/
│   ├── test_msgfmt_deadletter.sh         # cap reached -> moved to DLQ; below-cap delivered;
│   │                                     #   in-flight-unexpired not dead-lettered; expired-lease
│   │                                     #   dead-lettered; Feature-003 parity when DLQ/cap omitted
│   ├── test_msgfmt_peek.sh               # single = next-deliverable (== dequeue pick, no mutation);
│   │                                     #   top-N order + lease fields; empty/all-leased; DLQ peek
│   └── test_msgfmt_redrive.sh            # DLQ -> source, reset RA=0/DB=0, ReadDateTime retained,
│                                         #   redelivered; not-in-DLQ no-op; already-in-source guard
└── unit/
    ├── test_msgfmt_peek_validation.sh    # bad now/timeout/count, tag mismatch, wrong-type; read-only
    └── test_msgfmt_redrive_validation.sh # bad args, tag mismatch, dangling/malformed Hash; no-write
```

**Structure Decision**: Single-library layout, extended in place — the two new functions and the
dequeue extension join `src/functions/message_format.lua` to reuse the file-local helpers, member
format, and id-parse (function libraries are self-contained). A shared front-scan/selection helper
keeps `msgfmt_peek` single-mode and `msgfmt_dequeue` in exact agreement about which message is
"next deliverable". Tests follow the three Spec-Kit categories and reuse the Docker engine harness
(Principle IX); the Feature 003 suite is re-run for the backward-compatibility guarantee. The
static gate is **unchanged** (no new commands).

## Complexity Tracking

> No constitution violations and no amendments. Table intentionally empty.

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|--------------------------------------|
| — | — | — |
