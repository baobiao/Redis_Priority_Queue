"""Mirrors test_bash/integration/test_pq_scheduled.sh: scheduled delivery via
VisibleAt (not-before). A future VisibleAt is skipped by dequeue until now >= it, then
delivered normally; a not-yet-visible high-priority message does not block a visible
lower-priority one; VisibleAt=0/absent is immediately visible."""
import pqsupport as pq


def test_future_visible_at_skipped_then_delivered(client):
    q, pfx = "pq:{sc}", "pq:{sc}:m:"
    client.delete(q, pfx + "A")
    pq.fcall(client, "pq_enqueue", [q, pfx + "A"],
             "A", "1", "Priority", "5", "Payload", "PAY-A", "VisibleAt", "5000")
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "4999", "30000")
    assert pq.deep(out) == ""  # not visible yet (now<VisibleAt) -> null
    assert client.hget(pfx + "A", "DirtyBit") == "0"  # skipped message not leased: DirtyBit=0
    assert client.hget(pfx + "A", "ReadAttempts") == "0"  # skipped message not leased: ReadAttempts=0
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "5000", "30000")
    assert "PAY-A" in pq.deep(out)  # visible at now==VisibleAt (>=) -> delivered


def test_hidden_high_priority_does_not_block_visible_low(client):
    q, pfx = "pq:{sd}", "pq:{sd}:m:"
    client.delete(q, pfx + "H", pfx + "L")
    pq.fcall(client, "pq_enqueue", [q, pfx + "H"],
             "H", "1", "Priority", "5", "Payload", "PAY-H", "VisibleAt", "5000")   # higher prio, hidden
    pq.fcall(client, "pq_enqueue", [q, pfx + "L"],
             "L", "2", "Priority", "10", "Payload", "PAY-L", "VisibleAt", "0")     # lower prio, visible
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    assert "PAY-L" in pq.deep(out)  # visible low-priority L delivered while high-priority H is hidden
    assert "PAY-H" not in pq.deep(out)  # hidden H must not be delivered early
    # Once H is visible it takes precedence (higher priority) over any remaining visible message.
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "5000", "30000")
    assert "PAY-H" in pq.deep(out)  # H delivered once visible


def test_visible_at_zero_and_omitted(client):
    q, pfx = "pq:{s0}", "pq:{s0}:m:"
    client.delete(q, pfx + "Z", pfx + "Y")
    pq.fcall(client, "pq_enqueue", [q, pfx + "Z"],
             "Z", "1", "Priority", "5", "Payload", "PAY-Z", "VisibleAt", "0")
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1", "30000")
    assert "PAY-Z" in pq.deep(out)  # explicit VisibleAt=0 is immediately visible
    pq.fcall(client, "pq_enqueue", [q, pfx + "Y"], "Y", "2", "Priority", "5", "Payload", "PAY-Y")  # no VisibleAt
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1", "30000")
    assert "PAY-Y" in pq.deep(out)  # omitted VisibleAt defaults to immediately visible
