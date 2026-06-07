# Implementation Plan: Message Format

**Branch**: `001-message-format` | **Date**: 2026-06-07 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-message-format/spec.md`

## Summary

Provide the canonical message representation for the Redis/Valkey priority queue as a set of server-side Lua functions. A message is five attributes — ReadAttempts (int, default 0), DirtyBit (bool, default false), ReadDateTime (epoch-ms int, default 0), Priority (int, default 1000, lower = higher priority), Payload (string, default "") — stored as a single Redis **Hash** (one field per attribute) at a caller-supplied key. The feature exposes three functions: a writer that builds a message from arguments (applying defaults + validation) and stores it, a read-only reader that returns the message in a typed shape, and a read-only validator that reports field-level validity. Booleans are encoded 0/1 and numbers as their decimal string form for storage; callers always see logical types. Enqueue/dequeue and ordering are out of scope.

## Technical Context

**Language/Version**: Lua 5.1 semantics (engine-embedded interpreter), deployed as a Redis Functions library via `FUNCTION LOAD`, invoked with `FCALL` / `FCALL_RO`
**Primary Dependencies**: Embedded Lua standard library and the Redis/Valkey scripting API (`redis.*`) only. No third-party Lua modules. `cjson`/`cmsgpack` are available but **not required** for this feature (Hash storage needs no serialization library)
**Storage**: Redis/Valkey Hash, one Hash per message, key supplied by the caller via `KEYS[1]`. Fields: `ReadAttempts`, `DirtyBit`, `ReadDateTime`, `Priority`, `Payload`
**Testing**: Test-first. Local harness uses the Docker CLI to start official Redis 7.0+ and Valkey 7.2+ container images, connects with a Redis client, `FUNCTION LOAD`s the library, and asserts on `FCALL`/`FCALL_RO` responses, in both standalone and cluster mode
**Target Platform**: Self-hosted Redis 7.0+, self-hosted Valkey 7.2+, Amazon ElastiCache, Amazon MemoryDB — one identical Lua source across all four
**Project Type**: Single library (server-side Lua function library)
**Performance Goals**: Each operation is a single bounded `FCALL`/`FCALL_RO` with O(1) Hash access; no unbounded loops; functions short enough to not block the shard meaningfully
**Constraints**: Lua 5.1 numbers are IEEE-754 doubles (integers exact up to 2^53) — millisecond epoch and Priority both fit comfortably; every key via `KEYS[]`; no computed/hardcoded keys; no privileged/admin commands; no cross-slot access; read functions registered with the `no-writes` flag and callable via `FCALL_RO`
**Scale/Scope**: One Hash per message; three functions; no relationships between messages in this feature

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Compliance in this plan |
|---|-----------|--------------------------|
| I | Spec-Driven Development | Spec exists at `specs/001-message-format/spec.md`; every function file will reference it. PASS |
| II | Minimal Dependencies | Uses only embedded Lua stdlib + `redis.*`. No `require`, no third-party modules, no serialization library needed. PASS |
| III | Portability Across All Four Targets | Uses only `HSET`/`HGET`/`HGETALL`/`HSET`-family + `redis.error_reply`/`redis.status_reply`, all available and unrestricted on Redis, Valkey, ElastiCache, MemoryDB. No platform-specific options. PASS |
| IV | Cluster-Safe Key Access | The Hash key is the only key, passed as `KEYS[1]`. Functions never compute, derive, or hardcode keys. Single key per call ⇒ no cross-slot risk. PASS |
| V | No Privileged/Admin Commands | Only Hash read/write commands used; none of `CONFIG`/`SAVE`/`DEBUG`/`FLUSHALL`/etc. PASS |
| VI | Server-Side Atomicity, Single Round Trip | Create and read each complete in one `FCALL`/`FCALL_RO`; no multi-round-trip design. PASS |
| VII | Determinism, Flags, Non-Blocking | Reader and validator carry the `no-writes` flag and are `FCALL_RO`-callable; writer is deterministic (no randomness/time generation inside — timestamps are supplied by the caller); all operations bounded O(1). PASS |
| VIII | Explicit Contracts & Error Handling | Each function documents `KEYS[]`, `ARGV[]`, return shape, and write/no-write status; invalid input returns `redis.error_reply`, not uncaught Lua errors. See `contracts/`. PASS |
| IX | Tested on Every Target Engine and Mode | Docker-based harness loads the library and asserts `FCALL`/`FCALL_RO` on Redis 7.0+ and Valkey 7.2+, standalone and cluster, tests written first. PASS |

**Technology Constraints**: Lua 5.1, `FUNCTION LOAD` deployment, `FCALL`/`FCALL_RO` invocation, no modules — all satisfied. **No violations; Complexity Tracking left empty.**

## Project Structure

### Documentation (this feature)

```text
specs/001-message-format/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── functions.md     # Function contracts (KEYS/ARGV/returns/flags)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
src/
└── functions/
    └── message_format.lua     # The Redis Functions library: registers
                               # msgfmt_create, msgfmt_read, msgfmt_validate

tests/
├── harness/
│   ├── docker_engines.sh      # Start/stop Redis 7.0+ & Valkey 7.2+ containers (standalone + cluster)
│   ├── load_and_call.*        # Helper: FUNCTION LOAD + FCALL/FCALL_RO assertions
│   └── static_checks.sh       # Static gate: restricted cmds / computed keys / cross-target portability (Principles III, IV, V)
├── contract/
│   └── test_message_format_contract.*   # Asserts contracts: KEYS/ARGV/return shape/flags
├── integration/
│   └── test_message_format_roundtrip.*  # create→read round-trips across engines & modes
└── unit/
    └── test_message_format_validation.* # defaults, validation, error replies
```

**Structure Decision**: Single-library layout. All production logic lives in one Lua function library at `src/functions/message_format.lua` (so it can be loaded with a single `FUNCTION LOAD`). Tests are split into the three Spec-Kit categories (contract / integration / unit) and share a Docker-based engine harness under `tests/harness/` that satisfies Principle IX. No application/service/CLI layers exist — the "interface" is the set of registered functions, documented in `contracts/functions.md`.

## Complexity Tracking

> No constitution violations. Section intentionally left empty.
