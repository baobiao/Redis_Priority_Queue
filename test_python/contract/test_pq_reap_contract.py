"""Mirrors test_bash/contract/test_pq_reap_contract.sh: KEYS[1]=DLQ, KEYS[2]=prefix; ARGV =
now, retention, limit; returns a {removed,scanned,truncated} map. An expired entry removes
both the member and its Hash. Write-flag rejected under FCALL_RO. Errors:
EKEYS/ENOW/ERET/ELIMIT/ETAG/EMALFORMED.

The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster those
keys span slots, so the cross-slot call is rejected before the Lua runs."""
import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport as pq


def test_pq_reap_contract(client):
    dl = "dlq:{rc}"
    pfx = "pq:{rc}:m:"
    h1 = "pq:{rc}:m:1"
    client.delete(dl, h1)

    # Empty DLQ -> zero map.
    empty = pq.deep(pq.fcall(client, "pq_reap", [dl, pfx], "1000", "1000", "10"))
    assert "removed" in empty
    assert "scanned" in empty
    assert "truncated" in empty

    # One expired entry -> removed (member + Hash).
    pq.fcall(client, "pq_create", [h1], "Priority", "5", "Payload", "x", "DeadLetteredAt", "100")
    member = "%020d:%s" % (1, "1")
    client.zadd(dl, {member: 5})
    reaped = pq.deep(pq.fcall(client, "pq_reap", [dl, pfx], "100000", "1000", "10"))
    assert "removed" in reaped
    assert client.zscore(dl, member) is None
    assert client.exists(h1) == 0

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_reap", [dl], "1000", "1000", "10")

    # Invalid args.
    pq.assert_error("ENOW", pq.fcall, client, "pq_reap", [dl, pfx], "-1", "1000", "10")
    pq.assert_error("ERET", pq.fcall, client, "pq_reap", [dl, pfx], "1000", "-1", "10")
    pq.assert_error("ELIMIT", pq.fcall, client, "pq_reap", [dl, pfx], "1000", "1000", "0")

    # Tag mismatch -> ETAG (standalone) / cross-slot rejection (cluster).
    if isinstance(client, RedisCluster):
        with pytest.raises(redis.exceptions.RedisClusterException):
            pq.fcall(client, "pq_reap", ["dlq:{rc}", "pq:{other}:m:"], "1000", "1000", "10")
    else:
        pq.assert_error("ETAG", pq.fcall, client, "pq_reap", ["dlq:{rc}", "pq:{other}:m:"], "1000", "1000", "10")

    # Non-zset DLQ -> EMALFORMED.
    client.delete("str:{rc}")
    client.set("str:{rc}", "notazset")
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_reap", ["str:{rc}", "str:{rc}:m:"], "1000", "1000", "10")

    # Write function: rejected under FCALL_RO.
    pq.assert_rejected_ro(client, "pq_reap", [dl, pfx], "1000", "1000", "10")
