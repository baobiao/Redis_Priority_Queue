# Phase 1 Contracts: Message Format Functions

Library name (for `FUNCTION LOAD`): **`message_format`**. All functions registered in `src/functions/message_format.lua`. Each contract states `KEYS[]`, `ARGV[]`, return shape, flags, and write/no-write status (Principle VIII).

Conventions:
- All keys passed via `KEYS[]`; never computed internally (Principle IV).
- `ARGV` for create is a flat list of `name value name value ...` pairs (field name then value), allowing any subset.
- Errors are returned via `redis.error_reply("MSGFMT <CODE>: <detail>")`; success statuses via `redis.status_reply(...)`.

---

## `msgfmt_create` — create & store a message

- **Write**: YES (no flags)
- **KEYS[1]**: the Hash key where the message is stored.
- **ARGV**: zero or more `field value` pairs. Recognised fields: `ReadAttempts`, `DirtyBit`, `ReadDateTime`, `Priority`, `Payload`. Omitted fields take defaults.
- **Behaviour**:
  1. Parse `ARGV` pairs. If `ARGV` length is odd → error `MSGFMT EARGS`.
  2. Reject any field name not in the closed set → error `MSGFMT EFIELD: <name>` (FR-012).
  3. Reject duplicate field names → error `MSGFMT EDUP: <name>`.
  4. Validate each supplied value per `data-model.md`. First invalid → error `MSGFMT EINVAL: <field>` and **nothing is stored** (FR-011).
  5. Apply defaults for omitted fields (FR-007).
  6. `HSET KEYS[1]` all five encoded fields in one call (FR-008, FR-017).
- **Returns**: `redis.status_reply("OK")` on success.
- **Contract examples**:
  - `FCALL msgfmt_create 1 q:{m1}` → stores all defaults, returns `OK`.
  - `FCALL msgfmt_create 1 q:{m1} Payload "hello" Priority 5` → stores Payload="hello", Priority=5, rest default, returns `OK`.
  - `FCALL msgfmt_create 1 q:{m1} ReadAttempts -1` → error `MSGFMT EINVAL: ReadAttempts`.
  - `FCALL msgfmt_create 1 q:{m1} Color red` → error `MSGFMT EFIELD: Color`.

---

## `msgfmt_read` — read a message into a typed shape

- **Write**: NO — flags `{ 'no-writes' }`, callable via `FCALL_RO` (Principle VII, FR-010).
- **KEYS[1]**: the Hash key to read.
- **ARGV**: none.
- **Behaviour**:
  1. If the key does not exist → return `redis.status_reply("NOTFOUND")` (FR-013).
  2. If the key exists but is not a Hash, or is missing required fields → error `MSGFMT EMALFORMED` (edge case).
  3. Otherwise read all fields, decode to logical types, and return them (FR-009).
- **Returns**: a flat array (RESP map-style) of field/value pairs, with values decoded:
  `["ReadAttempts", <int>, "DirtyBit", <0|1>, "ReadDateTime", <int>, "Priority", <int>, "Payload", <string>]`.
  Note: `DirtyBit` is returned as integer `1` (true) / `0` (false). It is deliberately **not** returned as a Lua boolean, because under RESP2 a Lua `false` serializes to a null reply — indistinguishable from "missing". Integer `0`/`1` is unambiguous on every protocol version.
- **Contract examples**:
  - `FCALL_RO msgfmt_read 1 q:{m1}` after default create → `["ReadAttempts",0,"DirtyBit",0,"ReadDateTime",0,"Priority",1000,"Payload",""]`.
  - `FCALL_RO msgfmt_read 1 q:{absent}` → status `NOTFOUND`.

---

## `msgfmt_validate` — validate candidate field values without storing

- **Write**: NO — flags `{ 'no-writes' }`, callable via `FCALL_RO`.
- **KEYS**: none (pure validation; no key access).
- **ARGV**: same `field value` pair format as `msgfmt_create`.
- **Behaviour**: runs the same parse + validation as `msgfmt_create` steps 1–4 but stores nothing.
- **Returns**: `redis.status_reply("VALID")` if all supplied values are valid and field names are recognised; otherwise the same structured `MSGFMT E...` error identifying the first problem.
- **Purpose**: lets callers/tests check inputs and lets future features reuse one validation routine. Read-only and side-effect-free.

---

## Cross-cutting contract guarantees

- Every function completes in a single `FCALL`/`FCALL_RO` (Principle VI, FR-017).
- No function calls any restricted/admin command (Principle V).
- No function computes a key name; the only key is `KEYS[1]` for create/read (Principle IV).
- Error replies are structured `redis.error_reply` strings prefixed `MSGFMT`; no uncaught Lua errors on the validated paths (Principle VIII).
