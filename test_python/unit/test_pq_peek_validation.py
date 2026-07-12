"""Mirrors test_bash/unit/test_pq_peek_validation.sh: pq_peek input validation and
read-only malformed handling. Invalid now/timeout/count and a non-zset queue ->
structured errors; a malformed message Hash errors in single mode but is skipped
in top-N mode; nothing is ever written (peek is no-writes).

The tag-mismatch scenario uses cross-slot keys and is standalone-only (the cluster
client rejects them before the function's ETAG guard runs)."""
import pytest
from redis.cluster import RedisCluster

import pqsupport as pq

Q = "pq:{pv}"
PFX = "pq:{pv}:m:"


def test_peek_input_and_malformed_validation(client):
    pq.load(client)
    client.delete(Q, PFX + "a")
    pq.fcall(client, "pq_enqueue", [Q, PFX + "a"], "a", "1", "Priority", "5", "Payload", "hi")

    # now / timeout / count validation.
    for bad in ("-1", "1.5", "abc"):
        pq.assert_error("ENOW", pq.fcall_ro, client, "pq_peek", [Q, PFX], bad, "30000")
    for bad in ("0", "-5", "x"):
        pq.assert_error("ETMO", pq.fcall_ro, client, "pq_peek", [Q, PFX], "1000", bad)
    for bad in ("0", "-2", "1.5", "nope"):
        pq.assert_error("ECOUNT", pq.fcall_ro, client, "pq_peek", [Q, PFX], "1000", "30000", bad)

    # Non-zset queue key.
    client.delete("str:{pv}")
    client.set("str:{pv}", "not-a-zset")
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_peek", ["str:{pv}", "str:{pv}:m:"], "1000", "30000")

    # Malformed message Hash: single mode -> EMALFORMED; top-N -> skipped.
    mq = "pq:{pvm}"
    mpfx = "pq:{pvm}:m:"
    client.delete(mq, mpfx + "bad")
    pq.fcall(client, "pq_enqueue", [mq, mpfx + "bad"], "bad", "1", "Priority", "5", "Payload", "x")
    client.delete(mpfx + "bad")
    client.set(mpfx + "bad", "corrupt")  # member present, Hash is a string
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_peek", [mq, mpfx], "1000", "30000")
    topn = pq.fcall_ro(client, "pq_peek", [mq, mpfx], "1000", "30000", "5")
    assert "member" not in pq.deep(topn)

    # No writes happened anywhere: the read-only queue member is still present.
    assert client.zscore(Q, f"{1:020d}:a") == 5.0


def test_tag_mismatch(client):
    if isinstance(client, RedisCluster):
        pytest.skip("cross-slot ETAG check is standalone-only (cluster rejects cross-slot keys)")
    pq.load(client)
    pq.assert_error("ETAG", pq.fcall_ro, client, "pq_peek", ["pq:{pv}", "pq:{nope}:m:"], "1000", "30000")
