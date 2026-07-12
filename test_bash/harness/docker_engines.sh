#!/usr/bin/env bash
#
# Docker-based engine harness for the `priority_queue` Redis Functions library.
# Spec: specs/001-message-format/spec.md  (Constitution Principle IX)
#
# Spins up the official Redis 7.0+ and Valkey 7.2+ container images via the
# Docker CLI so tests can FUNCTION LOAD the library and assert on FCALL/FCALL_RO
# responses. Provides standalone bring-up (used by the test suite here) and a
# best-effort single-shard cluster bring-up for cluster-mode runs.
#
# Usage:
#   ./docker_engines.sh up          # start standalone redis + valkey
#   ./docker_engines.sh down        # remove them
#   ./docker_engines.sh cluster-up  # start a 3-master cluster per engine (best effort)
#   ./docker_engines.sh cluster-down
#
# It is also sourced by load_and_call.sh to expose the helper functions.

set -euo pipefail

_ENGINES_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load shared engine constants (image pins + published host ports) from the repo-root
# engines.env. Apply a key only when it is NOT already set in the environment, so the
# environment still overrides the file (T003 / FR-011). Tolerates CRLF line endings.
if [ -f "$_ENGINES_HERE/../../engines.env" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|'#'*) continue ;; esac
    _v="${_v%$'\r'}"
    if [ -z "${!_k:-}" ]; then export "$_k=$_v"; fi
  done < "$_ENGINES_HERE/../../engines.env"
fi

REDIS_IMAGE="${REDIS_IMAGE:-redis:7.4}"
VALKEY_IMAGE="${VALKEY_IMAGE:-valkey/valkey:8.0}"
REDIS_NAME="${REDIS_NAME:-pq-redis}"
VALKEY_NAME="${VALKEY_NAME:-pq-valkey}"
REDIS_PORT="${REDIS_PORT:-7379}"
VALKEY_PORT="${VALKEY_PORT:-7380}"
REDIS_CLUSTER_PORT="${REDIS_CLUSTER_PORT:-7381}"
VALKEY_CLUSTER_PORT="${VALKEY_CLUSTER_PORT:-7382}"

# Host port mapped to each engine's in-container 6379 (standalone), and each cluster
# node's announced data port (bus port = data + 10000).
engine_port()       { case "$1" in redis) echo "$REDIS_PORT" ;; valkey) echo "$VALKEY_PORT" ;; *) return 1 ;; esac; }
cluster_data_port() { case "$1" in redis) echo "$REDIS_CLUSTER_PORT" ;; valkey) echo "$VALKEY_CLUSTER_PORT" ;; *) return 1 ;; esac; }

engine_image() {
  case "$1" in
    redis)  echo "$REDIS_IMAGE" ;;
    valkey) echo "$VALKEY_IMAGE" ;;
    *) echo "unknown engine: $1" >&2; return 1 ;;
  esac
}

engine_name() {
  case "$1" in
    redis)  echo "$REDIS_NAME" ;;
    valkey) echo "$VALKEY_NAME" ;;
    *) echo "unknown engine: $1" >&2; return 1 ;;
  esac
}

# Run the engine's CLI inside its container, auto-selecting redis-cli/valkey-cli.
engine_cli() {
  local engine="$1"; shift
  local name; name="$(engine_name "$engine")"
  docker exec -i "$name" sh -lc \
    'if command -v redis-cli >/dev/null 2>&1; then exec redis-cli "$@"; else exec valkey-cli "$@"; fi' _ "$@"
}

engine_up() {
  local engine="$1" name image
  name="$(engine_name "$engine")"
  image="$(engine_image "$engine")"
  if [ -n "$(docker ps -q -f "name=^${name}$")" ]; then
    return 0
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Publish a host TCP port (127.0.0.1 only) so host-run Jedis/redis-py can connect;
  # the Bash suite continues to use `docker exec` (engine_cli), so this is additive.
  docker run -d --name "$name" -p "127.0.0.1:$(engine_port "$engine"):6379" "$image" >/dev/null
  local i
  for i in $(seq 1 50); do
    if engine_cli "$engine" PING 2>/dev/null | grep -q PONG; then
      return 0
    fi
    sleep 0.3
  done
  echo "engine '$engine' ($image) did not become ready" >&2
  return 1
}

