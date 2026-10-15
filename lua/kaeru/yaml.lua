-- A small dependency-free YAML reader/writer for `kaeru.yaml`.
--
-- Supported subset (enough for configuration files):
--   * block mappings and sequences (indentation based)
--   * flow sequences `[a, b]` and flow mappings `{a: 1, b: 2}`
--   * plain, 'single' and "double" quoted scalars (with escapes)
--   * literal `|` and folded `>` block scalars
--   * comments, `---` document markers, booleans, null (~), integers, floats
-- Not supported: anchors/aliases, tags, multi-document files, complex keys.
local M = {}

---@class YamlLine
---@field indent integer
---@field text string
---@field lineno integer
---@field raw string

--- Strip a trailing comment that is not inside quotes.
---@param s string
---@return string
local function strip_comment(s)
  local in_s, in_d = false, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "'" and not in_d then
      in_s = not in_s
    elseif c == '"' and not in_s then
      if s:sub(i - 1, i - 1) ~= "\\" then
        in_d = not in_d
      end
    elseif c == "#" and not in_s and not in_d and (i == 1 or s:sub(i - 1, i - 1):match("%s")) then
      return (s:sub(1, i - 1):gsub("%s+$", ""))
    end
  end
  return (s:gsub("%s+$", ""))
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["0"] = "\0", ["/"] = "/" }

---@param s string
---@return string
local function unescape(s)
  return (s:gsub("\\(.)", function(c)
    return ESCAPES[c] or ("\\" .. c)
  end))
end

--- Convert a plain scalar to its Lua value.
---@param s string
---@return any
local function plain(s)
  if s == "" or s == "~" or s == "null" or s == "Null" or s == "NULL" then
    return nil
  end
  if s == "true" or s == "True" or s == "TRUE" or s == "yes" or s == "on" then
    return true
  end
  if s == "false" or s == "False" or s == "FALSE" or s == "no" or s == "off" then
    return false
  end
  if s:match("^[+-]?%d+$") or s:match("^[+-]?%d+%.%d*$") or s:match("^[+-]?%d*%.%d+$") or s:match("^[+-]?%d+[eE][+-]?%d+$") then
    return tonumber(s)
  end
  if s:match("^0x%x+$") then
    return tonumber(s)
  end
  return s
end

-- Flow syntax ------------------------------------------------------------------

local parse_flow

