"""Mirrors test_bash/unit/test_pq_enqueue_validation.sh: pq_enqueue input
rejection and the no-write guarantee (neither the message Hash nor the queue
index is created on any failure)."""
import pqsupport as pq

Q = "pq:{u1}"
M = "pq:{u1}:m:x"


def test_enqueue_validation(client):
    pq.load(client)
    client.delete(Q, M)

    pq.assert_error("EID", pq.fcall, client, "pq_enqueue", [Q, M], "", "1")
    pq.assert_error("ESEQ", pq.fcall, client, "pq_enqueue", [Q, M], "x", "-1")
    pq.assert_error("ESEQ", pq.fcall, client, "pq_enqueue", [Q, M], "x", "1.5")
    pq.assert_error("ESEQ", pq.fcall, client, "pq_enqueue", [Q, M], "x", "abc")
    pq.assert_error("EINVAL: Priority", pq.fcall, client, "pq_enqueue", [Q, M], "x", "1", "Priority", "foo")
    pq.assert_error("EFIELD: Color", pq.fcall, client, "pq_enqueue", [Q, M], "x", "1", "Color", "red")
    pq.assert_error("EDUP: Priority", pq.fcall, client, "pq_enqueue", [Q, M], "x", "1", "Priority", "1", "Priority", "2")
    pq.assert_error("EARGS", pq.fcall, client, "pq_enqueue", [Q, M], "x", "1", "Payload")

    # Nothing written to either structure after any failure.
    assert client.exists(M) == 0
    assert client.exists(Q) == 0
