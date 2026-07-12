"""Engine × topology fixtures for the Python parity suite, sourced from repo-root
engines.env (env vars override the file). Mirrors the Bash ENGINES loop (redis + valkey)
and adds the automated cluster topology. Only reachable combos are parameterized, so a
developer who has not run `docker_engines.sh cluster-up` still gets the standalone combos.
"""
from __future__ import annotations

import os
import socket

import pytest
import redis
from redis.cluster import RedisCluster

import pqsupport

HOST = "127.0.0.1"


def _engines_env() -> dict:
    env: dict = {}
    f = pqsupport.repo_find("engines.env")
    if f is not None:
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def _port(env: dict, key: str, default: int) -> int:
    return int(os.environ.get(key) or env.get(key) or default)


def _reachable(port: int) -> bool:
    try:
        with socket.create_connection((HOST, port), timeout=0.6):
            return True
    except OSError:
        return False


def _combos():
    env = _engines_env()
    candidates = [
        ("redis-standalone", "standalone", _port(env, "REDIS_PORT", 7379)),
        ("valkey-standalone", "standalone", _port(env, "VALKEY_PORT", 7380)),
        ("redis-cluster", "cluster", _port(env, "REDIS_CLUSTER_PORT", 7381)),
        ("valkey-cluster", "cluster", _port(env, "VALKEY_CLUSTER_PORT", 7382)),
    ]
    reachable = [c for c in candidates if _reachable(c[2])]
    if not reachable:
        raise RuntimeError(
            "No engines reachable on 127.0.0.1. Run: "
            "test_bash/harness/docker_engines.sh up (and cluster-up)."
        )
    return reachable


def _connect(topology: str, port: int):
    if topology == "cluster":
        return RedisCluster(host=HOST, port=port, decode_responses=True)
    return redis.Redis(host=HOST, port=port, decode_responses=True)


_COMBOS = _combos()


@pytest.fixture(params=_COMBOS, ids=[c[0] for c in _COMBOS])
def client(request):
    _, topology, port = request.param
    c = _connect(topology, port)
    pqsupport.load(c)
    yield c
    try:
        c.close()
    except Exception:
        pass
