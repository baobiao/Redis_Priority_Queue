"""Mirrors test_bash/contract/test_pq_redrive_contract.sh: KEYS = DLQ, source, message Hash;
ARGV = member. OK on a move (member re-scored into the source), NOOP when absent from the
DLQ. Write-flag rejected under FCALL_RO. Errors: EKEYS/EARGS/ETAG.

The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster those
keys span slots, so the cross-slot call is rejected before the Lua runs."""
import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport as pq


def test_pq_redrive_contract(client):
    q = "pq:{rc}"
    dl = "dlq:{rc}"
    msg_key = "pq:{rc}:m:k"
    client.delete(q, dl, msg_key)

    # Place k in the DLQ with its Hash at the normal source-prefixed key.
    pq.fcall(client, "pq_enqueue", [q, msg_key], "k", "1", "Priority", "5", "Payload", "hello")
    member = "%020d:%s" % (1, "k")
    client.zrem(q, member)
    client.zadd(dl, {member: 5})

    # Move it back -> OK; then a second redrive is a NOOP (no longer in the DLQ).
    assert pq.deep(pq.fcall(client, "pq_redrive", [dl, q, msg_key], member)) == "OK"
    assert client.zscore(q, member) == 5
    assert pq.deep(pq.fcall(client, "pq_redrive", [dl, q, msg_key], member)) == "NOOP"

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_redrive", [dl, q], member)

    # Empty member -> EARGS.
    pq.assert_error("EARGS", pq.fcall, client, "pq_redrive", [dl, q, msg_key], "")

    # Tag mismatch across the three keys -> ETAG (standalone) / cross-slot (cluster).
    if isinstance(client, RedisCluster):
        with pytest.raises(redis.exceptions.RedisClusterException):
            pq.fcall(client, "pq_redrive", ["dlq:{rc}", "pq:{other}", "pq:{rc}:m:k"], member)
    else:
        pq.assert_error("ETAG", pq.fcall, client, "pq_redrive",
                        ["dlq:{rc}", "pq:{other}", "pq:{rc}:m:k"], member)

    # Write function: must be rejected under FCALL_RO.
    pq.assert_rejected_ro(client, "pq_redrive", [dl, q, msg_key], member)
