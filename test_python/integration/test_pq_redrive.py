"""Mirrors test_bash/integration/test_pq_redrive.sh: redrive a message from the DLQ
back to the source. The member moves DLQ -> source at score=Priority (verbatim),
delivery state resets (ReadAttempts=0, DirtyBit=0) while ReadDateTime is retained,
and it is redelivered on the next dequeue; a member not in the DLQ is a NOOP; a
member already in the source is rejected (EQDUP) with no duplicate."""
import pqsupport as pq


def test_redrive_resets_and_redelivers(client):
    q, pfx, dl = "pq:{rd}", "pq:{rd}:m:", "dlq:{rd}"
    client.delete(q, dl, pfx + "G")
    pq.fcall(client, "pq_enqueue", [q, pfx + "G"], "G", "1", "Priority", "5", "Payload", "PAY-G")
    m_g = "%020d:%s" % (1, "G")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "1")  # RA 0<1 -> leased, RA=1, RDT=1000
    pq.fcall(client, "pq_nack", [pfx + "G"], "1")                            # RA=1, DirtyBit=0
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "2000", "30000", "0", "1")  # RA=1>=1 -> dead-lettered
    assert client.zscore(dl, m_g) == 5.0  # G is in the DLQ before redrive

    out = pq.fcall(client, "pq_redrive", [dl, q, pfx + "G"], m_g)
    assert pq.deep(out) == "OK"  # redrive returns OK
    assert client.zscore(q, m_g) == 5.0  # G back in the source at score=Priority
    assert client.zscore(dl, m_g) is None  # G removed from the DLQ
    assert client.hget(pfx + "G", "ReadAttempts") == "0"  # redrive reset ReadAttempts=0
    assert client.hget(pfx + "G", "DirtyBit") == "0"  # redrive reset DirtyBit=0
    assert client.hget(pfx + "G", "ReadDateTime") == "1000"  # redrive retained ReadDateTime

    # Redelivered on the next dequeue (below the cap after reset).
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "5000", "30000", "0", "1")
    assert "PAY-G" in pq.deep(out)  # redriven G is delivered again

    # ---- NOOP when the member is not in the DLQ ----
    out = pq.fcall(client, "pq_redrive", [dl, q, pfx + "G"], m_g)
    assert pq.deep(out) == "NOOP"  # redrive of a non-DLQ member -> NOOP


def test_reject_already_in_source(client):
    q2, pfx2, dl2 = "pq:{rd2}", "pq:{rd2}:m:", "dlq:{rd2}"
    client.delete(q2, dl2, pfx2 + "H")
    pq.fcall(client, "pq_enqueue", [q2, pfx2 + "H"], "H", "1", "Priority", "5", "Payload", "PAY-H")
    m_h = "%020d:%s" % (1, "H")
    client.zadd(dl2, {m_h: 5})  # H present in BOTH source and DLQ
    pq.assert_error("EQDUP", pq.fcall, client, "pq_redrive", [dl2, q2, pfx2 + "H"], m_h)
    assert client.zscore(q2, m_h) == 5.0  # source still holds H (unchanged)
    assert client.zscore(dl2, m_h) == 5.0  # DLQ copy of H untouched by the rejected redrive
