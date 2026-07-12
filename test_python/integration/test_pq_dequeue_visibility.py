"""Mirrors test_bash/integration/test_pq_dequeue_visibility.sh: visibility-timeout reclaim
+ fencing. An unsettled lease is skipped before the timeout and reclaimed after it (all
"now" values are caller-supplied ARGV, no real sleeps); the original (stale) token can no
longer ack/nack the reacquired message. Spec: FR-003/004/011, SC-006/007."""
import pqsupport as pq


def _member(seq, mid):
    return f"{seq:020d}:{mid}"


def test_visibility_reclaim_and_fencing(client):
    q = "pq:{v1}"
    pfx = "pq:{v1}:m:"
    member = _member(1, "v")
    client.delete(q, pfx + "v")
    pq.fcall(client, "pq_enqueue", [q, pfx + "v"], "v", "1", "Priority", "5", "Payload", "pv")

    # Consumer A leases at now=1000, timeout=30000 (token = ReadAttempts = 1).
    d1 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "pv" in pq.deep(d1)
    assert client.hget(pfx + "v", "ReadAttempts") == "1"
    assert client.hget(pfx + "v", "ReadDateTime") == "1000"

    # Before the timeout (now=5000, 5000-1000 < 30000): still leased, not returned.
    d2 = pq.fcall(client, "pq_dequeue", [q, pfx], "5000", "30000")
    assert pq.deep(d2) == ""

    # At/after the timeout (now=31000, 31000-1000 = 30000 >= 30000): reclaimed by B.
    d3 = pq.fcall(client, "pq_dequeue", [q, pfx], "31000", "30000")
    assert "pv" in pq.deep(d3)
    assert client.hget(pfx + "v", "ReadAttempts") == "2"
    assert client.hget(pfx + "v", "ReadDateTime") == "31000"

    # A's stale token (1) can no longer settle the reacquired message.
    pq.assert_error("EFENCED", pq.fcall, client, "pq_ack", [q, pfx + "v"], member, "1")
    pq.assert_error("EFENCED", pq.fcall, client, "pq_nack", [pfx + "v"], "1")
    # B's lease is untouched by the stale attempts.
    assert client.exists(pfx + "v") == 1
    assert client.hget(pfx + "v", "DirtyBit") == "1"

    # B settles normally with the current token (2).
    ack_b = pq.fcall(client, "pq_ack", [q, pfx + "v"], member, "2")
    assert pq.deep(ack_b) == "OK"
    assert client.exists(pfx + "v") == 0
    assert client.zcard(q) == 0
