"""Mirrors test_bash/integration/test_pq_create_roundtrip.sh: create-with-defaults,
create-with-explicit-values, and partial create, each verified by direct Hash
inspection (HGET). Spec: FR-002..FR-008, SC-001/SC-002."""
import pqsupport as pq


def test_create_defaults(client):
    client.delete("q:{d1}")
    pq.fcall(client, "pq_create", ["q:{d1}"])
    assert client.hget("q:{d1}", "ReadAttempts") == "0"
    assert client.hget("q:{d1}", "DirtyBit") == "0"
    assert client.hget("q:{d1}", "ReadDateTime") == "0"
    assert client.hget("q:{d1}", "Priority") == "1000"
    assert client.hget("q:{d1}", "Payload") == ""


def test_create_explicit_values(client):
    # Explicit values incl. large epoch-ms and DirtyBit token 'true'.
    client.delete("q:{v1}")
    pq.fcall(client, "pq_create", ["q:{v1}"],
             "ReadAttempts", "3", "DirtyBit", "true", "ReadDateTime", "1700000000000",
             "Priority", "5", "Payload", "order-42")
    assert client.hget("q:{v1}", "ReadAttempts") == "3"
    assert client.hget("q:{v1}", "DirtyBit") == "1"        # true -> 1
    assert client.hget("q:{v1}", "ReadDateTime") == "1700000000000"
    assert client.hget("q:{v1}", "Priority") == "5"
    assert client.hget("q:{v1}", "Payload") == "order-42"


def test_create_partial(client):
    # Only Payload + Priority supplied; the rest default.
    client.delete("q:{p1}")
    pq.fcall(client, "pq_create", ["q:{p1}"], "Payload", "x", "Priority", "7")
    assert client.hget("q:{p1}", "Payload") == "x"
    assert client.hget("q:{p1}", "Priority") == "7"
    assert client.hget("q:{p1}", "ReadAttempts") == "0"
