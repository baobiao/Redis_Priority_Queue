"""Mirrors test_bash/contract/test_pq_stats_contract.sh: KEYS = queue, prefix, [DLQ]; ARGV =
now, timeout, [max_scan]. Returns a cheap flat map (depth/dlq_depth/front_priority). It is
no-writes: callable via both FCALL_RO and FCALL, and leaves the message unleased. 2-key and
3-key forms are valid. Errors: EKEYS/ENOW/ETMO/ESCAN/ETAG/EMALFORMED.

The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster those
keys span slots, so the cross-slot call is rejected before the Lua runs."""
import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport as pq


def test_pq_stats_contract(client):
    q = "pq:{sc}"
    pfx = "pq:{sc}:m:"
    h1 = "pq:{sc}:m:1"
    dl = "dlq:{sc}"
    client.delete(q, dl, h1)
    pq.fcall(client, "pq_enqueue", [q, h1], "1", "1", "Priority", "5", "Payload", "x")

    # Cheap tier via FCALL_RO (no-writes): returns depth/dlq_depth/front_priority.
    cheap = pq.deep(pq.fcall_ro(client, "pq_stats", [q, pfx, dl], "1000", "30000"))
    assert "depth" in cheap
    assert "dlq_depth" in cheap
    assert "front_priority" in cheap

    # 2-key form (no DLQ) is valid.
    assert "depth" in pq.deep(pq.fcall_ro(client, "pq_stats", [q, pfx], "1000", "30000"))

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall_ro, client, "pq_stats", [q], "1000", "30000")
    pq.assert_error("EKEYS", pq.fcall_ro, client, "pq_stats", [q, pfx, dl, "x:{sc}"], "1000", "30000")

    # Bad args.
    pq.assert_error("ENOW", pq.fcall_ro, client, "pq_stats", [q, pfx], "-1", "30000")
    pq.assert_error("ETMO", pq.fcall_ro, client, "pq_stats", [q, pfx], "1000", "0")
    pq.assert_error("ESCAN", pq.fcall_ro, client, "pq_stats", [q, pfx], "1000", "30000", "-1")

    # Tag mismatch -> ETAG (standalone) / cross-slot rejection (cluster).
    if isinstance(client, RedisCluster):
        with pytest.raises(redis.exceptions.RedisClusterException):
            pq.fcall_ro(client, "pq_stats", ["pq:{sc}", "pq:{other}:m:"], "1000", "30000")
    else:
        pq.assert_error("ETAG", pq.fcall_ro, client, "pq_stats", ["pq:{sc}", "pq:{other}:m:"], "1000", "30000")

    # Non-zset queue -> EMALFORMED.
    client.delete("str:{sc}")
    client.set("str:{sc}", "notazset")
    pq.assert_error("EMALFORMED", pq.fcall_ro, client, "pq_stats", ["str:{sc}", "str:{sc}:m:"], "1000", "30000")

    # It is no-writes: FCALL (write path) also works, and it left the message unleased.
    assert "depth" in pq.deep(pq.fcall(client, "pq_stats", [q, pfx], "1000", "30000"))
    assert client.hget(h1, "DirtyBit") == "0"
