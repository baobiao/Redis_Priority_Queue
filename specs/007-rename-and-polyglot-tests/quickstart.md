# Quickstart: running the three parity suites

**No queue behaviour changed** — this shows how to run the renamed Bash suite plus the new Java and
Python suites, all against the same engines.

## Prerequisites

- Docker (engine images pulled on first run: `redis:7.4`, `valkey/valkey:8.0`)
- JDK 25 + Maven (for `test_java/`)
- Python 3.11+ (for `test_python/`)
- Engine pins + host ports come from repo-root `engines.env` (all env-overridable)

## 1. Bring engines up (publishes TCP ports)

The Java/Python suites connect over `localhost:<port>`, so the shared harness must be up first. The Bash
suite also brings engines up idempotently, but Java/Python do not.

```bash
# standalone redis + valkey (now with published ports from engines.env)
test_bash/harness/docker_engines.sh up
# single-shard all-slots cluster per engine (announces a host-reachable address)
test_bash/harness/docker_engines.sh cluster-up
```

## 2. Bash suite (source of truth)

```bash
test_bash/run_all.sh                 # all suites on redis + valkey (standalone) + static gate
ENGINES=redis test_bash/run_all.sh   # single engine
# expect: same total as pre-rename baseline — 832 assertions, 0 failed
```

Bash **cluster** coverage is a manual smoke (it has never been part of `run_all.sh`): after
`cluster-up`, load `priority_queue.lua` into each cluster container and issue one `pq_*` FCALL to
confirm `cluster_state:ok` / no `CROSSSLOT`. The **automated** cluster parity is provided by the Java
and Python suites below.

The static gate now scans `src/functions/priority_queue.lua`:

```bash
test_bash/harness/static_checks.sh   # no violations
```

## 3. Java suite

```bash
cd test_java
mvn test        # reads ../engines.env; runs every mirrored class across redis+valkey, standalone+cluster
```

## 4. Python suite

```bash
cd test_python
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt      # pytest + redis>=5
pytest -q                            # reads ../engines.env; redis+valkey, standalone+cluster
```

## 5. Tear down

```bash
test_bash/harness/docker_engines.sh cluster-down
test_bash/harness/docker_engines.sh down
```

## 6. Zero-stale-reference grep sweep (verification gate)

From the repo root — expected output is **empty**. Frozen records are excluded: the whole `specs/**`
tree (007 documents the old→new mapping), `.specify/templates/`, and the constitution's Sync-Impact
comment. `EXCL` filters those plus build dirs.

```bash
EXCL='(^|/)(specs/|\.specify/templates/|\.specify/memory/constitution\.md|\.git/|target/|__pycache__/|\.pytest_cache/|\.venv/)'

# (a) rename tokens — expect empty
grep -rInE 'message_format|msgfmt|MSGFMT' --exclude-dir=.git -- . | grep -vE "$EXCL"

# (b) old test-folder subpaths (precise: avoids the 007-…-tests/ dir name) — expect empty
grep -rInE '(^|[[:space:]"'\''(/])tests/(harness|contract|integration|unit|run_all|\.artifacts)' \
  --exclude-dir=.git -- . | grep -vE "$EXCL"
```

## Parity check

Every `test_bash/**` suite has a mirrored Java class and Python module (see `data-model.md` §3). All
three MUST pass on both engines; the Bash totals are the regression baseline (SC-001), and the Java/Python
suites prove the same behaviour from real Jedis/redis-py clients (SC-002/SC-003).
