"""Mirrors test_bash/contract/test_pq_enqueue_contract.sh: pq_enqueue takes KEYS[1]=queue
Sorted Set, KEYS[2]=message Hash, ARGV = id, sequence, then field pairs; returns OK. Wrong
key count -> EKEYS. It is a write function: rejected under FCALL_RO."""
import pqsupport as pq


def test_pq_enqueue_contract(client):
    client.delete("pq:{c1}", "pq:{c1}:m:1")

    assert pq.deep(pq.fcall(client, "pq_enqueue", ["pq:{c1}", "pq:{c1}:m:1"],
                            "1", "1", "Payload", "hello", "Priority", "5")) == "OK"

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_enqueue", ["pq:{c1}"], "1", "1")

    # Write function: rejected under FCALL_RO.
    client.delete("pq:{c3}", "pq:{c3}:m:1")
    pq.assert_rejected_ro(client, "pq_enqueue", ["pq:{c3}", "pq:{c3}:m:1"], "1", "1")