--- Split a flow body on top-level commas, respecting quotes and nesting.
---@param body string
---@return string[]
local function split_flow(body)
  local parts, depth, buf, in_s, in_d = {}, 0, {}, false, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == "'" and not in_d then
      in_s = not in_s
    elseif c == '"' and not in_s and body:sub(i - 1, i - 1) ~= "\\" then
      in_d = not in_d
    elseif not in_s and not in_d then
      if c == "[" or c == "{" then
        depth = depth + 1
      elseif c == "]" or c == "}" then
        depth = depth - 1
      elseif c == "," and depth == 0 then
        parts[#parts + 1] = trim(table.concat(buf))
        buf = {}
        goto continue
      end
    end
    buf[#buf + 1] = c
    ::continue::
  end
  local last = trim(table.concat(buf))
  if last ~= "" then
    parts[#parts + 1] = last
  end
  return parts
end

--- Parse a scalar (quoted / plain / flow).
---@param s string
---@param lineno integer
---@return any
local function scalar(s, lineno)
  s = trim(s)
  if s == "" then
    return nil
  end
  local first = s:sub(1, 1)
  if first == '"' then
    local body = s:match('^"(.*)"$')
    if not body then
      error(("yaml: unterminated string on line %d"):format(lineno), 0)
    end
    return unescape(body)
  elseif first == "'" then
    local body = s:match("^'(.*)'$")
    if not body then
      error(("yaml: unterminated string on line %d"):format(lineno), 0)
    end
    return (body:gsub("''", "'"))
  elseif first == "[" or first == "{" then
    return parse_flow(s, lineno)
  end
  return plain(s)
end

---@param s string
---@param lineno integer
---@return any
parse_flow = function(s, lineno)
  s = trim(s)
  if s:sub(1, 1) == "[" then
    if s:sub(-1) ~= "]" then
      error(("yaml: unterminated flow sequence on line %d"):format(lineno), 0)
    end
    local out = {}
    for _, part in ipairs(split_flow(s:sub(2, -2))) do
      out[#out + 1] = scalar(part, lineno)
    end
    return out
  elseif s:sub(1, 1) == "{" then
    if s:sub(-1) ~= "}" then
      error(("yaml: unterminated flow mapping on line %d"):format(lineno), 0)
    end
    local out = {}
    for _, part in ipairs(split_flow(s:sub(2, -2))) do
      local k, v = part:match("^(.-)%s*:%s*(.*)$")
      if not k then
        k, v = part, ""
      end
      out[scalar(k, lineno)] = scalar(v, lineno)
    end
    return out
  end
  return scalar(s, lineno)
end

-- Block syntax -----------------------------------------------------------------

--- Split `key: value` at the first unquoted `: ` (or trailing `:`).
---@param text string
---@return string|nil key, string|nil rest
local function split_key(text)
  local first = text:sub(1, 1)
  if first == '"' or first == "'" then
    local close = text:find(first, 2, true)
    while close and first == '"' and text:sub(close - 1, close - 1) == "\\" do
      close = text:find(first, close + 1, true)
    end
    if close and text:sub(close + 1):match("^%s*:") then
      local rest = text:sub(close + 1):gsub("^%s*:%s?", "", 1)
      return text:sub(1, close), rest
    end
    return nil
  end
  local in_flow = 0
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == "[" or c == "{" then
      in_flow = in_flow + 1
    elseif c == "]" or c == "}" then
      in_flow = in_flow - 1
    elseif c == ":" and in_flow == 0 then
      local nxt = text:sub(i + 1, i + 1)
      if nxt == "" or nxt:match("%s") then
        return text:sub(1, i - 1):gsub("%s+$", ""), trim(text:sub(i + 1))
      end
    elseif c == "#" and i > 1 and text:sub(i - 1, i - 1):match("%s") then
      break
    end
  end
  return nil
end

---@class YamlParser
---@field lines YamlLine[]
---@field pos integer
local Parser = {}
Parser.__index = Parser

---@param text string
---@return YamlParser
local function new_parser(text)
  local lines = {}
  local lineno = 0
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    lineno = lineno + 1
    local stripped = strip_comment(raw)
    if trim(stripped) ~= "" and trim(stripped) ~= "---" and trim(stripped) ~= "..." then
      local indent = #raw:match("^ *")
      if raw:match("^\t") then
        error(("yaml: tabs are not allowed for indentation (line %d)"):format(lineno), 0)
      end
      lines[#lines + 1] = { indent = indent, text = trim(stripped), lineno = lineno, raw = raw }
    end
  end
  return setmetatable({ lines = lines, pos = 1 }, Parser)
end

function Parser:peek()
  return self.lines[self.pos]
end

--- Read a block scalar (`|` or `>`) whose header is on `line`.
---@param header string
---@param parent_indent integer
---@return string
function Parser:block_scalar(header, parent_indent)
  local folded = header:sub(1, 1) == ">"
  local chomp = header:match("[+-]")
  local out = {}
  local block_indent
  -- consume raw lines (including blank ones) while they are indented deeper than the parent
  local l = self:peek()
  local start_lineno = (l and l.lineno) or math.huge
  -- we need raw access to blank lines: look them up via lineno gaps -> we keep it simple and
  -- only use the filtered lines, joining with newlines.
  while l and l.indent > parent_indent do
    block_indent = block_indent or l.indent
    out[#out + 1] = l.raw:sub(block_indent + 1)
    self.pos = self.pos + 1
    l = self:peek()
  end
  local _ = start_lineno
  local text
  if folded then
    text = table.concat(out, " ")
  else
    text = table.concat(out, "\n")
  end
  if chomp ~= "-" then
    text = text .. "\n"
  end
  return text
end

--- Parse the value that follows `key:` / `- ` when it is empty (nested block)
---@param indent integer indentation of the owning key/item
---@return any
function Parser:nested(indent)
  local l = self:peek()
  if not l or l.indent <= indent then
    return nil
  end
  return self:block(l.indent)
end

--- Parse an inline value or the nested block.
---@param rest string
---@param indent integer
---@return any
function Parser:value(rest, indent)
  if rest == "" then
    return self:nested(indent)
  end
  if rest:match("^[|>][+-]?$") then
    return self:block_scalar(rest, indent)
  end
  if rest:sub(1, 1) == "[" or rest:sub(1, 1) == "{" then
    -- flow collections may span several lines: join until balanced
    local open, close = rest:sub(1, 1), rest:sub(1, 1) == "[" and "]" or "}"
    local depth = 0
    local acc = rest
    local function balance(s)
      local d = 0
      for c in s:gmatch("[%[%]{}]") do
        if c == open then
          d = d + 1
        elseif c == close then
          d = d - 1
        end
      end
      return d
    end
    depth = balance(acc)
    local l = self:peek()
    while depth > 0 and l do
      acc = acc .. " " .. l.text
      depth = depth + balance(l.text)
      self.pos = self.pos + 1
      l = self:peek()
    end
    return parse_flow(acc, 0)
  end
  return scalar(rest, 0)
end

--- Parse a block (mapping or sequence) whose items start at `indent`.
---@param indent integer
---@return any
function Parser:block(indent)
  local first = self:peek()
  if not first then
    return nil
  end
  if first.text:match("^%-%s") or first.text == "-" then
    return self:sequence(indent)
  end
  return self:mapping(indent)
end

---@param indent integer
---@return table
function Parser:sequence(indent)
  local out = {}
  while true do
    local l = self:peek()
    if not l or l.indent ~= indent or not (l.text:match("^%-%s") or l.text == "-") then
      break
    end
    self.pos = self.pos + 1
    local rest = trim(l.text:sub(2))
    if rest == "" then
      out[#out + 1] = self:nested(indent)
    else
      -- `- key: value` starts an inline mapping whose further keys are indented by 2+
      local k, v = split_key(rest)
      if k and not rest:match("^[%[{\"']") then
        local item_indent = indent + 2 + (#l.text:sub(2):match("^%s*") - 1)
        -- the first key lives on the dash line; rewrite it as a virtual line
        local saved = self.lines[self.pos - 1]
        self.lines[self.pos - 1] = { indent = item_indent, text = rest, lineno = saved.lineno, raw = saved.raw }
        self.pos = self.pos - 1
        out[#out + 1] = self:mapping(item_indent)
        self.lines[self.pos - 1] = saved
        local _ = v
      else
        out[#out + 1] = self:value(rest, indent)
      end
    end
  end
  return out
end

---@param indent integer
---@return table
function Parser:mapping(indent)
  local out = {}
  while true do
    local l = self:peek()
    if not l or l.indent ~= indent then
      break
    end
    if l.text:match("^%-%s") or l.text == "-" then
      break
    end
    local k, rest = split_key(l.text)
    if not k then
      error(("yaml: expected `key: value` on line %d: %s"):format(l.lineno, l.text), 0)
    end
    self.pos = self.pos + 1
    local key = scalar(k, l.lineno)
    if key == nil then
      key = k
    end
    out[key] = self:value(rest, indent)
    if out[key] == nil and rest == "" then
      -- `key:` with nothing nested -> explicit empty table keeps the key around
      out[key] = nil
    end
  end
  return out
end

--- Decode a YAML document.
---@param text string
---@return any value
function M.decode(text)
  local p = new_parser(text or "")
  if not p:peek() then
    return {}
  end
  local l = p:peek()
  local result = p:block(l.indent)
  local extra = p:peek()
  if extra then
    error(("yaml: unexpected indentation on line %d: %s"):format(extra.lineno, extra.text), 0)
  end
  return result
end

--- Decode without raising.
---@param text string
---@return any|nil value, string|nil err
function M.safe_decode(text)
  local ok, res = pcall(M.decode, text)
  if ok then
    return res, nil
  end
  return nil, res
end

-- Encoder ----------------------------------------------------------------------

local function is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

local function needs_quotes(s)
  if s == "" then
    return true
  end
  if plain(s) ~= s then
    return true -- would be read back as bool/number/null
  end
  if s:match("^[%s%-%?:,%[%]{}#&%*!|>'\"%%@`]") or s:match("[:#]%s") or s:match(":$") or s:match("%s$") or s:find("\n") then
    return true
  end
  return false
end

local function encode_scalar(v)
  local t = type(v)
  if t == "string" then
    if needs_quotes(v) then
      return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
    end
    return v
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif v == nil then
    return "null"
  end
  return '"' .. tostring(v) .. '"'
end

local function list_extend(dst, src)
  for _, v in ipairs(src) do
    dst[#dst + 1] = v
  end
  return dst
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function encode_value(v, indent, lines, key_prefix)
  local pad = string.rep("  ", indent)
  if type(v) ~= "table" then
    lines[#lines + 1] = pad .. key_prefix .. encode_scalar(v)
  elseif next(v) == nil then
    lines[#lines + 1] = pad .. key_prefix .. (is_list(v) and "[]" or "{}")
  elseif is_list(v) then
    local simple = true
    for _, item in ipairs(v) do
      if type(item) == "table" then
        simple = false
      end
    end
    if simple and #v <= 6 then
      local parts = {}
      for _, item in ipairs(v) do
        parts[#parts + 1] = encode_scalar(item)
      end
      lines[#lines + 1] = pad .. key_prefix .. "[" .. table.concat(parts, ", ") .. "]"
    else
      lines[#lines + 1] = (pad .. key_prefix):gsub("%s+$", "")
      for _, item in ipairs(v) do
        if type(item) == "table" and not is_list(item) then
          local keys = sorted_keys(item)
          local sub = {}
          for _, k in ipairs(keys) do
            encode_value(item[k], indent + 2, sub, encode_scalar(tostring(k)) .. ": ")
          end
          -- first key goes on the dash line
          sub[1] = pad .. "  - " .. trim(sub[1])
          list_extend(lines, sub)
        else
          encode_value(item, indent + 1, lines, "- ")
        end
      end
    end
  else
    lines[#lines + 1] = (pad .. key_prefix):gsub("%s+$", "")
    for _, k in ipairs(sorted_keys(v)) do
      encode_value(v[k], indent + 1, lines, encode_scalar(tostring(k)) .. ": ")
    end
  end
end

--- Encode a Lua table as YAML (keys sorted, 2-space indent).
---@param value table
---@return string
function M.encode(value)
  local lines = {}
  if type(value) ~= "table" then
    return encode_scalar(value) .. "\n"
  end
  if is_list(value) then
    encode_value(value, -1, lines, "")
    table.remove(lines, 1)
  else
    for _, k in ipairs(sorted_keys(value)) do
      encode_value(value[k], 0, lines, encode_scalar(tostring(k)) .. ": ")
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
