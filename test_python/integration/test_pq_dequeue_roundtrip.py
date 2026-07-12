"""Mirrors test_bash/integration/test_pq_dequeue_roundtrip.sh: acquire in priority then
FIFO order, lease fields set, Payload fidelity, null on empty; ack removes (idempotent
NOOP on retry); nack releases and the message is redelivered with ReadAttempts retained.
All timestamps are caller-supplied ARGV (no real sleeps).
Spec: FR-002/003/004/005/006/009/010/012, SC-001/002/004/005/009."""
import pqsupport as pq


def _member(seq, mid):
    return f"{seq:020d}:{mid}"


def test_dequeue_ack_nack_round_trip(client):
    q = "pq:{d1}"
    pfx = "pq:{d1}:m:"
    client.delete(q, pfx + "a", pfx + "b", pfx + "c")

    # a: seq1 pri10 ; b: seq2 pri5 ; c: seq3 pri10  -> delivery order b, a, c.
    pq.fcall(client, "pq_enqueue", [q, pfx + "a"], "a", "1", "Priority", "10", "Payload", "task-a")
    pq.fcall(client, "pq_enqueue", [q, pfx + "b"], "b", "2", "Priority", "5",  "Payload", "task-b")
    pq.fcall(client, "pq_enqueue", [q, pfx + "c"], "c", "3", "Priority", "10", "Payload", "task-c")

    # Priority then FIFO order.
    d1 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "task-b" in pq.deep(d1)
    d2 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "task-a" in pq.deep(d2)
    d3 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "task-c" in pq.deep(d3)

    # All in-flight -> null (distinct from an empty payload).
    d4 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert pq.deep(d4) == ""

    # Lease fields set on the acquired message b.
    assert client.hget(pfx + "b", "DirtyBit") == "1"
    assert client.hget(pfx + "b", "ReadAttempts") == "1"
    assert client.hget(pfx + "b", "ReadDateTime") == "1000"

    # ack removes b (member + hash); ZCARD drops from 3 to 2; retry is NOOP.
    before = client.zcard(q)
    ackout = pq.fcall(client, "pq_ack", [q, pfx + "b"], _member(2, "b"), "1")
    assert pq.deep(ackout) == "OK"
    assert pq.deep(pq.fcall_ro(client, "pq_read", [pfx + "b"])) == "NOTFOUND"
    assert client.zcard(q) == before - 1
    assert pq.deep(pq.fcall(client, "pq_ack", [q, pfx + "b"], _member(2, "b"), "1")) == "NOOP"

    # nack releases a; DirtyBit back to 0, ReadDateTime/ReadAttempts retained.
    nackout = pq.fcall(client, "pq_nack", [pfx + "a"], "1")
    assert pq.deep(nackout) == "OK"
    assert client.hget(pfx + "a", "DirtyBit") == "0"
    assert client.hget(pfx + "a", "ReadAttempts") == "1"
    assert client.hget(pfx + "a", "ReadDateTime") == "1000"

    # a is available again and redelivered with a higher ReadAttempts.
    d5 = pq.fcall(client, "pq_dequeue", [q, pfx], "2000", "30000")
    assert "task-a" in pq.deep(d5)
    assert client.hget(pfx + "a", "ReadAttempts") == "2"
    assert client.hget(pfx + "a", "ReadDateTime") == "2000"
