"""Mirrors test_bash/integration/test_pq_enqueue_roundtrip.sh: priority ordering (incl.
boundary values), FIFO among equal priorities, and stored-message fidelity.
Spec: FR-002/004/005/013/016, SC-001/SC-002/SC-003."""
import pqsupport as pq


def _member(seq, mid):
    # member = fixed-width zero-padded sequence (20 digits) + ':' + id (see the Lua source).
    return f"{seq:020d}:{mid}"


def test_priority_ordering_incl_boundaries(client):
    client.delete("pq:{o1}", "pq:{o1}:m:low", "pq:{o1}:m:mid", "pq:{o1}:m:hi",
                  "pq:{o1}:m:min", "pq:{o1}:m:max")
    pq.fcall(client, "pq_enqueue", ["pq:{o1}", "pq:{o1}:m:low"], "low", "1", "Priority", "1000")
    pq.fcall(client, "pq_enqueue", ["pq:{o1}", "pq:{o1}:m:mid"], "mid", "2", "Priority", "100")
    pq.fcall(client, "pq_enqueue", ["pq:{o1}", "pq:{o1}:m:hi"],  "hi",  "3", "Priority", "5")
    pq.fcall(client, "pq_enqueue", ["pq:{o1}", "pq:{o1}:m:min"], "min", "4", "Priority", "-9007199254740992")
    pq.fcall(client, "pq_enqueue", ["pq:{o1}", "pq:{o1}:m:max"], "max", "5", "Priority", "9007199254740992")

    # Ascending by score: min(-2^53) < hi(5) < mid(100) < low(1000) < max(2^53).
    expected = [_member(4, "min"), _member(3, "hi"), _member(2, "mid"),
                _member(1, "low"), _member(5, "max")]
    assert client.zrange("pq:{o1}", 0, -1) == expected


def test_fifo_within_equal_priority(client):
    client.delete("pq:{f1}", "pq:{f1}:m:a", "pq:{f1}:m:b", "pq:{f1}:m:c")
    # Enqueued out of order (b, a, c) but with sequences 11, 10, 12 at equal Priority.
    pq.fcall(client, "pq_enqueue", ["pq:{f1}", "pq:{f1}:m:b"], "b", "11", "Priority", "50")
    pq.fcall(client, "pq_enqueue", ["pq:{f1}", "pq:{f1}:m:a"], "a", "10", "Priority", "50")
    pq.fcall(client, "pq_enqueue", ["pq:{f1}", "pq:{f1}:m:c"], "c", "12", "Priority", "50")
    expected = [_member(10, "a"), _member(11, "b"), _member(12, "c")]
    assert client.zrange("pq:{f1}", 0, -1) == expected


def test_stored_message_fidelity(client):
    client.delete("pq:{r1}", "pq:{r1}:m:1")
    pq.fcall(client, "pq_enqueue", ["pq:{r1}", "pq:{r1}:m:1"],
             "1", "1", "Payload", "order-42", "Priority", "5")
    msg = pq.fcall_ro(client, "pq_read", ["pq:{r1}:m:1"])
    assert "order-42" in pq.deep(msg)
    assert client.zscore("pq:{r1}", _member(1, "1")) == 5.0
    assert client.hget("pq:{r1}:m:1", "ReadAttempts") == "0"
    assert client.hget("pq:{r1}:m:1", "DirtyBit") == "0"
    assert client.hget("pq:{r1}:m:1", "Priority") == "5"
