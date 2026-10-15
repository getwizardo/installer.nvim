-- Minimal, dependency-free JSON codec (RFC 8259) used by the :Kikru IPC /
-- 2-Neovim protocol, the playlist store and anywhere else JSON is needed
-- *without* relying on `vim.json` (which does not exist in plain LuaJIT tests
-- and differs between Neovim versions).
--
-- `encode` understands `vim.empty_dict()` and `vim.NIL` when running inside
-- Neovim so round-trips stay faithful.
local M = {}

-- `vim.NIL` marks JSON null when running inside Neovim.
local NULL = vim and vim.NIL or nil

local escape_map = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_char(c)
  return ("\\u%04x"):format(c:byte())
end

local function escape_string(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    return escape_map[c] or escape_char(c)
  end))
end

local function is_array(t)
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #t
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return "null"
  end
  if math.type and math.type(n) == "integer" then
    return tostring(n)
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return ("%d"):format(n)
  end
  return (("%.14g"):format(n))
end

local encode_value

---@param value any
---@param stack table
---@return string
local function encode_table(value, stack)
  if stack[value] then
    error("cannot encode recursive table")
  end
  stack[value] = true
  local out
  if is_array(value) and not (vim and vim.empty_dict and vim.empty_dict() == value) then
    local parts = {}
    for i = 1, #value do
      parts[#parts + 1] = encode_value(value[i], stack)
    end
    out = "[" .. table.concat(parts, ",") .. "]"
  else
    local keys = {}
    for k in pairs(value) do
      if type(k) == "string" or type(k) == "number" then
        keys[#keys + 1] = k
      elseif type(k) ~= "boolean" then
        error("unsupported JSON key type: " .. type(k))
      end
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = ('"%s":%s'):format(escape_string(tostring(k)), encode_value(value[k], stack))
    end
    out = "{" .. table.concat(parts, ",") .. "}"
  end
  stack[value] = nil
  return out
end

---@param value any
---@param stack table
---@return string
encode_value = function(value, stack)
  stack = stack or {}
  local t = type(value)
  if value == nil or value == NULL then
    return "null"
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    return encode_number(value)
  elseif t == "string" then
    return '"' .. escape_string(value) .. '"'
  elseif t == "table" then
    return encode_table(value, stack)
  end
  error("cannot encode a " .. t .. " as JSON")
end

--- Encode a Lua value as JSON text.
---@param value any
---@param opts? {indent?: boolean}
---@return string
function M.encode(value, opts)
  local text = encode_value(value, {})
  if opts and opts.indent then
    -- Light-weight pretty printer good enough for config/dump output.
    local indent, out = 0, {}
    local in_string, escaped = false, false
    for i = 1, #text do
      local c = text:sub(i, i)
      if in_string then
        out[#out + 1] = c
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == '"' then
          in_string = false
        end
      elseif c == '"' then
        in_string = true
        out[#out + 1] = c
      elseif c == "{" or c == "[" then
        indent = indent + 1
        out[#out + 1] = c .. "\n" .. string.rep("  ", indent)
      elseif c == "}" or c == "]" then
        indent = indent - 1
        out[#out + 1] = "\n" .. string.rep("  ", indent) .. c
      elseif c == "," then
        out[#out + 1] = ",\n" .. string.rep("  ", indent)
      else
        out[#out + 1] = c
      end
    end
    return table.concat(out)
  end
  return text
end

-- Decoder -----------------------------------------------------------------------

--- Encode a code point as UTF-8 (surrogate pairs handled by the caller).
local function utf8_encode(cp)
  if cp < 128 then
    return string.char(cp)
  elseif cp < 2048 then
    return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
  elseif cp < 65536 then
    return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
  end
  return string.char(
    240 + math.floor(cp / 262144),
    128 + math.floor(cp / 4096) % 64,
    128 + math.floor(cp / 64) % 64,
    128 + cp % 64
  )
end

--- Decode a `\uXXXX` sequence (surrogate pairs included) to UTF-8.
local function utf8_from_code_units(hi, lo)
  local cp = hi
  if hi >= 0xD800 and hi <= 0xDBFF and lo and lo >= 0xDC00 and lo <= 0xDFFF then
    cp = 0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)
  end
  return utf8_encode(cp)
end

---@param text string
---@param pos integer  index of the opening quote
---@return string value, integer next_pos
local function decode_string(text, pos)
  local out = {}
  local i = pos + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local esc = text:sub(i + 1, i + 1)
      if esc == "u" then
        local hex = text:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then
          error(("invalid \\u escape at %d"):format(i))
        end
        if code >= 0xD800 and code <= 0xDBFF and text:sub(i + 6, i + 7) == "\\u" then
          local low = tonumber(text:sub(i + 8, i + 11), 16)
          out[#out + 1] = utf8_from_code_units(code, low)
          i = i + 12
        else
          out[#out + 1] = utf8_from_code_units(code)
          i = i + 6
        end
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        out[#out + 1] = map[esc] or esc
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error("unterminated string")
end

local function skip_ws(text, pos)
  while pos <= #text and text:sub(pos, pos):match("%s") do
    pos = pos + 1
  end
  return pos
end

local decode_value

---@param text string
---@param pos integer
---@return any value, integer next_pos
decode_value = function(text, pos)
  pos = skip_ws(text, pos)
  local c = text:sub(pos, pos)
  if c == "" then
    error("unexpected end of input")
  elseif c == "{" then
    local obj = {}
    pos = skip_ws(text, pos + 1)
    if text:sub(pos, pos) == "}" then
      return (vim.empty_dict and vim.empty_dict() or obj), pos + 1
    end
    while true do
      pos = skip_ws(text, pos)
      if text:sub(pos, pos) ~= '"' then
        error(("expected string key at %d"):format(pos))
      end
      local key
      key, pos = decode_string(text, pos)
      pos = skip_ws(text, pos)
      if text:sub(pos, pos) ~= ":" then
        error(("expected ':' at %d"):format(pos))
      end
      local value
      value, pos = decode_value(text, pos + 1)
      obj[key] = value
      pos = skip_ws(text, pos)
      local next_c = text:sub(pos, pos)
      if next_c == "," then
        pos = pos + 1
      elseif next_c == "}" then
        return obj, pos + 1
      else
        error(("expected ',' or '}' at %d"):format(pos))
      end
    end
  elseif c == "[" then
    local arr = {}
    pos = skip_ws(text, pos + 1)
    if text:sub(pos, pos) == "]" then
      return arr, pos + 1
    end
    while true do
      local value
      value, pos = decode_value(text, pos)
      arr[#arr + 1] = value
      pos = skip_ws(text, pos)
      local next_c = text:sub(pos, pos)
      if next_c == "," then
        pos = pos + 1
      elseif next_c == "]" then
        return arr, pos + 1
      else
        error(("expected ',' or ']' at %d"):format(pos))
      end
    end
  elseif c == '"' then
    return decode_string(text, pos)
  elseif text:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif text:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif text:sub(pos, pos + 3) == "null" then
    return NULL, pos + 4
  else
    local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if not number or number == "" then
      error(("unexpected character %q at %d"):format(c, pos))
    end
    local value = tonumber(number)
    if not value then
      error(("invalid number %q at %d"):format(number, pos))
    end
    return value, pos + #number
  end
end

--- Decode JSON text. Returns `nil, err` on malformed input.
---@param text string
---@return any value, string? err
function M.decode(text)
  if type(text) ~= "string" then
    return nil, "expected a string"
  end
  local ok, value = pcall(function()
    local result = decode_value(text, 1)
    return result
  end)
  if not ok then
    return nil, tostring(value):gsub("^.*:%d+:%s*", "")
  end
  return value
end

--- Decode a JSON *line* (newline delimited protocol) with a helpful error.
---@param line string
---@return table|nil, string? err
function M.decode_line(line)
  local value, err = M.decode(line)
  if value == nil then
    return nil, err or "empty message"
  end
  if type(value) ~= "table" then
    return nil, "expected a JSON object"
  end
  return value
end

return M
