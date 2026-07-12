"""Shared helpers for the Python parity suite (mirror of test_bash/harness/load_and_call.sh).

The library name and function names live in the Lua source, so redis-py drives the
identical `priority_queue` library that the Bash and Java suites do.
"""
from __future__ import annotations

import pathlib

import pytest
import redis

LIBRARY = "priority_queue"
RO_ON_WRITE = "Can not execute a script with write flag using *_ro command"

_LIB_SOURCE: str | None = None


def repo_find(relative: str) -> pathlib.Path | None:
    d = pathlib.Path.cwd().resolve()
    for _ in range(12):
        candidate = d / relative
        if candidate.exists():
            return candidate
        if d.parent == d:
            break
        d = d.parent
    return None


def source() -> str:
    global _LIB_SOURCE
    if _LIB_SOURCE is None:
        f = repo_find("src/functions/priority_queue.lua")
        if f is None:
            raise RuntimeError("src/functions/priority_queue.lua not found")
        _LIB_SOURCE = f.read_text()
    return _LIB_SOURCE


def load(client) -> str:
    """FUNCTION LOAD REPLACE; returns the library name (expected 'priority_queue')."""
    return client.function_load(source(), replace=True)


def fcall(client, fn: str, keys, *args):
    return client.fcall(fn, len(keys), *keys, *args)


def fcall_ro(client, fn: str, keys, *args):
    return client.fcall_ro(fn, len(keys), *keys, *args)


def deep(o) -> str:
    """Recursively flatten a reply to a searchable string (mirrors the Bash text dump)."""
    if o is None:
        return ""
    if isinstance(o, bytes):
        return o.decode()
    if isinstance(o, (list, tuple)):
        return " ".join(deep(x) for x in o)
    if isinstance(o, dict):
        return " ".join(f"{deep(k)} {deep(v)}" for k, v in o.items())
    return str(o)


def pairs(reply) -> dict:
    """Flat [k, v, k, v, ...] reply -> ordered dict (values stringified via deep)."""
    m: dict = {}
    if isinstance(reply, (list, tuple)):
        for i in range(0, len(reply) - 1, 2):
            m[deep(reply[i])] = deep(reply[i + 1])
    return m


def assert_error(needle: str, fn, *args, **kwargs):
    """Assert the call raises a ResponseError whose message contains needle."""
    with pytest.raises(redis.exceptions.ResponseError) as ei:
        fn(*args, **kwargs)
    assert needle in str(ei.value), f"expected error containing [{needle}] but got [{ei.value}]"


def assert_rejected_ro(client, fn: str, keys, *args):
    """Assert a write function is rejected under FCALL_RO."""
    assert_error(RO_ON_WRITE, fcall_ro, client, fn, keys, *args)
