"""Mirrors test_bash/unit/test_pq_reap_validation.sh: pq_reap validation +
fail-before-write. Invalid now/retention/limit and a tag mismatch return the
correct PQ E... errors and write nothing (a seeded expired entry survives).

The tag-mismatch scenario uses cross-slot keys and is standalone-only."""
import pytest
from redis.cluster import RedisCluster

import pqsupport as pq

DL = "dlq:{rv}"
PFX = "pq:{rv}:m:"


def test_reap_validation(client):
    pq.load(client)
    client.delete(DL, PFX + "1")
    # Seed one clearly-expired entry; assert it survives every rejected call.
    pq.fcall(client, "pq_create", [PFX + "1"], "Priority", "5", "Payload", "x", "DeadLetteredAt", "1")
    m1 = f"{1:020d}:1"
    client.zadd(DL, {m1: 5})

    for bad in ("-1", "1.5", "abc"):
        pq.assert_error("ENOW", pq.fcall, client, "pq_reap", [DL, PFX], bad, "1000", "10")
    for bad in ("-1", "1.5", "abc"):
        pq.assert_error("ERET", pq.fcall, client, "pq_reap", [DL, PFX], "100000", bad, "10")
    for bad in ("0", "-5", "1.5", "abc"):
        pq.assert_error("ELIMIT", pq.fcall, client, "pq_reap", [DL, PFX], "100000", "1000", bad)

    # Nothing was written on any failure: the expired entry is still present.
    assert client.zscore(DL, m1) == 5.0
    assert client.exists(PFX + "1") == 1


def test_tag_mismatch(client):
    if isinstance(client, RedisCluster):
        pytest.skip("cross-slot ETAG check is standalone-only (cluster rejects cross-slot keys)")
    pq.load(client)
    pq.assert_error("ETAG", pq.fcall, client, "pq_reap", ["dlq:{rv}", "pq:{nope}:m:"], "100000", "1000", "10")
