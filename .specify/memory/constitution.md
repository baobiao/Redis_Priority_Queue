<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 1.1.0
Bump rationale: MINOR — added mandatory local unit-testing methodology (Docker-based
  Redis and Valkey container images) to Principle IX and the Development Workflow &
  Quality Gates section. New guidance, no principle removed or redefined.

Modified in 1.1.0:
  - Principle IX (Tested on Every Target Engine and Mode): added container-based local
    testing rules and check.
  - Development Workflow & Quality Gates: added "Local testing" subsection.

------------------------------------------------------------
Prior entry — Version change: (template, unversioned) → 1.0.0
Bump rationale: Initial ratification of the project constitution. MAJOR baseline (1.0.0)
  establishing all governing principles from scratch.

Modified principles: N/A (initial adoption)

Added principles:
  I.    Spec-Driven Development is Mandatory
  II.   Minimal Dependencies
  III.  Portability Across All Four Targets
  IV.   Cluster-Safe Key Access
  V.    No Privileged or Admin Commands
  VI.   Server-Side Atomicity, Single Round Trip
  VII.  Determinism, Flags, and Non-Blocking Execution
  VIII. Explicit Contracts and Error Handling
  IX.   Tested on Every Target Engine and Mode

Added sections:
  - Technology Constraints
  - Development Workflow & Quality Gates
  - Governance

Removed sections: N/A

Templates requiring updates:
  ✅ .specify/templates/plan-template.md   — no change needed (Constitution Check gate
       defers dynamically to this file via "[Gates determined based on constitution file]")
  ✅ .specify/templates/spec-template.md   — no change needed (domain-agnostic, no hardcoded principles)
  ✅ .specify/templates/tasks-template.md  — no change needed (domain-agnostic, no hardcoded principles)
  ✅ .specify/templates/checklist-template.md — no change needed (generic)

Follow-up TODOs: None. All placeholders resolved.
-->

# Redis Priority Queue Constitution

The sole deliverable of this project is a library of **server-side Lua functions** for
Redis and Valkey. Functions are packaged into a single library, deployed with
`FUNCTION LOAD`, and invoked with `FCALL` / `FCALL_RO`. The **same Lua source MUST run
unmodified** on all four target platforms:

- Self-hosted Redis 7.0+
- Self-hosted Valkey 7.2+
- Amazon ElastiCache
- Amazon MemoryDB

## Core Principles

### I. Spec-Driven Development is Mandatory

No function is written or changed without first passing through the Spec-Kit flow
(constitution → specify → clarify → plan → tasks → analyze → implement). Every code
change MUST trace to a spec under `specs/`. Pull requests that introduce or modify a
function without a corresponding spec MUST be rejected.

**Check**: PR review and CI MUST confirm each changed function file references a spec
under `specs/NNN-feature/`; changes with no traceable spec fail the gate.

**Rationale**: Intent is the source of truth; the constitution and spec govern the code,
not the reverse.

### II. Minimal Dependencies

Implementations MUST use only the Lua standard library available in the embedded
interpreter and the Redis/Valkey scripting API (`redis.*`). Any third-party Lua
dependency MUST be explicitly justified in the plan and approved before use; built-ins
are preferred and MUST be chosen when they suffice.

**Check**: CI MUST statically scan for `require`/external module usage; any unapproved
dependency fails the build. The plan's Complexity Tracking table MUST record every
approved exception.

**Rationale**: Portability and a small, auditable surface.

### III. Portability Across All Four Targets is Non-Negotiable

A function MUST behave identically on self-hosted Redis 7.0+, self-hosted Valkey 7.2+,
ElastiCache, and MemoryDB. Only commands and command options available on all four MAY
be used. Each command and option used MUST be verified against every platform's
supported-commands documentation (e.g., some `SET` and `RESTORE` options are restricted
on MemoryDB) and MUST NOT rely on platform-specific behavior.

**Check**: CI MUST run `FUNCTION LOAD` and the function suite against Redis 7.0+ and
Valkey 7.2+, and statically reject commands/options not on the common-support list for
all four targets.

**Rationale**: One artifact, four environments.

### IV. Cluster-Safe Key Access

Every key a function touches MUST be passed in via `KEYS[]`. Functions MUST NOT compute,
derive, or hardcode key names internally. All keys accessed in a single call MUST hash to
the same slot, and related keys MUST be co-located with a hash tag
(e.g. `user:{42}:profile`, `user:{42}:sessions`).

**Check**: CI MUST statically reject computed/hardcoded key names inside function bodies
and MUST exercise cluster mode to surface `CROSSSLOT` errors.

**Rationale**: ElastiCache and MemoryDB always run in cluster mode and reject undeclared
keys and cross-slot access (`CROSSSLOT`).

### V. No Privileged or Admin Commands

Function bodies MUST NOT call restricted/admin commands — including `CONFIG`, `SAVE`,
`BGSAVE`, `BGREWRITEAOF`, `DEBUG`, `SHUTDOWN`, `REPLICAOF`/`SLAVEOF`, `MIGRATE`, `SYNC` —
nor `FLUSHALL` / `FLUSHDB`.

