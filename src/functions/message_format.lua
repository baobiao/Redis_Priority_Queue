#!lua name=message_format

-- ============================================================================
-- message_format - canonical priority-queue message representation
--
-- Spec      : specs/001-message-format/spec.md
-- Plan      : specs/001-message-format/plan.md
-- Contracts : specs/001-message-format/contracts/functions.md
-- Enqueue   : specs/002-enqueue/spec.md (msgfmt_enqueue; contracts/functions.md)
-- Dequeue   : specs/003-dequeue/spec.md (msgfmt_dequeue/ack/nack; contracts/functions.md)
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

local FIELDS = { 'ReadAttempts', 'DirtyBit', 'ReadDateTime', 'Priority', 'Payload' }

-- Literal membership set. Built as a literal (not a load-time loop) because the
-- Redis Functions sandbox blocks global access (e.g. ipairs) in the top-level
-- load chunk; loops over FIELDS are only used inside callbacks at runtime.
local FIELD_SET = {
  ReadAttempts = true,
  DirtyBit     = true,
  ReadDateTime = true,
  Priority     = true,
  Payload      = true,
}

-- Stored (encoded) defaults.
local DEFAULTS = {
  ReadAttempts = '0',
  DirtyBit     = '0',
  ReadDateTime = '0',
  Priority     = '1000',
  Payload      = '',
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

-- Encode a supplied value for storage, validating per field.
-- Returns (encoded_string, nil) on success or (nil, "ECODE: Field") on failure.
local function encode_field(name, value)
  if name == 'ReadAttempts' or name == 'ReadDateTime' then
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
    'ReadAttempts', 'DirtyBit', 'ReadDateTime', 'Priority', 'Payload')
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
  local max_scan = 0
  if args[3] ~= nil then
    max_scan = tonumber(args[3])
    if not is_int(max_scan) or max_scan < 0 or max_scan > MAX_SAFE_INT then
      return redis.error_reply('MSGFMT ESCAN: max_scan must be a non-negative integer')
    end
  end

  -- Co-location: queue and message-key prefix must share one hash tag so every
  -- constructed KEYS[2]..id lands in the queue's slot (Principle IV / cluster-safe).
  local qtag = hash_tag(queue)
  local ptag = hash_tag(prefix)
  if qtag == nil or ptag == nil or qtag ~= ptag then
    return redis.error_reply('MSGFMT ETAG: queue and message-key prefix must share one hash tag')
  end

  if redis.call('EXISTS', queue) == 0 then
    return false -- empty queue -> nothing available (RESP null)
  end
  local qt = redis.call('TYPE', queue)
  if qt.ok ~= 'zset' then
    return redis.error_reply('MSGFMT EMALFORMED: queue is not a sorted set')
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
        'DirtyBit', 'ReadDateTime', 'ReadAttempts', 'Priority', 'Payload')
      if vals[1] == false or vals[2] == false or vals[3] == false then
        return redis.error_reply('MSGFMT EMALFORMED: message ' .. mkey .. ' missing lease field')
      end
      local available = false
      if vals[1] == '0' then
        available = true
      elseif vals[1] == '1' then
        local rdt = tonumber(vals[2])
        if rdt ~= nil and (now - rdt) >= timeout then
          available = true -- expired lease -> reclaim
        end
      end
      if available then
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
--   KEYS[1] = message Hash. ARGV[1] = token (fencing).
--   On a valid current lease releases it: DirtyBit=0, retaining ReadDateTime and
--   ReadAttempts, so the message becomes available again at its original position
--   (the queue member is never removed). Idempotent NOOP if already gone; fenced.
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
  redis.call('HSET', mkey, 'DirtyBit', '0') -- retain ReadDateTime and ReadAttempts
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
