# Specification Quality Checklist: Rename to priority_queue and Polyglot Test Parity

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

- All four design forks were resolved by the user up front (recorded in spec's Clarifications):
  **(1) rename depth = full (c)** — file + `#!lua name=priority_queue` + `msgfmt_*`→`pq_*` +
  `MSGFMT `→`PQ ` error prefix (codes/detail unchanged); **(2) engine provisioning = shared,
  port-published containers (B)** — no Testcontainers, Java/Python connect over `localhost:<port>` and
  require the harness up first; **(3) cluster = covered in all three languages**; **(4) native tools
  only** — no orchestrator.
- Fixed assumptions: behaviour is byte-for-byte unchanged vs Feature 006 apart from renamed tokens; the
  Bash suite is the source of truth for expected values; historical specs 001–006 are frozen and
  excluded from the grep sweep; engine pins stay `redis:7.4` / `valkey/valkey:8.0` in a single shared
  constants source.
- Grounded by three sub-agents: (a) rename **blast radius** mapped file:line (file/shebang/functions/
  error prefix, 2 harness LIB paths, the library-name assertion in the flags test, doc refs, container/
  var names, and the frozen historical specs); (b) **polyglot stacks** verified — Jedis ≥ 4.2.0 /
  redis-py ≥ 4.3.0 expose FUNCTION LOAD + FCALL/FCALL_RO; error replies surface as
  `JedisDataException` / `ResponseError` carrying the `PQ E…` code; the **integer-vs-string coercion
  trap** (`Long`/`int`, not `"0"`) is called out as an Edge Case; and the current harness publishes **no
  ports** (the reason option B changes `docker_engines.sh`); (c) **constitution/static-gate** —
  **no constitution change** (Principle II is library-runtime-scoped; test tooling is out of scope;
  Principle IX is language-agnostic and already satisfied — multi-client parity is additive), and the
  static gate needs only its LIB default path updated.
- **Content-quality note** (consistent with specs 002–006): this feature is *inherently* about test
  tooling and a concrete rename, so the spec necessarily names the target languages/clients
  (Java/Jedis, Python/redis-py) and the artifact names. The "users" are Redis/Valkey library
  developers; the Success Criteria remain outcome-based and measurable (assertion-count parity, a
  zero-match grep sweep, 1-to-1 case correspondence, zero behavioural change). Exact wire details
  (published port numbers, Maven/pytest layout, per-suite parity mapping) are fixed at planning in the
  plan/contracts, not the spec.
- **Zero behavioural change is the central safety property**: FR-005 + SC-006 require identical results
  vs Feature 006 for identical inputs, and SC-001 pins the relocated Bash suite to the pre-rename
  baseline (832 assertions, 0 failed) as the regression guard.
- All items pass; the specification is ready for `/speckit-plan`.
