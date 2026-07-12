"""Mirrors test_bash/contract/test_pq_nack_contract.sh: KEYS[1]=message Hash, ARGV[1]=token,
optional ARGV[2]=VisibleAt (Feature 005). Idempotent NOOP for an absent message; EKEYS on
wrong key count; EARGS on a non-integer token; EFENCED on a stale token; EVIS on an invalid
VisibleAt (fail-before-write); OK sets VisibleAt; ENOTLEASED once released; write-flag
rejected under FCALL_RO."""
import pqsupport as pq


def test_pq_nack_contract(client):
    q = "pq:{nc}"
    m1 = "pq:{nc}:m:1"
    pfx = "pq:{nc}:m:"
    client.delete(q, m1)

    # Absent message -> idempotent NOOP.
    assert pq.deep(pq.fcall(client, "pq_nack", [m1], "1")) == "NOOP"

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_nack", [q, m1], "1")

    # Non-integer token -> EARGS.
    pq.assert_error("EARGS", pq.fcall, client, "pq_nack", [m1], "notanum")

    pq.fcall(client, "pq_enqueue", [q, m1], "1", "1", "Priority", "5", "Payload", "w")
    pq.fcall(client, "pq_dequeue", [q, pfx], "1000", "30000")  # lease: token=1, DirtyBit=1

    # Stale token -> EFENCED.
    pq.assert_error("EFENCED", pq.fcall, client, "pq_nack", [m1], "999")

    # Optional VisibleAt: invalid -> EVIS (fail-before-write).
    pq.assert_error("EVIS", pq.fcall, client, "pq_nack", [m1], "1", "-1")

    # Valid nack with VisibleAt -> OK, sets VisibleAt.
    assert pq.deep(pq.fcall(client, "pq_nack", [m1], "1", "4000")) == "OK"
    assert client.hget(m1, "VisibleAt") == "4000"

    # Not in-flight now (released) -> ENOTLEASED on a second settle.
    pq.assert_error("ENOTLEASED", pq.fcall, client, "pq_nack", [m1], "1")

    # Write function: rejected under FCALL_RO.
    pq.assert_rejected_ro(client, "pq_nack", [m1], "1")
