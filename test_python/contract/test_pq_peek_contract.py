"""Mirrors test_bash/contract/test_pq_peek_contract.sh: single vs top-N return, no-writes
(callable via FCALL_RO, leaves the message unleased at DirtyBit=0), and the
EKEYS/ENOW/ETMO/ECOUNT/ETAG errors. Feature 005: records carry VisibleAt; single mode skips
a not-yet-visible message and returns it once visible.

The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster those
keys span slots, so the cross-slot call is rejected before the Lua runs."""
import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport as pq


def test_pq_peek_contract(client):
    q = "pq:{pc}"
    mk = "pq:{pc}:m:k"
    pfx = "pq:{pc}:m:"
    client.delete(q, mk)

    # Empty queue: single -> null.
    assert pq.deep(pq.fcall_ro(client, "pq_peek", [q, pfx], "1000", "30000")) == ""

    # Enqueue one, then peek (read-only) returns a record carrying id/member/Payload.
    pq.fcall(client, "pq_enqueue", [q, mk], "k", "1", "Payload", "hello", "Priority", "5")
    rec = pq.deep(pq.fcall_ro(client, "pq_peek", [q, pfx], "1000", "30000"))
    assert "k" in rec
    assert ("%020d:%s" % (1, "k")) in rec
    assert "hello" in rec
    assert "DirtyBit" in rec

    # Top-N form is callable and returns the member.
    assert "hello" in pq.deep(pq.fcall_ro(client, "pq_peek", [q, pfx], "1000", "30000", "2"))

    # Peek is no-writes: it did not lease the message (still available at DirtyBit=0).
    assert client.hget(mk, "DirtyBit") == "0"

    # Error surface.
    pq.assert_error("EKEYS", pq.fcall_ro, client, "pq_peek", [q], "1000", "30000")
    pq.assert_error("ENOW", pq.fcall_ro, client, "pq_peek", [q, pfx], "-1", "30000")
    pq.assert_error("ETMO", pq.fcall_ro, client, "pq_peek", [q, pfx], "1000", "0")
    pq.assert_error("ECOUNT", pq.fcall_ro, client, "pq_peek", [q, pfx], "1000", "30000", "0")
    if isinstance(client, RedisCluster):
        with pytest.raises(redis.exceptions.RedisClusterException):
            pq.fcall_ro(client, "pq_peek", ["pq:{pc}", "pq:{other}:m:"], "1000", "30000")
    else:
        pq.assert_error("ETAG", pq.fcall_ro, client, "pq_peek", ["pq:{pc}", "pq:{other}:m:"], "1000", "30000")

    # --- Feature 005: records carry VisibleAt; single mode honours it ---
    vq = "pq:{pcv}"
    vh = "pq:{pcv}:m:h"
    vpfx = "pq:{pcv}:m:"
    client.delete(vq, vh)
    pq.fcall(client, "pq_enqueue", [vq, vh],
             "h", "1", "Priority", "5", "Payload", "hid", "VisibleAt", "9000")
    # top-N reports the record with its VisibleAt
    topn = pq.deep(pq.fcall_ro(client, "pq_peek", [vq, vpfx], "1000", "30000", "5"))
    assert "VisibleAt" in topn
    assert "9000" in topn
    # single mode skips it while hidden, returns it once visible
    assert pq.deep(pq.fcall_ro(client, "pq_peek", [vq, vpfx], "8999", "30000")) == ""
    assert "hid" in pq.deep(pq.fcall_ro(client, "pq_peek", [vq, vpfx], "9000", "30000"))
