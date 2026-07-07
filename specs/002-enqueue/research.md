# Phase 0 Research: Enqueue

All design decisions below were resolved with the stakeholder (four clarifications) and
grounded by research into Feature 001's implementation and native Sorted Set semantics
before this plan was written. No `NEEDS CLARIFICATION` markers remain. Decisions build on
Feature 001 (`specs/001-message-format/`) and inherit all of its message-format research.

## Decision 1 — Priority index: a native Sorted Set (ZSET), score = integer Priority

- **Decision**: Represent each priority queue as a native Redis/Valkey **Sorted Set** at a
  caller-supplied key (`KEYS[1]`). Each enqueued message contributes exactly one member,
  scored by the message's integer `Priority`. The set is ordered ascending by score, so the
  highest-priority message (lowest `Priority` value) sits at the front for a future dequeue.
- **Rationale**: The Sorted Set is the native priority-ordered structure; insertion is
  O(log N) and later ordered retrieval is `ZRANGE`/`ZPOPMIN`-style. Using the **pure integer
  `Priority` as the score** is lossless because `|Priority| ≤ 2^53` (the exact-integer bound
  Feature 001 already enforces via `MAX_SAFE_INT`). `ZADD`/`ZSCORE`/`ZCARD`/`ZRANGE` are core
  keyspace commands, unrestricted on Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB.
- **Alternatives considered**:
  - *List (`LPUSH`/`RPOP`)* — FIFO only, no priority ordering. Rejected.
  - *Stream* — append-only, ordered by insertion/ID not priority; consumer-group semantics
    may suit a later visibility/ack feature, not priority ordering. Rejected here.
  - *One List per priority level* — unbounded key proliferation and cross-slot fan-out.
    Rejected.

## Decision 2 — FIFO tie-break lives in the member, never packed into the score

- **Decision**: Keep the score a **pure `Priority` integer**. Encode FIFO ordering among
  equal priorities into the **member string** as a fixed-width, zero-padded, caller-supplied
  monotonic **insertion sequence**, followed by the caller-supplied unique **id**:
  `member = <zero-padded sequence> ":" <id>` (padding width fixed, e.g. 20 digits, covering
  the full `≤ 2^53` sequence range).
- **Rationale**: Sorted Set scores are IEEE-754 doubles — exact only to 2^53. Packing
  `Priority × 10^k + sequence` into one score silently rounds away low-order (sequence) bits
  once the magnitude exceeds 2^53, corrupting order non-deterministically. Members, by
  contrast, are compared as **raw bytes** (binary-safe), with no precision limit; a
  fixed-width zero-padded sequence prefix makes lexicographic member order equal numeric
  insertion order. Ascending `ZRANGE`/`ZPOPMIN` then yields highest-priority, oldest-first.
- **Alternatives considered**:
  - *Pack sequence into the score* — precision loss beyond 2^53; rejected (see rationale).
  - *Server-side `INCR` counter for the sequence* — introduces a counter key that must be
    co-located and whitelisted plus an extra write; a caller-supplied sequence keeps the
    write path deterministic (Decision 5) with no extra state. Rejected per clarification.
  - *`id`-only member (no sequence)* — loses insertion order among equal priorities.
    Rejected per clarification (FIFO is required).

## Decision 3 — One atomic create-and-index function; reuse Feature 001 validation

