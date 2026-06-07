#!/usr/bin/env bash
#
# Static-compliance scan for the message_format library.
# Spec: specs/001-message-format/spec.md
# Enforces (statically, no engine required):
#   - Principle V : no restricted/admin commands in function bodies
#   - Principle IV: no computed/hardcoded key names (keys only via KEYS[])
#   - Principle II: no third-party module usage (no `require`)
#   - Principle III: only commands on the common-supported list for
#                    Redis 7.0+, Valkey 7.2+, ElastiCache, MemoryDB
#
# Exits non-zero on any violation.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${1:-$HERE/../../src/functions/message_format.lua}"

fail=0
note() { echo "  VIOLATION: $1"; fail=1; }

echo "== static checks on: $LIB =="

# Strip Lua line comments so command-name tokens in comments don't false-positive.
code="$(sed 's/--.*$//' "$LIB")"

# V. Restricted / admin commands
restricted='CONFIG|SAVE|BGSAVE|BGREWRITEAOF|DEBUG|SHUTDOWN|REPLICAOF|SLAVEOF|MIGRATE|SYNC|FLUSHALL|FLUSHDB'
if printf '%s\n' "$code" | grep -Eiq "redis\.call[^)]*['\"](${restricted})['\"]"; then
  note "restricted/admin command referenced in a redis.call"
fi

# II. No third-party modules
if printf '%s\n' "$code" | grep -Eq '(^|[^.[:alnum:]])require[[:space:]]*\('; then
  note "use of require() (third-party module) is forbidden"
fi

# IV. Keys must come from KEYS[]; flag obvious computed/hardcoded keys passed to
#     keyed commands as a string literal (e.g. redis.call('HSET', 'literalkey', ...)).
if printf '%s\n' "$code" | grep -Eiq "redis\.call\([^)]*['\"](HSET|HGET|HMGET|HGETALL|HDEL|EXISTS|TYPE|DEL|SET|GET)['\"][[:space:]]*,[[:space:]]*['\"]"; then
  note "keyed command appears to use a string-literal key (keys must come from KEYS[])"
fi

# III. Whitelist of commands this feature is allowed to use.
allowed='HSET|HGET|HMGET|HGETALL|HDEL|EXISTS|TYPE|DEL'
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if ! printf '%s' "$cmd" | grep -Eiq "^(${allowed})$"; then
    note "command not on the common-supported whitelist: $cmd"
  fi
done < <(printf '%s\n' "$code" \
          | grep -Eio "redis\.call\([[:space:]]*['\"][A-Za-z_]+['\"]" \
          | grep -Eio "['\"][A-Za-z_]+['\"]" \
          | tr -d "\"'" \
          | sort -u)

if [ "$fail" -eq 0 ]; then
  echo "  ok: no static violations"
fi
exit "$fail"
