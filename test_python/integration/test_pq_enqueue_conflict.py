"""Mirrors test_bash/integration/test_pq_enqueue_conflict.sh: occupied message location
(EEXISTS), wrong-type queue key (EMALFORMED), already-enqueued member (EQDUP), and the
atomic no-write-on-failure guarantee. Spec: FR-009/FR-010/FR-011/FR-012, SC-004/SC-006."""
import pqsupport as pq


def _member(seq, mid):
    return f"{seq:020d}:{mid}"


def test_occupied_message_location_eexists(client):
    client.delete("pq:{x1}", "pq:{x1}:m:1")
    pq.fcall(client, "pq_enqueue", ["pq:{x1}", "pq:{x1}:m:1"], "1", "1", "Priority", "5")
    before = client.zcard("pq:{x1}")
    pq.assert_error("EEXISTS", pq.fcall, client, "pq_enqueue",
                    ["pq:{x1}", "pq:{x1}:m:1"], "1", "2", "Priority", "9")
    assert client.zcard("pq:{x1}") == before
    assert client.zscore("pq:{x1}", _member(1, "1")) == 5.0


def test_wrong_type_queue_emalformed(client):
    client.delete("pq:{x2}", "pq:{x2}:m:1")
    client.set("pq:{x2}", "notazset")
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_enqueue",
                    ["pq:{x2}", "pq:{x2}:m:1"], "1", "1", "Priority", "5")
    assert client.exists("pq:{x2}:m:1") == 0


def test_already_enqueued_member_eqdup(client):
    client.delete("pq:{x3}", "pq:{x3}:m:1", "pq:{x3}:m:2")
    pq.fcall(client, "pq_enqueue", ["pq:{x3}", "pq:{x3}:m:1"], "dup", "7", "Priority", "5")
    before = client.zcard("pq:{x3}")
    # Same id+sequence -> same member -> EQDUP, even via a different message key.
    pq.assert_error("EQDUP", pq.fcall, client, "pq_enqueue",
                    ["pq:{x3}", "pq:{x3}:m:2"], "dup", "7", "Priority", "9")
    assert client.zcard("pq:{x3}") == before
    assert client.exists("pq:{x3}:m:2") == 0
