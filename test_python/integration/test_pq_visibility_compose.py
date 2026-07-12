"""Mirrors test_bash/integration/test_pq_visibility_compose.sh: VisibleAt
composition. read exposes VisibleAt; a pre-005 5-field message reads/dequeues as
VisibleAt=0 (no error); peek single skips a not-yet-visible front message while top-N
reports it with VisibleAt; a not-yet-visible over-cap message is dead-lettered only
once visible; redrive resets VisibleAt to 0."""
import pqsupport as pq


def test_read_exposes_visible_at(client):
    client.delete("q:{cm}:m:1")
    pq.fcall(client, "pq_create", ["q:{cm}:m:1"], "Priority", "5", "Payload", "hi", "VisibleAt", "90000")
    out = pq.fcall_ro(client, "pq_read", ["q:{cm}:m:1"])
    assert "VisibleAt" in pq.deep(out)  # read includes VisibleAt label
    assert "90000" in pq.deep(out)  # read includes VisibleAt value


def test_back_compat_five_field_message(client):
    q, pfx = "pq:{bc}", "pq:{bc}:m:"
    client.delete(q, pfx + "old")
    client.hset(pfx + "old", mapping={
        "ReadAttempts": "0", "DirtyBit": "0", "ReadDateTime": "0", "Priority": "5", "Payload": "OLD"})
    mold = "%020d:%s" % (1, "old")
    client.zadd(q, {mold: 5})
    out = pq.fcall_ro(client, "pq_read", [pfx + "old"])
    assert "OLD" in pq.deep(out)  # legacy 5-field message reads without error (Payload)
    assert "VisibleAt" in pq.deep(out)  # legacy message reports VisibleAt=0
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1", "30000")
    assert "OLD" in pq.deep(out)  # legacy message is immediately visible (dequeued)


def test_peek_single_skips_topn_reports(client):
    q, pfx = "pq:{pv}", "pq:{pv}:m:"
    client.delete(q, pfx + "F")
    pq.fcall(client, "pq_enqueue", [q, pfx + "F"],
             "F", "1", "Priority", "5", "Payload", "PAY-F", "VisibleAt", "8000")
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "7999", "30000")
    assert pq.deep(out) == ""  # single peek skips not-yet-visible -> null
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "7999", "30000", "10")
    assert "PAY-F" in pq.deep(out)  # top-N reports the not-yet-visible member
    assert "8000" in pq.deep(out)  # top-N record carries VisibleAt
    out = pq.fcall_ro(client, "pq_peek", [q, pfx], "8000", "30000")
    assert "PAY-F" in pq.deep(out)  # single peek returns it once visible


def test_dead_letter_deferred_then_redrive_resets(client):
    q, pfx, dl = "pq:{dv}", "pq:{dv}:m:", "dlq:{dv}"
    client.delete(q, dl, pfx + "M")
    pq.fcall(client, "pq_enqueue", [q, pfx + "M"], "M", "1", "Priority", "5", "Payload", "PAY-M")
    m_m = "%020d:%s" % (1, "M")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "1")  # RA 0<1 -> leased, RA=1
    pq.fcall(client, "pq_nack", [pfx + "M"], "1", "5000")                    # RA=1(=cap), hidden until 5000
    out = pq.fcall(client, "pq_dequeue", [q, pfx, dl], "4999", "30000", "0", "1")
    assert pq.deep(out) == ""  # over-cap but not-yet-visible -> null (not dead-lettered)
    assert client.zscore(dl, m_m) is None  # M NOT dead-lettered while hidden
    assert client.zscore(q, m_m) == 5.0  # M still in the source while hidden
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "5000", "30000", "0", "1")  # now visible + over cap -> DLQ
    assert client.zscore(dl, m_m) == 5.0  # M dead-lettered once visible
    assert client.zscore(q, m_m) is None  # M removed from the source

    # --- Redrive resets VisibleAt to 0 ---
    out = pq.fcall(client, "pq_redrive", [dl, q, pfx + "M"], m_m)
    assert pq.deep(out) == "OK"  # redrive returns OK
    assert client.hget(pfx + "M", "VisibleAt") == "0"  # redrive reset VisibleAt to 0
    out = pq.fcall(client, "pq_dequeue", [q, pfx], "1", "30000")
    assert "PAY-M" in pq.deep(out)  # redriven message is immediately deliverable
