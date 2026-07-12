# Phase 0 Research: Rename to priority_queue and Polyglot Test Parity

All NEEDS CLARIFICATION items were resolved with the user before planning (see spec Clarifications) and
grounded by three sub-agents (rename blast radius; polyglot stacks; constitution/static gate). Decisions
below carry rationale + rejected alternatives.

## D1 — Rename depth: FULL (option c)

- **Decision**: Rename the file → `src/functions/priority_queue.lua`, shebang → `#!lua name=priority_queue`,
  all 11 functions `msgfmt_*` → `pq_*`, and the error-reply prefix `MSGFMT ` → `PQ `.
- **Rationale**: The user chose maximum internal consistency — the artifact, library name, function
  namespace, and error namespace all say "priority queue". Half-measures (file-only / file+library) leave
  `msgfmt_` FCALL targets and `MSGFMT` errors visibly inconsistent with the new name.
- **Rejected**: (a) file-only and (b) file+library-name — smaller diffs but internally inconsistent.
- **Blast radius (from sub-agent, `message_format`/`msgfmt`/`MSGFMT`)**: the library file (shebang,
  header, 11 `redis.register_function` names, every `redis.error_reply("MSGFMT …")`, and the internal
  `msgfmt_*` helper call sites); the harness (`load_and_call.sh` LIB_PATH, `static_checks.sh` LIB default
  + comments, `docker_engines.sh` container names `msgfmt-redis`/`msgfmt-valkey`/`-cluster` + `REDIS_NAME`
  defaults + header, `run_all.sh` header); **every** Bash test (`FCALL … msgfmt_*` → `pq_*`, `MSGFMT`
  error assertions → `PQ`, and the **library-name assertion** in `contract/test_function_flags.sh`);
  developer docs (`README.md`, `docs/schema.md`, `docs/functions.md`); `CLAUDE.md`; `.specify/feature.json`.
  **Excluded**: `specs/001-*`…`specs/006-*` (frozen historical records) and the constitution's Sync-Impact
  comment (frozen; its `tests/harness/static_checks.sh` mention is a historical follow-up note).

## D2 — Error-reply namespace token: `PQ`

- **Decision**: `redis.error_reply("MSGFMT <CODE>: <detail>")` → `redis.error_reply("PQ <CODE>: <detail>")`.
  The **codes** (`EFIELD`, `EMALFORMED`, `ENOTFOUND`, `EWRONGTYPE`, `EARGS`, and any others) and all
  detail text are unchanged.
- **Rationale**: `PQ` is the uppercase of the `pq_` function prefix — terse and consistent. All three
  suites assert on the `PQ E…` substring, so the token must be fixed before the tests are ported.
- **Rejected**: `PRIORITYQUEUE` (verbose); keeping `MSGFMT` (inconsistent, and would fail the grep sweep).

## D3 — Engine provisioning: SHARED PORT-PUBLISHED CONTAINERS (option B)

- **Decision**: Modify `docker_engines.sh` to publish TCP host ports for the standalone redis + valkey
  engines and for the cluster nodes; all three suites connect over `localhost:<port>`. **No Testcontainers.**
- **Rationale**: The user chose B. It gives one engine-lifecycle/version source for all three languages
  and makes cluster parity uniform (one cluster bring-up, three clients). The current harness runs via
  `docker exec` and **publishes no ports** (sub-agent confirmed), so host-run Jedis/redis-py cannot connect
  as-is — publishing ports is the enabling change.
- **Additive, non-regressing**: adding `-p` to `docker run` does not affect the existing `docker exec`
  path, so the Bash suite stays byte-for-byte green.
- **Coupling accepted**: `mvn test` / `pytest` require `docker_engines.sh up` (and `cluster-up`) first.
  Documented in quickstart.
- **Rejected**: (A) Testcontainers-per-language — triples engine management, complicates single-node
  cluster wiring, and duplicates image pins.

## D4 — Single-node cluster over published ports needs an announced host address

