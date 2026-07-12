#!lua name=message_format

-- ============================================================================
-- message_format - canonical priority-queue message representation
--
-- Spec      : specs/001-message-format/spec.md
-- Plan      : specs/001-message-format/plan.md
-- Contracts : specs/001-message-format/contracts/functions.md
-- Enqueue   : specs/002-enqueue/spec.md (msgfmt_enqueue; contracts/functions.md)
-- Dequeue   : specs/003-dequeue/spec.md (msgfmt_dequeue/ack/nack; contracts/functions.md)
-- DLQ/Peek  : specs/004-dead-letter-peek/spec.md (dead-letter dequeue + msgfmt_peek/
--             msgfmt_redrive; contracts/functions.md)
-- DelayVis  : specs/005-delayed-visibility/spec.md (VisibleAt not-before field:
--             scheduled delivery + retry backoff; contracts/functions.md)
--
-- A message is stored as a single Redis/Valkey Hash (one field per attribute)
-- at a caller-supplied key (KEYS[1]). The same source runs unmodified on
-- Redis 7.0+, Valkey 7.2+, ElastiCache, and MemoryDB.
--
-- Fields (logical type / default):
--   ReadAttempts  integer >= 0   / 0
--   DirtyBit      boolean        / false   (stored "0"/"1")
--   ReadDateTime  integer >= 0   / 0       (Unix epoch ms; 0 = never read)
--   Priority      integer        / 1000    (lower value = higher priority)
--   Payload       string         / ""
--
-- Constitution: keys only via KEYS[] (IV); no admin commands (V); single
-- FCALL/FCALL_RO (VI); reads carry the no-writes flag (VII); structured error
-- replies, never uncaught Lua errors on validated paths (VIII).
-- ============================================================================

-- VisibleAt (Feature 005) is appended LAST so the stored/read order of the five
-- original fields is preserved and messages written before Feature 005 (which
-- lack VisibleAt) remain readable (a missing VisibleAt is treated as 0 = visible).
local FIELDS = { 'ReadAttempts', 'DirtyBit', 'ReadDateTime', 'Priority', 'Payload', 'VisibleAt' }

-- Literal membership set. Built as a literal (not a load-time loop) because the
-- Redis Functions sandbox blocks global access (e.g. ipairs) in the top-level
-- load chunk; loops over FIELDS are only used inside callbacks at runtime.
local FIELD_SET = {
  ReadAttempts = true,
  DirtyBit     = true,
  ReadDateTime = true,
  Priority     = true,
  Payload      = true,
  VisibleAt    = true,
}

-- Stored (encoded) defaults.
local DEFAULTS = {
  ReadAttempts = '0',
  DirtyBit     = '0',
  ReadDateTime = '0',
  Priority     = '1000',
  Payload      = '',
  VisibleAt    = '0', -- 0 = immediately visible (no not-before)
}

local MAX_SAFE_INT = 9007199254740992 -- 2^53; exact-integer ceiling for Lua doubles

-- Is n a finite value with an exact integer representation?
local function is_int(n)
  return n ~= nil and n == n and n ~= math.huge and n ~= -math.huge and math.floor(n) == n
end

-- Extract the cluster hash tag: the substring between the first '{' and the
-- first '}' after it. Returns nil when there is no non-empty {...} tag. Used by
-- msgfmt_dequeue to verify the queue key and the message-key prefix co-locate to
-- one slot before it constructs per-message keys (Principle IV, as amended v2.0.0).
local function hash_tag(key)
  local open = string.find(key, '{', 1, true)
  if not open then return nil end
  local close = string.find(key, '}', open + 1, true)
  if not close or close == open + 1 then return nil end
  return string.sub(key, open + 1, close - 1)
end

-- Is a message currently available to lease? Available = not in-flight
-- (DirtyBit '0'), or in-flight ('1') with an EXPIRED lease
-- (now - ReadDateTime >= timeout). Shared by msgfmt_dequeue (which then leases)
-- and msgfmt_peek (which reports the next deliverable) so both agree exactly on
-- which message is "next". Determinism: now/timeout are caller-supplied via ARGV
-- (Principle VII); no server clock is read here.
local function lease_available(dirtybit, readdatetime, now, timeout)
  if dirtybit == '0' then
    return true
  elseif dirtybit == '1' then
    local rdt = tonumber(readdatetime)
    return rdt ~= nil and (now - rdt) >= timeout
  end
  return false
