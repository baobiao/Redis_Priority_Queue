"""Mirrors test_bash/unit/test_pq_visibleat_field_validation.sh: the VisibleAt
field validated through validate/create/enqueue. A valid VisibleAt is accepted; a
non-integer / negative / >2^53 value is rejected with PQ EINVAL: VisibleAt,
writing nothing.

MAX = 9007199254740992 (2^53) is accepted; 9007199254740994 (2^53+2, the next
integer representable as a double above MAX_SAFE_INT) is rejected - kept verbatim."""
import pqsupport as pq

MAX = "9007199254740992"  # 2^53


def test_visibleat_field_validation(client):
    pq.load(client)

    # Valid values accepted (validate is no-writes; create stores).
    for v in ("0", "1", "1000", MAX):
        assert pq.deep(pq.fcall_ro(client, "pq_validate", [], "VisibleAt", v)) == "VALID"

    # Invalid values rejected with EINVAL: VisibleAt.
    for bad in ("-1", "1.5", "abc", "9007199254740994"):
        pq.assert_error("EINVAL: VisibleAt", pq.fcall_ro, client, "pq_validate", [], "VisibleAt", bad)

    # create rejects a bad VisibleAt and writes nothing.
    client.delete("q:{vf}:m:1")
    pq.assert_error("EINVAL: VisibleAt", pq.fcall, client, "pq_create", ["q:{vf}:m:1"],
                    "Priority", "5", "VisibleAt", "-5")
    assert client.exists("q:{vf}:m:1") == 0

    # enqueue rejects a bad VisibleAt and writes neither the Hash nor the queue member.
    client.delete("pq:{vf}", "pq:{vf}:m:1")
    pq.assert_error("EINVAL: VisibleAt", pq.fcall, client, "pq_enqueue", ["pq:{vf}", "pq:{vf}:m:1"],
                    "1", "1", "Priority", "5", "VisibleAt", "notanum")
    assert client.exists("pq:{vf}:m:1") == 0
    assert client.zcard("pq:{vf}") == 0

    # A valid VisibleAt is stored and read back.
    client.delete("q:{vf}:m:2")
    pq.fcall(client, "pq_create", ["q:{vf}:m:2"], "Priority", "5", "VisibleAt", "12345")
    assert client.hget("q:{vf}:m:2", "VisibleAt") == "12345"
