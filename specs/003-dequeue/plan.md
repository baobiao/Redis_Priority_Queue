# Implementation Plan: Dequeue

**Branch**: `003-dequeue` | **Date**: 2026-07-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-dequeue/spec.md`

## Summary

Add a **dequeue / consume** capability to the Redis/Valkey priority queue as **three** new
server-side Lua functions in the existing `message_format` library. Because an `FCALL` is
atomic and cannot block for external client work, the "blocking dequeue" is realised as a
two-phase lease:

- **`msgfmt_dequeue`** (acquire, WRITE): scan the queue **Sorted Set** front-to-back (ascending
  `Priority`, then FIFO by member), find the first message whose lease is **available**
  (`DirtyBit=0`, or `DirtyBit=1` with `now − ReadDateTime ≥ timeout` — an expired lease), mark
  it in-flight (`DirtyBit=1`, `ReadDateTime=now`, `ReadAttempts+1`), and return its `Payload`
  plus a handle. Returns a null reply immediately when nothing is available.
- **`msgfmt_ack`** (WRITE): on successful processing, remove the message — `ZREM` the queue
  member and `DEL` the message Hash.
- **`msgfmt_nack`** (WRITE): on failed processing, release the lease — set `DirtyBit=0`,
  retaining the incremented `ReadAttempts` and updated `ReadDateTime`; the member stays, so the
  message is available again at its original position.

`now` and the visibility `timeout` are **caller-supplied via ARGV** (deterministic; no server
clock), consistent with enqueue. A **fencing token** — the `ReadAttempts` value captured at
lease grant — lets `ack`/`nack` reject a superseded lease, so a consumer whose lease expired and
was reclaimed cannot corrupt the new holder's message. All settle calls are **fail-before-write**
and idempotent on an already-settled (absent) message (`NOOP`).

Acquire must address the message it selects **at runtime** (the caller cannot know which message
is at the front). It does so by appending the runtime `id` to a caller-declared, hash-tagged
message-key **prefix** (`KEYS[2] .. id`) — the narrow construction newly permitted by
**constitution Principle IV as amended to v2.0.0** (a prerequisite completed before this plan).

Out of scope (later specs): dead-letter routing / max-attempts cap, delayed visibility, batch
dequeue, consumer-identity ownership, non-destructive peek.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded interpreter), deployed as the
`message_format` Redis Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua standard library and the Redis/Valkey scripting API
(`redis.*`) only. No third-party modules. Reuses the existing Feature 001/002 helpers in the
same library (`is_int`, `FIELDS`, `MAX_SAFE_INT`, field encodings) and the enqueue member format
**Storage**: The Feature 002 **Sorted Set** per queue at `KEYS[1]` (score = `Priority`, member =
`%020.0f:id`) and the Feature 001 **Hash** per message. Acquire reaches each message Hash by
`KEYS[2] .. id` (co-located prefix); ack/nack receive the message Hash directly in `KEYS[]`
**Testing**: Test-first. Docker harness starts official Redis 7.0+ and Valkey 7.2+ images,
`FUNCTION LOAD`s the library, and asserts on `FCALL`/`FCALL_RO` responses, standalone + cluster
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, Amazon ElastiCache,
Amazon MemoryDB — one identical Lua source across all four
**Project Type**: Single library (server-side Lua function library) — extended, not new
**Performance Goals**: `msgfmt_ack`/`msgfmt_nack` are O(log N)/O(1) single `FCALL`s.
`msgfmt_dequeue` is one `FCALL` that scans the congested front: O(K) reads where K = leased
messages ahead of the first available one, bounded by an optional `max_scan`; no unbounded blocking
**Constraints**: No server clock or randomness — `now`, `timeout`, `id`, `sequence`, `Priority`
all caller-supplied (Principle VII; static gate enforces). Every key co-located in one slot via a
shared hash tag; acquire's constructed `KEYS[2] .. id` inherits the declared prefix's tag
(Principle IV as amended). All three functions are WRITEs (no `no-writes`, not `FCALL_RO`-callable)
**Scale/Scope**: Three new functions; one Sorted Set per logical queue; lease state carried in the
existing five Hash fields; no new persistent structures

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — still PASS.*

Constitution version at plan time: **2.0.0** (Principle IV amended for this feature; see the
prerequisite note below).

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec at `specs/003-dequeue/spec.md`; the new functions reference it in the library header. PASS |
| II | Minimal Dependencies | Only embedded Lua stdlib + `redis.*`; reuses existing helpers; no `require`, no modules, no serialization. PASS |
| III | Portability Across All Four Targets | Adds only `ZREM` and `HINCRBY` to the already-used `ZRANGE`/`HMGET`/`HSET`/`EXISTS`/`TYPE`/`DEL`/`ZADD`/`ZSCORE` set — all on the common-supported list for Redis 7.0+, Valkey 7.2+, ElastiCache, MemoryDB, no platform-specific options. `HINCRBY` on an absent field defaults to 0 identically on all four. The static gate is extended to allow-list `ZREM`/`HINCRBY`. PASS |
| IV | Cluster-Safe Key Access *(as amended, v2.0.0)* | `ack`/`nack` take every key literally via `KEYS[]`. `dequeue` takes `KEYS[1]` (queue) and `KEYS[2]` (message-key prefix), both caller-declared and sharing one hash tag, and forms each message key as `KEYS[2] .. id` — the **sanctioned** construction (append a runtime suffix to a declared, hash-tagged prefix, for a key the caller cannot know in advance). Acquire validates the prefix shares the queue's tag (`ETAG`) so every key is in one slot; cluster tests confirm no `CROSSSLOT`. PASS |
| V | No Privileged/Admin Commands | Only Hash/Sorted-Set data commands; none of `CONFIG`/`SAVE`/`DEBUG`/`FLUSHALL`/etc. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Each of the three functions is exactly one atomic `FCALL`. The lease spans two operations (acquire → settle) only because the consumer's processing is **external** and a function must not block (Principle VII); no single atomic operation is split across round trips, and correctness does not depend on the client returning (the visibility timeout + fencing recover an abandoned lease). PASS |
| VII | Determinism, Flags, Non-Blocking | All three are WRITEs registered with no flags (correctly not `no-writes`). No server clock/random: `now` and `timeout` come from `ARGV`. Execution is bounded — ack/nack O(1); dequeue's scan is bounded by queue size and an optional `max_scan`. PASS |
| VIII | Explicit Contracts & Error Handling | `contracts/functions.md` documents `KEYS[]`, `ARGV[]`, return shape, and write status for each; all failures are structured `MSGFMT E...` replies (no uncaught Lua errors); fail-before-write on every rejection. PASS |
| IX | Tested on Every Target Engine and Mode | Docker harness `FUNCTION LOAD`s the library and asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster (co-located keys); tests written first. PASS |
| X | Documentation Currency | `README.md`, `docs/schema.md`, and `docs/functions.md` are updated in this feature to add dequeue/ack/nack, the lease lifecycle, the visibility timeout, and the fencing token. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD`, `FCALL`, no modules — all satisfied.
**No unresolved violations; Complexity Tracking records the one amended principle below.**

