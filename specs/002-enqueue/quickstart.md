# Quickstart: Enqueue

This feature extends the Redis/Valkey **Functions** library (`message_format`) with
`msgfmt_enqueue`, which stores a message (Feature 001 format) and indexes it in a
priority-ordered Sorted Set — in one atomic call. It runs identically on Redis 7.0+,
Valkey 7.2+, ElastiCache, and MemoryDB.

## Prerequisites

- Docker CLI (for the local test harness — official `redis` and `valkey` images)
- A Redis client (`redis-cli`) for manual exercise

## Load the library

```bash
redis-cli FUNCTION LOAD REPLACE "$(cat src/functions/message_format.lua)"
redis-cli FUNCTION LIST   # msgfmt_create, msgfmt_read, msgfmt_validate, msgfmt_enqueue
```

## Enqueue messages onto a priority queue

`KEYS`: `1`=queue Sorted Set, `2`=message Hash (same slot via a shared hash tag).
`ARGV`: `id`, `sequence`, then optional `field value` pairs.

```bash
# Queue "q1": both keys share the {q1} hash tag so they land in one slot.
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:1 1 1 Payload "low"   Priority 1000
# -> OK
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:2 2 2 Payload "high"  Priority 5
# -> OK
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:3 3 3 Payload "mid"   Priority 100
# -> OK
```

## Inspect priority ordering (highest priority = lowest score = front)

```bash
redis-cli ZRANGE pq:{q1} 0 -1 WITHSCORES
# 1) "00000000000000000002:2"   2) "5"      <- highest priority (Priority 5)
# 3) "00000000000000000003:3"   4) "100"
# 5) "00000000000000000001:1"   6) "1000"   <- lowest priority
```

## FIFO among equal priorities

```bash
# ARGV order is id, sequence, then field/value pairs. Same Priority (50), different sequence.
redis-cli FCALL msgfmt_enqueue 2 pq:{q2} pq:{q2}:m:a a 10 Priority 50
redis-cli FCALL msgfmt_enqueue 2 pq:{q2} pq:{q2}:m:b b 11 Priority 50
redis-cli ZRANGE pq:{q2} 0 -1
# 1) "00000000000000000010:a"   <- earlier sequence first (FIFO)
# 2) "00000000000000000011:b"
```

## The stored message is a Feature 001 Hash

```bash
redis-cli FCALL_RO msgfmt_read 1 pq:{q1}:m:2
# -> ["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",0,"Priority",5,"Payload","high"]
```

## Errors (nothing is written on failure)

```bash
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:1 1 1
# -> (error) MSGFMT EEXISTS: message location occupied   (m:1 already stored above)

redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 -1
# -> (error) MSGFMT ESEQ: sequence must be a non-negative integer

redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 2 Priority foo
# -> (error) MSGFMT EINVAL: Priority

redis-cli SET pq:{bad} notazset
redis-cli FCALL msgfmt_enqueue 2 pq:{bad} pq:{bad}:m:1 1 1
# -> (error) MSGFMT EMALFORMED: queue is not a sorted set
```

## Run the tests (real engines, both modes)

```bash
tests/harness/docker_engines.sh up
# then the contract/integration/unit suites for enqueue, across redis and valkey
```

## Notes

- Both keys are always supplied by you; the library never invents keys. Use a shared hash tag
  (`{q1}`) so the queue and its messages occupy one cluster slot.
- The `id` and `sequence` are caller-supplied; the function generates nothing
  non-deterministic (Principle VII). Supply a per-queue monotonic `sequence` for correct FIFO.
- `msgfmt_enqueue` is a write; it is rejected under `FCALL_RO`.
