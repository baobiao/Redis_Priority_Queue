# Implementation Plan: Enqueue

**Branch**: `002-enqueue` | **Date**: 2026-07-06 (docs increment 2026-07-07) | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-enqueue/spec.md`

## Summary

Add an **enqueue** capability to the Redis/Valkey priority queue as one new server-side Lua
function, `msgfmt_enqueue`, in the existing `message_format` library. In a single atomic
`FCALL` it validates and stores a message (reusing Feature 001's `build_message`, defaults,
and validation) as a **Hash** at a caller-supplied key, and indexes that message in a native
**Sorted Set** priority queue at a second caller-supplied key. The Sorted Set **score is the
message's integer `Priority`** (lower = higher priority ⇒ front); FIFO among equal priorities
is preserved by the **member** — a fixed-width zero-padded, caller-supplied insertion
`sequence` followed by the caller-supplied unique `id` — since scores are doubles (exact only
to 2^53) and must not carry the sequence. The two keys are co-located in one cluster slot via
a shared hash tag. Enqueue is **fail-before-write**: invalid values, unknown/duplicate fields,
an occupied message key, a wrong-type target, or an already-present member are all rejected
with a structured `MSGFMT E...` error and nothing is written to either structure. The `id` and
`sequence` are caller-supplied so the write path is deterministic. Dequeue, retrieval, and
visibility/ack/retry are out of scope (later specs).

**Documentation increment (this update):** Feature 002 also ships developer-facing
documentation — a root `README.md` (what the library is, prerequisites, how to load/call the
functions, how to run the tests), `docs/schema.md` (the message schema and the native types:
the message **Hash** and the priority-index **Sorted Set**), and `docs/functions.md` (every
library function: FCALL-able functions first, then local helpers, alphabetical within each
group). This increment adds **no library code and no runtime behaviour**; the constitution
gains a new **Documentation Currency** principle (v1.1.0 → v1.2.0). Per direction, documentation
needs no automated tests; the existing Docker suite is re-run only to confirm no regression.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded interpreter), deployed as the
`message_format` Redis Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua standard library and the Redis/Valkey scripting API
(`redis.*`) only. No third-party Lua modules; no serialization library. Reuses the existing
Feature 001 helpers in the same library (`build_message`, `parse_args`, `encode_field`,
`FIELDS`/`DEFAULTS`/`FIELD_SET`/`MAX_SAFE_INT`)
**Storage**: A Redis/Valkey **Hash** per message (Feature 001) at `KEYS[2]`, plus a Redis/
Valkey **Sorted Set** per queue at `KEYS[1]` whose members are enqueued messages, scored by
`Priority`. Both keys caller-supplied and co-located in one slot via a shared hash tag
**Testing**: Test-first. Local harness uses the Docker CLI to start official Redis 7.0+ and
Valkey 7.2+ container images, `FUNCTION LOAD`s the library, and asserts on `FCALL`/`FCALL_RO`
responses, in both standalone and cluster mode
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, Amazon ElastiCache,
Amazon MemoryDB — one identical Lua source across all four
**Project Type**: Single library (server-side Lua function library) — extended, not new
**Performance Goals**: One bounded `FCALL` per enqueue: O(1) Hash write + O(log N) Sorted Set
insert; no unbounded loops; short enough to not block the shard meaningfully
**Constraints**: Lua 5.1 numbers are IEEE-754 doubles (integers exact to 2^53) — `Priority`
fits and is used directly as the score (never packed with the sequence); the FIFO sequence
lives in the member string (byte-compared, no precision limit); every key via `KEYS[]`; the
two keys must be same-slot (hash tag); no computed/hardcoded keys; no privileged/admin
commands; write function carries no flags and is not `FCALL_RO`-callable
**Scale/Scope**: One new function; one Sorted Set per logical queue; one member per enqueued
message; no removal/mutation in this feature

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — still PASS.*

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec at `specs/002-enqueue/spec.md`; the new function references it in the library header. PASS |
| II | Minimal Dependencies | Only embedded Lua stdlib + `redis.*`; reuses existing helpers; no `require`, no third-party modules, no serialization. PASS |
| III | Portability Across All Four Targets | Uses only `HSET`, `EXISTS`, `TYPE`, `ZSCORE`, `ZADD` — all on the common-supported list for Redis 7.0+, Valkey 7.2+, ElastiCache, MemoryDB, with no platform-specific options. The static portability gate (`tests/harness/static_checks.sh`) is extended to allow-list the Sorted Set commands. PASS |
| IV | Cluster-Safe Key Access | Exactly two keys — `KEYS[1]` (queue Sorted Set) and `KEYS[2]` (message Hash) — both caller-supplied; the function computes/derives/hardcodes no key. The contract requires the two keys to share a hash tag so they hash to one slot; cluster-mode tests confirm no `CROSSSLOT`. PASS |
| V | No Privileged/Admin Commands | Only Hash/Sorted-Set data commands; none of `CONFIG`/`SAVE`/`DEBUG`/`FLUSHALL`/etc. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Validate + build + precondition-check + `HSET` + `ZADD` all complete in one `FCALL`; no multi-round-trip design. PASS |
| VII | Determinism, Flags, Non-Blocking | Write function carries no flags (correctly not `no-writes`); `id`, `sequence`, and `Priority` (hence score and member) come from `ARGV` — no server-side time/counter/random; execution is bounded O(log N). PASS |
| VIII | Explicit Contracts & Error Handling | `contracts/functions.md` documents `KEYS[]`, `ARGV[]`, return shape, and write status; all failures return structured `MSGFMT E...` replies (no uncaught Lua errors); fail-before-write leaves both structures untouched on any error. PASS |
| IX | Tested on Every Target Engine and Mode | Docker harness `FUNCTION LOAD`s the library and asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster; tests written first. PASS |
| X | Documentation Currency *(added by this increment, v1.2.0)* | This increment introduces the principle and satisfies it: it ships `README.md`, `docs/schema.md`, and `docs/functions.md` reflecting the current schema, functions, and native types, updated alongside the code. The amendment rides this feature's branch/PR. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD` deployment, `FCALL` invocation, no
modules — all satisfied. **No violations; Complexity Tracking left empty.**

