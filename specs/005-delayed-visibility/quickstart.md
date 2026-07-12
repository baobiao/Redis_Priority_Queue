# Quickstart: Delayed Visibility

Walkthrough of scheduled delivery and retry backoff against the Docker harness. Commands shown as
`redis-cli` (same with `valkey-cli`). `now` and `VisibleAt` are epoch-ms values the caller supplies.

Load the library:

```bash
redis-cli -x FUNCTION LOAD REPLACE < src/functions/message_format.lua
```

## 1. Scheduled delivery (US1)

`VisibleAt` is just a field on enqueue — no new argument shape. Here message `9` is not deliverable
until epoch `60000`.

```bash
redis-cli DEL "pq:{q1}" "pq:{q1}:m:9" >/dev/null
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 9 Priority 5 Payload "later" VisibleAt 60000
# -> OK

# Before its time: dequeue skips it (queue looks empty).
redis-cli FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 59999 30000
# -> (nil)

# At/after its time: delivered normally.
redis-cli FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 60000 30000
# -> ["id","9","member","00000000000000000009:9","ReadAttempts",1,"ReadDateTime",60000,"Priority",5,"Payload","later"]
```

`VisibleAt` does not change priority order: a not-yet-visible high-priority message never blocks a
visible lower-priority one — dequeue simply scans past it.

## 2. Read shows VisibleAt; old messages still work (US3)

```bash
redis-cli FCALL msgfmt_create 1 q:{m1} Payload hi VisibleAt 90000 >/dev/null
redis-cli FCALL_RO msgfmt_read 1 q:{m1}
# -> ["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",0,"Priority",1000,"Payload","hi","VisibleAt",90000]

# A message written before Feature 005 (no VisibleAt field) reads as VisibleAt=0 (immediately visible):
redis-cli HSET legacy:{m} ReadAttempts 0 DirtyBit 0 ReadDateTime 0 Priority 1000 Payload old >/dev/null
redis-cli FCALL_RO msgfmt_read 1 legacy:{m}
# -> [... ,"Payload","old","VisibleAt",0]   (no error for the missing field)
```

## 3. Retry backoff (US2)

Lease a message, fail, and nack it with a future `VisibleAt` so it is retried only after a backoff.

```bash
redis-cli DEL "pq:{q2}" "pq:{q2}:m:1" >/dev/null
redis-cli FCALL msgfmt_enqueue 2 pq:{q2} pq:{q2}:m:1 1 1 Priority 5 Payload work >/dev/null

# Lease at now=1000 (ReadAttempts=1), then nack with a backoff to 5000.
redis-cli FCALL msgfmt_dequeue 2 pq:{q2} pq:{q2}:m: 1000 30000 >/dev/null
redis-cli FCALL msgfmt_nack 1 pq:{q2}:m:1 1 5000
# -> OK      (DirtyBit->0, VisibleAt=5000; ReadAttempts/ReadDateTime retained)

# Before the backoff elapses: not redelivered.
redis-cli FCALL msgfmt_dequeue 2 pq:{q2} pq:{q2}:m: 4999 30000
# -> (nil)

# After: redelivered, ReadAttempts incremented from the retained value.
redis-cli FCALL msgfmt_dequeue 2 pq:{q2} pq:{q2}:m: 5000 30000
# -> ["id","1", ... ,"ReadAttempts",2, ... ,"Payload","work"]

# A plain nack (no VisibleAt) is unchanged from Feature 003 (immediately available):
redis-cli FCALL msgfmt_nack 1 pq:{q2}:m:1 2          # -> OK
redis-cli FCALL msgfmt_nack 1 pq:{q2}:m:1 2 -5       # -> MSGFMT EVIS: visibleAt must be a non-negative integer
```

## 4. Peek honours / reports VisibleAt (US3)

```bash
# Single mode = what dequeue would lease next: skips not-yet-visible messages.
redis-cli FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 59999 30000
# -> (nil)      (message 9 not visible yet)

# Top-N reports it regardless, with its VisibleAt, for observability.
redis-cli FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 59999 30000 10
# -> [["id","9", ... ,"VisibleAt",60000]]
```

## 5. Redrive resets VisibleAt to 0 (US3)

A dead-lettered message that carried a `VisibleAt` is immediately deliverable after redrive:

```bash
# (message m was dead-lettered into dlq:{q1}; redrive it back)
redis-cli FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:9 00000000000000000009:9
# -> OK
redis-cli HMGET pq:{q1}:m:9 ReadAttempts DirtyBit VisibleAt
# -> 1) "0"  2) "0"  3) "0"     (VisibleAt reset -> visible now)
```

## 6. Run the tests

```bash
tests/run_all.sh                      # both engines, all suites + static gate
ENGINES=redis tests/run_all.sh        # single engine
tests/harness/docker_engines.sh cluster-up    # cluster mode (co-located {q1} keys)
```