engine_down() {
  local name; name="$(engine_name "$1")"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

up() {
  engine_up redis
  engine_up valkey
  echo "standalone engines up: $REDIS_NAME ($REDIS_IMAGE), $VALKEY_NAME ($VALKEY_IMAGE)"
}

down() {
  engine_down redis
  engine_down valkey
  echo "standalone engines down"
}

# --- Cluster bring-up (single master owning all slots) ---------------------
# Single-key operations (this feature) never cross slots, so a one-node cluster
# that owns all 16384 slots is sufficient to prove FUNCTION LOAD + FCALL behave
# identically in cluster mode (cluster_state:ok, no CROSSSLOT for one key).
CLUSTER_REDIS_NAME="${CLUSTER_REDIS_NAME:-pq-redis-cluster}"
CLUSTER_VALKEY_NAME="${CLUSTER_VALKEY_NAME:-pq-valkey-cluster}"

cluster_name() {
  case "$1" in
    redis)  echo "$CLUSTER_REDIS_NAME" ;;
    valkey) echo "$CLUSTER_VALKEY_NAME" ;;
    *) return 1 ;;
  esac
}

cluster_cli() {
  local engine="$1"; shift
  docker exec -i "$(cluster_name "$engine")" sh -lc \
    'if command -v redis-cli >/dev/null 2>&1; then exec redis-cli "$@"; else exec valkey-cli "$@"; fi' _ "$@"
}

cluster_engine_up() {
  local engine="$1" name image dport bport
  name="$(cluster_name "$engine")"; image="$(engine_image "$engine")"
  dport="$(cluster_data_port "$engine")"; bport=$((dport + 10000))
  if [ -n "$(docker ps -q -f "name=^${name}$")" ]; then return 0; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Publish data + bus ports and announce a host-reachable address (127.0.0.1:<dport>)
  # so JedisCluster / RedisCluster can discover this single all-slots node over the
  # mapped port. The Bash cluster path itself uses `docker exec` (cluster_cli), so the
  # announce flags exist purely for the host-run Java/Python clients.
  docker run -d --name "$name" \
    -p "127.0.0.1:${dport}:6379" -p "127.0.0.1:${bport}:16379" "$image" \
    redis-server --cluster-enabled yes --cluster-node-timeout 5000 \
                 --appendonly no --save '' \
                 --cluster-announce-ip 127.0.0.1 \
                 --cluster-announce-port "${dport}" \
                 --cluster-announce-bus-port "${bport}" >/dev/null 2>&1 \
    || docker run -d --name "$name" \
         -p "127.0.0.1:${dport}:6379" -p "127.0.0.1:${bport}:16379" "$image" \
         valkey-server --cluster-enabled yes --cluster-node-timeout 5000 \
                       --appendonly no --save '' \
                       --cluster-announce-ip 127.0.0.1 \
                       --cluster-announce-port "${dport}" \
                       --cluster-announce-bus-port "${bport}" >/dev/null
  local i
  for i in $(seq 1 50); do
    if cluster_cli "$engine" PING 2>/dev/null | grep -q PONG; then break; fi
    sleep 0.3
  done
  cluster_cli "$engine" CLUSTER ADDSLOTSRANGE 0 16383 >/dev/null 2>&1 || true
  for i in $(seq 1 50); do
    if cluster_cli "$engine" CLUSTER INFO 2>/dev/null | grep -q 'cluster_state:ok'; then
      return 0
    fi
    sleep 0.3
  done
  echo "cluster engine '$engine' did not reach cluster_state:ok" >&2
  return 1
}

cluster_up()   { cluster_engine_up redis; cluster_engine_up valkey; echo "cluster engines up"; }
cluster_down() {
  docker rm -f "$CLUSTER_REDIS_NAME" "$CLUSTER_VALKEY_NAME" >/dev/null 2>&1 || true
  echo "cluster engines down"
}

# Only act on CLI verbs when executed directly (not when sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    up) up ;;
    down) down ;;
    cluster-up) cluster_up ;;
    cluster-down) cluster_down ;;
    *) echo "usage: $0 {up|down|cluster-up|cluster-down}" >&2; exit 1 ;;
  esac
fi
