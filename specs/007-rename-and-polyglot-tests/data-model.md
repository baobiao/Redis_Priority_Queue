# Phase 1 Data Model: Rename to priority_queue and Polyglot Test Parity

This feature introduces **no queue-data changes**. The "model" here is (1) the rename token map and
(2) the three-suite parity structure. The message schema (7 Hash fields + priority Sorted Set + sibling
DLQ) is **frozen** — see `docs/schema.md` and `specs/006-dlq-retention-observability/`.

## 1. Rename token map (old → new)

| Kind | Old | New |
|---|---|---|
| Library file | `src/functions/message_format.lua` | `src/functions/priority_queue.lua` |
| Shebang / library name | `#!lua name=message_format` | `#!lua name=priority_queue` |
| Error-reply prefix | `MSGFMT <CODE>: <detail>` | `PQ <CODE>: <detail>` (codes + detail unchanged) |
| Function | `msgfmt_create` (write) | `pq_create` |
| Function | `msgfmt_read` (**no-writes**) | `pq_read` |
| Function | `msgfmt_validate` (**no-writes**) | `pq_validate` |
| Function | `msgfmt_enqueue` (write) | `pq_enqueue` |
| Function | `msgfmt_dequeue` (write) | `pq_dequeue` |
| Function | `msgfmt_ack` (write) | `pq_ack` |
| Function | `msgfmt_nack` (write) | `pq_nack` |
| Function | `msgfmt_peek` (**no-writes**) | `pq_peek` |
| Function | `msgfmt_redrive` (write) | `pq_redrive` |
| Function | `msgfmt_reap` (write) | `pq_reap` |
| Function | `msgfmt_stats` (**no-writes**) | `pq_stats` |
| Container (standalone) | `msgfmt-redis`, `msgfmt-valkey` | `pq-redis`, `pq-valkey` |
| Container (cluster) | `msgfmt-redis-cluster`, `msgfmt-valkey-cluster` | `pq-redis-cluster`, `pq-valkey-cluster` |
| Harness env defaults | `REDIS_NAME=msgfmt-redis`, … | `REDIS_NAME=pq-redis`, … |

**Invariants (FR-005)**: KEYS/ARGV shapes, field set/order, priority-score encoding, return shapes,
`no-writes` flags, and all decision logic are **identical** to Feature 006. Only the tokens above change.

**No-writes set (FCALL_RO-callable)**: `pq_read`, `pq_validate`, `pq_peek`, `pq_stats`.
**Write set (FCALL only; rejected under FCALL_RO)**: `pq_create`, `pq_enqueue`, `pq_dequeue`, `pq_ack`,
`pq_nack`, `pq_redrive`, `pq_reap`.

## 2. Test filename rename (Bash)

The `tests/` → `test_bash/` move preserves structure. Bash test **filenames** embedding `msgfmt` are
renamed `test_msgfmt_*` → `test_pq_*` so the grep sweep (D10) finds zero `msgfmt` outside historical
specs. `run_all.sh` globs by directory, so filename changes do not break discovery.
`contract/test_function_flags.sh` keeps its name (no `msgfmt` token) but its **content** updates
(library-name assertion `message_format` → `priority_queue`; any `msgfmt_` FCALL → `pq_`).

## 3. Parity mapping table (source of truth = Bash)

Each Bash suite maps 1-to-1 to one Java class (package `pq.<dir>`, `src/test/java/pq/<dir>/`) and one
Python module (`test_python/<dir>/`). Equivalence is by **scenario + expected value**, not identical
assertion integers.

### contract/ (11)

| Bash (`test_bash/contract/`) | Java (`pq.contract`) | Python (`test_python/contract/`) | Covers |
|---|---|---|---|
| `test_function_flags.sh` | `FunctionFlagsTest` | `test_function_flags.py` | library name `priority_queue`, 11 `pq_*` registered, `no-writes` flags, FCALL_RO on write rejected |
| `test_pq_create_contract.sh` | `PqCreateContractTest` | `test_pq_create_contract.py` | `pq_create` KEYS/ARGV, OK/NOOP, `PQ` errors |
| `test_pq_read_contract.sh` | `PqReadContractTest` | `test_pq_read_contract.py` | `pq_read` FCALL_RO, NOTFOUND, EMALFORMED, 7-field return |
| `test_pq_validate_contract.sh` | `PqValidateContractTest` | `test_pq_validate_contract.py` | `pq_validate` VALID / `PQ EFIELD` |
| `test_pq_enqueue_contract.sh` | `PqEnqueueContractTest` | `test_pq_enqueue_contract.py` | `pq_enqueue` ZADD index, atomic write |
| `test_pq_dequeue_contract.sh` | `PqDequeueContractTest` | `test_pq_dequeue_contract.py` | `pq_dequeue` lease/fencing, VisibleAt gate |
| `test_pq_nack_contract.sh` | `PqNackContractTest` | `test_pq_nack_contract.py` | `pq_nack` requeue/backoff |
| `test_pq_peek_contract.sh` | `PqPeekContractTest` | `test_pq_peek_contract.py` | `pq_peek` FCALL_RO, no writes, both queues |
| `test_pq_reap_contract.sh` | `PqReapContractTest` | `test_pq_reap_contract.py` | `pq_reap` bounded delete, DeadLetteredAt |
| `test_pq_redrive_contract.sh` | `PqRedriveContractTest` | `test_pq_redrive_contract.py` | `pq_redrive` DLQ→main, reset RA/DLA |
| `test_pq_stats_contract.sh` | `PqStatsContractTest` | `test_pq_stats_contract.py` | `pq_stats` FCALL_RO aggregates |

