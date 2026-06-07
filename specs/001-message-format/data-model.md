# Phase 1 Data Model: Message Format

## Entity: Message

A single queue message, stored as one Redis/Valkey **Hash** at a caller-supplied key (`KEYS[1]`). One Hash = one message. No relationships to other messages in this feature.

### Fields

| Field | Logical type | Default | Stored as (Hash field value) | Validation rule |
|-------|--------------|---------|------------------------------|-----------------|
| `ReadAttempts` | Integer ≥ 0 | `0` | decimal string, e.g. `"0"` | `tonumber` succeeds, finite, `floor(n)==n`, `n >= 0` |
| `DirtyBit` | Boolean | `false` | `"0"` (false) / `"1"` (true) | input ∈ {`0`,`1`,`true`,`false`} case-insensitive |
| `ReadDateTime` | Integer ≥ 0 (epoch ms) | `0` | decimal string, e.g. `"0"` | `tonumber` succeeds, finite, `floor(n)==n`, `n >= 0`, ≤ 2^53 |
| `Priority` | Integer | `1000` | decimal string, e.g. `"1000"` | `tonumber` succeeds, finite, `floor(n)==n`, `|n|` ≤ 2^53 |
| `Payload` | String | `""` | raw byte string | always valid (any string, incl. empty) |

- **Field set is closed**: exactly these five fields. Supplying any other attribute name on create is an error (FR-012).
- **Semantics**: `DirtyBit` marks in-flight/modified; `ReadDateTime` 0 = never read; lower `Priority` = higher priority (ordering not implemented here).

### Storage key

- The Hash key is **always** provided by the caller as `KEYS[1]`. The library never computes, derives, or hardcodes it (Principle IV). A single message touches exactly one key, so no cross-slot concern arises.

### Encoding / decoding rules (round-trip)

- **Write**: each logical value is converted to its stored string form (boolean → `"0"`/`"1"`, number → decimal string, string → as-is) and written with a single `HSET` of all five fields.
- **Read**: each stored field is decoded back to its logical type (`"1"`/`"0"` → `true`/`false`; numeric strings → `tonumber`; payload → as-is). Round-trip is lossless for all in-range values (FR-014, FR-015).

### Lifecycle / state

This feature defines only **create** and **read**; there are no state transitions yet. (Future features will mutate `ReadAttempts`, `DirtyBit`, `ReadDateTime`.) A message location is either:

- **absent** — no Hash at the key → read returns a "not found" status, and
- **present & well-formed** — a Hash with the five fields → read returns the typed message.
- **present & malformed / wrong type** — key holds a non-Hash value or an incomplete Hash → read returns a structured error (edge case), never silently corrupted fields.
