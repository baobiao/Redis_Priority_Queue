"""Mirrors test_bash/integration/test_pq_stats.sh: pq_stats. Exact depths + front
Priority (cheap tier); a bounded breakdown classifies the scanned front as available /
in-flight / delayed with a truncated flag; an approximate oldest-dead-letter age; and
it mutates nothing."""
import pqsupport as pq


def test_depths_breakdown_and_age(client):
    q, pfx, dl = "pq:{st}", "pq:{st}:m:", "dlq:{st}"
    client.delete(q, dl, pfx + "A", pfx + "B", pfx + "C", pfx + "D")
    # A available (pri5), B available (pri10), C delayed (VisibleAt future), D will be leased.
    pq.fcall(client, "pq_enqueue", [q, pfx + "A"], "A", "1", "Priority", "5", "Payload", "a")
    pq.fcall(client, "pq_enqueue", [q, pfx + "B"], "B", "2", "Priority", "10", "Payload", "b")
    pq.fcall(client, "pq_enqueue", [q, pfx + "C"],
             "C", "3", "Priority", "10", "Payload", "c", "VisibleAt", "999999")
    pq.fcall(client, "pq_enqueue", [q, pfx + "D"], "D", "4", "Priority", "20", "Payload", "d")
    # Dequeue once leases the front deliverable (A). A in-flight; B available; C delayed; D available.
    pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")

    # --- Cheap tier: exact depths + front Priority ---
    out = pq.fcall_ro(client, "pq_stats", [q, pfx, dl], "2000", "30000")
    assert "depth" in pq.deep(out)  # cheap: depth reported
    assert "4" in pq.deep(out)  # cheap: queue depth = 4
    assert "front_priority" in pq.deep(out)  # cheap: front_priority label

    # --- Bounded breakdown: A in-flight, B available, C delayed, D available ---
    out = pq.fcall_ro(client, "pq_stats", [q, pfx, dl], "2000", "30000", "100")
    assert "available" in pq.deep(out)  # breakdown: available label
    assert "in_flight" in pq.deep(out)  # breakdown: in_flight label
    assert "delayed" in pq.deep(out)  # breakdown: delayed label
    assert "truncated" in pq.deep(out)  # breakdown: truncated label
    # exact counts: available=2 (B,D), in_flight=1 (A), delayed=1 (C)
    assert "available 2" in pq.deep(out)  # available=2 (B,D)

    # --- No mutation: A still leased (DirtyBit=1), others untouched ---
    assert client.hget(pfx + "A", "DirtyBit") == "1"  # stats did not mutate A (DirtyBit=1)
    assert client.hget(pfx + "C", "VisibleAt") == "999999"  # stats did not mutate C VisibleAt

    # --- Truncated flag when depth > max_scan ---
    out = pq.fcall_ro(client, "pq_stats", [q, pfx, dl], "2000", "30000", "2")
    assert "truncated 1" in pq.deep(out)  # truncated=1 when depth>max_scan

    # --- Approximate oldest-dead-letter age from the scanned DLQ prefix ---
    client.delete(pfx + "X")
    pq.fcall(client, "pq_create", [pfx + "X"], "Priority", "5", "Payload", "x", "DeadLetteredAt", "1000")
    client.zadd(dl, {"%020d:%s" % (9, "X"): 5})
    out = pq.fcall_ro(client, "pq_stats", [q, pfx, dl], "5000", "30000", "100")
    assert "oldest_dead_letter_age" in pq.deep(out)  # age: oldest_dead_letter_age label
    # age = now(5000) - DeadLetteredAt(1000) = 4000
    assert "oldest_dead_letter_age 4000" in pq.deep(out)  # oldest age = 4000


def test_empty_queue(client):
    eq, epfx = "pq:{se}", "pq:{se}:m:"
    client.delete(eq)
    out = pq.fcall_ro(client, "pq_stats", [eq, epfx], "1000", "30000")
    assert "0" in pq.deep(out)  # empty queue: depth 0
    assert "-1" in pq.deep(out)  # empty queue: front_priority -1