end

-- Delayed visibility (Feature 005), DISTINCT from the lease visibility timeout
-- above: a message is not deliverable until now >= its not-before time VisibleAt.
-- A missing/nil VisibleAt (a message stored before Feature 005) coalesces to 0 =
-- immediately visible. now is caller-supplied via ARGV (Principle VII; no clock).
-- A message is deliverable only when lease_available(...) AND is_visible(...).
local function is_visible(visibleat, now)
  return (tonumber(visibleat) or 0) <= now
end

-- Encode a supplied value for storage, validating per field.
-- Returns (encoded_string, nil) on success or (nil, "ECODE: Field") on failure.
local function encode_field(name, value)
  if name == 'ReadAttempts' or name == 'ReadDateTime' or name == 'VisibleAt' then
    local n = tonumber(value)
    if not is_int(n) or n < 0 or n > MAX_SAFE_INT then
      return nil, 'EINVAL: ' .. name
    end
    return string.format('%.0f', n)
  elseif name == 'Priority' then
    local n = tonumber(value)
    if not is_int(n) or n > MAX_SAFE_INT or n < -MAX_SAFE_INT then
      return nil, 'EINVAL: ' .. name
    end
    return string.format('%.0f', n)
  elseif name == 'DirtyBit' then
    local v = string.lower(tostring(value))
    if v == '1' or v == 'true' then
      return '1'
    elseif v == '0' or v == 'false' then
      return '0'
    end
    return nil, 'EINVAL: DirtyBit'
  elseif name == 'Payload' then
    return tostring(value)
  end
  return nil, 'EFIELD: ' .. tostring(name)
end

