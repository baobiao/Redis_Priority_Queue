"""Mirrors test_bash/unit/test_pq_stats_validation.sh: pq_stats validation
(read-only). Invalid now/timeout/max_scan and a non-zset queue return the correct
PQ E... errors; stats never writes (the seeded message stays unleased).

The tag-mismatch scenario uses cross-slot keys and is standalone-only."""
import pytest
from redis.cluster import RedisCluster

import pqsupport as pq

Q = "pq:{sv}"
PFX = "pq:{sv}:m:"


def test_stats_validation(client):
    pq.load(client)
    client.delete(Q, PFX + "1")
    pq.fcall(client, "pq_enqueue", [Q, PFX + "1"], "1", "1", "Priority", "5", "Payload", "x")

    for bad in ("-1", "1.5", "abc"):
        pq.assert_error("ENOW", pq.fcall_ro, client, "pq_stats", [Q, PFX], bad, "30000")
    for bad in ("0", "-5", "abc"):
        pq.assert_error("ETMO", pq.fcall_ro, client, "pq_stats", [Q, PFX], "1000", bad)
    for bad in ("-1", "1.5", "abc"):
        pq.assert_error("ESCAN", pq.fcall_ro, client, "pq_stats", [Q, PFX], "1000", "30000", bad)

    # Non-zset queue.
    client.delete("str:{sv}")
    client.set("str:{sv}", "notazset")
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_stats", ["str:{sv}", "str:{sv}:m:"], "1000", "30000")

    # Read-only: the seeded message is unchanged (never leased) after all calls.
    assert client.hget(PFX + "1", "DirtyBit") == "0"


def test_tag_mismatch(client):
    if isinstance(client, RedisCluster):
        pytest.skip("cross-slot ETAG check is standalone-only (cluster rejects cross-slot keys)")
    pq.load(client)
    pq.assert_error("ETAG", pq.fcall_ro, client, "pq_stats", ["pq:{sv}", "pq:{nope}:m:"], "1000", "30000")
