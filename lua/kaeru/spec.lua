-- Builds a lazy.nvim plugin spec from the form fields and renders it as Lua source.
--
-- Spec reference: https://lazy.folke.io/spec
local M = {}

---@class KaeruForm
---@field repo string           owner/repo, full https:// git url or git@ url (required)
---@field file? string          file name (without .lua) inside the plugins directory
---@field name? string          custom plugin name (spec.name)
---@field lazy? string          "true" | "false" | ""
---@field priority? string      number
---@field event? string         comma separated
---@field cmd? string           comma separated
---@field ft? string            comma separated
---@field keys? string          comma separated lhs values
---@field dependencies? string  comma separated plugin short names
---@field branch? string
---@field tag? string
---@field version? string
---@field commit? string
---@field build? string
---@field opts? string          Lua table literal, e.g. `{ foo = "bar" }`
---@field config? string        "true" | "false" | "" | "function" | raw `function(...) ... end` source
---@field init? string          raw `function() ... end` source
---@field pin? string           "true" | "false" | ""
---@field cond? string          "true" | "false" | raw `function() ... end`
---@field enabled? string       "true" | "false" | raw `function() ... end`
---
--- `keys`, `dependencies` and `build` may also be given as raw Lua (`{ ... }`),
--- which is emitted verbatim.

--- A raw chunk of Lua source that should be emitted verbatim by `M.render`.
---@class KaeruRaw
---@field raw string

local load_lua = loadstring or load

---@param s? string
---@return string
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s? string
---@return boolean
local function blank(s)
  return trim(s) == ""
end

---@param s string
---@return string[]
local function csv(s)
  local out = {}
  for part in tostring(s):gmatch("[^,]+") do
    part = trim(part)
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

---@param s? string
---@return boolean|nil
local function tobool(s)
  if type(s) == "boolean" then
    return s
  end
  s = trim(s):lower()
  if s == "true" or s == "yes" or s == "y" or s == "1" or s == "on" then
    return true
  elseif s == "false" or s == "no" or s == "n" or s == "0" or s == "off" then
    return false
  end
  return nil
end

--- Normalise user input into something lazy.nvim understands.
--- Returns the short name (`owner/repo`) when it is a GitHub URL, otherwise the
--- url itself, plus the repo "basename" used to derive names.
---@param input string
---@return {short?: string, url?: string, base: string}|nil, string? err
function M.parse_repo(input)
  input = trim(input)
  -- Strip trailing commas/semicolons and surrounding quotes when pasted from a README
  input = input:gsub("[,;]+$", "")
  input = trim(input)
  if (input:sub(1, 1) == '"' and input:sub(-1) == '"') or (input:sub(1, 1) == "'" and input:sub(-1) == "'") then
    input = trim(input:sub(2, -2))
  end

  if input == "" then
    return nil, "Repository is required (owner/repo or a git URL)"
  end

  -- https://github.com/owner/repo(.git)(/)(tree/<branch>|blob/…|?query|#frag)
  local owner, repo, rest = input:match("^https?://github%.com/([%w_.-]+)/([%w_.-]+)(.*)$")
  if owner and not (rest == "" or rest:match("^[/?#]")) then
    owner = nil
  end
  if not owner then
    -- git@github.com:owner/repo.git
    owner, repo = input:match("^git@github%.com:([%w_.-]+)/([%w_.-]+)$")
  end
  if owner then
    repo = repo:gsub("%.git$", "")
    return { short = owner .. "/" .. repo, base = repo }
  end

  -- owner/repo
  owner, repo = input:match("^([%w_.-]+)/([%w_.-]+)$")
  if owner then
    repo = repo:gsub("%.git$", "")
    return { short = owner .. "/" .. repo, base = repo }
  end

  -- any other git url
  if input:match("^%a[%w+.-]*://") or input:match("^git@") then
    local base = input:match("([^/:]+)$") or input
    base = base:gsub("%.git$", "")
    return { url = input, base = base }
  end

  return nil, ("Invalid repository %q. Use owner/repo or a full git URL"):format(input)
end

