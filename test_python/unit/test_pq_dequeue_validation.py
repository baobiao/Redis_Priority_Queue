"""Mirrors test_bash/unit/test_pq_dequeue_validation.sh: input/precondition
rejection for dequeue/ack/nack and the fail-before-write guarantee.

The Bash suite runs this standalone only (ETAG is enforced by the function
itself). The prefix-tag-mismatch scenario uses cross-slot keys, which the cluster
client rejects before the function runs, so it is standalone-only here; every
other scenario runs on all reachable combos (same-slot / single-key)."""
import pytest
from redis.cluster import RedisCluster

import pqsupport as pq

Q = "pq:{u1}"
PFX = "pq:{u1}:m:"


def test_dequeue_ack_nack_validation(client):
    pq.load(client)
    client.delete(Q, PFX + "y", PFX + "z")

    # ----- pq_dequeue input validation -----
    pq.assert_error("EKEYS", pq.fcall, client, "pq_dequeue", [Q], "1000", "30000")
    pq.assert_error("ENOW", pq.fcall, client, "pq_dequeue", [Q, PFX], "-1", "30000")
    pq.assert_error("ENOW", pq.fcall, client, "pq_dequeue", [Q, PFX], "abc", "30000")
    pq.assert_error("ETMO", pq.fcall, client, "pq_dequeue", [Q, PFX], "1000", "0")
    pq.assert_error("ETMO", pq.fcall, client, "pq_dequeue", [Q, PFX], "1000", "1.5")
    pq.assert_error("ESCAN", pq.fcall, client, "pq_dequeue", [Q, PFX], "1000", "30000", "-1")

    # Non-sorted-set queue -> EMALFORMED (fail-before-write).
    client.delete(Q)
    client.set(Q, "notazset")
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_dequeue", [Q, PFX], "1000", "30000")
    client.delete(Q)

    # ----- Set up one enqueued (available) message y for settle checks -----
    pq.fcall(client, "pq_enqueue", [Q, PFX + "y"], "y", "1", "Priority", "5", "Payload", "py")
    ymember = f"{1:020d}:y"

    # ack/nack on a not-in-flight message -> ENOTLEASED (nothing changes).
    pq.assert_error("ENOTLEASED", pq.fcall, client, "pq_ack", [Q, PFX + "y"], ymember, "1")
    pq.assert_error("ENOTLEASED", pq.fcall, client, "pq_nack", [PFX + "y"], "1")

    # ack/nack arg validation.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_ack", [Q], ymember, "1")
    pq.assert_error("EARGS", pq.fcall, client, "pq_ack", [Q, PFX + "y"], "", "1")
    pq.assert_error("EKEYS", pq.fcall, client, "pq_nack", [PFX + "y", Q], "1")
    pq.assert_error("EARGS", pq.fcall, client, "pq_nack", [PFX + "y"], "abc")

    # Lease y, then a wrong token is fenced.
    pq.fcall(client, "pq_dequeue", [Q, PFX], "1000", "30000")
    pq.assert_error("EFENCED", pq.fcall, client, "pq_ack", [Q, PFX + "y"], ymember, "999")
    pq.assert_error("EFENCED", pq.fcall, client, "pq_nack", [PFX + "y"], "999")

    # Settling an absent message -> idempotent NOOP.
    assert pq.deep(pq.fcall(client, "pq_ack", [Q, PFX + "absent"], f"{9:020d}:absent", "1")) == "NOOP"
    assert pq.deep(pq.fcall(client, "pq_nack", [PFX + "absent"], "1")) == "NOOP"

    # Fail-before-write: y is still leased and unchanged, queue still holds 1 member.
    assert client.hget(PFX + "y", "DirtyBit") == "1"
    assert client.hget(PFX + "y", "ReadAttempts") == "1"
    assert client.zcard(Q) == 1


def test_prefix_tag_mismatch(client):
    if isinstance(client, RedisCluster):
        pytest.skip("cross-slot ETAG check is standalone-only (cluster rejects cross-slot keys)")
    pq.load(client)
    pq.assert_error("ETAG", pq.fcall, client, "pq_dequeue", [Q, "pq:{u2}:m:"], "1000", "30000")