-- Parse a flat ARGV list of `name value name value ...` pairs.
-- Returns (supplied_table, nil) or (nil, "ECODE: detail").
local function parse_args(args)
  if (#args % 2) ~= 0 then
    return nil, 'EARGS: arguments must be name/value pairs'
  end
  local supplied = {}
  local i = 1
  while i <= #args do
    local name = args[i]
    local value = args[i + 1]
    if not FIELD_SET[name] then
      return nil, 'EFIELD: ' .. tostring(name)
    end
    if supplied[name] ~= nil then
      return nil, 'EDUP: ' .. name
    end
    supplied[name] = value
    i = i + 2
  end
  return supplied
end

-- Build the encoded {field, value, field, value, ...} list, applying defaults
-- for omitted fields and validating supplied ones.
-- Returns (hset_args, nil) or (nil, "ECODE: detail").
local function build_message(args)
  local supplied, err = parse_args(args)
  if err then return nil, err end
  local hset = {}
  for _, name in ipairs(FIELDS) do
    local stored
    if supplied[name] ~= nil then
      local enc, eerr = encode_field(name, supplied[name])
      if eerr then return nil, eerr end
      stored = enc
    else
      stored = DEFAULTS[name]
    end
    hset[#hset + 1] = name
    hset[#hset + 1] = stored
  end
  return hset
end

-- ---------------------------------------------------------------------------
-- msgfmt_create  (WRITE)
--   KEYS[1] = hash key ; ARGV = optional field/value pairs.
--   Applies defaults, validates, stores all five fields, returns +OK.
--   Stores nothing on any validation failure.
-- ---------------------------------------------------------------------------
local function msgfmt_create(keys, args)
  if #keys ~= 1 then
    return redis.error_reply('MSGFMT EKEYS: exactly one key required')
  end
  local hset, err = build_message(args)
  if err then
    return redis.error_reply('MSGFMT ' .. err)
  end
  local cmd = { 'HSET', keys[1] }
  for _, v in ipairs(hset) do cmd[#cmd + 1] = v end
  redis.call(unpack(cmd))
  return redis.status_reply('OK')
end

-- ---------------------------------------------------------------------------
-- msgfmt_read  (NO-WRITES, FCALL_RO)
--   KEYS[1] = hash key.
--   Returns a flat field/value array with decoded logical types, or +NOTFOUND
--   when absent, or a MSGFMT EMALFORMED error for a non-hash/incomplete key.
--   DirtyBit is returned as integer 0/1 (RESP2 has no boolean; this avoids the
--   false->nil ambiguity) - see contracts/functions.md.
-- ---------------------------------------------------------------------------
local function msgfmt_read(keys, args)
  if #keys ~= 1 then
    return redis.error_reply('MSGFMT EKEYS: exactly one key required')
  end
  local key = keys[1]
  if redis.call('EXISTS', key) == 0 then
    return redis.status_reply('NOTFOUND')
  end
  local t = redis.call('TYPE', key)
  if t.ok ~= 'hash' then
    return redis.error_reply('MSGFMT EMALFORMED: key is not a hash')
  end
  local vals = redis.call('HMGET', key,
    'ReadAttempts', 'DirtyBit', 'ReadDateTime', 'Priority', 'Payload', 'VisibleAt')
  -- The five original fields remain strictly required; a MISSING VisibleAt (a
  -- message written before Feature 005) is tolerated and reported as 0 (visible).
  for idx = 1, 5 do
    if vals[idx] == false then
      return redis.error_reply('MSGFMT EMALFORMED: missing field ' .. FIELDS[idx])
    end
  end
  return {
    'ReadAttempts', tonumber(vals[1]),
    'DirtyBit',     tonumber(vals[2]), -- 0 or 1
    'ReadDateTime', tonumber(vals[3]),
    'Priority',     tonumber(vals[4]),
    'Payload',      vals[5],
    'VisibleAt',    tonumber(vals[6]) or 0, -- missing -> 0 (immediately visible)
  }
end

-- ---------------------------------------------------------------------------
-- msgfmt_validate  (NO-WRITES, FCALL_RO)
--   No KEYS. ARGV = optional field/value pairs.
--   Runs the same validation as create without storing. Returns +VALID or the
--   matching MSGFMT E... error.
-- ---------------------------------------------------------------------------
local function msgfmt_validate(keys, args)
  local _, err = build_message(args)
  if err then
    return redis.error_reply('MSGFMT ' .. err)
  end
  return redis.status_reply('VALID')
end

-- ---------------------------------------------------------------------------
-- msgfmt_enqueue  (WRITE)
--   KEYS[1] = priority-queue Sorted Set ; KEYS[2] = message Hash (same slot).
--   ARGV[1] = id (unique, non-empty) ; ARGV[2] = sequence (integer 0..2^53) ;
--   ARGV[3..] = optional field/value pairs (same set as msgfmt_create).
--   Validates + stores the message and indexes it by Priority in one atomic
--   call:  score = message Priority ;  member = %020.0f(sequence) .. ':' .. id
--   (fixed-width zero-pad so lexical member order == FIFO among equal scores).
--   Fail-before-write: on any error nothing is written to either key.
-- ---------------------------------------------------------------------------
local function msgfmt_enqueue(keys, args)
  if #keys ~= 2 then
    return redis.error_reply('MSGFMT EKEYS: exactly two keys required')
  end
  local id = args[1]
  if id == nil or id == '' then
    return redis.error_reply('MSGFMT EID: id must be a non-empty string')
  end
  local seq = tonumber(args[2])
  if not is_int(seq) or seq < 0 or seq > MAX_SAFE_INT then
    return redis.error_reply('MSGFMT ESEQ: sequence must be a non-negative integer')
  end

  -- Field pairs are ARGV[3..]; reuse the Feature 001 builder (defaults + validation).
  local fields = {}
  for i = 3, #args do
    fields[#fields + 1] = args[i]
  end
  local hset, err = build_message(fields)
  if err then
    return redis.error_reply('MSGFMT ' .. err)
  end

  -- score = the message's Priority (from the built, encoded field list).
  local score
  for i = 1, #hset, 2 do
    if hset[i] == 'Priority' then
      score = hset[i + 1]
      break
    end
  end

  local member = string.format('%020.0f', seq) .. ':' .. id

  -- Fail-before-write preconditions: reject conflicts and wrong-type targets.
  if redis.call('EXISTS', keys[2]) == 1 then
    return redis.error_reply('MSGFMT EEXISTS: message location occupied')
  end
  if redis.call('EXISTS', keys[1]) == 1 then
    local t = redis.call('TYPE', keys[1])
    if t.ok ~= 'zset' then
      return redis.error_reply('MSGFMT EMALFORMED: queue is not a sorted set')
    end
  end
  if redis.call('ZSCORE', keys[1], member) ~= false then
    return redis.error_reply('MSGFMT EQDUP: already enqueued')
  end

  -- Write: store the message Hash, then index it in the queue Sorted Set.
  local cmd = { 'HSET', keys[2] }
  for _, v in ipairs(hset) do cmd[#cmd + 1] = v end
  redis.call(unpack(cmd))
  redis.call('ZADD', keys[1], score, member)
  return redis.status_reply('OK')
end

-- ---------------------------------------------------------------------------
-- msgfmt_dequeue  (WRITE)
--   KEYS[1] = priority-queue Sorted Set ; KEYS[2] = message-key prefix (same tag).
--   ARGV[1] = now (epoch ms, integer >=0) ; ARGV[2] = timeout (ms, integer >=1) ;
--   ARGV[3] = max_scan (optional, integer >=0; 0/absent = unbounded).
--   Selects the front AVAILABLE message (DirtyBit=0, or DirtyBit=1 with an expired
--   lease: now-ReadDateTime >= timeout), marks it in-flight (DirtyBit=1,
--   ReadDateTime=now, ReadAttempts+1) and returns its Payload plus a handle
--   (id, member, ReadAttempts = fencing token, ReadDateTime, Priority). Returns a
--   null reply when nothing is available. The winning message Hash is reached at
--   KEYS[2] .. id (the sanctioned same-slot construction). Fail-before-write.
-- ---------------------------------------------------------------------------
local function msgfmt_dequeue(keys, args)
  -- KEYS[1]=source queue, KEYS[2]=message-key prefix, KEYS[3]=DLQ (optional).
  -- With KEYS[3] present (dead-letter mode) ARGV[4]=cap is required: an available
  -- candidate whose ReadAttempts >= cap is moved to the DLQ (index-only, score =
  -- Priority, member verbatim) instead of being leased, and the scan continues.
  -- With only 2 keys the behaviour is exactly Feature 003. See
  -- specs/004-dead-letter-peek/contracts/functions.md.
  if #keys ~= 2 and #keys ~= 3 then
    return redis.error_reply('MSGFMT EKEYS: two or three keys required')
  end
  local queue = keys[1]
  local prefix = keys[2]
  local dlq = keys[3] -- nil in Feature 003 mode

  local now = tonumber(args[1])
  if not is_int(now) or now < 0 or now > MAX_SAFE_INT then
    return redis.error_reply('MSGFMT ENOW: now must be a non-negative integer')
  end
  local timeout = tonumber(args[2])
  if not is_int(timeout) or timeout < 1 or timeout > MAX_SAFE_INT then
    return redis.error_reply('MSGFMT ETMO: timeout must be a positive integer')
  end
  local max_scan = 0
  if args[3] ~= nil then
    max_scan = tonumber(args[3])
    if not is_int(max_scan) or max_scan < 0 or max_scan > MAX_SAFE_INT then
      return redis.error_reply('MSGFMT ESCAN: max_scan must be a non-negative integer')
    end
  end
  local cap = nil
  if dlq ~= nil then
    cap = tonumber(args[4])
    if not is_int(cap) or cap < 1 or cap > MAX_SAFE_INT then
      return redis.error_reply('MSGFMT ECAP: cap must be a positive integer')
    end
  end

  -- Co-location: queue and message-key prefix must share one hash tag so every
  -- constructed KEYS[2]..id lands in the queue's slot (Principle IV / cluster-safe).
  local qtag = hash_tag(queue)
  local ptag = hash_tag(prefix)
  if qtag == nil or ptag == nil or qtag ~= ptag then
    return redis.error_reply('MSGFMT ETAG: queue and message-key prefix must share one hash tag')
  end
  if dlq ~= nil then
    -- The DLQ takes writes in the same call, so it must share the queue's slot.
    local dtag = hash_tag(dlq)
    if dtag == nil or dtag ~= qtag then
      return redis.error_reply('MSGFMT ETAG: dead-letter queue must share the queue hash tag')
    end
  end

  if redis.call('EXISTS', queue) == 0 then
    return false -- empty queue -> nothing available (RESP null)
  end
  local qt = redis.call('TYPE', queue)
  if qt.ok ~= 'zset' then
    return redis.error_reply('MSGFMT EMALFORMED: queue is not a sorted set')
  end
  if dlq ~= nil and redis.call('EXISTS', dlq) == 1 then
    local dt = redis.call('TYPE', dlq)
    if dt.ok ~= 'zset' then
      return redis.error_reply('MSGFMT EMALFORMED: dead-letter queue is not a sorted set')
    end
  end

  -- Walk the front ascending (lowest score first, ties by member byte order = FIFO).
  -- When max_scan is set, fetch only that many front members (index-range ZRANGE
  -- has no LIMIT option, so bound the fetch itself).
  local stop = -1
  if max_scan > 0 then stop = max_scan - 1 end
  local members = redis.call('ZRANGE', queue, 0, stop)

  for _, member in ipairs(members) do
    -- id = text after the first ':' (the sequence is a fixed 20-digit prefix).
    local colon = string.find(member, ':', 1, true)
    local id = colon and string.sub(member, colon + 1) or member
    local mkey = prefix .. id

    if redis.call('EXISTS', mkey) == 0 then
      -- Dangling member (message Hash deleted out of band): clean up and skip.
      redis.call('ZREM', queue, member)
    else
      local mt = redis.call('TYPE', mkey)
      if mt.ok ~= 'hash' then
        return redis.error_reply('MSGFMT EMALFORMED: message ' .. mkey .. ' is not a hash')
      end
      local vals = redis.call('HMGET', mkey,
        'DirtyBit', 'ReadDateTime', 'ReadAttempts', 'Priority', 'Payload', 'VisibleAt')
      if vals[1] == false or vals[2] == false or vals[3] == false then
        return redis.error_reply('MSGFMT EMALFORMED: message ' .. mkey .. ' missing lease field')
      end
      -- Deliverable only when lease-available AND visible (now >= VisibleAt). A
      -- missing VisibleAt (vals[6]) coalesces to 0 = visible (back-compat). A
      -- not-yet-visible message is skipped like an unexpired lease; the dead-letter
      -- cap check below runs only AFTER this gate, so a not-yet-visible over-cap
      -- message is not dead-lettered until it becomes visible.
      if lease_available(vals[1], vals[2], now, timeout) and is_visible(vals[6], now) then
        if cap ~= nil and tonumber(vals[3]) >= cap then
          -- Poison: at/over the delivery cap. Move the index to the DLQ (score =
          -- Priority, member verbatim); the message Hash is left untouched. A plain
          -- ZADD updates in place if the member already exists (no duplicate). Then
          -- continue scanning for the next deliverable message.
          redis.call('ZREM', queue, member)
          redis.call('ZADD', dlq, vals[4], member)
        else
          local new_ra = redis.call('HINCRBY', mkey, 'ReadAttempts', 1)
          redis.call('HSET', mkey, 'DirtyBit', '1', 'ReadDateTime', string.format('%.0f', now))
          return {
            'id',           id,
            'member',       member,
            'ReadAttempts', new_ra, -- fencing token
            'ReadDateTime', now,
            'Priority',     tonumber(vals[4]),
            'Payload',      vals[5],
          }
        end
      end
    end
  end
  return false -- nothing available within the scan (RESP null)
end

-- ---------------------------------------------------------------------------
-- msgfmt_ack  (WRITE)
--   KEYS[1] = priority-queue Sorted Set ; KEYS[2] = message Hash.
--   ARGV[1] = member (from the handle, for ZREM) ; ARGV[2] = token (fencing).
--   On a valid current lease (DirtyBit=1 and ReadAttempts == token) removes the
--   member (ZREM) and deletes the Hash (DEL). Idempotent NOOP if already gone.
--   Fenced: a superseded lease is rejected (EFENCED) with no side effects.
-- ---------------------------------------------------------------------------
local function msgfmt_ack(keys, args)
  if #keys ~= 2 then
    return redis.error_reply('MSGFMT EKEYS: exactly two keys required')
  end
  local queue = keys[1]
  local mkey = keys[2]
  local member = args[1]
  local token = tonumber(args[2])
  if member == nil or member == '' or not is_int(token) then
    return redis.error_reply('MSGFMT EARGS: member and token required')
  end
  if redis.call('EXISTS', mkey) == 0 then
    return redis.status_reply('NOOP') -- already settled
  end
  local mt = redis.call('TYPE', mkey)
  if mt.ok ~= 'hash' then
    return redis.error_reply('MSGFMT EMALFORMED: key is not a hash')
  end
  local vals = redis.call('HMGET', mkey, 'DirtyBit', 'ReadAttempts')
  if vals[1] == false or vals[2] == false then
    return redis.error_reply('MSGFMT EMALFORMED: missing lease field')
  end
  if vals[1] ~= '1' then
    return redis.error_reply('MSGFMT ENOTLEASED: message not in-flight')
  end
  if tonumber(vals[2]) ~= token then
    return redis.error_reply('MSGFMT EFENCED: lease superseded')
  end
  redis.call('ZREM', queue, member)
  redis.call('DEL', mkey)
  return redis.status_reply('OK')
end

-- ---------------------------------------------------------------------------
-- msgfmt_nack  (WRITE)
--   KEYS[1] = message Hash. ARGV[1] = token (fencing). ARGV[2] = VisibleAt
--   (OPTIONAL, non-negative integer epoch ms; Feature 005 retry backoff).
--   On a valid current lease releases it: DirtyBit=0, retaining ReadDateTime and
--   ReadAttempts, so the message becomes available again at its original position
--   (the queue member is never removed). When ARGV[2] is supplied, also sets
--   VisibleAt so the message is not redelivered until now >= VisibleAt (delayed
--   retry); when omitted, VisibleAt is left unchanged. Idempotent NOOP if already
--   gone; fenced.
-- ---------------------------------------------------------------------------
local function msgfmt_nack(keys, args)
  if #keys ~= 1 then
    return redis.error_reply('MSGFMT EKEYS: exactly one key required')
  end
  local mkey = keys[1]
  local token = tonumber(args[1])
  if not is_int(token) then
    return redis.error_reply('MSGFMT EARGS: token required')
  end
  -- Optional not-before (retry backoff). Validate up front (fail-before-write).
  local visible_at = nil
  if args[2] ~= nil then
    visible_at = tonumber(args[2])
    if not is_int(visible_at) or visible_at < 0 or visible_at > MAX_SAFE_INT then
      return redis.error_reply('MSGFMT EVIS: visibleAt must be a non-negative integer')
    end
  end
  if redis.call('EXISTS', mkey) == 0 then
    return redis.status_reply('NOOP') -- already settled
  end
  local mt = redis.call('TYPE', mkey)
  if mt.ok ~= 'hash' then
    return redis.error_reply('MSGFMT EMALFORMED: key is not a hash')
  end
  local vals = redis.call('HMGET', mkey, 'DirtyBit', 'ReadAttempts')
  if vals[1] == false or vals[2] == false then
    return redis.error_reply('MSGFMT EMALFORMED: missing lease field')
  end
  if vals[1] ~= '1' then
    return redis.error_reply('MSGFMT ENOTLEASED: message not in-flight')
  end
  if tonumber(vals[2]) ~= token then
    return redis.error_reply('MSGFMT EFENCED: lease superseded')
  end
  if visible_at ~= nil then
    -- Retry backoff: release AND hide until now >= VisibleAt.
    redis.call('HSET', mkey, 'DirtyBit', '0', 'VisibleAt', string.format('%.0f', visible_at))
  else
    redis.call('HSET', mkey, 'DirtyBit', '0') -- retain ReadDateTime/ReadAttempts/VisibleAt
  end
  return redis.status_reply('OK')
end

-- ---------------------------------------------------------------------------
-- msgfmt_peek  (NO-WRITES; callable via FCALL_RO)
--   KEYS[1] = queue Sorted Set to inspect (a source queue or a DLQ).
--   KEYS[2] = message-key prefix (same hash tag as KEYS[1]).
--   ARGV[1] = now ; ARGV[2] = timeout ; ARGV[3] = count (optional).
--   No count (or count=1) -> SINGLE mode: return the front AVAILABLE message
--   (exactly what msgfmt_dequeue would lease next), as a record, WITHOUT mutating
--   anything; null when nothing is deliverable. count=N -> TOP-N mode: up to N
--   front members in priority-then-FIFO order regardless of lease state, each a
--   record annotated with its lease fields. Dangling/malformed members are
--   SKIPPED (never removed - this is a read-only function). Fail-before-return.
--   A record is a flat array:
--     {id, member, DirtyBit(0|1), ReadAttempts, ReadDateTime, Priority, Payload}.
-- ---------------------------------------------------------------------------
local function msgfmt_peek(keys, args)
  if #keys ~= 2 then
    return redis.error_reply('MSGFMT EKEYS: exactly two keys required')
  end
  local queue = keys[1]
  local prefix = keys[2]

  local now = tonumber(args[1])
  if not is_int(now) or now < 0 or now > MAX_SAFE_INT then
    return redis.error_reply('MSGFMT ENOW: now must be a non-negative integer')
  end
  local timeout = tonumber(args[2])
  if not is_int(timeout) or timeout < 1 or timeout > MAX_SAFE_INT then
    return redis.error_reply('MSGFMT ETMO: timeout must be a positive integer')
  end
  local count = 1
  local topn = false
  if args[3] ~= nil then
    count = tonumber(args[3])
    if not is_int(count) or count < 1 or count > MAX_SAFE_INT then
      return redis.error_reply('MSGFMT ECOUNT: count must be a positive integer')
    end
    if count > 1 then topn = true end
  end

  local qtag = hash_tag(queue)
  local ptag = hash_tag(prefix)
  if qtag == nil or ptag == nil or qtag ~= ptag then
    return redis.error_reply('MSGFMT ETAG: queue and message-key prefix must share one hash tag')
  end

  if redis.call('EXISTS', queue) == 0 then
    if topn then return {} else return false end
  end
  local qt = redis.call('TYPE', queue)
  if qt.ok ~= 'zset' then
    return redis.error_reply('MSGFMT EMALFORMED: queue is not a sorted set')
  end

  -- Top-N fetches only the front `count` members; single mode scans the front
  -- (bounded by queue size) to skip leased/dangling and find the first available.
  local stop = -1
  if topn then stop = count - 1 end
  local members = redis.call('ZRANGE', queue, 0, stop)

  local results = {}
  for _, member in ipairs(members) do
    local colon = string.find(member, ':', 1, true)
    local id = colon and string.sub(member, colon + 1) or member
    local mkey = prefix .. id

    if redis.call('EXISTS', mkey) == 1 then
      local mt = redis.call('TYPE', mkey)
      if mt.ok ~= 'hash' then
        if topn then
          -- observability: skip a malformed member
        else
          return redis.error_reply('MSGFMT EMALFORMED: message ' .. mkey .. ' is not a hash')
        end
      else
        local vals = redis.call('HMGET', mkey,
          'DirtyBit', 'ReadDateTime', 'ReadAttempts', 'Priority', 'Payload', 'VisibleAt')
        if vals[1] == false or vals[2] == false or vals[3] == false then
          if topn then
            -- observability: skip a member missing a lease field
          else
            return redis.error_reply('MSGFMT EMALFORMED: message ' .. mkey .. ' missing lease field')
          end
        else
          local record = {
            'id',           id,
            'member',       member,
            'DirtyBit',     tonumber(vals[1]),
            'ReadAttempts', tonumber(vals[3]),
            'ReadDateTime', tonumber(vals[2]),
            'Priority',     tonumber(vals[4]),
            'Payload',      vals[5],
            'VisibleAt',    tonumber(vals[6]) or 0, -- missing -> 0 (immediately visible)
          }
          if topn then
            results[#results + 1] = record -- top-N reports every member, regardless of visibility
          elseif lease_available(vals[1], vals[2], now, timeout) and is_visible(vals[6], now) then
            return record -- single mode: the front deliverable (lease-available AND visible) message
          end
        end
      end
    end
    -- dangling member (Hash absent): skip; never ZREM (read-only)
  end

  if topn then
    return results
  end
  return false -- single mode: nothing deliverable
end

-- ---------------------------------------------------------------------------
-- msgfmt_redrive  (WRITE)
--   KEYS[1] = dead-letter Sorted Set (source of the move).
--   KEYS[2] = source priority-queue Sorted Set (destination).
--   KEYS[3] = the message Hash (passed literally; the id is known to the caller).
--   ARGV[1] = member (the exact DLQ member string to move).
--   Moves one member DLQ -> source at score = Priority (member verbatim) and
--   resets delivery state: ReadAttempts=0, DirtyBit=0, VisibleAt=0 (immediately
--   visible), retaining ReadDateTime. NOOP when the member is not in the DLQ;
--   EQDUP when it is already in the source. Fail-before-write. All three keys
--   must share one hash tag.
-- ---------------------------------------------------------------------------
local function msgfmt_redrive(keys, args)
  if #keys ~= 3 then
    return redis.error_reply('MSGFMT EKEYS: exactly three keys required')
  end
  local dlq = keys[1]
  local queue = keys[2]
  local mkey = keys[3]
  local member = args[1]
  if member == nil or member == '' then
    return redis.error_reply('MSGFMT EARGS: member required')
  end

  local dtag = hash_tag(dlq)
  local qtag = hash_tag(queue)
  local mtag = hash_tag(mkey)
  if dtag == nil or qtag == nil or mtag == nil or dtag ~= qtag or dtag ~= mtag then
    return redis.error_reply('MSGFMT ETAG: keys must share one hash tag')
  end

  -- Guards, all before any write:
  if redis.call('ZSCORE', dlq, member) == false then
    return redis.status_reply('NOOP') -- not in the dead-letter queue
  end
  if redis.call('ZSCORE', queue, member) ~= false then
    return redis.error_reply('MSGFMT EQDUP: already present in source queue')
  end
  if redis.call('EXISTS', mkey) == 0 then
    return redis.error_reply('MSGFMT EMALFORMED: message hash missing')
  end
  local mt = redis.call('TYPE', mkey)
  if mt.ok ~= 'hash' then
    return redis.error_reply('MSGFMT EMALFORMED: key is not a hash')
  end
  local priority = redis.call('HGET', mkey, 'Priority')
  if priority == false then
    return redis.error_reply('MSGFMT EMALFORMED: missing field Priority')
  end

  redis.call('ZREM', dlq, member)
  redis.call('ZADD', queue, priority, member)
  -- Reset delivery state so the redriven message is immediately deliverable;
  -- VisibleAt=0 clears any not-before. ReadDateTime is retained.
  redis.call('HSET', mkey, 'ReadAttempts', '0', 'DirtyBit', '0', 'VisibleAt', '0')
  return redis.status_reply('OK')
end

redis.register_function('msgfmt_create', msgfmt_create)
redis.register_function{
  function_name = 'msgfmt_read',
  callback      = msgfmt_read,
  flags         = { 'no-writes' },
}
redis.register_function{
  function_name = 'msgfmt_validate',
  callback      = msgfmt_validate,
  flags         = { 'no-writes' },
}
redis.register_function('msgfmt_enqueue', msgfmt_enqueue)
redis.register_function('msgfmt_dequeue', msgfmt_dequeue)
redis.register_function('msgfmt_ack', msgfmt_ack)
redis.register_function('msgfmt_nack', msgfmt_nack)
redis.register_function{
  function_name = 'msgfmt_peek',
  callback      = msgfmt_peek,
  flags         = { 'no-writes' },
}
redis.register_function('msgfmt_redrive', msgfmt_redrive)
