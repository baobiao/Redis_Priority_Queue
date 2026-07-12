"""Mirrors test_bash/contract/test_function_flags.sh: pq_read/pq_validate/pq_peek carry
the no-writes flag (FCALL_RO-callable) while writers are rejected under FCALL_RO."""
import pqsupport as pq


def test_function_flags(client):
    assert pq.load(client) == pq.LIBRARY  # library registered as priority_queue

    listing = pq.deep(client.function_list())
    assert pq.LIBRARY in listing
    assert "no-writes" in listing

    # Writers must be rejected under FCALL_RO (no no-writes flag).
    pq.assert_rejected_ro(client, "pq_create", ["q:{flag}"])
    pq.assert_rejected_ro(client, "pq_enqueue", ["pq:{flag}", "pq:{flag}:m:1"], "1", "1")
    pq.assert_rejected_ro(client, "pq_dequeue", ["pq:{flag}", "pq:{flag}:m:"], "1000", "30000")
    pq.assert_rejected_ro(client, "pq_ack", ["pq:{flag}", "pq:{flag}:m:1"], "00000000000000000001:1", "1")
    pq.assert_rejected_ro(client, "pq_nack", ["pq:{flag}:m:1"], "1")
    pq.assert_rejected_ro(client, "pq_redrive",
                          ["dlq:{flag}", "pq:{flag}", "pq:{flag}:m:1"], "00000000000000000001:1")

    # pq_peek is no-writes and IS callable via FCALL_RO (empty -> None).
    client.delete("pq:{flag}")
    peek = pq.fcall_ro(client, "pq_peek", ["pq:{flag}", "pq:{flag}:m:"], "1000", "30000")
    assert pq.deep(peek) == ""

    # Reader works under the read-only command.
    client.delete("q:{flag}")
    pq.fcall(client, "pq_create", ["q:{flag}"])
    read = pq.fcall_ro(client, "pq_read", ["q:{flag}"])
    assert "Priority" in pq.deep(read)
