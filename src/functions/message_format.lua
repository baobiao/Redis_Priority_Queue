#!lua name=message_format

-- ============================================================================
-- message_format - canonical priority-queue message representation
--
-- Spec      : specs/001-message-format/spec.md
-- Plan      : specs/001-message-format/plan.md
-- Contracts : specs/001-message-format/contracts/functions.md
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