### integration/ (16)

| Bash (`test_bash/integration/`) | Java (`pq.integration`) | Python (`test_python/integration/`) | Covers |
|---|---|---|---|
| `test_pq_create_roundtrip.sh` | `PqCreateRoundtripTest` | `test_pq_create_roundtrip.py` | create → read round trip |
| `test_pq_read_roundtrip.sh` | `PqReadRoundtripTest` | `test_pq_read_roundtrip.py` | read field fidelity |
| `test_pq_enqueue_roundtrip.sh` | `PqEnqueueRoundtripTest` | `test_pq_enqueue_roundtrip.py` | enqueue → index ordering |
| `test_pq_enqueue_conflict.sh` | `PqEnqueueConflictTest` | `test_pq_enqueue_conflict.py` | duplicate/conflict handling |
| `test_pq_dequeue_roundtrip.sh` | `PqDequeueRoundtripTest` | `test_pq_dequeue_roundtrip.py` | dequeue highest-priority-first |
| `test_pq_dequeue_visibility.sh` | `PqDequeueVisibilityTest` | `test_pq_dequeue_visibility.py` | visibility timeout / re-delivery |
| `test_pq_dequeue_concurrency.sh` | `PqDequeueConcurrencyTest` | `test_pq_dequeue_concurrency.py` | two consumers, no double-lease |
| `test_pq_dequeue_priority_interleave.sh` | `PqDequeuePriorityInterleaveTest` | `test_pq_dequeue_priority_interleave.py` | higher/lower priority inserted mid-consume |
| `test_pq_deadletter.sh` | `PqDeadletterTest` | `test_pq_deadletter.py` | cap at dequeue → DLQ |
| `test_pq_peek.sh` | `PqPeekTest` | `test_pq_peek.py` | non-destructive peek main + DLQ |
| `test_pq_redrive.sh` | `PqRedriveTest` | `test_pq_redrive.py` | redrive DLQ → main |
| `test_pq_retention.sh` | `PqRetentionTest` | `test_pq_retention.py` | reap expired DLQ entries |
| `test_pq_retry_backoff.sh` | `PqRetryBackoffTest` | `test_pq_retry_backoff.py` | nack backoff via VisibleAt |
| `test_pq_scheduled.sh` | `PqScheduledTest` | `test_pq_scheduled.py` | delayed visibility (not-before) |
| `test_pq_stats.sh` | `PqStatsTest` | `test_pq_stats.py` | stats over populated queues |
| `test_pq_visibility_compose.sh` | `PqVisibilityComposeTest` | `test_pq_visibility_compose.py` | composed visibility scenarios |

### unit/ (9)

| Bash (`test_bash/unit/`) | Java (`pq.unit`) | Python (`test_python/unit/`) | Covers |
|---|---|---|---|
| `test_pq_validation.sh` | `PqValidationTest` | `test_pq_validation.py` | field validation matrix |
| `test_pq_enqueue_validation.sh` | `PqEnqueueValidationTest` | `test_pq_enqueue_validation.py` | enqueue arg validation |
| `test_pq_dequeue_validation.sh` | `PqDequeueValidationTest` | `test_pq_dequeue_validation.py` | dequeue arg validation |
| `test_pq_nack_visibleat_validation.sh` | `PqNackVisibleAtValidationTest` | `test_pq_nack_visibleat_validation.py` | nack VisibleAt bounds (2^53 probe) |
| `test_pq_peek_validation.sh` | `PqPeekValidationTest` | `test_pq_peek_validation.py` | peek arg validation |
| `test_pq_reap_validation.sh` | `PqReapValidationTest` | `test_pq_reap_validation.py` | reap arg/limit validation |
| `test_pq_redrive_validation.sh` | `PqRedriveValidationTest` | `test_pq_redrive_validation.py` | redrive arg validation |
| `test_pq_stats_validation.sh` | `PqStatsValidationTest` | `test_pq_stats_validation.py` | stats arg validation |
| `test_pq_visibleat_field_validation.sh` | `PqVisibleAtFieldValidationTest` | `test_pq_visibleat_field_validation.py` | VisibleAt field validation |

**Totals**: 11 + 16 + 9 = **36** Bash suites → 36 Java classes → 36 Python modules.

## 4. Shared engine constants (`engines.env`)

| Key | Default | Meaning |
|---|---|---|
| `REDIS_IMAGE` | `redis:7.4` | standalone + cluster redis image |
| `VALKEY_IMAGE` | `valkey/valkey:8.0` | standalone + cluster valkey image |
| `REDIS_PORT` | `7379` | host port → redis standalone `6379` |
| `VALKEY_PORT` | `7380` | host port → valkey standalone `6379` |
| `REDIS_CLUSTER_PORT` | `7381` | host port → redis cluster node data port (announced) |
| `VALKEY_CLUSTER_PORT` | `7382` | host port → valkey cluster node data port (announced) |

All keys are env-overridable. Sourced by `docker_engines.sh`; read by Java `Properties` and Python
`conftest.py`. Bus ports (data `+10000`) are published/announced for the cluster nodes.
