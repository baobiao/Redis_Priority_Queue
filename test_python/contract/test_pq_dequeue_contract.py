"""Mirrors test_bash/contract/test_pq_dequeue_contract.sh: KEYS/ARGV shape, handle vs null
reply, EKEYS on wrong key count, and the write-flag (rejected under FCALL_RO). Feature 004
adds the optional KEYS[3]=DLQ + trailing cap ARGV with ECAP/ETAG/EMALFORMED.

The ETAG case uses mismatched hash tags on purpose. On standalone the Lua guard fires
(PQ ETAG). On cluster those keys span slots, so the client rejects the cross-slot call
before the Lua runs -- the single-slot enforcement is the equivalent protection."""
import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport as pq


def test_pq_dequeue_contract(client):
    client.delete("pq:{c1}", "pq:{c1}:m:x")

    # Empty queue -> null reply (empty output).
    assert pq.deep(pq.fcall(client, "pq_dequeue", ["pq:{c1}", "pq:{c1}:m:"], "1000", "30000")) == ""

    # Enqueue one, then acquire -> the handle carries id/member/ReadAttempts/Payload.
    pq.fcall(client, "pq_enqueue", ["pq:{c1}", "pq:{c1}:m:x"],
             "x", "1", "Payload", "hello", "Priority", "5")
    handle = pq.deep(pq.fcall(client, "pq_dequeue", ["pq:{c1}", "pq:{c1}:m:"], "1000", "30000"))
    assert "x" in handle
    assert ("%020d:%s" % (1, "x")) in handle
    assert "ReadAttempts" in handle
    assert "hello" in handle

    # Wrong key count -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_dequeue", ["pq:{c1}"], "1000", "30000")

    # Write function: must be rejected under FCALL_RO.
    pq.assert_rejected_ro(client, "pq_dequeue", ["pq:{c1}", "pq:{c1}:m:"], "1000", "30000")

    # --- Feature 004 dead-letter mode: optional KEYS[3]=DLQ + trailing cap ARGV ---
    client.delete("pq:{c1}", "pq:{c1}:m:x", "dlq:{c1}")
    pq.fcall(client, "pq_enqueue", ["pq:{c1}", "pq:{c1}:m:x"],
             "x", "1", "Payload", "hello", "Priority", "5")

    # 3-key call with a valid cap: below-cap message is leased and returned as usual.
    assert "hello" in pq.deep(pq.fcall(client, "pq_dequeue",
                                       ["pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"], "1000", "30000", "0", "5"))

    # Too many keys -> EKEYS.
    pq.assert_error("EKEYS", pq.fcall, client, "pq_dequeue",
                    ["pq:{c1}", "pq:{c1}:m:", "dlq:{c1}", "x:{c1}"], "1000", "30000")

    # Dead-letter mode with a missing/invalid cap -> ECAP.
    pq.assert_error("ECAP", pq.fcall, client, "pq_dequeue",
                    ["pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"], "1000", "30000")
    pq.assert_error("ECAP", pq.fcall, client, "pq_dequeue",
                    ["pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"], "1000", "30000", "0", "0")

    # DLQ key not sharing the source hash tag -> ETAG (standalone) / cross-slot (cluster).
    if isinstance(client, RedisCluster):
        with pytest.raises(redis.exceptions.RedisClusterException):
            pq.fcall(client, "pq_dequeue", ["pq:{c1}", "pq:{c1}:m:", "dlq:{other}"], "1000", "30000", "0", "5")
    else:
        pq.assert_error("ETAG", pq.fcall, client, "pq_dequeue",
                        ["pq:{c1}", "pq:{c1}:m:", "dlq:{other}"], "1000", "30000", "0", "5")

    # DLQ key holding a non-sorted-set value -> EMALFORMED.
    client.delete("dlq:{c1}")
    client.set("dlq:{c1}", "not-a-zset")
    pq.assert_error("EMALFORMED", pq.fcall, client, "pq_dequeue",
                    ["pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"], "1000", "30000", "0", "5")
    client.delete("dlq:{c1}")
