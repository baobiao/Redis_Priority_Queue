"""Mirrors test_bash/integration/test_pq_deadletter.sh: dead-letter at dequeue
(SQS-style max-receive cap). An available message whose ReadAttempts >= cap is moved
to the DLQ (index-only) instead of being leased; an unexpired in-flight message is
never dead-lettered; an expired-lease over-cap message is; a below-cap message is
delivered; omitting the DLQ/cap reproduces Feature 003 exactly."""
import pqsupport as pq


def test_scenario_a_cap_reached_moved_to_dlq(client):
    q, pfx, dl = "pq:{dlA}", "pq:{dlA}:m:", "dlq:{dlA}"
    client.delete(q, dl, pfx + "A")
    pq.fcall(client, "pq_enqueue", [q, pfx + "A"], "A", "1", "Priority", "5", "Payload", "PAY-A")
    m_a = "%020d:%s" % (1, "A")
    # Two deliver-then-nack cycles bring ReadAttempts to 2 (= cap).
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "2")
    pq.fcall(client, "pq_nack", [pfx + "A"], "1")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "2000", "30000", "0", "2")
    pq.fcall(client, "pq_nack", [pfx + "A"], "2")
    assert client.hget(pfx + "A", "ReadAttempts") == "2"  # A at cap: ReadAttempts=2
    # Next dead-letter dequeue: A is available (DirtyBit=0) and ReadAttempts>=cap -> DLQ.
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "3000", "30000", "0", "2")
    assert pq.deep(out) == ""  # poison A not delivered (null reply)
    assert client.zscore(dl, m_a) == 5.0  # A moved to DLQ at score=Priority
    assert client.zscore(q, m_a) is None  # A removed from the source
    assert client.hget(pfx + "A", "Payload") == "PAY-A"  # A message Hash untouched


def test_scenario_b_below_cap_delivered(client):
    q, pfx, dl = "pq:{dlB}", "pq:{dlB}:m:", "dlq:{dlB}"
    client.delete(q, dl, pfx + "B")
    pq.fcall(client, "pq_enqueue", [q, pfx + "B"], "B", "1", "Priority", "5", "Payload", "PAY-B")
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "2")
    assert "PAY-B" in pq.deep(out)  # below-cap B is leased and returned
    m_b = "%020d:%s" % (1, "B")
    assert client.zscore(dl, m_b) is None  # B NOT dead-lettered


def test_scenario_c_inflight_not_deadlettered_until_expired(client):
    q, pfx, dl = "pq:{dlC}", "pq:{dlC}:m:", "dlq:{dlC}"
    client.delete(q, dl, pfx + "C")
    pq.fcall(client, "pq_enqueue", [q, pfx + "C"], "C", "1", "Priority", "5", "Payload", "PAY-C")
    m_c = "%020d:%s" % (1, "C")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "2")  # RA=1, in-flight
    pq.fcall(client, "pq_nack", [pfx + "C"], "1")                            # RA=1, DirtyBit=0
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "2000", "30000", "0", "2")  # RA=2, in-flight, RDT=2000
    assert client.hget(pfx + "C", "DirtyBit") == "1"  # C in-flight after 2nd lease
    # now=2001: lease NOT expired (1ms < 30000) and RA>=cap -> C must be skipped, not dead-lettered.
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "2001", "30000", "0", "2")
    assert pq.deep(out) == ""  # unexpired in-flight over-cap yields null
    assert client.zscore(dl, m_c) is None  # C NOT dead-lettered while in-flight
    assert client.zscore(q, m_c) == 5.0  # C still in the source queue
    # now=40000: lease expired (38000ms >= 30000) and RA>=cap -> C is dead-lettered.
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "40000", "30000", "0", "2")
    assert pq.deep(out) == ""  # expired-lease over-cap yields null
    assert client.zscore(dl, m_c) == 5.0  # C moved to DLQ once lease expired
    assert client.zscore(q, m_c) is None  # C removed from the source


def test_scenario_e_f003_parity_no_dlq_never_deadletters(client):
    q, pfx = "pq:{dlE}", "pq:{dlE}:m:"
    client.delete(q, pfx + "E")
    pq.fcall(client, "pq_enqueue", [q, pfx + "E"], "E", "1", "Priority", "5", "Payload", "PAY-E")
    m_e = "%020d:%s" % (1, "E")
    pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")
    pq.fcall(client, "pq_nack", [pfx + "E"], "1")
    pq.fcall(client, "pq_dequeue", [q, pfx], "2000", "30000")
    pq.fcall(client, "pq_nack", [pfx + "E"], "2")
    # ReadAttempts=2, but the 2-key call has no cap -> must lease, never dead-letter.
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "3000", "30000")
    assert "PAY-E" in pq.deep(out)  # 2-key dequeue still delivers an over-cap message (F003 parity)
    assert client.zscore(q, m_e) == 5.0  # E remains in the source (not dead-lettered)


def test_scenario_f_no_duplicate_in_dlq(client):
    q, pfx, dl = "pq:{dlF}", "pq:{dlF}:m:", "dlq:{dlF}"
    client.delete(q, dl, pfx + "F")
    pq.fcall(client, "pq_enqueue", [q, pfx + "F"], "F", "1", "Priority", "7", "Payload", "PAY-F")
    m_f = "%020d:%s" % (1, "F")
    client.zadd(dl, {m_f: 7})  # simulate prior DLQ presence
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "2")
    pq.fcall(client, "pq_nack", [pfx + "F"], "1")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "2000", "30000", "0", "2")
    pq.fcall(client, "pq_nack", [pfx + "F"], "2")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "3000", "30000", "0", "2")  # dead-letter F (already in DLQ)
    assert client.zcard(dl) == 1  # DLQ still holds exactly one F member (no duplicate)
    assert client.zscore(q, m_f) is None  # F removed from the source
