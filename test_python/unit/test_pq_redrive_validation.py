"""Mirrors test_bash/unit/test_pq_redrive_validation.sh: pq_redrive input
validation + fail-before-write. Bad key count / empty member, and a dangling or
malformed message Hash -> the correct PQ E... results; nothing is written on any
failure.

The tag-mismatch scenario uses cross-slot keys and is standalone-only."""
import pytest
from redis.cluster import RedisCluster

import pqsupport as pq

Q = "pq:{uv}"
PFX = "pq:{uv}:m:"
DL = "dlq:{uv}"


def test_redrive_validation(client):
    pq.load(client)
    client.delete(Q, DL, PFX + "X", PFX + "Y")

    # Bad key count.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_redrive", [DL, Q], "m")
    # Empty member.
    pq.assert_error("EARGS", pq.fcall, client, "pq_redrive", [DL, Q, PFX + "X"], "")

    # Dangling DLQ member: present in the DLQ but its message Hash is missing.
    mX = f"{1:020d}:X"
    client.zadd(DL, {mX: 5})
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_redrive", [DL, Q, PFX + "X"], mX)
    assert client.zscore(DL, mX) == 5.0
    assert client.zscore(Q, mX) is None

    # Malformed message Hash: member in DLQ, Hash key holds a non-hash value.
    mY = f"{2:020d}:Y"
    client.zadd(DL, {mY: 5})
    client.set(PFX + "Y", "corrupt")
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_redrive", [DL, Q, PFX + "Y"], mY)
    assert client.zscore(DL, mY) == 5.0
    assert client.zscore(Q, mY) is None


def test_tag_mismatch(client):
    if isinstance(client, RedisCluster):
        pytest.skip("cross-slot ETAG check is standalone-only (cluster rejects cross-slot keys)")
    pq.load(client)
    pq.assert_error("ETAG", pq.fcall, client, "pq_redrive", ["dlq:{uv}", "pq:{nope}", "pq:{uv}:m:X"], "anything")
