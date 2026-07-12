"""Mirrors test_bash/integration/test_pq_dequeue_priority_interleave.sh: messages enqueued
WHILE a consumer is actively consuming. A higher-priority arrival is delivered on the next
acquire ahead of a lower-priority arrival, but NEITHER preempts the message already
in-flight. Priority is delivery order among AVAILABLE (un-leased) messages, and each acquire
re-scans the queue from the front. All "now" values are caller-supplied ARGV.
Spec: priority-then-FIFO ordering + concurrent lease visibility (US1)."""
import pqsupport as pq


def test_priority_interleave_does_not_preempt_inflight(client):
    q = "pq:{pi1}"
    pfx = "pq:{pi1}:m:"
    client.delete(q, pfx + "A", pfx + "B", pfx + "C")

    # A is the only message initially: seq1, Priority 10.
    pq.fcall(client, "pq_enqueue", [q, pfx + "A"], "A", "1", "Priority", "10", "Payload", "PAY-A")

    # Consumer acquires A -> A is now in-flight (DirtyBit=1, ReadAttempts=1, ReadDateTime=1000).
    d_a = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "PAY-A" in pq.deep(d_a)
    assert client.hget(pfx + "A", "DirtyBit") == "1"
    assert client.hget(pfx + "A", "ReadAttempts") == "1"
    assert client.hget(pfx + "A", "ReadDateTime") == "1000"

    # While A is IN-FLIGHT, enqueue a HIGHER-priority (B, pri5) and a LOWER-priority (C, pri20).
    pq.fcall(client, "pq_enqueue", [q, pfx + "B"], "B", "2", "Priority", "5",  "Payload", "PAY-B")
    pq.fcall(client, "pq_enqueue", [q, pfx + "C"], "C", "3", "Priority", "20", "Payload", "PAY-C")
    assert client.zcard(q) == 3

    # Next acquire must return the NEW higher-priority B (jumps ahead of C), must NOT
    # re-deliver the leased A, and must NOT skip to the lower-priority C.
    d_b = pq.fcall(client, "pq_dequeue", [q, pfx], "1001", "30000")
    assert "PAY-B" in pq.deep(d_b)
    assert "PAY-A" not in pq.deep(d_b)
    assert "PAY-C" not in pq.deep(d_b)

    # The higher-priority arrival must NOT have preempted the in-flight A.
    assert client.hget(pfx + "A", "DirtyBit") == "1"
    assert client.hget(pfx + "A", "ReadAttempts") == "1"
    assert client.hget(pfx + "A", "ReadDateTime") == "1000"

    # With A and B both leased, the lower-priority C is delivered last.
    d_c = pq.fcall(client, "pq_dequeue", [q, pfx], "1002", "30000")
    assert "PAY-C" in pq.deep(d_c)
    assert "PAY-A" not in pq.deep(d_c)
    assert "PAY-B" not in pq.deep(d_c)

    # All three now leased and unexpired -> nothing available (null, not empty payload).
    d_null = pq.fcall(client, "pq_dequeue", [q, pfx], "1003", "30000")
    assert pq.deep(d_null) == ""