**Prerequisite — Principle IV amendment (completed before this plan)**: acquire cannot receive
the winning message's key literally (the caller does not know which message is at the front until
the server scans). The only faithful realisation of the user's DirtyBit-in-Hash design that keeps
acquire a single atomic call is to construct that key at runtime. Principle IV was therefore
amended **1.2.0 → 2.0.0** (MAJOR, redefinition) to permit exactly one narrow construction:
appending a runtime suffix to a declared, hash-tagged `KEYS[]` prefix. Alternatives were weighed
and rejected (see `research.md`): a queue-scoped message store (avoids the amendment but discards
the clean per-message-Hash schema shared with Features 001/002) and a peek + CAS-mark protocol
(adds round trips and changes DirtyBit from the availability flag). Lease/visibility/fencing
semantics are documented at the feature level, not as a new constitution principle.

## Project Structure

### Documentation (this feature)

```text
specs/003-dequeue/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── functions.md     # msgfmt_dequeue / msgfmt_ack / msgfmt_nack contracts
├── checklists/
│   └── requirements.md  # Spec quality checklist (/speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
src/
└── functions/
    └── message_format.lua     # EXTENDED: add msgfmt_dequeue, msgfmt_ack, msgfmt_nack
                               #   (all registered as write functions) alongside
                               #   msgfmt_create/read/validate/enqueue; reuse is_int,
                               #   the field encodings, MAX_SAFE_INT, and the enqueue
                               #   member format; add a file-local hash-tag helper

docs/                          # UPDATED (Principle X)
├── schema.md                  #   add the lease lifecycle (DirtyBit/ReadDateTime/ReadAttempts),
│                              #   visibility timeout, fencing token, and the prefix+id convention
└── functions.md               #   add msgfmt_dequeue/ack/nack (public section, alphabetical)
README.md                      # UPDATED: dequeue/ack/nack usage + lease/visibility notes

tests/
├── run_all.sh                 # (existing) convenience runner; picks up new suites automatically
├── harness/
│   ├── docker_engines.sh      # (existing) start/stop Redis 7.0+ & Valkey 7.2+ (standalone + cluster)
│   ├── load_and_call.sh       # (existing) FUNCTION LOAD + FCALL/FCALL_RO assertions
│   └── static_checks.sh       # EXTENDED: allow-list ZREM/HINCRBY; keep rejecting admin/off-list
│                              #   commands and hardcoded literal keys; determinism scan unchanged
├── contract/
│   ├── test_msgfmt_dequeue_contract.sh   # KEYS/ARGV/return shape + write-flag (FCALL_RO rejected)
│   └── test_function_flags.sh            # EXTENDED: dequeue/ack/nack carry no no-writes flag
├── integration/
│   ├── test_msgfmt_dequeue_roundtrip.sh  # priority order + FIFO + lease fields + ack removes +
│   │                                     #   nack re-delivers, across engines & modes
│   ├── test_msgfmt_dequeue_visibility.sh # timeout reclaim + fencing (stale settle rejected)
│   └── test_msgfmt_dequeue_concurrency.sh# two acquires never return the same message
└── unit/
    └── test_msgfmt_dequeue_validation.sh # bad now/timeout, tag mismatch, wrong-type, ENOTLEASED,
                                          #   double-settle NOOP; nothing-written on failure
```

**Structure Decision**: Single-library layout, extended in place — the three functions join
`src/functions/message_format.lua` to reuse the file-local helpers and the enqueue member format
(function libraries are self-contained and cannot call across libraries). Tests follow the three
Spec-Kit categories and reuse the Docker engine harness (Principle IX). The static gate is
extended for the two new commands.

## Complexity Tracking

> One constitution change was required and made (not a waiver).

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|--------------------------------------|
| Principle IV amended (1.2.0 → 2.0.0) to permit `KEYS[2] .. id` construction in acquire | Acquire must address a message discovered only at runtime while staying a single atomic `FCALL` (Principle VI); the caller cannot pass that key literally | **Queue-scoped message store** discards the per-message-Hash schema shared with Features 001/002 and duplicates/rewrites `create`/`read`/`enqueue`. **Peek + CAS-mark** adds client round trips and retries and repurposes DirtyBit away from being the availability flag. Both are more disruptive than a narrow, slot-safe key construction. |