--- Derive a safe file name from a repo base name, e.g. `nvim-treesitter` -> `treesitter`.
---@param base string
---@return string
function M.default_filename(base)
  local name = tostring(base or ""):lower()
  name = name:gsub("%.n?vim$", ""):gsub("^n?vim%-", ""):gsub("%-n?vim$", "")
  name = name:gsub("[^%w_%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if name == "" then
    name = tostring(base or ""):gsub("[^%w_%-]", "-")
  end
  if name == "" then
    name = "plugin"
  end
  return name
end

--- Build a safe proxy environment for evaluating table/function expressions during spec validation
--- so expressions referencing uninstalled plugins (`require("cmp")`) or `vim.cmd.*` / `vim.fn.*`
--- inside `opts` or `keys` do not fail validation before the plugin is installed.
local function make_validation_env()
  local proxy
  local mt = {
    __index = function()
      return proxy
    end,
    __call = function()
      return proxy
    end,
    __concat = function()
      return ""
    end,
    __tostring = function()
      return ""
    end,
  }
  proxy = setmetatable({}, mt)
  return setmetatable({
    vim = proxy,
    require = function()
      return proxy
    end,
     pairs = pairs,
    ipairs = ipairs,
    tostring = tostring,
    tonumber = tonumber,
    table = table,
    string = string,
    math = math,
    os = os,
  }, {
    __index = function()
      return proxy
    end,
  })
end

local function eval_chunk(chunk)
  if setfenv then
    pcall(setfenv, chunk, make_validation_env())
  end
  return pcall(chunk)
end

--- Validate that `text` is a Lua expression of the given type and return it trimmed.
---@param text string
---@param kind "table"|"function"
---@param what string
---@return string|nil, string? err
function M.validate_raw(text, kind, what)
  text = trim(text)
  local chunk, err = load_lua("return " .. text)
  if not chunk then
    return nil, ("Invalid Lua for %s: %s"):format(what, tostring(err))
  end
  local ok, val = eval_chunk(chunk)
  if not ok or type(val) ~= kind then
    return nil, ("`%s` must be a Lua %s"):format(what, kind)
  end
  return text
end

--- Re-indent a multi-line raw snippet so it sits nicely inside the spec table.
---@param text string
---@return string
local function reindent(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines == 1 then
    return text
  end
  -- strip the common indentation of lines 2..n
  local min
  for i = 2, #lines do
    local ws = lines[i]:match("^(%s*)%S")
    if ws and (not min or #ws < #min) then
      min = ws
    end
  end
  for i = 2, #lines do
    if min and #min > 0 then
      lines[i] = lines[i]:sub(#min + 1)
    end
    lines[i] = "  " .. lines[i]
  end
  return table.concat(lines, "\n")
end

--- Validate that `text` is a Lua table literal. Returns the normalised text.
---@param text string
---@return string|nil, string? err
function M.validate_table(text)
  text = trim(text)
  if text == "" then
    return nil
  end
  if not text:match("^{") then
    text = "{ " .. text .. " }"
  end
  local chunk, err = load_lua("return " .. text)
  if not chunk then
    return nil, "Invalid Lua table: " .. tostring(err)
  end
  local ok, val = eval_chunk(chunk)
  if not ok or type(val) ~= "table" then
    return nil, "`opts` must evaluate to a Lua table"
  end
  return text
end

local function raw(src)
  return { raw = src }
end

--- Build an ordered list of `{ key, value }` pairs representing the spec.
--- Values can be strings, numbers, booleans, string lists or `KaeruRaw`.
---@param form KaeruForm
---@return {entries: {[1]: string|nil, [2]: any}[], name: string, file: string, short?: string}|nil, string? err
function M.build(form)
  if type(form) ~= "table" then
    return nil, "Spec form must be a table"
  end
  local repo, err = M.parse_repo(form.repo)
  if not repo then
    return nil, err
  end

  ---@type {[1]: string|nil, [2]: any}[]
  local entries = {}
  local function add(key, value)
    if value ~= nil then
      entries[#entries + 1] = { key, value }
    end
  end

  if repo.short then
    add(nil, repo.short)
  else
    add("url", repo.url)
  end

  local name = trim(form.name)
  if name ~= "" then
    add("name", name)
  else
    name = repo.base
  end

  local lazy = tobool(form.lazy)
  if lazy ~= nil then
    add("lazy", lazy)
  end

  if not blank(form.priority) then
    local n = tonumber(trim(form.priority))
    if not n then
      return nil, "Priority must be a number"
    end
    add("priority", n)
  end

  if not blank(form.version) then
    local v = trim(form.version)
    if v == "false" then
      add("version", false)
    else
      add("version", v)
    end
  end
  for _, key in ipairs({ "branch", "tag", "commit" }) do
    if not blank(form[key]) then
      add(key, trim(form[key]))
    end
  end
  local pin = tobool(form.pin)
  if pin ~= nil then
    if pin then
      add("pin", true)
    end
  end

  for _, key in ipairs({ "enabled", "cond" }) do
    if not blank(form[key]) then
      local v = trim(form[key])
      local b = tobool(v)
      if b ~= nil then
        add(key, b)
      elseif v:match("^function") then
        local text, ferr = M.validate_raw(v, "function", key)
        if ferr then
          return nil, ferr
        end
        add(key, raw(reindent(text)))
      else
        return nil, ("`%s` must be true, false or a `function() ... end`"):format(key)
      end
    end
  end

  for _, key in ipairs({ "event", "cmd", "ft" }) do
    if not blank(form[key]) then
      local val = form[key]
      if type(val) == "table" then
        if #val > 0 then
          add(key, #val == 1 and val[1] or val)
        end
      elseif trim(val):match("^{") then
        local text, terr = M.validate_raw(val, "table", key)
        if terr then
          return nil, terr
        end
        add(key, raw(reindent(text)))
      else
        local list = csv(val)
        if #list > 0 then
          add(key, #list == 1 and list[1] or list)
        end
      end
    end
  end

  if not blank(form.keys) then
    if trim(form.keys):match("^{") then
      local text, kerr = M.validate_raw(form.keys, "table", "keys")
      if kerr then
        return nil, kerr
      end
      add("keys", raw(reindent(text)))
    elseif #csv(form.keys) > 0 then
      add("keys", csv(form.keys))
    end
  end

  if not blank(form.dependencies) and trim(form.dependencies):match("^{") then
    local text, derr = M.validate_raw(form.dependencies, "table", "dependencies")
    if derr then
      return nil, derr
    end
    add("dependencies", raw(reindent(text)))
  elseif not blank(form.dependencies) then
    local deps = {}
    for _, dep in ipairs(csv(form.dependencies)) do
      local parsed = M.parse_repo(dep)
      deps[#deps + 1] = parsed and (parsed.short or parsed.url) or dep
    end
    if #deps > 0 then
      add("dependencies", deps)
    end
  end

  if not blank(form.build) then
    if trim(form.build):match("^{") then
      local text, berr = M.validate_raw(form.build, "table", "build")
      if berr then
        return nil, berr
      end
      add("build", raw(reindent(text)))
    elseif trim(form.build):match("^function") then
      local text, berr = M.validate_raw(form.build, "function", "build")
      if berr then
        return nil, berr
      end
      add("build", raw(reindent(text)))
    else
      add("build", trim(form.build))
    end
  end

  if not blank(form.opts) then
    local text, terr = M.validate_table(form.opts)
    if terr then
      return nil, terr
    end
    add("opts", raw(reindent(text)))
  end

  if not blank(form.init) then
    local text, ierr = M.validate_raw(form.init, "function", "init")
    if ierr then
      return nil, ierr
    end
    add("init", raw(reindent(text)))
  end

  local config = trim(form.config)
  local lconfig = config:lower()
  if lconfig == "function" or lconfig == "fn" or lconfig == "func" then
    add("config", raw("function(_, opts)\n    -- require(\"" .. M.default_filename(repo.base) .. "\").setup(opts)\n  end"))
  elseif lconfig:match("^function") then
    local text, cerr = M.validate_raw(config, "function", "config")
    if cerr then
      return nil, cerr
    end
    add("config", raw(reindent(text)))
  elseif tobool(config) ~= nil then
    add("config", tobool(config))
  end

  local file = trim(form.file)
  if file == "" then
    file = M.default_filename(repo.base)
  end
  file = file:gsub("%.lua$", "")
  if file:match("[/\\]") then
    return nil, "File name must not contain path separators"
  end

  return { entries = entries, name = name, file = file, short = repo.short }
end

---@param s string
local function quote(s)
  return string.format("%q", s):gsub("\\\n", "\\n")
end

---@param value any
---@param indent string
---@return string
local function render_value(value, indent)
  local t = type(value)
  if t == "table" and value.raw then
    return value.raw
  elseif t == "table" then
    if #value == 1 then
      return "{ " .. render_value(value[1], indent) .. " }"
    end
    local parts = {}
    for _, v in ipairs(value) do
      parts[#parts + 1] = indent .. "  " .. render_value(v, indent .. "  ") .. ","
    end
    return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
  elseif t == "string" then
    return quote(value)
  else
    return tostring(value)
  end
end

local IDENT = "^[%a_][%w_]*$"

--- Render a built spec as the contents of a `lua/plugins/<file>.lua` module.
---@param built {entries: {[1]: string|nil, [2]: any}[]}
---@param opts? {header?: boolean}
---@return string
function M.render(built, opts)
  opts = opts or {}
  local lines = {}
  if opts.header ~= false then
    lines[#lines + 1] = "-- Generated by kaeru.nvim on " .. os.date("%Y-%m-%d")
    lines[#lines + 1] = "-- Spec reference: https://lazy.folke.io/spec"
  end
  lines[#lines + 1] = "return {"
  for _, entry in ipairs(built.entries) do
    local key, value = entry[1], entry[2]
    local rendered = render_value(value, "  ")
    if key == nil then
      lines[#lines + 1] = "  " .. rendered .. ","
    elseif key:match(IDENT) then
      lines[#lines + 1] = "  " .. key .. " = " .. rendered .. ","
    else
      lines[#lines + 1] = "  [" .. quote(key) .. "] = " .. rendered .. ","
    end
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

--- Convenience: build + render in one go.
---@param form KaeruForm
---@param opts? {header?: boolean}
---@return {source: string, name: string, file: string, short?: string}|nil, string? err
function M.generate(form, opts)
  local built, err = M.build(form)
  if not built then
    return nil, err
  end
  return { source = M.render(built, opts), name = built.name, file = built.file, short = built.short }
end

M._trim = trim
M._csv = csv
M._tobool = tobool

return M
