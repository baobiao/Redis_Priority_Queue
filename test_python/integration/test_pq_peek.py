"""Mirrors test_bash/integration/test_pq_peek.sh: non-destructive peek. Single mode
returns exactly what dequeue would lease next and mutates nothing; top-N returns the
front members regardless of lease state with their lease fields; count>size returns
all; empty/all-leased -> null/empty; dangling members are skipped (never removed);
peek works on a DLQ-shaped queue."""
import pqsupport as pq


def test_single_topn_and_count_over_size(client):
    q, pfx = "pq:{pk}", "pq:{pk}:m:"
    client.delete(q, pfx + "A", pfx + "B", pfx + "C")
    # Front order by (priority, seq): B(pri5), A(pri10,seq1), C(pri10,seq3).
    pq.fcall(client, "pq_enqueue", [q, pfx + "A"], "A", "1", "Priority", "10", "Payload", "PAY-A")
    pq.fcall(client, "pq_enqueue", [q, pfx + "B"], "B", "2", "Priority", "5", "Payload", "PAY-B")
    pq.fcall(client, "pq_enqueue", [q, pfx + "C"], "C", "3", "Priority", "10", "Payload", "PAY-C")

    # --- Single mode: returns the front deliverable (B), mutating nothing ---
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "1000", "30000")
    assert "PAY-B" in pq.deep(out)  # single peek returns front message B
    assert "PAY-A" not in pq.deep(out)  # single peek returns only one record (no A)
    assert client.hget(pfx + "B", "ReadAttempts") == "0"  # peek did not mutate B ReadAttempts
    assert client.hget(pfx + "B", "DirtyBit") == "0"  # peek did not mutate B DirtyBit
    assert client.hget(pfx + "B", "ReadDateTime") == "0"  # peek did not mutate B ReadDateTime

    # --- Single peek == the message a subsequent dequeue leases ---
    deq = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "PAY-B" in pq.deep(deq)  # dequeue leases the same message peek showed (B)
    assert client.hget(pfx + "B", "DirtyBit") == "1"  # dequeue DID mutate B (now in-flight)

    # --- Top-N mode: front N regardless of lease state (B now in-flight) ---
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "2000", "30000", "3")
    assert "PAY-B" in pq.deep(out)  # top-N includes B (in-flight)
    assert "PAY-A" in pq.deep(out)  # top-N includes A
    assert "PAY-C" in pq.deep(out)  # top-N includes C

    # --- count greater than queue size returns all, no error ---
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "2000", "30000", "100")
    assert "PAY-A" in pq.deep(out)  # count>size returns all (A)
    assert "PAY-C" in pq.deep(out)  # count>size returns all (C)


def test_empty_queue(client):
    eq, epfx = "pq:{pke}", "pq:{pke}:m:"
    client.delete(eq)
    out = pq.fcall_ro(client, "pq_peek", [eq, epfx], "1000", "30000")
    assert pq.deep(out) == ""  # empty queue single peek -> null
    out = pq.fcall_ro(client, "pq_peek", [eq, epfx], "1000", "30000", "5")
    assert "member" not in pq.deep(out)  # empty queue top-N peek -> no records


def test_all_leased_single_null(client):
    lq, lpfx = "pq:{pkl}", "pq:{pkl}:m:"
    client.delete(lq, lpfx + "Z")
    pq.fcall(client, "pq_enqueue", [lq, lpfx + "Z"], "Z", "1", "Priority", "5", "Payload", "PAY-Z")
    pq.fcall(client, "pq_dequeue", [lq, lpfx], "1000", "30000")  # lease Z (unexpired)
    out = pq.fcall_ro(client, "pq_peek", [lq, lpfx], "1001", "30000")
    assert pq.deep(out) == ""  # all-leased single peek -> null


def test_dangling_member_skipped_never_removed(client):
    dq, dpfx = "pq:{pkd}", "pq:{pkd}:m:"
    client.delete(dq, dpfx + "D")
    pq.fcall(client, "pq_enqueue", [dq, dpfx + "D"], "D", "1", "Priority", "5", "Payload", "PAY-D")
    m_d = "%020d:%s" % (1, "D")
    client.delete(dpfx + "D")  # Hash gone -> dangling member
    out = pq.fcall_ro(client, "pq_peek", [dq, dpfx], "1000", "30000", "5")
    assert "PAY-D" not in pq.deep(out)  # top-N skips the dangling member
    assert client.zscore(dq, m_d) == 5.0  # peek did NOT remove the dangling member


def test_dlq_shaped_queue(client):
    dl, dlpfx = "dlq:{pk2}", "dlq:{pk2}:m:"
    client.delete(dl, dlpfx + "W")
    pq.fcall(client, "pq_enqueue", [dl, dlpfx + "W"], "W", "1", "Priority", "9", "Payload", "PAY-W")
    out = pq.fcall_ro(client, "pq_peek", [dl, dlpfx], "1000", "30000")
    assert "PAY-W" in pq.deep(out)  # peek inspects a DLQ-shaped queue
