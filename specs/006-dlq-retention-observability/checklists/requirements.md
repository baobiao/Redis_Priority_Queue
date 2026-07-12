# Specification Quality Checklist: DLQ Retention & Observability

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

- Design forks resolved by the user before drafting: retention mechanism = **A** (a 7th `DeadLetteredAt`
  Hash field stamped at dead-letter + an explicit bounded `msgfmt_reap`), NOT a time-scored DLQ (B) or
  native `PEXPIRE` TTL (C); observability = **cheap aggregates + an optional bounded state breakdown**;
  **age metric included** (approximate/bounded under mechanism A).
- Fixed assumptions: redrive clears `DeadLetteredAt`; retention is DLQ-only; `msgfmt_reap` is a WRITE,
  `msgfmt_stats` is `no-writes`/FCALL_RO; missing `DeadLetteredAt` coalesces to `0` (back-compat).
- **Honest design limitation recorded** (Edge Cases + Assumptions): because mechanism A keeps the DLQ
  Priority-ordered, a small fixed-`limit` reap cannot reach expired low-priority entries behind
  unexpired high-priority ones — full draining requires sizing `limit` to the DLQ depth (from
  `msgfmt_stats`) or paging. This ties US1 and US2 together and is the accepted cost of not changing
  Feature 004's DLQ ordering.
- Grounded by sub-agents: **no constitution change** (no principle caps schema size; native TTL would
  not even breach the *letter* of Principle VII, but was rejected on portability + convention grounds)
  and **no static-gate change** (`ZCARD`/`ZRANGE` already whitelisted; `ZREMRANGEBYSCORE`/`PEXPIRE`
  avoided). Determinism-scan gap noted for the rejected TTL path (not applicable to mechanism A).
- Content-quality note: consistent with specs 002–005, the spec names native types and field names
  because the "users" are Redis/Valkey developers and Principle VIII mandates explicit KEYS/ARGV
  contracts. Exact wire layouts + new error codes (`msgfmt_reap`/`msgfmt_stats`) fixed in
  `contracts/functions.md` at planning.
- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.
