-- kaeru.nvim: tiny compatibility shims.
--
-- The plugin targets Neovim 0.8+, but a surprising amount of the `vim.*`
-- helpers people take for granted only landed in 0.9/0.10 (`vim.list_slice`,
-- `vim.tbl_get`, …). Everything is resolved once here so the rest of the
-- code base can use a single, predictable API, and so the pure-Lua test
-- harness (LuaJIT + a small `vim` stub) can exercise the same code paths.

local M = {}

local function fallback_list_slice(t, first, last)
  t = t or {}
  first = first or 1
  last = last or #t
  local out = {}
  for i = first, last do
    if t[i] == nil then
      break
    end
    out[#out + 1] = t[i]
  end
  return out
end

local function fallback_tbl_get(t, ...)
  local cur = t
  for _, key in ipairs({ ... }) do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[key]
    if cur == nil then
      return nil
    end
  end
  return cur
end

local function fallback_tbl_count(t)
  local n = 0
  for _ in pairs(t or {}) do
    n = n + 1
  end
  return n
end

local function fallback_tbl_map(f, t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = f(v)
  end
  return out
end

local function fallback_tbl_filter(f, t)
  local out = {}
  for _, v in ipairs(t or {}) do
    if f(v) then
      out[#out + 1] = v
    end
  end
  return out
end

local function fallback_tbl_contains(t, value)
  for _, v in ipairs(t or {}) do
    if v == value then
      return true
    end
  end
  return false
end

local function fallback_tbl_keys(t)
  local out = {}
  for k in pairs(t or {}) do
    out[#out + 1] = k
  end
  return out
end

local function fallback_deepcopy(orig)
  if type(orig) ~= "table" then
    return orig
  end
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = fallback_deepcopy(v)
  end
  return setmetatable(copy, getmetatable(orig))
end

local function fallback_tbl_deep_extend(behavior, ...)
  local function merge(dst, src)
    for k, v in pairs(src or {}) do
      if type(v) == "table" and type(dst[k]) == "table" and next(v) ~= nil then
        merge(dst[k], v)
      elseif behavior == "keep" and dst[k] ~= nil then
        -- keep
      else
        dst[k] = v
      end
    end
    return dst
  end
  local out = {}
  for _, t in ipairs({ ... }) do
    merge(out, t)
  end
  return out
end

local function fallback_list_extend(a, b, first, last)
  for i = first or 1, last or #(b or {}) do
    a[#a + 1] = b[i]
  end
  return a
end

-- vim.* when available (fast path), pure-Lua otherwise.
local function fallback_tbl_extend(behavior, ...)
  local out = {}
  for _, t in ipairs({ ... }) do
    for k, v in pairs(t or {}) do
      out[k] = v
    end
  end
  if behavior == "keep" or behavior == "force" or behavior == "error" then
    local keep = {}
    for _, t in ipairs({ ... }) do
      for k, v in pairs(t or {}) do
        if keep[k] == nil then
          keep[k] = v
        end
      end
    end
    return keep
  end
  return out
end

M.list_slice = vim.list_slice or fallback_list_slice
M.list_extend = vim.list_extend or fallback_list_extend
M.tbl_get = vim.tbl_get or fallback_tbl_get
M.tbl_count = vim.tbl_count or fallback_tbl_count
M.tbl_map = vim.tbl_map or fallback_tbl_map
M.tbl_filter = vim.tbl_filter or fallback_tbl_filter
M.tbl_contains = vim.tbl_contains or fallback_tbl_contains
M.tbl_keys = vim.tbl_keys or fallback_tbl_keys
M.tbl_extend = vim.tbl_extend or fallback_tbl_extend
M.tbl_deep_extend = vim.tbl_deep_extend or fallback_tbl_deep_extend
M.deepcopy = vim.deepcopy or fallback_deepcopy
M.trim = vim.trim or function(str)
  return (tostring(str or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.json_encode = (vim.json and vim.json.encode) or vim.fn.json_encode
M.json_decode = (vim.json and vim.json.decode) or vim.fn.json_decode

--- `vim.fn.has("nvim-0.10") == 1` without the `== 1` noise.
---@param version string
---@return boolean
function M.has(version)
  if not vim.fn or not vim.fn.has then
    return false
  end
  return vim.fn.has(version) == 1
end

---@param name string
---@return boolean
function M.executable(name)
  if not vim.fn or not vim.fn.executable then
    return false
  end
  return vim.fn.executable(name) == 1
end

--- Wrapper around `vim.fn.getcompletion(category)` that tolerates both the
--- missing function (plain Lua / very old Neovim) and errors raised by
--- categories Neovim does not know about.
---@param base string
---@param category string
---@return string[]
function M.getcompletion(base, category)
  local fn = vim.fn and vim.fn.getcompletion
  if not fn then
    return {}
  end
  local ok, result = pcall(fn, base, category)
  if not ok or type(result) ~= "table" then
    return {}
  end
  return result
end

--- Command line helpers that no-op outside of a real `:` command line.
---@return string
function M.cmdline()
  if vim.fn and vim.fn.getcmdline then
    local ok, line = pcall(vim.fn.getcmdline)
    if ok and type(line) == "string" then
      return line
    end
  end
  return ""
end

---@return string|nil
function M.cmdtype()
  if vim.fn and vim.fn.getcmdtype then
    local ok, ctype = pcall(vim.fn.getcmdtype)
    if ok and type(ctype) == "string" then
      return ctype
    end
  end
  return nil
end

---@return integer
function M.cmdpos()
  if vim.fn and vim.fn.getcmdpos then
    local ok, pos = pcall(vim.fn.getcmdpos)
    if ok and type(pos) == "number" then
      return pos
    end
  end
  return #M.cmdline() + 1
end

--- Run `fn` later without crashing when `vim.defer_fn` does not exist.
---@param fn fun()
---@param ms? integer
function M.defer_fn(fn, ms)
  if vim.defer_fn then
    return vim.defer_fn(fn, ms or 0)
  end
  if vim.schedule then
    return vim.schedule(fn)
  end
  return fn()
end

--- `vim.notify` with a fallback to `print`.
---@param message string
---@param level? integer
function M.notify(message, level)
  if vim.notify then
    return vim.notify(message, level)
  end
  print(message)
end

---@return table|nil
function M.uv()
  return vim.uv or vim.loop
end

return M
