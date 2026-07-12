# Redis Priority Queue

A library of **server-side Lua functions** for **Redis / Valkey** that implements a
priority queue entirely inside the engine.

- Each **message** is stored as a **Hash** (`ReadAttempts`, `DirtyBit`, `ReadDateTime`,
  `Priority`, `Payload`).
- Each **queue** is a **Sorted Set** ordered by `Priority` — **lower score = higher
  priority = front of the queue**. FIFO among equal priorities is preserved by the
  member (a zero-padded caller-supplied `sequence`, then the caller-supplied `id`).
- A **consumer** leases the highest-priority available message with `msgfmt_dequeue`
  (marking it in-flight via `DirtyBit`, stamping `ReadDateTime`, incrementing
  `ReadAttempts`), then settles it with `msgfmt_ack` (delete on success) or `msgfmt_nack`
  (release for redelivery on failure). An unsettled lease is reclaimed after a
  caller-supplied **visibility timeout**, and a **fencing token** stops a stale consumer
  from settling a message that has since been reacquired.
- **Poison messages** are capped: with an optional dead-letter queue and a maximum-delivery
  cap, `msgfmt_dequeue` moves an over-cap message aside to a **dead-letter queue** instead of
  redelivering it; `msgfmt_redrive` sends one back to the source, and `msgfmt_peek` inspects any
  queue read-only (single next-deliverable, or a top-N view).
- **Delayed visibility** (`VisibleAt`, a not-before time): a message can be **scheduled** for future
  delivery (enqueue with `VisibleAt`) or released with a **retry backoff** (nack with a `VisibleAt`),
  and is skipped by consumers until `now ≥ VisibleAt`. This is distinct from the lease *visibility
  timeout* above.
- The **same Lua source runs unmodified** on **Redis 7.0+**, **Valkey 7.2+**,
  **Amazon ElastiCache**, and **Amazon MemoryDB**.
- It is deployed with `FUNCTION LOAD` and invoked with `FCALL` (writes) / `FCALL_RO`
  (reads). Every key is caller-supplied via `KEYS[]`; the one sanctioned exception is the
  runtime key construction `msgfmt_dequeue`/`msgfmt_peek` use to reach a message discovered by
  scanning — appending the runtime `id` to a caller-supplied, co-located key **prefix**
  (constitution Principle IV, amended in v2.0.0).

The current library exposes nine functions: `msgfmt_ack`, `msgfmt_create`, `msgfmt_dequeue`,
`msgfmt_enqueue`, `msgfmt_nack`, `msgfmt_peek`, `msgfmt_read`, `msgfmt_redrive`, and
`msgfmt_validate`.

See [`docs/schema.md`](docs/schema.md) for the message schema and the native types, and
[`docs/functions.md`](docs/functions.md) for every function's `KEYS` / `ARGV` / return
contract.

## Prerequisites

To modify or test the library locally you need:

- **A Docker runtime** (the Docker CLI). The test harness pulls the official engine
  images and runs everything in containers.
- **A Redis / Valkey command-line client** — but **it does not need to be installed on
  your host**. The harness runs `redis-cli` / `valkey-cli` **inside** the official
  container images via `docker exec`, auto-selecting whichever client the image ships.
  (Install one on the host only if you want to point a client at a remote engine
  yourself.)
- **A POSIX `bash` shell** to run the harness scripts (they are `bash`, not `zsh`).

The harness pins the images **`redis:7.4`** and **`valkey/valkey:8.0`**; override them
with the `REDIS_IMAGE` / `VALKEY_IMAGE` environment variables. **The Docker daemon must
be running** before you invoke any of the commands below.

## Load and use

Load (or replace) the library, then confirm it registered:

```bash
redis-cli FUNCTION LOAD REPLACE "$(cat src/functions/message_format.lua)"
redis-cli FUNCTION LIST   # msgfmt_create/read/validate/enqueue/dequeue/ack/nack
```

### Enqueue onto a priority queue

`KEYS`: `1` = queue Sorted Set, `2` = message Hash (share a hash tag so both keys land in
one cluster slot). `ARGV`: `id`, `sequence`, then optional `field value` pairs.

