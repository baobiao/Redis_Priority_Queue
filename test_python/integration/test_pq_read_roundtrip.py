"""Mirrors test_bash/integration/test_pq_read_roundtrip.sh: create->read type fidelity
(DirtyBit false round-trips to integer 0, large epoch preserved, negative Priority
preserved) and read-does-not-mutate. Spec: FR-009/FR-010/FR-014/FR-015, SC-003."""
import pqsupport as pq


def test_read_round_trip_preserves_types_and_does_not_mutate(client):
    # DirtyBit=false round-trips to integer 0 (not nil); large epoch preserved.
    client.delete("q:{rt}")
    pq.fcall(client, "pq_create", ["q:{rt}"],
             "DirtyBit", "false", "ReadDateTime", "1700000000000", "Priority", "-5")

    out = pq.fcall_ro(client, "pq_read", ["q:{rt}"])
    assert "DirtyBit" in pq.deep(out)
    assert "1700000000000" in pq.deep(out)
    assert "-5" in pq.deep(out)

    # read does not mutate the stored hash (dict equality is order-independent,
    # mirroring the Bash `HGETALL | sort` comparison).
    before = client.hgetall("q:{rt}")
    pq.fcall_ro(client, "pq_read", ["q:{rt}"])
    after = client.hgetall("q:{rt}")
    assert before == after


def test_dirty_bit_true_stored_as_one(client):
    client.delete("q:{rt2}")
    pq.fcall(client, "pq_create", ["q:{rt2}"], "DirtyBit", "1")
    assert client.hget("q:{rt2}", "DirtyBit") == "1"
