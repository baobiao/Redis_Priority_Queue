# Quickstart: DLQ Retention & Observability

Walkthrough against the Docker harness. Commands shown as `redis-cli` (same with `valkey-cli`). All
keys share the hash tag `q1`: source `pq:{q1}`, prefix `pq:{q1}:m:`, DLQ `dlq:{q1}`. `now`, the
retention window, and the scan limits are caller-supplied (no server clock).

Load the library:

```bash
redis-cli -x FUNCTION LOAD REPLACE < src/functions/message_format.lua
```

## 1. Dead-lettering now records DeadLetteredAt (US1)

```bash
redis-cli DEL "pq:{q1}" "dlq:{q1}" "pq:{q1}:m:7" >/dev/null
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:7 7 7 Priority 5 Payload job >/dev/null
# Drive it over a cap of 1 (deliver once, nack), then dead-letter it at now=100000.
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 0 1 >/dev/null
redis-cli FCALL msgfmt_nack 1 pq:{q1}:m:7 1 >/dev/null
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 100000 30000 0 1 >/dev/null   # -> (nil); dead-lettered
redis-cli HGET pq:{q1}:m:7 DeadLetteredAt      # -> "100000"   (stamped at dead-letter time)
redis-cli FCALL_RO msgfmt_read 1 pq:{q1}:m:7 | tail -2   # -> "DeadLetteredAt" / "100000"
```

## 2. Reap expired dead-lettered messages (US1)

`msgfmt_reap` permanently removes DLQ entries whose age exceeds the retention window (member + Hash),
bounded by a per-call `limit`, returning `{removed, scanned, truncated}`.

```bash
m7=$(printf '%020d:%s' 7 7)
# retention=30000. At now=120000, age = 120000-100000 = 20000 < 30000 -> NOT expired.
redis-cli FCALL msgfmt_reap 2 dlq:{q1} pq:{q1}:m: 120000 30000 100
# -> ["removed",0,"scanned",1,"truncated",0]
redis-cli ZSCORE dlq:{q1} "$m7"    # -> "5"   (still there)

# At now=140000, age = 40000 >= 30000 -> expired -> removed (member + Hash).
redis-cli FCALL msgfmt_reap 2 dlq:{q1} pq:{q1}:m: 140000 30000 100
# -> ["removed",1,"scanned",1,"truncated",0]
redis-cli ZSCORE dlq:{q1} "$m7"    # -> (nil)   (gone from the DLQ)
redis-cli EXISTS pq:{q1}:m:7       # -> 0        (Hash deleted)
```

Draining note: reap examines the DLQ front in **Priority** order. To fully drain a large DLQ, size
`limit` to its depth (from `msgfmt_stats`, below) or loop.

## 3. Redrive clears DeadLetteredAt (US1)

```bash
# (message m dead-lettered into dlq:{q1}) redrive it back:
redis-cli FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:8 "$(printf '%020d:%s' 8 8)"
redis-cli HMGET pq:{q1}:m:8 ReadAttempts DirtyBit VisibleAt DeadLetteredAt
# -> 1) "0"  2) "0"  3) "0"  4) "0"     (DeadLetteredAt cleared -> no longer dead-lettered)
```

## 4. Observe queue state without consuming (US2)

`msgfmt_stats` is read-only (`FCALL_RO`). Cheap tier (depths + front Priority) always; add a scan
limit for a bounded state breakdown + approximate oldest-dead-letter age.

```bash
# Cheap tier: KEYS = queue, prefix, DLQ ; ARGV = now, timeout.
redis-cli FCALL_RO msgfmt_stats 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000
# -> ["depth",<n>,"dlq_depth",<n>,"front_priority",<p>]     (O(1) depths)

# Bounded breakdown: add a max_scan. Classifies the scanned front as available / in-flight / delayed,
# with truncated=1 if the queue is larger than max_scan; plus an approx oldest DLQ age.
redis-cli FCALL_RO msgfmt_stats 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 100
# -> ["depth",<n>,"dlq_depth",<n>,"front_priority",<p>,"scanned",<n>,"truncated",0,
#     "available",<a>,"in_flight",<i>,"delayed",<d>,"skipped",0,
#     "dlq_scanned",<n>,"oldest_dead_letter_age",<ms>,"age_truncated",0]
```

`msgfmt_stats` mutates nothing (verify any message's fields are unchanged after a call) and never
removes dangling members (that is `msgfmt_reap`'s job).

## 5. Run the tests

```bash
tests/run_all.sh                      # both engines, all suites + static gate
ENGINES=redis tests/run_all.sh        # single engine
tests/harness/docker_engines.sh cluster-up    # cluster mode (co-located {q1} keys)
```
