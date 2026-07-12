"""Mirrors test_bash/integration/test_pq_dequeue_concurrency.sh: concurrent consumers never
receive the same message. The "concurrency" is a sequence of FCALLs simulating two
consumers: a leased (un-expired) message is skipped, so two acquires return distinct
messages. Spec: FR-003, SC-003."""
import pqsupport as pq


def test_concurrent_consumers_distinct_messages(client):
    q = "pq:{n1}"
    pfx = "pq:{n1}:m:"
    client.delete(q, pfx + "m1", pfx + "m2")

    # Single available message: first acquire gets it, second finds nothing (leased).
    pq.fcall(client, "pq_enqueue", [q, pfx + "m1"], "m1", "1", "Priority", "5", "Payload", "p1")
    d1 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "p1" in pq.deep(d1)
    d2 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert pq.deep(d2) == ""

    # Add a second message: consumer 2 now gets the new one, not the leased m1.
    pq.fcall(client, "pq_enqueue", [q, pfx + "m2"], "m2", "2", "Priority", "5", "Payload", "p2")
    d3 = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "p2" in pq.deep(d3)
    assert "p1" not in pq.deep(d3)  # leased message must not be re-delivered concurrently
