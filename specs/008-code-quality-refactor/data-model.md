# Phase 1 Data Model: Code-Quality Review & Refactor

This feature changes **no queue data**. The message schema (7 Hash fields + priority Sorted Set + sibling
DLQ) is **frozen** — see `docs/schema.md` and `specs/006-dlq-retention-observability/`. The "model" here
is (1) the **frozen invariants** the refactor must not touch, (2) the **refactor target map** (what
changes, per file), and (3) the **optimisation catalog** (specific Lua techniques → concrete locations).

## 1. Frozen invariants (the "do not change" surface)

| Invariant | Value (frozen at Feature 007) |
|---|---|
| Library file / name | `src/functions/priority_queue.lua` · `#!lua name=priority_queue` |
| Registered functions | `pq_create`, `pq_read`, `pq_validate`, `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`, `pq_peek`, `pq_redrive`, `pq_reap`, `pq_stats` (11) |
| No-writes set (FCALL_RO-callable) | `pq_read`, `pq_validate`, `pq_peek`, `pq_stats` |
| Write set (rejected under FCALL_RO) | `pq_create`, `pq_enqueue`, `pq_dequeue`, `pq_ack`, `pq_nack`, `pq_redrive`, `pq_reap` |
| Message fields (order) | `ReadAttempts`, `DirtyBit`, `ReadDateTime`, `Priority`, `Payload`, `VisibleAt`, `DeadLetteredAt` |
| Error convention | `PQ <CODE>: <detail>` — every **code and detail string** byte-for-byte unchanged |
| Contracts | every function's `KEYS`/`ARGV`, return shape, priority/score encoding, decision logic |
| Regression totals | Bash **832** / 0 · Java **268** run / 10 skip / 0 · Python **258** passed / 10 skip / 0 |

Full contract detail is in [`contracts/frozen-surface.md`](./contracts/frozen-surface.md).

## 2. Refactor target map (what changes, per file)

| Artifact | Goal 1 (readability) | Goal 2 (dead code) | Goal 3 (Lua perf) |
|---|---|---|---|
| `src/functions/priority_queue.lua` (962 ln) | rename/extract private helpers; accurate comments; consistent local naming | remove unused locals/branches, redundant computation, stale comments | **yes** — localise hot globals, drop redundant `redis.call`/table rebuilds, tighten loops |
| `test_bash/harness/*.sh` (319 ln) | shared assertion/key helpers | unused vars/branches | n/a |
| `test_bash/{contract,integration,unit}/*.sh` (2325 ln) | use harness helpers; consistent naming | dead code, stale comments | n/a |
| `test_java/src/test/java/pq/support/*` | shared abstract base test class + helpers | unused imports/fields | n/a |
| `test_java/.../{contract,integration,unit}/*Test.java` (36) | extend base class; consistent naming | unused imports/locals | n/a |
| `test_python/conftest.py` + `pqsupport.py` | shared fixtures + helpers | unused imports | n/a |
| `test_python/{contract,integration,unit}/*.py` (36) | use fixtures/parametrize; consistent naming | unused imports/locals | n/a |
| `README.md`, `docs/schema.md`, `docs/functions.md` | re-verify accuracy | — | — |

**Backstop (FR-003):** for every test file, the set of scenarios, the expected values, and the engine ×
topology matrix are preserved; only structure/readability changes. Per-suite totals stay at the frozen
numbers above.

## 3. Optimisation catalog (goal 3 → concrete Lua locations)

Static usage counts in the current `priority_queue.lua` (none localised today):

| Global | Count | Technique | Where |
|---|---:|---|---|
| `redis.call` | 71 | bind `local rcall = redis.call` | file-wide; every function body |
| `redis.error_reply` | 66 | bind `local rerr = redis.error_reply` | all validation/error paths |
| `tonumber` | 40 | bind `local tonumber = tonumber` | `parse_args`, `encode_field`, `is_int`, `lease_available`, `is_visible`, all readers |
| `redis.status_reply` | 10 | bind `local rstatus = redis.status_reply` | `pq_create`/`ack`/`nack`/`enqueue`/`redrive` OK/NOOP paths |
| `string.format` | 6 | bind `local sformat = string.format` | member/score formatting |
| `string.sub` | 6 | bind `local ssub = string.sub` | `hash_tag`, member parsing |
| `tostring` | 4 | bind `local tostring = tostring` | field encoding |

Additional, review-driven optimisations (verified behaviour-neutral by the suites):

- **Redundant `redis.call` removal** — where a function `HGET`/`HGETALL`s a field it already holds, or
  re-reads a key it just wrote, reuse the in-scope value. Candidate hot spots: `pq_dequeue`
  (scan → acquire), `pq_peek` (top-N loop), `pq_stats` (bounded breakdown loop), `pq_reap` (bounded
  delete loop).
- **Single result-table build** — build each function's return array once (fill by index), avoiding
  intermediate tables in the read/peek/stats shapes.
- **Loop tightening** — in the `pq_dequeue`/`pq_peek`/`pq_reap`/`pq_stats` scan loops, hoist invariants
  (field lists, the localised `rcall`, key prefixes) out of the loop body.

**Invariant (FR-012):** the per-function `redis.call` **count must not increase** after these changes;
redundant-call removal may only *reduce* it. No optimisation adds a client round trip or changes a flag.

## 4. Verification model (how each goal is proven)

| Goal | Proof |
|---|---|
| Behaviour/contract freeze | all three suites green at frozen totals on redis+valkey, standalone+cluster (SC-001/002) |
| Readability | duplicated blocks consolidated into shared helpers; consistent naming; review (SC-005) |
| Zero unused code | grep-assisted review shows no unused local/private fn/import/branch; framework symbols retained (SC-003) |
| Lua performance | localised globals + per-function `redis.call` count unchanged-or-lower + timing gate p50 no-regression (SC-004) |
| Docs currency | README/docs re-verified accurate (SC-007) |
| Constitution | static portability/determinism gate green; runtime deps still empty (SC-006) |