```bash
# Queue "q1": both keys share the {q1} hash tag so they land in one slot.
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:1 1 1 Payload "low"  Priority 1000
# -> OK
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:2 2 2 Payload "high" Priority 5
# -> OK
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:3 3 3 Payload "mid"  Priority 100
# -> OK
```

### Inspect priority ordering (highest priority = lowest score = front)

```bash
redis-cli ZRANGE pq:{q1} 0 -1 WITHSCORES
# 1) "00000000000000000002:2"   2) "5"      <- highest priority (Priority 5)
# 3) "00000000000000000003:3"   4) "100"
# 5) "00000000000000000001:1"   6) "1000"   <- lowest priority
```

### Read the stored message (Feature 001 Hash)

```bash
redis-cli FCALL_RO msgfmt_read 1 pq:{q1}:m:2
# -> ["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",0,"Priority",5,"Payload","high"]
```

### Dequeue, process, and settle

`msgfmt_dequeue` `KEYS`: `1` = queue Sorted Set, `2` = message-key **prefix** (same hash tag
as the queue). `ARGV`: `now` (epoch ms), `timeout` (visibility ms), optional `max_scan`. It
returns a handle (or a null reply when nothing is available).

```bash
# Lease the highest-priority available message (now=1000ms, visibility=30000ms).
redis-cli FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 1000 30000
# -> ["id","2","member","00000000000000000002:2","ReadAttempts",1,
#     "ReadDateTime",1000,"Priority",5,"Payload","high"]
```

The message is now in-flight (`DirtyBit=1`); other consumers skip it until it is settled or
its lease expires. `ReadAttempts` (here `1`) is the **fencing token** — pass it back to settle.

```bash
# On success: delete it (KEYS: queue, message hash; ARGV: member, token).
redis-cli FCALL msgfmt_ack 2 pq:{q1} pq:{q1}:m:2 00000000000000000002:2 1
# -> OK    (a retry returns NOOP)

# On failure: release it for redelivery (KEYS: message hash; ARGV: token).
redis-cli FCALL msgfmt_nack 1 pq:{q1}:m:2 1
# -> OK    (DirtyBit back to 0; ReadDateTime/ReadAttempts retained)
```

If a consumer crashes without settling, the next `msgfmt_dequeue` whose `now` is at least
`timeout` past the lease's `ReadDateTime` reclaims the message (incrementing `ReadAttempts`
and issuing a new token); the crashed consumer's old token is then rejected with
`MSGFMT EFENCED`.

### Dead-letter poison messages (optional)

A message that always fails is redelivered indefinitely. To cap that, pass an extra key
(`KEYS[3]` = a dead-letter Sorted Set, same hash tag) and a trailing `cap` argument. When
`msgfmt_dequeue` reaches an available message whose `ReadAttempts` has already reached the cap,
it moves that message to the dead-letter queue instead of delivering it, and returns the next
deliverable message (silently). The message Hash is left in place; only the index moves.

```bash
# Dead-letter mode: max 5 deliveries. Pass max_scan (0 = unbounded) then the cap.
redis-cli FCALL msgfmt_dequeue 3 pq:{q1} pq:{q1}:m: dlq:{q1} 1000 30000 0 5
# -> the next deliverable handle, or (nil); any front message with ReadAttempts>=5
#    is moved to dlq:{q1} at its Priority (verbatim member) on the way.
```

Omitting `KEYS[3]` and the cap makes `msgfmt_dequeue` behave exactly as the 2-key call above.

### Inspect a queue without consuming (peek)

`msgfmt_peek` is read-only (`FCALL_RO`). With no `count` it returns the single message a dequeue
would lease next (lease-aware); with a `count` it returns the front N entries and their state,
regardless of lease. It works on a source queue or a dead-letter queue and mutates nothing.

```bash
# The next deliverable message (no mutation):
redis-cli FCALL_RO msgfmt_peek 2 pq:{q1} pq:{q1}:m: 1000 30000
# The front 10 entries of the DLQ with their lease fields:
redis-cli FCALL_RO msgfmt_peek 2 dlq:{q1} pq:{q1}:m: 1000 30000 10
```

### Redrive a message from the dead-letter queue

