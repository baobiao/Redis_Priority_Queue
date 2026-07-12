"""Mirrors test_bash/contract/test_pq_create_contract.sh: pq_create returns OK for
all-defaults and for supplied field pairs, and rejects odd ARGV (EARGS), unknown fields
(EFIELD), and duplicate fields (EDUP)."""
import pqsupport as pq


def test_pq_create_contract(client):
    client.delete("q:{c1}")

    assert pq.deep(pq.fcall(client, "pq_create", ["q:{c1}"])) == "OK"
    assert pq.deep(pq.fcall(client, "pq_create", ["q:{c1}"],
                            "Payload", "hello", "Priority", "5")) == "OK"

    pq.assert_error("EARGS", pq.fcall, client, "pq_create", ["q:{c1}"], "Payload")
    pq.assert_error("EFIELD", pq.fcall, client, "pq_create", ["q:{c1}"], "Color", "red")
    pq.assert_error("EDUP", pq.fcall, client, "pq_create", ["q:{c1}"], "Priority", "1", "Priority", "2")
