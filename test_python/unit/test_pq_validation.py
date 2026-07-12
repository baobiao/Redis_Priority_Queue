"""Mirrors test_bash/unit/test_pq_validation.sh: pq_create validation rules
(invalid values, unknown/duplicate fields) and the guarantee that nothing is
stored on failure."""
import pqsupport as pq


def test_validation_rules(client):
    pq.load(client)
    client.delete("q:{bad}")

    pq.assert_error("EINVAL: ReadAttempts", pq.fcall, client, "pq_create", ["q:{bad}"], "ReadAttempts", "-1")
    pq.assert_error("EINVAL: ReadAttempts", pq.fcall, client, "pq_create", ["q:{bad}"], "ReadAttempts", "1.5")
    pq.assert_error("EINVAL: ReadAttempts", pq.fcall, client, "pq_create", ["q:{bad}"], "ReadAttempts", "abc")
    pq.assert_error("EINVAL: DirtyBit", pq.fcall, client, "pq_create", ["q:{bad}"], "DirtyBit", "maybe")
    pq.assert_error("EINVAL: ReadDateTime", pq.fcall, client, "pq_create", ["q:{bad}"], "ReadDateTime", "-7")
    pq.assert_error("EINVAL: Priority", pq.fcall, client, "pq_create", ["q:{bad}"], "Priority", "xx")
    pq.assert_error("EFIELD: Color", pq.fcall, client, "pq_create", ["q:{bad}"], "Color", "red")
    pq.assert_error("EDUP: Priority", pq.fcall, client, "pq_create", ["q:{bad}"], "Priority", "1", "Priority", "2")

    # Nothing stored on any failure.
    assert client.exists("q:{bad}") == 0
