"""Mirrors test_bash/contract/test_pq_read_contract.sh: pq_read is FCALL_RO-callable and
returns the field map; NOTFOUND for an absent key; EMALFORMED for a wrong-type key or a
message missing an original field. Feature 005 adds VisibleAt (sixth field) and Feature 006
adds DeadLetteredAt (seventh field); legacy messages missing only those read as 0."""
import pqsupport as pq


def test_pq_read_contract(client):
    # Different hash tags -> different slots, so delete individually (cluster-safe).
    client.delete("q:{r1}")
    client.delete("q:{absent}")
    client.delete("q:{wrong}")
    pq.fcall(client, "pq_create", ["q:{r1}"], "Payload", "hi", "Priority", "9")

    # read is callable via FCALL_RO (no-writes flag).
    r1 = pq.deep(pq.fcall_ro(client, "pq_read", ["q:{r1}"]))
    assert "hi" in r1
    assert "9" in r1
    assert "ReadAttempts" in r1

    # absent key -> NOTFOUND
    assert pq.deep(pq.fcall_ro(client, "pq_read", ["q:{absent}"])) == "NOTFOUND"

    # wrong type (string at key) -> EMALFORMED
    client.set("q:{wrong}", "notahash")
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_read", ["q:{wrong}"])

    # --- Feature 005: VisibleAt is the sixth returned field ---
    client.delete("q:{rv}")
    pq.fcall(client, "pq_create", ["q:{rv}"], "Priority", "5", "VisibleAt", "4242")
    rv = pq.deep(pq.fcall_ro(client, "pq_read", ["q:{rv}"]))
    assert "VisibleAt" in rv
    assert "4242" in rv

    # Message missing ONLY VisibleAt (stored before Feature 005) reads as VisibleAt=0.
    client.delete("q:{rlegacy}")
    client.hset("q:{rlegacy}", mapping={"ReadAttempts": "0", "DirtyBit": "0",
                                        "ReadDateTime": "0", "Priority": "5", "Payload": "old"})
    rlegacy = pq.deep(pq.fcall_ro(client, "pq_read", ["q:{rlegacy}"]))
    assert "old" in rlegacy
    assert "VisibleAt" in rlegacy

    # Missing an ORIGINAL field still -> EMALFORMED (only VisibleAt is tolerated).
    client.delete("q:{rbad}")
    client.hset("q:{rbad}", mapping={"ReadAttempts": "0", "DirtyBit": "0",
                                     "ReadDateTime": "0", "Priority": "5"})  # no Payload
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_read", ["q:{rbad}"])

    # --- Feature 006: DeadLetteredAt is the seventh returned field ---
    client.delete("q:{rdla}")
    pq.fcall(client, "pq_create", ["q:{rdla}"], "Priority", "5", "DeadLetteredAt", "7777")
    rdla = pq.deep(pq.fcall_ro(client, "pq_read", ["q:{rdla}"]))
    assert "DeadLetteredAt" in rdla
    assert "7777" in rdla

    # Message missing only VisibleAt AND DeadLetteredAt (pre-005/006) reads as 0/0.
    client.delete("q:{rlegacy6}")
    client.hset("q:{rlegacy6}", mapping={"ReadAttempts": "0", "DirtyBit": "0",
                                         "ReadDateTime": "0", "Priority": "5", "Payload": "old2"})
    rlegacy6 = pq.deep(pq.fcall_ro(client, "pq_read", ["q:{rlegacy6}"]))
    assert "old2" in rlegacy6
    assert "DeadLetteredAt" in rlegacy6
