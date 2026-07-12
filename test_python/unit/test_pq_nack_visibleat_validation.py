"""Mirrors test_bash/unit/test_pq_nack_visibleat_validation.sh: nack's optional
VisibleAt argument (ARGV[2]) validation. An invalid value (non-integer / negative
/ >2^53) is rejected with PQ EVIS and writes nothing (fail-before-write); a valid
one is applied.

9007199254740994 = 2^53+2 is the next integer representable as a double above
MAX_SAFE_INT (2^53+1 is not representable and rounds down to 2^53, which is in
range) - kept verbatim to probe the IEEE-754 boundary."""
import pqsupport as pq

Q = "pq:{nv}"
PFX = "pq:{nv}:m:"


def test_nack_visibleat_validation(client):
    pq.load(client)
    client.delete(Q, PFX + "1")
    pq.fcall(client, "pq_enqueue", [Q, PFX + "1"], "1", "1", "Priority", "5", "Payload", "w")
    pq.fcall(client, "pq_dequeue", [Q, PFX], "1000", "30000")  # lease (token=1, DirtyBit=1)

    # Invalid VisibleAt at nack -> EVIS, and the lease is untouched.
    for bad in ("-1", "1.5", "abc", "9007199254740994"):
        pq.assert_error("EVIS", pq.fcall, client, "pq_nack", [PFX + "1"], "1", bad)
    assert client.hget(PFX + "1", "DirtyBit") == "1"
    assert client.hget(PFX + "1", "VisibleAt") == "0"

    # A valid VisibleAt is applied (released + hidden).
    assert pq.deep(pq.fcall(client, "pq_nack", [PFX + "1"], "1", "7000")) == "OK"
    assert client.hget(PFX + "1", "DirtyBit") == "0"
    assert client.hget(PFX + "1", "VisibleAt") == "7000"
