# Quickstart: Dequeue

End-to-end walkthrough of the consume lifecycle, runnable against a loaded `message_format`
library. Commands are shown as `redis-cli`/`valkey-cli` `FCALL` calls; run them inside a
container via the harness (`tests/harness/load_and_call.sh`). All keys for one queue share the
hash tag `{q1}`: queue `pq:{q1}`, message-key prefix `pq:{q1}:m:`, message Hashes
`pq:{q1}:m:<id>`.

Prerequisite: the library is loaded (`FUNCTION LOAD`) and Features 001/002 are present.

## 1. Enqueue three messages (Feature 002)

`ARGV` = `id sequence [field value ...]`. Lower `Priority` = higher priority.

```
FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:a  a 1 Priority 10 Payload "task-a"   -> OK
FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:b  b 2 Priority 5  Payload "task-b"   -> OK
FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:c  c 3 Priority 10 Payload "task-c"   -> OK
```

Order now: `b` (priority 5), then `a` (priority 10, seq 1), then `c` (priority 10, seq 2).

## 2. Acquire the front message

`KEYS` = `queue prefix`; `ARGV` = `now timeout [max_scan]`. Here `now=1000` ms, `timeout=30000` ms.

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","b","member","00000000000000000002:b","ReadAttempts",1,
      "ReadDateTime",1000,"Priority",5,"Payload","task-b"]
```

`b` is now leased: `DirtyBit=1`, `ReadDateTime=1000`, `ReadAttempts=1`. The fencing **token = 1**.
A concurrent acquire skips `b` and returns `a` next:

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","a",...,"ReadAttempts",1,"ReadDateTime",1000,"Priority",10,"Payload","task-a"]
```

## 3a. Acknowledge on success (delete)

`KEYS` = `queue messageHash`; `ARGV` = `member token`.

```
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:b 00000000000000000002:b 1   -> OK
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:b 00000000000000000002:b 1   -> NOOP   (idempotent retry)
FCALL_RO msgfmt_read 1 pq:{q1}:m:b                                -> NOTFOUND
```

`b` is gone from both the queue index and storage; it will never be dequeued again.

## 3b. Negative-acknowledge on failure (release)

Release `a` (token 1). `KEYS` = `messageHash`; `ARGV` = `token`.

```
FCALL msgfmt_nack 1 pq:{q1}:m:a 1   -> OK
```

`a` is available again at its original position, with `ReadAttempts` retained at 1:

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 2000 30000
  -> ["id","a",...,"ReadAttempts",2,"ReadDateTime",2000,"Priority",10,"Payload","task-a"]
```

Now the token for `a` is **2**; the old token 1 is stale.

## 4. Empty / all-in-flight queue returns null

Continuing the timeline (after §3: `a` is leased again with token 2, `b` was acked/removed, and
`c` is still available), acquire the last available message `c`; after that nothing is available:

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 2000 30000
  -> ["id","c","member","00000000000000000003:c","ReadAttempts",1,
      "ReadDateTime",2000,"Priority",10,"Payload","task-c"]
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 2000 30000
  -> (nil)          # a and c in-flight, b removed — nothing available
```

Null means "nothing available now" — distinct from a hit whose `Payload` is an empty string.

## 5. Visibility-timeout reclaim + fencing (crash recovery)

This scenario uses a **fresh queue** to show reclaim in isolation: assume `pq:{q1}` holds a single
message `c` (sequence 3, priority 10), available. Consumer A acquires it at `now=1000` with
`timeout=30000`, then crashes without settling:

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
  -> ["id","c",...,"ReadAttempts",1,"ReadDateTime",1000,...]      # A's token = 1
```

Before the timeout (`now < 31000`) another acquire skips `c`:

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 5000 30000   -> (nil)   # c still leased
```

At/after the timeout, consumer B reclaims `c` (`now=31000 ≥ 1000+30000`):

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 31000 30000
  -> ["id","c",...,"ReadAttempts",2,"ReadDateTime",31000,...]     # B's token = 2
```

If crashed consumer A revives and tries to settle with its stale token 1, fencing rejects it and
B's lease is untouched:

```
FCALL msgfmt_ack  2 pq:{q1} pq:{q1}:m:c 00000000000000000003:c 1  -> MSGFMT EFENCED: lease superseded
FCALL msgfmt_nack 1 pq:{q1}:m:c 1                                 -> MSGFMT EFENCED: lease superseded
```

B settles normally with token 2:

```
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:c 00000000000000000003:c 2   -> OK
```

## 6. Error cases (fail-before-write)

```
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: -1 30000     -> MSGFMT ENOW: now must be a non-negative integer
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 0       -> MSGFMT ETMO: timeout must be a positive integer
FCALL msgfmt_dequeue 2 pq:{q1} pq:{q2}:m: 1000 30000   -> MSGFMT ETAG: queue and message-key prefix must share one hash tag
FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:a 00000000000000000001:a 1  (after a is available)
                                                       -> MSGFMT ENOTLEASED: message not in-flight
```

None of these modify the queue or any message.

## Cluster note

On a cluster, the queue key, the message-key prefix, and every message Hash MUST share one hash
tag (here `{q1}`) so all keys — including the runtime-constructed `pq:{q1}:m:<id>` — map to one
slot. Mismatched tags yield `MSGFMT ETAG` (caught by the function) or `CROSSSLOT` (caught by the
engine). During slot resharding a call may transiently return `TRYAGAIN`/`ASK`; retry.
