"""Mirrors test_bash/integration/test_pq_retention.sh: DLQ retention. Dead-lettering
stamps DeadLetteredAt=now; pq_reap permanently removes (member + Hash) entries older
than the retention window and keeps within-window ones; it is bounded by `limit`
(truncated flag); it cleans dangling members; and pq_redrive clears DeadLetteredAt."""
import pqsupport as pq


def test_stamp_and_reap_window(client):
    q, pfx, dl = "pq:{rt}", "pq:{rt}:m:", "dlq:{rt}"
    client.delete(q, dl, pfx + "7")
    pq.fcall(client, "pq_enqueue", [q, pfx + "7"], "7", "7", "Priority", "5", "Payload", "job")
    m7 = "%020d:%s" % (7, "7")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "1000", "30000", "0", "1")  # RA 0<1 -> leased, RA=1
    pq.fcall(client, "pq_nack", [pfx + "7"], "1")
    pq.fcall(client, "pq_dequeue", [q, pfx, dl], "100000", "30000", "0", "1")  # RA=1>=1 -> dead-lettered at 100000
    assert client.hget(pfx + "7", "DeadLetteredAt") == "100000"  # dead-letter stamps DeadLetteredAt=now
    assert client.zscore(dl, m7) == 5.0  # in DLQ before reap
    # now=120000: age 20000 < 30000 -> kept.
    out = pq.fcall(client, "pq_reap", [dl, pfx], "120000", "30000", "100")
    assert "removed" in pq.deep(out)  # within-window reap removes 0
    assert client.zscore(dl, m7) == 5.0  # kept: still in DLQ
    # now=140000: age 40000 >= 30000 -> removed (member + Hash).
    out = pq.fcall(client, "pq_reap", [dl, pfx], "140000", "30000", "100")
    assert "removed" in pq.deep(out)  # expired reap reports removed
    assert client.zscore(dl, m7) is None  # removed from DLQ
    assert client.exists(pfx + "7") == 0  # message Hash deleted


def test_bounded_by_limit(client):
    q2, pfx2, dl2 = "pq:{rb}", "pq:{rb}:m:", "dlq:{rb}"
    client.delete(q2, dl2, pfx2 + "1", pfx2 + "2", pfx2 + "3")
    for i in (1, 2, 3):
        pq.fcall(client, "pq_create", [pfx2 + str(i)],
                 "Priority", "5", "Payload", "p%d" % i, "DeadLetteredAt", "100000")
        client.zadd(dl2, {"%020d:%s" % (i, i): 5})
    out = pq.fcall(client, "pq_reap", [dl2, pfx2], "200000", "1000", "2")
    assert "truncated" in pq.deep(out)  # bounded reap examined at most limit -> truncated
    assert client.zcard(dl2) == 1  # DLQ down to 1 after first bounded reap
    pq.fcall(client, "pq_reap", [dl2, pfx2], "200000", "1000", "2")
    assert client.zcard(dl2) == 0  # DLQ drained after second reap


def test_dangling_member_cleaned(client):
    q3, pfx3, dl3 = "pq:{rd}", "pq:{rd}:m:", "dlq:{rd}"
    client.delete(q3, dl3)
    client.zadd(dl3, {"%020d:%s" % (9, 9): 5})  # member with no Hash
    pq.fcall(client, "pq_reap", [dl3, pfx3], "200000", "1000", "100")
    assert client.zcard(dl3) == 0  # dangling member cleaned from DLQ


def test_redrive_clears_deadlettered_at(client):
    q4, pfx4, dl4 = "pq:{rr}", "pq:{rr}:m:", "dlq:{rr}"
    client.delete(q4, dl4, pfx4 + "5")
    pq.fcall(client, "pq_create", [pfx4 + "5"],
             "Priority", "5", "Payload", "z", "DeadLetteredAt", "100000")
    m5 = "%020d:%s" % (5, "5")
    client.zadd(dl4, {m5: 5})
    pq.fcall(client, "pq_redrive", [dl4, q4, pfx4 + "5"], m5)
    assert client.hget(pfx4 + "5", "DeadLetteredAt") == "0"  # redrive clears DeadLetteredAt to 0
    assert client.zscore(q4, m5) == 5.0  # redriven message back in source