**Two-key note (Principle IV)**: this is the first feature to access two keys in one call. It
stays compliant because both keys are declared in `KEYS[]`, neither is computed, and the
contract mandates a shared hash tag so the pair occupies a single slot — exactly the
constitution's co-location rule (`user:{42}:profile`, `user:{42}:sessions`).

## Project Structure

### Documentation (this feature)

```text
specs/002-enqueue/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── functions.md     # msgfmt_enqueue contract (KEYS/ARGV/returns/flags)
├── checklists/
│   └── requirements.md  # Spec quality checklist (/speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
README.md                     # NEW (docs increment): project entry point (usage,
                              #   prerequisites, how to load/call, how to run tests)
docs/                         # NEW (docs increment)
├── schema.md                 #   message schema + native types (Hash + Sorted Set)
└── functions.md              #   every library function (public first, then helpers, A–Z)

src/
└── functions/
    └── message_format.lua     # EXTENDED: add msgfmt_enqueue (registered as a write
                               # function) alongside msgfmt_create/read/validate, reusing
                               # build_message / parse_args / encode_field / FIELDS /
                               # DEFAULTS / FIELD_SET / MAX_SAFE_INT (same library)

tests/
├── run_all.sh                 # convenience runner: all suites on redis+valkey + static gate
├── harness/
│   ├── docker_engines.sh      # (existing) start/stop Redis 7.0+ & Valkey 7.2+ (standalone + cluster)
│   ├── load_and_call.sh       # (existing) FUNCTION LOAD + FCALL/FCALL_RO assertions
│   └── static_checks.sh       # EXTENDED: allow-list ZADD/ZSCORE/ZCARD/ZRANGE and update the
│                              #  literal-key regex (Principles III, IV, V)
├── contract/
│   ├── test_msgfmt_enqueue_contract.sh     # KEYS/ARGV/return shape/flags for msgfmt_enqueue
│   └── test_function_flags.sh              # EXTENDED: assert msgfmt_enqueue is a write (rejected under FCALL_RO)
├── integration/
│   ├── test_msgfmt_enqueue_roundtrip.sh    # priority ordering (incl. boundary values) + FIFO +
│   │                                       #  stored-message fidelity, across engines & modes
│   └── test_msgfmt_enqueue_conflict.sh     # EEXISTS / wrong-type / EQDUP + atomic no-write, across engines
└── unit/
    └── test_msgfmt_enqueue_validation.sh   # bad id/sequence, invalid/unknown/duplicate fields;
                                            #  nothing-written on failure
```

**Structure Decision**: Single-library layout, extended in place. The enqueue logic is a new
registered function inside the existing `src/functions/message_format.lua` so it can reuse
Feature 001's file-local validation/encoding helpers (Redis/Valkey function libraries are
self-contained and cannot call across libraries). Tests follow the same three Spec-Kit
categories (contract / integration / unit) and reuse the existing Docker engine harness
(Principle IX). The static portability gate is extended to cover the Sorted Set commands.

## Documentation Increment (this update)

Scope: developer documentation + a constitution amendment; no library code, no runtime change.

- **Deliverables**: root `README.md`; `docs/schema.md`; `docs/functions.md` (public FCALL-able
  functions first — `msgfmt_create`, `msgfmt_enqueue`, `msgfmt_read`, `msgfmt_validate` — then
  local helpers — `build_message`, `encode_field`, `is_int`, `parse_args` — alphabetical within
  each group).
- **Constitution**: adds a new principle, **Documentation Currency** (MINOR bump v1.1.0 →
  v1.2.0), requiring docs to be updated alongside any feature change that affects them; the
  amendment records a sync-impact report and rides this feature's branch/PR.
- **Approach**: the three docs are independent files, drafted by **parallel sub-agents** from
  the existing spec / data-model / contracts / source, then consolidated and verified.
- **Testing**: none for documentation (per direction). The existing Docker suite
  (`tests/run_all.sh`) is re-run on redis + valkey to confirm the constitution/doc changes cause
  no regression.
- **Constitution compliance for this increment**: Principle IX (test on every engine, test-first)
  governs the **Lua function library** — its `FCALL` behaviour. Documentation is not part of that
  library and produces no engine behaviour, so there is nothing to test on an engine; Principle IX
  is satisfied here by re-running the existing suite (T020) on both engines to confirm no
  regression. This is scoping, not a waiver of the principle. The new **Documentation Currency**
  principle (X) does not yet exist in the constitution at HEAD (still v1.1.0); it is added by T018
  (bump to v1.2.0) and lands in this same feature branch/PR, so the Constitution Check row above is
  forward-looking by design.

## Complexity Tracking

> No constitution violations. The two-key access is compliant with Principle IV (both keys via
> `KEYS[]`, co-located via hash tag). Section intentionally left empty.
