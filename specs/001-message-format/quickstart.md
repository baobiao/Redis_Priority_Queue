# Quickstart: Message Format

This feature ships a Redis/Valkey **Functions** library (`message_format`) written in Lua. It runs identically on Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB.

## Prerequisites

- Docker CLI (for the local test harness — official `redis` and `valkey` images)
- A Redis client (`redis-cli`) for manual exercise

## Load the library

```bash
# Load (or replace) the function library
redis-cli FUNCTION LOAD REPLACE "$(cat src/functions/message_format.lua)"

# Confirm it registered
redis-cli FUNCTION LIST
```

## Create a message (defaults)

```bash
# All defaults: ReadAttempts=0, DirtyBit=false, ReadDateTime=0, Priority=1000, Payload=""
redis-cli FCALL msgfmt_create 1 q:{m1}
# -> OK
```

## Create a message (explicit values)

```bash
redis-cli FCALL msgfmt_create 1 q:{m2} Payload "order-42" Priority 5 ReadDateTime 1700000000000
# -> OK
```

## Read a message (read-only)

```bash
redis-cli FCALL_RO msgfmt_read 1 q:{m2}
# -> ["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",1700000000000,"Priority",5,"Payload","order-42"]
#    (DirtyBit is integer 0/1 — see contracts/functions.md)

redis-cli FCALL_RO msgfmt_read 1 q:{absent}
# -> NOTFOUND
```

## Validation errors

```bash
redis-cli FCALL msgfmt_create 1 q:{bad} ReadAttempts -1
# -> (error) MSGFMT EINVAL: ReadAttempts

redis-cli FCALL msgfmt_create 1 q:{bad} Color red
# -> (error) MSGFMT EFIELD: Color

redis-cli FCALL_RO msgfmt_validate 0 DirtyBit maybe
# -> (error) MSGFMT EINVAL: DirtyBit
```

## Run the tests (real engines, both modes)

```bash
# Spins up Redis 7.0+ and Valkey 7.2+ containers (standalone + cluster),
# FUNCTION LOADs the library, and asserts FCALL/FCALL_RO responses.
tests/harness/docker_engines.sh up
# then the contract/integration/unit suites
```

## Notes

- The Hash key (`q:{m1}` above) is always supplied by you; the library never invents keys. Use a hash tag (`{...}`) to control slot placement in cluster mode.
- `msgfmt_read` and `msgfmt_validate` are `no-writes` and callable with `FCALL_RO`.