- **Decision**: The cluster bring-up MUST start the node with `--cluster-announce-ip 127.0.0.1
  --cluster-announce-port <hostDataPort>` (and a published, announced bus port) so `CLUSTER SLOTS`
  advertises a host-reachable address.
- **Rationale**: `JedisCluster`/`RedisCluster` connect to a seed, read `CLUSTER SLOTS`, then talk to the
  announced node address. A container that announces its internal `6379` is unreachable from the host via
  a mapped port; announcing `127.0.0.1:<hostport>` fixes discovery. The single node owns all 16384 slots
  (existing rationale: single-key ops never cross slots), so no `MOVED` redirection occurs beyond the
  initial topology read.
- **Note**: The Bash cluster path uses `docker exec` and is unaffected by the announce flags; they exist
  purely so host clients can discover the node. This is the principal technical risk of the feature and is
  called out for early validation in tasks.

## D5 — Shared constants: repo-root `engines.env` (KEY=VALUE)

- **Decision**: A single `engines.env` at the repo root holds the engine image pins and published host
  ports as `KEY=VALUE` lines. `docker_engines.sh` sources it (env still overrides); Java loads it via
  `java.util.Properties` (KEY=VALUE is Properties-compatible); Python parses it in `conftest.py`.
- **Keys (defaults, all env-overridable)**: `REDIS_IMAGE=redis:7.4`, `VALKEY_IMAGE=valkey/valkey:8.0`,
  `REDIS_PORT=7379`, `VALKEY_PORT=7380`, `REDIS_CLUSTER_PORT=7381`, `VALKEY_CLUSTER_PORT=7382`
  (+ bus ports `+10000` if published). Non-6379 defaults avoid colliding with a developer's local redis.
- **Rationale**: KEY=VALUE is the lingua franca readable by all three ecosystems with no extra dependency,
  giving one source of truth for versions AND ports (satisfies FR-011, prevents drift).
- **Rejected**: embedding constants in `docker_engines.sh` only (Java/Python would re-hardcode); a
  language-specific format (YAML/JSON) needs a parser dependency in at least one stack.

## D6 — Java stack + Functions API (sub-agent verified)

- **Decision**: Java 25 + Maven + JUnit 5 (5.13.x) + **Jedis 7.1.0**. Standalone via `JedisPooled`
  (`UnifiedJedis`); cluster via `JedisCluster`. Toolchain: `maven-compiler-plugin` ≥ 3.14.0 +
  `maven-surefire-plugin` 3.5.x (older ASM/Byte Buddy reject JDK 25 class-file **major v69**).
- **API**: `functionLoadReplace(String luaSource)` → returns library name (`"priority_queue"`);
  `fcall(name, List<String> keys, List<String> args)` and `fcallReadonly(...)` — **Jedis derives
  `numkeys` from `keys.size()`** (do not pass it).
- **Reply mapping (parity trap)**: the `String` overloads decode via `AGGRESSIVE_ENCODED_OBJECT` →
  status/bulk = `String`, RESP integer = `Long`, array = `List<Object>`, nil = `null`. Assert numeric
  fields as `Long`/typed, not `"0"`. (The `byte[]` overloads return `byte[]`; do not mix.)
