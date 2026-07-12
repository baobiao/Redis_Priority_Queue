"""Mirrors test_bash/integration/test_pq_retry_backoff.sh: retry backoff via nack
with a future VisibleAt. A nacked message with a delay is not redelivered until now >=
VisibleAt, then redelivered with ReadAttempts retained across the delay; a plain nack
is unchanged (Feature 003 parity); fencing intact."""
import pqsupport as pq


def test_backoff_delays_redelivery(client):
    q, pfx = "pq:{bo}", "pq:{bo}:m:"
    client.delete(q, pfx + "1")
    pq.fcall(client, "pq_enqueue", [q, pfx + "1"], "1", "1", "Priority", "5", "Payload", "work")

    # Lease at now=1000 (ReadAttempts=1), then nack with a backoff to VisibleAt=5000.
    pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    out = pq.fcall(client, "pq_nack", [pfx + "1"], "1", "5000")
    assert pq.deep(out) == "OK"  # nack-with-delay returns OK
    assert client.hget(pfx + "1", "DirtyBit") == "0"  # released: DirtyBit=0
    assert client.hget(pfx + "1", "VisibleAt") == "5000"  # VisibleAt set to 5000
    assert client.hget(pfx + "1", "ReadAttempts") == "1"  # ReadAttempts retained (1)
    assert client.hget(pfx + "1", "ReadDateTime") == "1000"  # ReadDateTime retained (1000)

    # Before the backoff elapses -> not redelivered.
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "4999", "30000")
    assert pq.deep(out) == ""  # not redelivered before VisibleAt -> null

    # At/after the backoff -> redelivered, ReadAttempts incremented from the retained value.
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "5000", "30000")
    assert "work" in pq.deep(out)  # redelivered at VisibleAt
    assert client.hget(pfx + "1", "ReadAttempts") == "2"  # ReadAttempts incremented to 2


def test_plain_nack_immediate_and_fencing(client):
    q, pfx = "pq:{bp}", "pq:{bp}:m:"
    client.delete(q, pfx + "2")
    pq.fcall(client, "pq_enqueue", [q, pfx + "2"], "2", "1", "Priority", "5", "Payload", "w2")
    pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    pq.fcall(client, "pq_nack", [pfx + "2"], "1")  # no delay
    assert client.hget(pfx + "2", "VisibleAt") == "0"  # plain nack leaves VisibleAt at default 0
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1001", "30000")
    assert "w2" in pq.deep(out)  # plain-nacked message immediately available (F003 parity)

    # Fencing still applies to a nack-with-delay: a stale token is rejected.
    pq.assert_error("EFENCED", pq.fcall, client, "pq_nack", [pfx + "2"], "999", "5000")
