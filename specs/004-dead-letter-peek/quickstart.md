# Quickstart: Dead-Letter Handling and Peek

End-to-end walkthrough of Feature 004 against the Docker harness. Commands are shown as `redis-cli`
(the same works with `valkey-cli`). Keys share the hash tag `q1` so the source queue, the DLQ, and
every message Hash live in one cluster slot: source `pq:{q1}`, prefix `pq:{q1}:m:`, DLQ `dlq:{q1}`.

Load the library first:

```bash
redis-cli -x FUNCTION LOAD REPLACE < src/functions/message_format.lua
```

## 1. Enqueue a message

```bash
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:7 7 7 Priority 5 Payload "job-7"
# -> OK   (member 00000000000000000007:7 scored 5; hash at pq:{q1}:m:7)
```

## 2. Dead-letter a poison message (US1)

Dead-letter mode adds `KEYS[3]` = the DLQ and a trailing `cap` argument (after `now timeout max_scan`).
Drive `job-7` to the cap by dequeue→nack cycles, then watch the next dequeue set it aside.

```bash
# cap = 2. First two deliveries lease then fail (nack keeps ReadAttempts, clears DirtyBit).
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 0 2
# -> ["id","7", ... ,"ReadAttempts",1, ... ,"Payload","job-7"]
redis-cli FCALL msgfmt_nack 1 pq:{q1}:m:7 1                       # -> OK  (ReadAttempts stays 1)

redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 2000 30000 0 2
# -> ["id","7", ... ,"ReadAttempts",2, ... ,"Payload","job-7"]
redis-cli FCALL msgfmt_nack 1 pq:{q1}:m:7 2                       # -> OK  (ReadAttempts now 2 = cap)

# Next dequeue: job-7 is available with ReadAttempts(2) >= cap(2) -> moved to the DLQ, not returned.
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 3000 30000 0 2
# -> (nil)                          (source now empty; job-7 sits in dlq:{q1}, silently)
redis-cli ZSCORE dlq:{q1} 00000000000000000007:7      # -> "5"   (in the DLQ at its Priority)
redis-cli ZSCORE pq:{q1}  00000000000000000007:7      # -> (nil) (gone from the source)
redis-cli HGET   pq:{q1}:m:7 Payload                  # -> "job-7"  (hash untouched)
```

Omitting `KEYS[3]` and the cap (`FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: <now> <timeout>`) is exactly
Feature 003 — no dead-lettering.

## 3. Peek — inspect without consuming (US2)

`msgfmt_peek` is read-only (`FCALL_RO`). No `count` → the single next deliverable; `count=N` → the
front N with their state. It works on a source queue or a DLQ.

```bash
# Single mode on the DLQ: what would a dequeue of the DLQ hand out next? (job-7, unchanged)
redis-cli FCALL_RO msgfmt_peek 2 dlq:{q1} pq:{q1}:m: 4000 30000
# -> ["id","7","member","00000000000000000007:7","DirtyBit",0,"ReadAttempts",2,"ReadDateTime",2000,"Priority",5,"Payload","job-7"]

# Top-N mode: the front 10 DLQ entries with lease fields, priority-then-FIFO. Mutates nothing.
redis-cli FCALL_RO msgfmt_peek 2 dlq:{q1} pq:{q1}:m: 4000 30000 10
# -> [["id","7", ... ,"Payload","job-7"]]

# An empty/all-leased queue: single mode returns nil, top-N returns an empty array.
redis-cli FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 4000 30000     # -> (nil)
```

Verify peek changed nothing:

```bash
redis-cli HGET pq:{q1}:m:7 ReadAttempts    # -> "2"   (unchanged by peek)
redis-cli HGET pq:{q1}:m:7 DirtyBit        # -> "0"   (unchanged by peek)
```

## 4. Redrive — send it back for reprocessing (US3)

After fixing the failure cause, move `job-7` from the DLQ back to the source. All three keys are
passed literally (the id is known). Redrive resets `ReadAttempts`→0 and `DirtyBit`→0 and **retains**
`ReadDateTime`.

```bash
redis-cli FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:7 00000000000000000007:7
# -> OK
redis-cli ZSCORE pq:{q1}  00000000000000000007:7     # -> "5"    (back in the source at its Priority)
redis-cli ZSCORE dlq:{q1} 00000000000000000007:7     # -> (nil)  (gone from the DLQ)
redis-cli HMGET  pq:{q1}:m:7 ReadAttempts DirtyBit ReadDateTime
# -> 1) "0"   2) "0"   3) "2000"     (attempts reset, not in-flight, ReadDateTime retained)

# It is delivered again on the next dequeue and, with ReadAttempts=0, is below the cap.
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 5000 30000 0 2
# -> ["id","7", ... ,"ReadAttempts",1, ... ,"Payload","job-7"]

# Redriving something not in the DLQ is a safe NOOP.
redis-cli FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:7 00000000000000000007:7   # -> NOOP
```

## 5. Run the tests

```bash
tests/run_all.sh                      # both engines, all suites + static gate
ENGINES=redis tests/run_all.sh        # single engine
tests/harness/docker_engines.sh cluster-up   # cluster mode (co-located {q1} keys, no CROSSSLOT)
```