`msgfmt_redrive` moves one message from a DLQ back to its source and resets its delivery state
(`ReadAttempts=0`, `DirtyBit=0`, `ReadDateTime` retained) so it is reprocessed from a clean slate.

```bash
# KEYS: DLQ, source queue, the message hash (all same tag). ARGV: the member string.
redis-cli FCALL msgfmt_redrive 3 dlq:{q1} pq:{q1} pq:{q1}:m:7 00000000000000000007:7
# -> OK   (back in pq:{q1} at its Priority; NOOP if it was not in the DLQ; VisibleAt reset to 0)
```

### Schedule a message for the future (delayed visibility)

`VisibleAt` (epoch ms; `0` = immediately visible) is a **not-before** time — the message is skipped
by consumers until `now ≥ VisibleAt`. It is just a field on enqueue (no new argument). This is
**distinct** from the lease *visibility timeout*.

```bash
# Deliverable only at/after now=60000.
redis-cli FCALL msgfmt_enqueue 2 pq:{q1} pq:{q1}:m:9 9 9 Priority 5 Payload later VisibleAt 60000
redis-cli FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 59999 30000   # -> (nil)   (not visible yet)
redis-cli FCALL msgfmt_dequeue 2 pq:{q1} pq:{q1}:m: 60000 30000   # -> ["id","9", ...]   (now visible)
```

### Retry with a backoff delay

Nack a failed message with a `VisibleAt` (a 2nd `ARGV` after the token) so it is redelivered only
after a backoff — instead of immediately. The caller computes `VisibleAt = now + delay`.

```bash
# ... after leasing the message (token = 1) and failing to process it:
redis-cli FCALL msgfmt_nack 1 pq:{q1}:m:9 1 90000
# -> OK   (released now, but hidden until now >= 90000; ReadDateTime/ReadAttempts retained)
```

### Create a standalone message (no queue index)

```bash
# All defaults: ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, Payload=""
redis-cli FCALL msgfmt_create 1 q:{m1}
# -> OK
redis-cli FCALL msgfmt_create 1 q:{m2} Payload "order-42" Priority 5
# -> OK
```

`msgfmt_read`, `msgfmt_validate`, and `msgfmt_peek` are `no-writes` and callable with `FCALL_RO`;
`msgfmt_create`, `msgfmt_enqueue`, `msgfmt_dequeue`, `msgfmt_ack`, `msgfmt_nack`, and
`msgfmt_redrive` are writes and are rejected under `FCALL_RO`. All failures return a structured
`MSGFMT E...` error, and every write is fail-before-write — nothing is written on any error.

## Run the tests locally

The suites bring the engines up on demand (idempotent), `FUNCTION LOAD` the library, and
assert on `FCALL` / `FCALL_RO` responses. Everything runs in Docker.

```bash
# All contract/integration/unit suites on redis + valkey, then the static portability gate
tests/run_all.sh

# Single engine
ENGINES=redis tests/run_all.sh

# Skip the static portability gate
tests/run_all.sh --no-static

# Run one suite directly
bash tests/integration/test_msgfmt_enqueue_roundtrip.sh

# Cluster mode (single-shard cluster per engine, best effort)
bash tests/harness/docker_engines.sh cluster-up

# Tear the standalone engines down when finished
bash tests/harness/docker_engines.sh down
```

## Repository layout

```text
.
├── README.md                     # this file
├── docs/
│   ├── schema.md                 # message schema + native types (Hash + Sorted Set)
│   └── functions.md              # every library function (public FCALL-able first, then helpers)
├── src/
│   └── functions/
│       └── message_format.lua    # the Redis/Valkey Functions library (Lua)
├── specs/                        # feature specs (001-message-format, 002-enqueue, 003-dequeue)
└── tests/
    ├── run_all.sh                # convenience runner (all suites + static gate)
    ├── harness/                  # docker_engines.sh, load_and_call.sh, static_checks.sh
    ├── contract/                 # KEYS/ARGV/return-shape/flags assertions
    ├── integration/              # end-to-end behaviour (enqueue roundtrip/conflict; dequeue roundtrip/concurrency/visibility)
    └── unit/                     # validation edge cases
```
