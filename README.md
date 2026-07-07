# Redis Priority Queue

A library of **server-side Lua functions** for **Redis / Valkey** that implements a
priority queue entirely inside the engine.

- Each **message** is stored as a **Hash** (`ReadAttempts`, `DirtyBit`, `ReadDateTime`,
  `Priority`, `Payload`).
- Each **queue** is a **Sorted Set** ordered by `Priority` — **lower score = higher
  priority = front of the queue**. FIFO among equal priorities is preserved by the
  member (a zero-padded caller-supplied `sequence`, then the caller-supplied `id`).
- The **same Lua source runs unmodified** on **Redis 7.0+**, **Valkey 7.2+**,
  **Amazon ElastiCache**, and **Amazon MemoryDB**.
- It is deployed with `FUNCTION LOAD` and invoked with `FCALL` (writes) / `FCALL_RO`
  (reads). Every key is caller-supplied; the library never invents keys.

The current library exposes four functions: `msgfmt_create`, `msgfmt_enqueue`,
`msgfmt_read`, and `msgfmt_validate`.

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
redis-cli FUNCTION LIST   # msgfmt_create, msgfmt_read, msgfmt_validate, msgfmt_enqueue
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

### Create a standalone message (no queue index)

```bash
# All defaults: ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, Payload=""
redis-cli FCALL msgfmt_create 1 q:{m1}
# -> OK
redis-cli FCALL msgfmt_create 1 q:{m2} Payload "order-42" Priority 5
# -> OK
```

`msgfmt_read` and `msgfmt_validate` are `no-writes` and callable with `FCALL_RO`;
`msgfmt_create` and `msgfmt_enqueue` are writes and are rejected under `FCALL_RO`. All
failures return a structured `MSGFMT E...` error, and enqueue is fail-before-write —
nothing is written to either structure on error.

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
├── specs/                        # feature specs (001-message-format, 002-enqueue)
└── tests/
    ├── run_all.sh                # convenience runner (all suites + static gate)
    ├── harness/                  # docker_engines.sh, load_and_call.sh, static_checks.sh
    ├── contract/                 # KEYS/ARGV/return-shape/flags assertions
    ├── integration/              # end-to-end behaviour (roundtrip, conflict)
    └── unit/                     # validation edge cases
```