- **Errors**: `redis.error_reply(...)` → `JedisDataException` (a `RuntimeException`); `getMessage()`
  carries `PQ E…`. The FCALL_RO-on-write rejection ("Can not execute a script with write flag using *_ro
  command") likewise arrives as `JedisDataException`.
- **Minimum**: Jedis ≥ 4.2.0 first exposed `functionLoad`/`fcall`/`fcallReadonly`; 7.1.0 is current.

## D7 — Python stack + Functions API (sub-agent verified)

- **Decision**: Python 3.11+ + pytest + **redis-py 5.x**. Standalone via `redis.Redis(...,
  decode_responses=True)`; cluster via `redis.cluster.RedisCluster`.
- **API**: `function_load(code: str, replace=True)` → returns library name; `fcall(name, numkeys,
  *keys_and_args)` and `fcall_ro(...)` — **redis-py requires an explicit `numkeys`** (parity difference
  vs Jedis).
- **Reply mapping**: with `decode_responses=True`, status/bulk = `str` (`"OK"`/`"VALID"`/`"NOOP"`/
  `"NOTFOUND"`, payloads), RESP integer = `int`, array = `list`, nil = `None`. RESP2/RESP3 is a non-issue
  here — the library returns flat arrays (not RESP3 maps), which deserialize as `list` under both; pin
  `protocol=2` only as belt-and-suspenders.
- **Errors**: `redis.error_reply(...)` → `redis.exceptions.ResponseError`; `str(e)` carries `PQ E…`
  (regardless of `decode_responses`). FCALL_RO-on-write rejection is the same `ResponseError`.
- **Minimum**: redis-py ≥ 4.3.0 first exposed `function_load`/`fcall`/`fcall_ro`; 5.x is current
  (requires Python ≥ 3.10).

## D8 — "Same file, any client" invariant

- **Fact (sub-agent confirmed)**: the library name and function names live in the **Lua source**
  (`#!lua name=priority_queue` + `redis.register_function('pq_…')`), not the client. Loading the exact
  same file bytes via `redis-cli -x FUNCTION LOAD REPLACE`, Jedis `functionLoadReplace(String)`, or
  redis-py `function_load(code, replace=True)` yields an identical library; `FCALL pq_… …` targets the
  same names from every client. This is what makes 1-to-1 polyglot parity meaningful.

## D9 — Cluster scope: single-node, all-slots (unchanged rationale)

- **Decision**: All three languages cover a single-shard cluster owning all 16384 slots. Single-key
  operations (this library) never cross slots, so `cluster_state:ok` + no `CROSSSLOT` for co-located
  hash-tag keys is sufficient to prove cluster behaviour — the same rationale the existing Bash
  `cluster-up` already documents.

## D10 — Grep sweep methodology (the zero-stale-reference gate)

Grounded against the **actual** pre-rename footprint (grep run during analyze), which revealed several
false-positive sources the naive sweep would trip over. Corrected methodology:

- **Frozen-record exclusions** (matches here are legitimate, not stale): the entire `specs/**` tree
  (001–006 are historical records; **007 legitimately documents the old→new mapping**, so it *must*
  contain `message_format`/`msgfmt`), the generic upstream `.specify/templates/*.md` (their `tests/`
  examples are scaffolding, not our folder), and the constitution's non-normative Sync-Impact comment
  `.specify/memory/constitution.md` (a frozen governance amendment log whose `tests/harness/static_checks.sh`
  follow-up note described the state at v2.0.0). We do **not** edit the constitution (user chose "no
  constitution change"). Also exclude `.git/` and build dirs (`target`, `__pycache__`, `.pytest_cache`).
- **Rename-token sweep**: `grep -rInE 'message_format|msgfmt|MSGFMT'` over the repo minus the exclusions
  above. **Expected: zero.** Active surface that MUST be clean: `src/`, `test_bash/`, `test_java/`,
  `test_python/`, `docs/`, `README.md`, `CLAUDE.md`, `.claude/settings.local.json`, `.gitignore`,
  `engines.env`.
- **Relocate sweep**: must match the *real* test subpaths, NOT bare `tests/` — because the feature
  directory `007-rename-and-polyglot-tests/` and template examples contain the substring `tests/`. Use
  `grep -rInE '(^|[[:space:]"'\''(/])tests/(harness|contract|integration|unit|run_all|\.artifacts)'`
  minus the same exclusions. **Expected: zero.**
- The exact commands live in `quickstart.md` §6 and are executed in tasks T029 + T030.

## D11 — Parity mapping (source of truth = Bash)

- **Decision**: Each of the 36 Bash suites (11 contract + 16 integration + 9 unit) maps to exactly one
  Java class and one Python module covering the same scenarios and expected values. The mapping table is
  recorded in `data-model.md` and is the checklist for "1-to-1 equivalent". Equivalence is by **case and
  expected value**, not by identical assertion integers (JUnit/pytest count differently than the Bash
  `expect` counter); the Bash suite remains authoritative for the expected values themselves.
