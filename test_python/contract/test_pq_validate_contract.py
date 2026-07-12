"""Mirrors test_bash/contract/test_pq_validate_contract.sh: pq_validate takes no KEYS
(numkeys 0), is FCALL_RO-callable, returns VALID for valid/empty input, and reports
EINVAL (out-of-range value) / EFIELD (unknown field) with the offending field name."""
import pqsupport as pq


def test_pq_validate_contract(client):
    assert pq.deep(pq.fcall_ro(client, "pq_validate", [], "Priority", "5", "DirtyBit", "true")) == "VALID"
    assert pq.deep(pq.fcall_ro(client, "pq_validate", [])) == "VALID"

    pq.assert_error("EINVAL: ReadAttempts", pq.fcall_ro, client, "pq_validate", [], "ReadAttempts", "-1")
    pq.assert_error("EFIELD: Nope", pq.fcall_ro, client, "pq_validate", [], "Nope", "1")
