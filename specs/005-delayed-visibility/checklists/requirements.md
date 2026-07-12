# Specification Quality Checklist: Delayed Visibility (Scheduled Delivery & Retry Backoff)

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-12
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Design forks resolved by the user before drafting: mechanism = **A** (a sixth `VisibleAt` Hash
  field + skip-in-scan, not a separate scheduled Sorted Set); time input = **absolute `VisibleAt`
  epoch** (not a relative delay); set points = **both enqueue (scheduled) and nack (retry backoff)**;
  redrive **resets `VisibleAt` to 0**.
- Fixed assumption (only non-breaking choice): a **missing `VisibleAt` is treated as `0`** /
  immediately visible, so messages stored by Features 001–004 keep working without migration —
  `msgfmt_read`'s current strict 5-field check must be relaxed for `VisibleAt` only.
- Grounded by sub-agents: **no constitution change** (no principle closes the schema at five fields;
  Principle X mandates the docs update, which is compliance not amendment) and **no static-gate
  change** (only `HSET`/`HMGET`/`HGET` used; the whitelist is command-name-only; the determinism scan
  does not trip on a `now`-vs-`VisibleAt` comparison; the whole-file scan covers new/edited functions).
- Content-quality note: consistent with the house style of specs 002–004, the spec names native
  types (Hash, Sorted Set) and the message field names, because the "users" are Redis/Valkey
  developers and Principle VIII mandates explicit KEYS/ARGV contracts. Exact wire-level `KEYS`/`ARGV`
  and the `VisibleAt`/nack error code are fixed in `contracts/functions.md` at planning time.
- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.