**Check**: CI MUST statically scan function bodies for the prohibited command set and
fail the build on any match.

**Rationale**: These are blocked on the managed services and/or unsafe inside server-side
execution.

### VI. Server-Side Atomicity, Single Round Trip

Each function MUST encapsulate its complete multi-step logic so the client needs exactly
one call (`FCALL` / `FCALL_RO`). Designs that require multiple client↔server round trips
to complete a single logical operation MUST be rejected.

**Check**: Plan and PR review MUST confirm each operation is expressed as one server-side
call; multi-round-trip designs are rejected at the `/speckit.plan` gate.

**Rationale**: Eliminate network round trips and race conditions.

### VII. Determinism, Flags, and Non-Blocking Execution

Functions MUST be registered with correct flags (e.g. `no-writes` for read-only
functions, which MUST then be callable via `FCALL_RO`) and MUST avoid non-deterministic
behavior that breaks replication. Functions MUST be short and bounded: a function blocks
its shard while running and becomes unkillable once it has written.

**Check**: CI MUST verify read-only functions carry the `no-writes` flag and are callable
via `FCALL_RO`; review MUST confirm execution is bounded and free of
replication-breaking non-determinism.

**Rationale**: Correct replication and cluster availability.

### VIII. Explicit Contracts and Error Handling

Every function MUST document its expected `KEYS[]` and `ARGV[]`, its return shape, and
whether it writes. Errors MUST use the scripting error/status conventions
(`redis.error_reply` / `redis.status_reply` / structured error tables) rather than
uncaught Lua errors wherever avoidable.

**Check**: PR review MUST confirm each function carries a documented contract
(`KEYS[]`, `ARGV[]`, return shape, write/no-write); CI MAY assert error paths return
structured replies rather than raising uncaught errors.

**Rationale**: Predictable, client-friendly interfaces.

### IX. Tested on Every Target Engine and Mode

Tests MUST cover Redis 7.0+ and Valkey 7.2+, in both standalone and cluster mode, and
MUST follow a test-first discipline (tests written and failing before implementation).

Local unit testing MUST run against real engines, not mocks. For each engine, the test
harness MUST:

1. Spin up the official **Redis** and **Valkey** container images using the Docker CLI
   (e.g., `docker run`), one container per engine.
2. Connect to each running container with a Redis client.
3. Load the Lua function library into the container via `FUNCTION LOAD`.
4. Invoke the functions with `FCALL` / `FCALL_RO` and assert on the responses.

**Check**: CI MUST execute the test suite on Redis 7.0+ and Valkey 7.2+ in both
standalone and cluster mode; a missing engine/mode combination fails the gate. The local
harness MUST start both the Redis and Valkey container images and run the load-and-assert
cycle above against each.

**Rationale**: Cluster mode and version differences are where portability breaks.

## Technology Constraints

- **Language**: Lua, targeting the engine-embedded interpreter (Lua 5.1 semantics). No
  transpilation and no native modules.
- **Engine floor**: Redis 7.0+, Valkey 7.2+ (the Functions API requires these versions).
- **Deployment**: `FUNCTION LOAD`. **Invocation**: `FCALL` / `FCALL_RO`.
- **No modules**: No reliance on Redis/Valkey modules or any module-provided command or
  data type — modules cannot be loaded on ElastiCache or MemoryDB.
- **Repository layout**: Follows the Spec-Kit layout (`.specify/`, `specs/NNN-feature/`).

## Development Workflow & Quality Gates

- The Spec-Kit phases are enforced in order. `/speckit.clarify` is REQUIRED before
  `/speckit.plan`, and `/speckit.analyze` is REQUIRED before `/speckit.implement`.
- Every pull request MUST be reviewed for constitution compliance.
- **Local testing**: Developers MUST run unit tests against real engines before opening a
  PR. The harness spins up the Redis and Valkey container images via the Docker CLI,
  connects with a Redis client, loads the Lua function library with `FUNCTION LOAD`, and
  asserts on `FCALL` / `FCALL_RO` responses (per Principle IX).
- CI MUST:
  - Load and run the function library on Redis 7.0+ and Valkey 7.2+.
  - Exercise cluster mode.
  - Statically reject restricted commands (Principle V), computed/hardcoded key names
    (Principle IV), and cross-slot access.
  - Verify `FUNCTION LOAD` succeeds on each target engine version.

## Governance

- This constitution is the supreme authority. Specs, plans, and tasks MUST comply, and
  any conflict is resolved in the constitution's favor.
- **Versioning** is semantic:
  - **MAJOR**: principle removals or redefinitions.
  - **MINOR**: new principles or sections.
  - **PATCH**: clarifications and non-semantic refinements.
- Amendments MUST be proposed via pull request, justified against project goals, and
  recorded with a version bump and date.
- Compliance is reviewed at the `/speckit.plan` and `/speckit.implement` gates;
  violations block progress until resolved or the constitution is formally amended.

**Version**: 1.1.0 | **Ratified**: 2026-05-30 | **Last Amended**: 2026-05-30