- **Decision**: `msgfmt_enqueue` is a single **WRITE** function that, in one `FCALL`:
  validates and builds the message (reusing Feature 001's `build_message`), checks
  preconditions, then writes the message Hash (`HSET`) and the queue member (`ZADD`). It is
  added to the **existing `message_format` library** so it can call `build_message`,
  `parse_args`, `encode_field`, and the `FIELDS`/`DEFAULTS`/`FIELD_SET`/`MAX_SAFE_INT` tables
  directly.
- **Rationale**: One logical operation ⇒ one server-side round trip (Principle VI). Reusing
  the single validation routine is exactly what Feature 001's `msgfmt_validate` contract
  anticipated ("future features reuse one validation routine"). Redis/Valkey function
  libraries are self-contained — a function cannot call helpers in another library — so
  reuse *requires* sharing the library. **Fail-before-write**: all validation and
  precondition checks complete before any `HSET`/`ZADD`, so a rejected request writes
  nothing (mirrors `msgfmt_create`).
- **Alternatives considered**:
  - *New separate library re-implementing validation* — duplicates logic and invites drift.
    Rejected per clarification.
  - *Client-side create-then-index (two calls)* — multi-round-trip and non-atomic; a crash
    between the two leaves an indexed-but-unstored (or stored-but-unindexed) message.
    Rejected (Principle VI).

## Decision 4 — Conflicts and wrong-type targets are rejected, never merged

- **Decision**: Before writing, `msgfmt_enqueue` checks, and rejects with a structured error
  (writing nothing) when: the message key already exists (`EXISTS` → occupied/duplicate); the
  queue key exists but is not a Sorted Set, or the message key holds a non-Hash value
  (`TYPE`); or the computed member is already present in the queue (`ZSCORE` non-nil →
  already enqueued).
- **Rationale**: A two-key write must never partially apply or silently overwrite
  (FR-009…FR-013). Because `msgfmt_enqueue` always *creates* a new message, requiring the
  message key to be absent doubles as duplicate protection. This mirrors Feature 001's
  conservative `EMALFORMED` stance for wrong-type keys.
- **Alternatives considered**: *Upsert / last-writes-win* — silent overwrite corrupts the
  queue for downstream consumers; rejected per clarification.

## Decision 5 — Determinism: caller supplies id and sequence; nothing generated server-side

- **Decision**: The message `id` and insertion `sequence` are passed via `ARGV`.
  `msgfmt_enqueue` generates no timestamps, counters, or random values.
- **Rationale**: Principle VII — functions must avoid replication-breaking non-determinism.
  This is the same decision Feature 001 made for `ReadDateTime` (Decision 4 there: the caller
  passes time-based/unique values). Redis 7.0+/Valkey Functions replicate by effects, but the
  constitution still mandates avoiding non-determinism, so score and member are wholly derived
  from `ARGV`.
- **Alternatives considered**: *Server-side `TIME`/`INCR`/random sequence* — non-deterministic
  and/or extra state; rejected.

## Decision 6 — Cluster co-location via caller-supplied, hash-tagged keys

- **Decision**: `KEYS[1]` = queue Sorted Set, `KEYS[2]` = message Hash. Both are supplied by
  the caller and MUST share a cluster slot via a common hash tag (e.g. `pq:{q1}` and
  `pq:{q1}:m:<id>`). The function touches only `KEYS[1]` and `KEYS[2]` and never computes,
  derives, or hardcodes a key.
- **Rationale**: Principle IV — every key via `KEYS[]`, and all keys in one call must hash to
  one slot. ElastiCache and MemoryDB always run in cluster mode and reject cross-slot access
  (`CROSSSLOT`). A single-slot two-key write is what makes the create+index atomic on cluster.
- **Alternatives considered**: *Single key holding both message and index* — impossible with
  two distinct native types (Hash + Sorted Set). Rejected.

## Decision 7 — Extend the static portability gate for the new commands

- **Decision**: Extend `tests/harness/static_checks.sh` — the allow-listed command set
  (currently `HSET|HGET|HMGET|HGETALL|HDEL|EXISTS|TYPE|DEL`) and the literal-key regex — to
  permit the Sorted Set commands this feature introduces (`ZADD`, `ZSCORE`, and the
  read-side `ZCARD`/`ZRANGE` used by tests). Confirm each added command/option is on the
  common-supported list for all four targets before adding it.
- **Rationale**: The static gate enforces Principle III by rejecting off-whitelist commands;
  it is Feature-001-scoped, so it must be extended (not bypassed) or it will fail the build
  for the legitimately-portable Sorted Set commands.

## Decision 8 — Developer documentation lives at the repo root + `docs/`

- **Decision**: A root `README.md` is the project entry point; `docs/schema.md` and
  `docs/functions.md` hold the schema and function references.
- **Rationale**: A root README is the conventional first file a developer opens, and the repo
  had none. Reference docs under `docs/` keep the root uncluttered and are easy to link from the
  README.
- **Alternatives considered**: all three at the repo root (clutters the root); all three under
  `docs/` with a thin root README (extra indirection). Rejected in favour of the hybrid.

## Decision 9 — `functions.md` documents all methods, public-first then helpers, alphabetical

- **Decision**: `functions.md` documents every function in `src/functions/message_format.lua`
  (excluding tests): a first section of caller-invocable FCALL-able functions (`msgfmt_create`,
  `msgfmt_enqueue`, `msgfmt_read`, `msgfmt_validate`) in alphabetical order, then a second
  section of local helpers (`build_message`, `encode_field`, `is_int`, `parse_args`) in
  alphabetical order.
- **Rationale**: Consumers need the public API first; maintainers also need the helpers.
  Alphabetical order within each section makes entries findable and stable as the library grows.
- **Alternatives considered**: public-only (loses maintainer value); source order (less
  findable). Rejected.

## Decision 10 — Documentation currency added as a constitution principle

- **Decision**: Add a new principle, "Documentation Currency," requiring that any feature change
  affecting documented behaviour updates the affected documentation in the same change, checked
  at the review gate. MINOR version bump 1.1.0 → 1.2.0, with a sync-impact report.
- **Rationale**: Makes keeping docs current a first-class, enforceable rule rather than an
  afterthought — consistent with the constitution's existing principle + Check structure.
- **Alternatives considered**: fold into "Development Workflow & Quality Gates" as a gate only
  (less prominent). Rejected in favour of a first-class principle, per stakeholder choice.

## Supporting research — Sorted Set / Redis Functions specifics

- **`ZADD` semantics**: `ZADD key [NX|XX] [GT|LT] [CH] [INCR] score member` adds one member
  with a numeric score; default behavior updates an existing member's score. `NX` (add-only)
  is available since 3.0.2 and can make the index write idempotent; `GT`/`LT` (6.2) are above
  the 7.0/7.2 engine floor and safe on all four targets, but are only needed for
  *re-prioritising* an existing member — plain `ZADD` (with an explicit prior `ZSCORE`
  duplicate check per Decision 4) suffices for enqueue.
- **Score precision**: IEEE-754 double, exact integers to 2^53 = 9,007,199,254,740,992 — the
  same `MAX_SAFE_INT` Feature 001 validates against. `Priority` fits with margin.
- **Equal-score ordering**: members with equal scores are ordered lexicographically by raw
  bytes — a defined, stable ordering. A fixed-width zero-padded numeric prefix exploits it for
  FIFO (Decision 2). Sequence formatting must be valid for values up to 2^53 (build the padded
  string from `%.0f` output rather than relying on `%d` with large doubles).
- **Determinism inside functions**: with score and member sourced from `ARGV`, `ZADD`/`HSET`
  are fully deterministic.
- **Command portability**: `ZADD`, `ZSCORE`, `ZCARD`, `ZRANGE`, `HSET`, `EXISTS`, `TYPE` are
  all core, unrestricted commands on Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB;
  MemoryDB's restrictions target admin/cluster/config commands and a few option-level cases,
  none of which apply here.
