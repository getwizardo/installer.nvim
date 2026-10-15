-- Universal installer snippet & README.md parser for installer.nvim.
--
-- Parses plugin installation instructions from README.md files, markdown buffers,
-- or raw snippets across Neovim / Vim plugin managers and converts them into
-- `InstallerForm` tables ready for `Spec.generate()` or the `:Installer` modal:
--
--   * lazy.nvim      ({ "owner/repo", ... }, return { ... }, require("lazy").setup(...))
--   * packer.nvim    (use "owner/repo", use { "owner/repo", requires = ..., run = ... })
--   * pckr.nvim      (require("pckr").add { ... })
--   * vim-plug       (Plug 'owner/repo', { 'do': ..., 'branch': ..., 'on': ..., 'for': ... })
--   * mini.deps      (MiniDeps.add({ source = "owner/repo", depends = ..., checkout = ..., hooks = ... }))
--   * vim.pack       (vim.pack.add({ "https://github.com/owner/repo", { src = ..., version = ... } }))
--   * paq-nvim       (require("paq")({ "owner/repo", { "owner/repo", build = ..., branch = ... } }))
--   * dein.vim       (call dein#add('owner/repo', { 'build': ..., 'on_ft': ..., 'on_cmd': ... }))
--   * Vundle/Bundle  (Plugin 'owner/repo', Bundle 'owner/repo')
--   * rocks.nvim     (:Rocks install ..., rocks.toml [plugins] entries)
--   * git clone      (git clone [-b branch] https://github.com/owner/repo.git)
--   * Mason          (:MasonInstall pkg1 pkg2, :Installer mason install ...)
--   * setup() blocks (require("mod").setup({ ... }) merged into opts when applicable)
local Spec = require("installer.spec")

local M = {}

---@class InstallerParsedSpec
---@field manager string        "lazy"|"packer"|"pckr"|"vim-plug"|"mini.deps"|"vim.pack"|"paq"|"dein"|"vundle"|"rocks"|"git"
---@field repo string           normalised owner/repo or URL
---@field form InstallerForm    ready for Spec.generate / Form.open
---@field score integer         richness score (higher = more fields / more native to lazy.nvim)

---@class InstallerParseResult
---@field specs InstallerParsedSpec[]
---@field primary InstallerForm|nil
---@field primary_manager string|nil
---@field mason string[]
---@field setup_calls {module: string, opts: string}[]

local MANAGER_PRIORITY = {
  ["lazy"] = 100,
  ["pckr"] = 85,
  ["packer"] = 80,
  ["mini.deps"] = 75,
  ["vim.pack"] = 70,
  ["paq"] = 65,
  ["vim-plug"] = 60,
  ["dein"] = 55,
  ["rocks"] = 50,
  ["vundle"] = 40,
  ["git"] = 30,
}

---@param s? string
---@return string
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Strip surrounding single, double, or long-bracket quotes from a string token.
---@param s string
---@return string
local function unquote(s)
  s = trim(s)
  local lbr = s:match("^%[(=*)%[(.*)%]=*%]$")
  if lbr then
    return s:match("^%[=*%[(.*)%]=*%]$") or s
  end
  if (s:sub(1, 1) == '"' and s:sub(-1) == '"') or (s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    local inner = s:sub(2, -2)
    inner = inner:gsub('\\"', '"'):gsub("\\'", "'"):gsub("\\\\", "\\")
    return inner
  end
  return s
end

--- Normalize a repository candidate (owner/repo, github URL, git@ URL, or rocks name).
---@param raw string
---@return string|nil repo
local function normalize_repo(raw)
  if type(raw) ~= "string" then
    return nil
  end
  raw = trim(unquote(raw))
  if raw == "" then
    return nil
  end
  local parsed = Spec.parse_repo(raw)
  if parsed then
    return parsed.short or parsed.url
  end
  return nil
end

--- Find the end index of a balanced Lua construct starting at `start_pos`.
--- Respects strings ('...', "...", [[...]]) and comments (--..., --[[...]]).
---@param src string
---@param start_pos integer
---@return integer|nil end_pos
local function find_lua_expr_end(src, start_pos)
  local n = #src
  local i = start_pos
  while i <= n and src:sub(i, i):match("%s") do
    i = i + 1
  end
  if i > n then
    return nil
  end

  local depth_brace = 0
  local depth_paren = 0
  local depth_bracket = 0
  local depth_func = 0
  local started_compound = false

  local function skip_string(pos)
    local q = src:sub(pos, pos)
    local j = pos + 1
    while j <= n do
      local ch = src:sub(j, j)
      if ch == "\\" then
        j = j + 2
      elseif ch == q then
        return j
      else
        j = j + 1
      end
    end
    return n
  end

  local function skip_long_bracket(pos)
    local eq = src:match("^%[(=*)%[", pos)
    if not eq then
      return nil
    end
    local close_pat = "%]" .. eq .. "%]"
    local _, e = src:find(close_pat, pos + 2 + #eq)
    return e or n
  end

  while i <= n do
    -- comments
    if src:sub(i, i + 1) == "--" then
      local lb = skip_long_bracket(i + 2)
      if lb then
        i = lb + 1
      else
        local nl = src:find("\n", i + 2, true)
        i = nl and (nl + 1) or (n + 1)
      end
    elseif src:sub(i, i) == '"' or src:sub(i, i) == "'" then
      i = skip_string(i) + 1
      if not started_compound and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
        return i - 1
      end
    elseif src:match("^%[=*%[", i) then
      i = (skip_long_bracket(i) or n) + 1
      if not started_compound and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
        return i - 1
      end
    else
      local ch = src:sub(i, i)
      if ch == "{" then
        depth_brace = depth_brace + 1
        started_compound = true
        i = i + 1
      elseif ch == "}" then
        if depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
          return i - 1
        end
        depth_brace = math.max(0, depth_brace - 1)
        i = i + 1
        if started_compound and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
          return i - 1
        end
      elseif ch == "(" then
        depth_paren = depth_paren + 1
        started_compound = true
        i = i + 1
      elseif ch == ")" then
        if depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
          return i - 1
        end
        depth_paren = math.max(0, depth_paren - 1)
        i = i + 1
        if started_compound and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
          return i - 1
        end
      elseif ch == "[" then
        depth_bracket = depth_bracket + 1
        i = i + 1
      elseif ch == "]" then
        depth_bracket = math.max(0, depth_bracket - 1)
        i = i + 1
      elseif ch == "," or ch == ";" then
        if depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
          return i - 1
        end
        i = i + 1
      elseif ch:match("[%a_]") then
        local word = src:match("^[%a_][%w_]*", i)
        local prev = i > 1 and src:sub(i - 1, i - 1) or " "
        local is_boundary = not prev:match("[%w_.]")
        if is_boundary then
          if word == "function" or word == "do" or word == "then" or word == "repeat" then
            if word == "function" or depth_func > 0 then
              if word ~= "then" then
                depth_func = depth_func + 1
                started_compound = true
              elseif depth_func == 0 then
                -- standalone if ... then
                depth_func = depth_func + 1
                started_compound = true
              end
            end
          elseif word == "if" or word == "for" or word == "while" then
            if depth_func > 0 then
              -- `do` or `then` will follow; track block on `if`/`for`/`while` and ignore `then`/`do`
            end
          elseif word == "end" or word == "until" then
            if depth_func > 0 then
              depth_func = depth_func - 1
              if started_compound and depth_brace == 0 and depth_paren == 0 and depth_bracket == 0 and depth_func == 0 then
                return i + #word - 1
              end
            end
          end
        end
        i = i + #word
      else
        i = i + 1
      end
    end
  end
  return n
end

--- Tokenize a top-level Lua table `{ ... }` into positional items and key-value pairs.
--- Preserves the exact raw source string of each value!
---@param tbl_src string
---@return {positional: string[], named: table<string, string>}
function M.parse_lua_table_fields(tbl_src)
  local out = { positional = {}, named = {} }
  tbl_src = trim(tbl_src)
  if tbl_src:sub(1, 1) ~= "{" or tbl_src:sub(-1) ~= "}" then
    return out
  end
  local inner = tbl_src:sub(2, -2)
  local n = #inner
  local i = 1

  local function skip_ws_and_comments()
    while i <= n do
      local ws = inner:match("^%s+", i)
      if ws then
        i = i + #ws
      elseif inner:sub(i, i + 1) == "--" then
        local eq = inner:match("^%[(=*)%[", i + 2)
        if eq then
          local _, e = inner:find("%]" .. eq .. "%]", i + 4 + #eq)
          i = (e or n) + 1
        else
          local nl = inner:find("\n", i + 2, true)
          i = nl and (nl + 1) or (n + 1)
        end
      elseif inner:sub(i, i) == "," or inner:sub(i, i) == ";" then
        i = i + 1
      else
        break
      end
    end
  end

  while i <= n do
    skip_ws_and_comments()
    if i > n then
      break
    end
    -- Check for `key = value` or `["key"] = value` or `[1] = value`
    local key, val_start
    local k_ident, after_ident = inner:match("^([%a_][%w_]*)%s*=%s*()", i)
    if k_ident and inner:sub(after_ident, after_ident) ~= "=" then
      key = k_ident
      val_start = after_ident
    else
      local k_brack, after_brack = inner:match("^%[%s*([\"'][^\"']+[\"'])%s*%]%s*=%s*()", i)
      if k_brack then
        key = unquote(k_brack)
        val_start = after_brack
      else
        local k_num, after_num = inner:match("^%[%s*(%d+)%s*%]%s*=%s*()", i)
        if k_num then
          key = tonumber(k_num)
          val_start = after_num
        end
      end
    end

    local expr_start = val_start or i
    local expr_end = find_lua_expr_end(inner, expr_start)
    if not expr_end or expr_end < expr_start then
      break
    end
    local val_raw = trim(inner:sub(expr_start, expr_end))
    if key == 1 then
      out.positional[1] = val_raw
    elseif type(key) == "string" then
      out.named[key] = val_raw
    elseif val_raw ~= "" then
      out.positional[#out.positional + 1] = val_raw
    end
    i = expr_end + 1
  end

  return out
end

--- Extract string elements from a Lua expression that is either a string literal or `{ "a", "b", ... }`.
---@param expr string
---@return string[]|nil list, boolean is_complex
local function extract_string_list(expr)
  expr = trim(expr)
  if expr == "" then
    return nil, false
  end
  if expr:sub(1, 1) == '"' or expr:sub(1, 1) == "'" then
    return { unquote(expr) }, false
  end
  if expr:sub(1, 1) == "{" and expr:sub(-1) == "}" then
    local parsed = M.parse_lua_table_fields(expr)
    if next(parsed.named) ~= nil then
      return nil, true
    end
    local items = {}
    for _, item in ipairs(parsed.positional) do
      item = trim(item)
      if (item:sub(1, 1) == '"' and item:sub(-1) == '"') or (item:sub(1, 1) == "'" and item:sub(-1) == "'") then
        items[#items + 1] = unquote(item)
      elseif item:sub(1, 1) == "{" and item:sub(-1) == "}" then
        -- Nested table (e.g. inside dependencies or keys)
        local sub = M.parse_lua_table_fields(item)
        if #sub.positional == 1 and next(sub.named) == nil then
          local p1 = trim(sub.positional[1])
          if p1:sub(1, 1) == '"' or p1:sub(1, 1) == "'" then
            items[#items + 1] = unquote(p1)
          else
            return nil, true
          end
        else
          return nil, true
        end
      else
        return nil, true
      end
    end
    return items, false
  end
  return nil, true
end

--- Extract dependencies from a Lua expression (handles strings, lists of strings, or nested specs).
---@param expr string
---@return string
local function format_dependencies_expr(expr)
  expr = trim(expr)
  local list, complex = extract_string_list(expr)
  if list and not complex then
    local out = {}
    for _, d in ipairs(list) do
      out[#out + 1] = normalize_repo(d) or d
    end
    return table.concat(out, ", ")
  end
  -- If it is a table of tables where each table only has a repo + simple `opt = true`, flatten if possible
  if expr:sub(1, 1) == "{" and expr:sub(-1) == "}" then
    local parsed = M.parse_lua_table_fields(expr)
    if next(parsed.named) == nil and #parsed.positional > 0 then
      local repos = {}
      local all_simple = true
      for _, p in ipairs(parsed.positional) do
        p = trim(p)
        if p:sub(1, 1) == '"' or p:sub(1, 1) == "'" then
          repos[#repos + 1] = normalize_repo(unquote(p)) or unquote(p)
        elseif p:sub(1, 1) == "{" and p:sub(-1) == "}" then
          local sub = M.parse_lua_table_fields(p)
          local r = sub.positional[1] and normalize_repo(sub.positional[1])
          local only_opt = true
          for k in pairs(sub.named) do
            if k ~= "opt" and k ~= "lazy" then
              only_opt = false
            end
          end
          if r and only_opt then
            repos[#repos + 1] = r
          else
            all_simple = false
          end
        else
          all_simple = false
        end
      end
      if all_simple and #repos > 0 then
        return table.concat(repos, ", ")
      end
    end
  end
  return expr
end

--- Convert a parsed Lua table (`{positional, named}`) into an `InstallerParsedSpec`.
---@param tbl_src string
---@param managerHint? string
---@return InstallerParsedSpec[]
local function lua_table_to_specs(tbl_src, managerHint)
  local parsed = M.parse_lua_table_fields(tbl_src)
  local pos = parsed.positional
  local named = parsed.named

  -- Check if this is a wrapper table of multiple plugin specs: `{ { "a/b" }, { "c/d" } }`
  local repo_candidate = pos[1] and normalize_repo(pos[1])
    or (named.url and normalize_repo(named.url))
    or (named.source and normalize_repo(named.source))
    or (named.src and normalize_repo(named.src))
    or (named.git and normalize_repo(named.git))

  if not repo_candidate and #pos > 0 then
    local sub_specs = {}
    for _, item in ipairs(pos) do
      item = trim(item)
      if item:sub(1, 1) == "{" and item:sub(-1) == "}" then
        local children = lua_table_to_specs(item, managerHint)
        for _, c in ipairs(children) do
          sub_specs[#sub_specs + 1] = c
        end
      elseif item:sub(1, 1) == '"' or item:sub(1, 1) == "'" then
        local r = normalize_repo(item)
        if r then
          sub_specs[#sub_specs + 1] = {
            manager = managerHint or "lazy",
            repo = r,
            form = { repo = r },
            score = MANAGER_PRIORITY[managerHint or "lazy"] or 50,
          }
        end
      end
    end
    if #sub_specs > 0 then
      return sub_specs
    end
    return {}
  end

  if not repo_candidate then
    return {}
  end

  -- Determine manager from keys if not explicitly given
  local manager = managerHint or "lazy"
  if not managerHint then
    if named.source or named.depends or named.checkout or named.hooks then
      manager = "mini.deps"
    elseif named.src then
      manager = "vim.pack"
    elseif named.config_pre or (named.cond and (named.cond:find("cmd%s*%(") or named.cond:find("keys%s*%("))) then
      manager = "pckr"
    elseif named.requires or named.run or named.opt ~= nil or named.as or named.wants or named.lock then
      manager = "packer"
    end
  end

  ---@type InstallerForm
  local form = { repo = repo_candidate }
  local field_count = 0
  local function set(k, v)
    if v and v ~= "" then
      form[k] = v
      field_count = field_count + 1
    end
  end

  -- Name (`name` in lazy/vim.pack, `as` in packer/paq)
  if named.name then
    set("name", unquote(named.name))
  elseif named.as then
    set("name", unquote(named.as))
  end

  -- Lazy (`lazy` in lazy, `opt` in packer/paq)
  if named.lazy ~= nil then
    set("lazy", trim(named.lazy))
  elseif named.opt ~= nil then
    set("lazy", trim(named.opt))
  end

  -- Priority
  if named.priority then
    set("priority", trim(named.priority))
  end

  -- Version / branch / tag / commit / checkout / rev
  if named.version then
    local v = trim(named.version)
    set("version", v == "false" and "false" or unquote(v))
  end
  if named.branch then
    set("branch", unquote(named.branch))
  elseif named.checkout then
    set("branch", unquote(named.checkout))
  end
  if named.tag then
    set("tag", unquote(named.tag))
  end
  if named.commit then
    set("commit", unquote(named.commit))
  elseif named.rev then
    set("commit", unquote(named.rev))
  end

  -- Pin (`pin` in lazy, `lock` in packer)
  if named.pin ~= nil then
    set("pin", trim(named.pin))
  elseif named.lock ~= nil then
    set("pin", trim(named.lock))
  end

  -- Event / Cmd / Ft
  for _, k in ipairs({ "event", "cmd", "ft" }) do
    if named[k] then
      local list = extract_string_list(named[k])
      if list then
        set(k, table.concat(list, ", "))
      end
    end
  end

  -- pckr `cond = cmd('Foo')` or `cond = keys('n', 'gc')`
  if named.cond then
    local cond_src = named.cond
    local pckr_cmds = {}
    for c in cond_src:gmatch("cmd%s*%(%s*([\"'][^\"']+[\"'])%s*%)") do
      pckr_cmds[#pckr_cmds + 1] = unquote(c)
    end
    if #pckr_cmds > 0 and not form.cmd then
      set("cmd", table.concat(pckr_cmds, ", "))
    end
    local pckr_keys = {}
    for _, lhs in cond_src:gmatch("keys%s*%(%s*([\"'][^\"']+[\"'])%s*,%s*([\"'][^\"']+[\"'])") do
      pckr_keys[#pckr_keys + 1] = unquote(lhs)
    end
    if #pckr_keys > 0 and not form.keys then
      set("keys", table.concat(pckr_keys, ", "))
    end
  end

  -- Keys
  if named.keys then
    local list, complex = extract_string_list(named.keys)
    if list and not complex then
      set("keys", table.concat(list, ", "))
    elseif trim(named.keys):sub(1, 1) == "{" then
      set("keys", trim(named.keys))
    end
  end

  -- Dependencies (`dependencies` in lazy, `requires`/`wants`/`after` in packer/pckr, `depends` in mini.deps)
  local dep_expr = named.dependencies or named.requires or named.depends or named.wants
  if dep_expr then
    set("dependencies", format_dependencies_expr(dep_expr))
  end

  -- Build (`build` in lazy/paq, `run` in packer/pckr, `hooks` in mini.deps)
  local build_expr = named.build or named.run
  if build_expr then
    local b = trim(build_expr)
    if b:sub(1, 1) == '"' or b:sub(1, 1) == "'" then
      set("build", unquote(b))
    elseif b:sub(1, 1) == "{" then
      set("build", b)
    elseif b:match("^function") then
      -- e.g. `run = function() vim.fn["..."]() end` -> extract `:Cmd` if vim.cmd
      local vcmd = b:match("vim%.cmd%s*%(%s*([\"'][^\"']+[\"'])%s*%)")
      if vcmd then
        set("build", ":" .. unquote(vcmd):gsub("^:", ""))
      end
    end
  elseif named.hooks then
    local vcmd = named.hooks:match("vim%.cmd%s*%(%s*([\"'][^\"']+[\"'])%s*%)")
    if vcmd then
      set("build", ":" .. unquote(vcmd):gsub("^:", ""))
    end
  end

  -- Opts
  if named.opts then
    local o = trim(named.opts)
    if o:sub(1, 1) == "{" and o:sub(-1) == "}" then
      set("opts", o)
    end
  end

  -- Init (`init` in lazy, `setup` in packer, `config_pre` in pckr)
  local init_expr = named.init or named.setup or named.config_pre
  if init_expr and trim(init_expr):match("^function") then
    set("init", trim(init_expr))
  end

  -- Config (`config` in lazy/packer/pckr)
  if named.config then
    local c = trim(named.config)
    if c == "true" or c == "false" or c:match("^function") then
      -- Check if `config = function() require("...").setup({ ... }) end` is a simple setup wrapper
      set("config", c)
    elseif c:sub(1, 1) == '"' or c:sub(1, 1) == "'" then
      local body = unquote(c)
      set("config", "function()\n  " .. body .. "\nend")
    end
  end

  local base_score = MANAGER_PRIORITY[manager] or 50
  return {
    {
      manager = manager,
      repo = repo_candidate,
      form = form,
      score = base_score + field_count * 5,
    },
  }
end

--- Parse Vimscript `Plug 'owner/repo', { ... }`, `dein#add(...)`, `Plugin '...'`, `Bundle '...'`.
---@param text string
---@return InstallerParsedSpec[]
local function parse_vimscript_specs(text)
  local specs = {}
  local plug_block_repos = {}
  local plug_specs = {}

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local tline = trim(line)
    -- Skip pure Vimscript comments
    if not tline:match('^"') then
      -- 1. vim-plug: `Plug 'owner/repo'` or `Plug 'owner/repo', { ... }`
      local plug_repo, plug_rest = tline:match("^Plug%s+([\"'][^\"']+[\"'])%s*(.*)$")
      if plug_repo then
        local repo = normalize_repo(plug_repo)
        if repo then
          local form = { repo = repo }
          local fields = 0
          local opts_str = plug_rest:match("^,%s*(%b{})")
          if opts_str then
            -- Parse Vimscript dict keys: `'do'`, `'branch'`, `'tag'`, `'commit'`, `'on'`, `'for'`, `'as'`, `'frozen'`
            local function vdict_str(k)
              return opts_str:match("[\"']" .. k .. "[\"']%s*:%s*([\"'][^\"']+[\"'])")
            end
            local function vdict_list_or_str(k)
              local arr = opts_str:match("[\"']" .. k .. "[\"']%s*:%s*(%b[])")
              if arr then
                local items = {}
                for item in arr:gmatch("[\"']([^\"']+)[\"']") do
                  items[#items + 1] = item
                end
                if #items > 0 then
                  return table.concat(items, ", ")
                end
              end
              local s = vdict_str(k)
              return s and unquote(s) or nil
            end
            local b = vdict_str("do")
            if b then
              form.build = unquote(b)
              fields = fields + 1
            end
            local br = vdict_str("branch")
            if br then
              form.branch = unquote(br)
              fields = fields + 1
            end
            local tg = vdict_str("tag")
            if tg then
              form.tag = unquote(tg)
              fields = fields + 1
            end
            local cm = vdict_str("commit")
            if cm then
              form.commit = unquote(cm)
              fields = fields + 1
            end
            local as = vdict_str("as")
            if as then
              form.name = unquote(as)
              fields = fields + 1
            end
            local on_cmd = vdict_list_or_str("on")
            if on_cmd then
              form.cmd = on_cmd
              fields = fields + 1
            end
            local for_ft = vdict_list_or_str("for")
            if for_ft then
              form.ft = for_ft
              fields = fields + 1
            end
            if opts_str:match("[\"']frozen[\"']%s*:%s*1") or opts_str:match("[\"']frozen[\"']%s*:%s*v:true") then
              form.pin = "true"
              fields = fields + 1
            end
          end
          plug_block_repos[#plug_block_repos + 1] = repo
          local entry = {
            manager = "vim-plug",
            repo = repo,
            form = form,
            score = MANAGER_PRIORITY["vim-plug"] + fields * 5,
          }
          plug_specs[#plug_specs + 1] = entry
          specs[#specs + 1] = entry
        end
      end

      -- 2. dein.vim: `call dein#add('owner/repo', { ... })`
      local dein_repo, dein_rest = tline:match("dein#add%s*%(%s*([\"'][^\"']+[\"'])%s*(.*)%)")
      if dein_repo then
        local repo = normalize_repo(dein_repo)
        if repo then
          local form = { repo = repo }
          local fields = 0
          local opts_str = dein_rest and dein_rest:match("^,%s*(%b{})")
          if opts_str then
            local rev = opts_str:match("[\"']rev[\"']%s*:%s*([\"'][^\"']+[\"'])")
            if rev then
              form.branch = unquote(rev)
              fields = fields + 1
            end
            local b = opts_str:match("[\"']build[\"']%s*:%s*([\"'][^\"']+[\"'])")
            if b then
              form.build = unquote(b)
              fields = fields + 1
            end
            local on_ft = opts_str:match("[\"']on_ft[\"']%s*:%s*([\"'][^\"']+[\"'])")
            if on_ft then
              form.ft = unquote(on_ft)
              fields = fields + 1
            end
            local on_cmd = opts_str:match("[\"']on_cmd[\"']%s*:%s*([\"'][^\"']+[\"'])")
            if on_cmd then
              form.cmd = unquote(on_cmd)
              fields = fields + 1
            end
          end
          specs[#specs + 1] = {
            manager = "dein",
            repo = repo,
            form = form,
            score = MANAGER_PRIORITY["dein"] + fields * 5,
          }
        end
      end

      -- 3. Vundle / NeoBundle: `Plugin 'owner/repo'` or `Bundle 'owner/repo'` or `NeoBundle 'owner/repo'`
      local vundle_repo = tline:match("^Plugin%s+([\"'][^\"']+[\"'])")
        or tline:match("^Neo?Bundle%s+([\"'][^\"']+[\"'])")
      if vundle_repo then
        local repo = normalize_repo(vundle_repo)
        if repo then
          specs[#specs + 1] = {
            manager = "vundle",
            repo = repo,
            form = { repo = repo },
            score = MANAGER_PRIORITY["vundle"],
          }
        end
      end

      -- 4. rocks.nvim command: `:Rocks install <pkg> [version] [opt=true]`
      local rocks_args = tline:match("^:?Rocks%s+install%s+(.+)$")
      if rocks_args then
        local parts = {}
        for w in rocks_args:gmatch("%S+") do
          parts[#parts + 1] = w
        end
        if parts[1] then
          local repo = normalize_repo(parts[1]) or parts[1]
          local form = { repo = repo }
          for idx = 2, #parts do
            local p = parts[idx]
            if p:match("^opt=") then
              form.lazy = p:sub(5)
            elseif p:match("^branch=") then
              form.branch = p:sub(8)
            elseif p:match("^%d+%.%d+") then
              form.version = p
            end
          end
          specs[#specs + 1] = {
            manager = "rocks",
            repo = repo,
            form = form,
            score = MANAGER_PRIORITY["rocks"],
          }
        end
      end
    end
  end

  -- If a vim-plug snippet had multiple `Plug` lines where the last one is the main plugin
  -- and preceding ones are dependencies (very common in READMEs like telescope.nvim),
  -- attach preceding Plug repos as `dependencies` on the last Plug spec if it has none!
  if #plug_specs > 1 then
    local last = plug_specs[#plug_specs]
    if not last.form.dependencies then
      local deps = {}
      for i = 1, #plug_specs - 1 do
        if plug_specs[i].repo ~= last.repo then
          deps[#deps + 1] = plug_specs[i].repo
        end
      end
      if #deps > 0 then
        last.form.dependencies = table.concat(deps, ", ")
        last.score = last.score + 5
      end
    end
  end

  return specs
end

--- Parse `git clone` shell commands and TOML (`rocks.toml`) entries.
---@param text string
---@return InstallerParsedSpec[]
local function parse_shell_and_toml_specs(text)
  local specs = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local tline = trim(line)
    -- 1. `git clone ... https://github.com/owner/repo(.git)`
    if tline:find("git%s+clone") then
      local url = tline:match("(https?://github%.com/[%w_.-]+/[%w_.-]+)")
        or tline:match("(git@github%.com:[%w_.-]+/[%w_.-]+)")
      if url then
        local repo = normalize_repo(url)
        if repo then
          local branch = tline:match("%-%-branch[=%s]+([%w_./-]+)") or tline:match("%-b%s+([%w_./-]+)")
          -- Skip plugin manager bootstrap clones (`packer.nvim`, `lazy.nvim`, `pckr.nvim`, `rocks.nvim`)
          if not repo:match("/packer%.nvim$") and not repo:match("/lazy%.nvim$") and not repo:match("/pckr%.nvim$") then
            local form = { repo = repo }
            if branch then
              form.branch = branch
            end
            specs[#specs + 1] = {
              manager = "git",
              repo = repo,
              form = form,
              score = MANAGER_PRIORITY["git"] + (branch and 5 or 0),
            }
          end
        end
      end
    end

    -- 2. TOML `git = "owner/repo"` or `"owner/repo" = "1.0.0"`
    local toml_git = tline:match("git%s*=%s*([\"'][^\"']+[\"'])")
    if toml_git then
      local repo = normalize_repo(toml_git)
      if repo then
        local form = { repo = repo }
        local br = tline:match("branch%s*=%s*([\"'][^\"']+[\"'])")
        local rev = tline:match("rev%s*=%s*([\"'][^\"']+[\"'])")
        local ver = tline:match("version%s*=%s*([\"'][^\"']+[\"'])")
        if br then
          form.branch = unquote(br)
        end
        if rev then
          form.commit = unquote(rev)
        end
        if ver then
          form.version = unquote(ver)
        end
        specs[#specs + 1] = {
          manager = "rocks",
          repo = repo,
          form = form,
          score = MANAGER_PRIORITY["rocks"] + 5,
        }
      end
    end
  end
  return specs
end

--- Parse Lua snippets for lazy.nvim, packer.nvim, pckr.nvim, mini.deps, vim.pack, paq-nvim.
---@param text string
---@return InstallerParsedSpec[]
local function parse_lua_specs(text)
  local specs = {}
  local seen_ranges = {}

  local function add_spec_list(list)
    for _, s in ipairs(list) do
      -- Ignore plugin manager self-declarations (`wbthomason/packer.nvim`, `folke/lazy.nvim`)
      if s.repo ~= "wbthomason/packer.nvim" and s.repo ~= "folke/lazy.nvim" and s.repo ~= "lewis6991/pckr.nvim" then
        specs[#specs + 1] = s
      end
    end
  end

  local default_manager = nil
  if text:find("require%s*%(?%s*[\"']pckr[\"']%s*%)?") then
    default_manager = "pckr"
  elseif text:find("require%s*%(?%s*[\"']paq[\"']%s*%)?") then
    default_manager = "paq"
  end

  -- 1. Explicit manager calls:
  --    use 'owner/repo' | use { ... } | use({ ... })
  local pos = 1
  while pos <= #text do
    local s, e, fn_name = text:find("([%a_][%w_.]*)%s*[({'\"]", pos)
    if not s then
      break
    end
    local arg_start = e
    local manager_hint = nil
    if fn_name == "use" then
      manager_hint = "packer"
    elseif fn_name == "MiniDeps.add" then
      manager_hint = "mini.deps"
    elseif fn_name == "add" then
      manager_hint = default_manager or "mini.deps"
    elseif fn_name == "vim.pack.add" then
      manager_hint = "vim.pack"
    elseif fn_name:match("pckr") then
      manager_hint = "pckr"
    elseif fn_name:match("paq") then
      manager_hint = "paq"
    end

    if manager_hint then
      local expr_end = find_lua_expr_end(text, arg_start)
      if expr_end and expr_end >= arg_start then
        local arg_src = trim(text:sub(arg_start, expr_end))
        if arg_src:sub(1, 1) == "(" and arg_src:sub(-1) == ")" then
          arg_src = trim(arg_src:sub(2, -2))
        end
        if arg_src:sub(1, 1) == '"' or arg_src:sub(1, 1) == "'" then
          local repo = normalize_repo(arg_src)
          if repo then
            add_spec_list({
              {
                manager = manager_hint,
                repo = repo,
                form = { repo = repo },
                score = MANAGER_PRIORITY[manager_hint] or 50,
              },
            })
            seen_ranges[#seen_ranges + 1] = { s, expr_end }
          end
        elseif arg_src:sub(1, 1) == "{" and arg_src:sub(-1) == "}" then
          add_spec_list(lua_table_to_specs(arg_src, manager_hint))
          seen_ranges[#seen_ranges + 1] = { s, expr_end }
        end
        pos = expr_end + 1
      else
        pos = e + 1
      end
    else
      pos = e
    end
  end

  local function inside_seen(idx)
    for _, r in ipairs(seen_ranges) do
      if idx >= r[1] and idx <= r[2] then
        return true
      end
    end
    return false
  end

  -- 2. Top-level / standalone Lua tables (`return { ... }`, `require("lazy").setup({ ... })`, `{ "owner/repo", ... }`)
  local i = 1
  while i <= #text do
    local brace_pos = text:find("{", i, true)
    if not brace_pos then
      break
    end
    if inside_seen(brace_pos) then
      i = brace_pos + 1
    else
      local brace_end = find_lua_expr_end(text, brace_pos)
      if brace_end and brace_end > brace_pos and text:sub(brace_end, brace_end) == "}" then
        local tbl_src = text:sub(brace_pos, brace_end)
        local extracted = lua_table_to_specs(tbl_src, default_manager)
        if #extracted > 0 then
          add_spec_list(extracted)
          seen_ranges[#seen_ranges + 1] = { brace_pos, brace_end }
          i = brace_end + 1
        else
          i = brace_pos + 1
        end
      else
        i = brace_pos + 1
      end
    end
  end

  return specs
end

--- Extract `:MasonInstall ...` / `:Installer mason install ...` packages from text.
---@param text string
---@return string[]
function M.extract_mason_packages(text)
  local pkgs = {}
  local seen = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local tline = trim(line)
    local m_args = tline:match("^:?MasonInstall%s+(.+)$")
      or tline:match("^:?Installer%s+mason%s+install%s+(.+)$")
    if m_args then
      for pkg in m_args:gmatch("[%w_.-]+") do
        if not seen[pkg] then
          seen[pkg] = true
          pkgs[#pkgs + 1] = pkg
        end
      end
    end
  end
  return pkgs
end

--- Extract standalone `require("<mod>").setup({ ... })` calls from text.
---@param text string
---@return {module: string, opts: string}[]
function M.extract_setup_calls(text)
  local calls = {}
  local pos = 1
  while pos <= #text do
    local s, e, mod = text:find('require%s*%(?%s*["\']([%w_.-]+)["\']%s*%)?%s*%.%s*setup%s*', pos)
    if not s then
      break
    end
    local next_ch = text:sub(e + 1, e + 1)
    if next_ch == "(" or next_ch == "{" then
      local expr_end = find_lua_expr_end(text, e + 1)
      if expr_end and expr_end > e then
        local arg = trim(text:sub(e + 1, expr_end))
        if arg:sub(1, 1) == "(" and arg:sub(-1) == ")" then
          arg = trim(arg:sub(2, -2))
        end
        if arg:sub(1, 1) == "{" and arg:sub(-1) == "}" then
          calls[#calls + 1] = { module = mod, opts = arg }
        elseif arg == "" then
          calls[#calls + 1] = { module = mod, opts = "{}" }
        end
        pos = expr_end + 1
      else
        pos = e + 1
      end
    else
      pos = e + 1
    end
  end
  return calls
end

--- Extract markdown code blocks from a document, or return the document itself as one block.
---@param markdown string
---@return {lang: string, code: string, heading: string}[]
function M.extract_blocks(markdown)
  local blocks = {}
  local heading = ""
  local in_fence = false
  local fence_marker = ""
  local fence_lang = ""
  local buf = {}

  for line in (markdown .. "\n"):gmatch("(.-)\n") do
    if not in_fence then
      local h = line:match("^#+%s+(.+)$")
      if h then
        heading = trim(h)
      else
        local ticks, lang = line:match("^%s*(```+)%s*([%w_.-]*)")
        if not ticks then
          ticks, lang = line:match("^%s*(~~~+)%s*([%w_.-]*)")
        end
        if ticks then
          in_fence = true
          fence_marker = ticks
          fence_lang = (lang or ""):lower()
          buf = {}
        end
      end
    else
      if line:match("^%s*" .. fence_marker .. "%s*$") then
        blocks[#blocks + 1] = {
          lang = fence_lang,
          code = table.concat(buf, "\n"),
          heading = heading,
        }
        in_fence = false
      else
        buf[#buf + 1] = line
      end
    end
  end

  if #blocks == 0 then
    blocks[#blocks + 1] = { lang = "", code = markdown, heading = "" }
  end
  return blocks
end

--- Merge complementary fields from lower-priority specs of the same repo into the best spec,
--- and attach standalone `require("...").setup({...})` opts if `opts` and `config` are empty.
---@param specs InstallerParsedSpec[]
---@param setup_calls {module: string, opts: string}[]
---@param target_repo? string
---@return InstallerForm|nil primary, string|nil manager
local function select_and_merge_primary(specs, setup_calls, target_repo)
  if #specs == 0 then
    return nil, nil
  end

  local target_norm = target_repo and normalize_repo(target_repo)
  local candidates = {}
  for _, s in ipairs(specs) do
    if not target_norm or s.repo:lower() == target_norm:lower() then
      candidates[#candidates + 1] = s
    end
  end
  if #candidates == 0 then
    candidates = specs
  end

  table.sort(candidates, function(a, b)
    return a.score > b.score
  end)

  local best = candidates[1]
  local merged = vim.deepcopy(best.form)

  -- Fill in missing fields from other specs of the same repo (e.g. if lazy block omitted `build` that packer block had)
  local merge_keys = { "dependencies", "build", "event", "cmd", "ft", "keys", "branch", "tag", "version", "opts", "config", "init" }
  for i = 2, #candidates do
    local other = candidates[i]
    if other.repo:lower() == best.repo:lower() then
      for _, k in ipairs(merge_keys) do
        if (not merged[k] or merged[k] == "") and other.form[k] and other.form[k] ~= "" then
          merged[k] = other.form[k]
        end
      end
    end
  end

  -- Check if a standalone `require("<mod>").setup({ ... })` matches this plugin
  if (not merged.opts or merged.opts == "") and (not merged.config or merged.config == "") and #setup_calls > 0 then
    local parsed_repo = Spec.parse_repo(merged.repo)
    local default_mod = parsed_repo and Spec.default_filename(parsed_repo.base) or ""
    local base_mod = parsed_repo and parsed_repo.base:gsub("%.n?vim$", "") or ""
    for _, call in ipairs(setup_calls) do
      local m = call.module:lower()
      if m == default_mod:lower() or m == base_mod:lower() or #setup_calls == 1 then
        if call.opts and call.opts ~= "{}" then
          merged.opts = call.opts
        elseif not merged.opts then
          merged.opts = "{}"
        end
        break
      end
    end
  end

  return merged, best.manager
end

--- Parse any README.md or installer snippet text.
---@param text string
---@param opts? {repo?: string}
---@return InstallerParseResult
function M.parse(text, opts)
  opts = opts or {}
  local blocks = M.extract_blocks(text or "")
  local all_specs = {}
  local mason_pkgs = M.extract_mason_packages(text or "")
  local setup_calls = M.extract_setup_calls(text or "")

  for _, block in ipairs(blocks) do
    local h_lower = (block.heading or ""):lower()
    local heading_bonus = 0
    if h_lower:find("lazy") then
      heading_bonus = 15
    elseif h_lower:find("install") or h_lower:find("setup") or h_lower:find("quickstart") or h_lower:find("get started") then
      heading_bonus = 10
    end

    local lang = block.lang
    local block_specs = {}

    if lang == "vim" or lang == "viml" then
      block_specs = parse_vimscript_specs(block.code)
    elseif lang == "sh" or lang == "bash" or lang == "zsh" or lang == "shell" or lang == "console" then
      block_specs = parse_shell_and_toml_specs(block.code)
    elseif lang == "toml" then
      block_specs = parse_shell_and_toml_specs(block.code)
    elseif lang == "lua" then
      block_specs = parse_lua_specs(block.code)
    else
      -- Unknown/empty language fence: try Lua, Vimscript, and Shell/TOML
      vim.list_extend(block_specs, parse_lua_specs(block.code))
      vim.list_extend(block_specs, parse_vimscript_specs(block.code))
      vim.list_extend(block_specs, parse_shell_and_toml_specs(block.code))
    end

    for _, s in ipairs(block_specs) do
      s.score = s.score + heading_bonus
      all_specs[#all_specs + 1] = s
    end
  end

  -- Fallback: if no specs were found but `opts.repo` was passed, create a spec for `opts.repo`
  -- and attach any discovered `setup({...})` call from the README!
  if #all_specs == 0 and opts.repo then
    local r = normalize_repo(opts.repo)
    if r then
      all_specs[#all_specs + 1] = {
        manager = "readme",
        repo = r,
        form = { repo = r },
        score = 10,
      }
    end
  end

  local primary, primary_manager = select_and_merge_primary(all_specs, setup_calls, opts.repo)

  return {
    specs = all_specs,
    primary = primary,
    primary_manager = primary_manager,
    mason = mason_pkgs,
    setup_calls = setup_calls,
  }
end

--- Read a local file (e.g. `README.md`) and parse all installer snippets from it.
---@param path? string
---@param opts? {repo?: string}
---@return InstallerParseResult|nil, string? err
function M.parse_file(path, opts)
  path = path and trim(path) or ""
  if path == "" then
    path = "README.md"
  end
  if vim and vim.fn and vim.fn.expand then
    path = vim.fn.expand(path)
  end
  local fd, err = io.open(path, "r")
  if not fd then
    return nil, "Could not read " .. path .. ": " .. tostring(err)
  end
  local content = fd:read("*a")
  fd:close()
  return M.parse(content, opts)
end

--- Fetch a repository's README.md from GitHub and parse its installer spec(s).
---@param repo string
---@param cb fun(err: string|nil, result: InstallerParseResult|nil)
function M.parse_github(repo, cb)
  local parsed, perr = Spec.parse_repo(repo)
  if not parsed or not parsed.short then
    return cb(perr or "Expected a GitHub repository (owner/repo)", nil)
  end
  local GitHub = require("installer.github")
  GitHub.readme(parsed.short, function(err, markdown)
    if err then
      return cb(err, nil)
    end
    local result = M.parse(markdown or "", { repo = parsed.short })
    cb(nil, result)
  end)
end

--- Interactive command entry point (`:Installer parse [target]`).
---@param target? string  owner/repo, file path, or empty (current buffer / README.md)
---@param opts? {bang?: boolean, range?: {line1: integer, line2: integer}}
function M.command(target, opts)
  opts = opts or {}
  local UI = require("installer.ui")
  local installer = require("installer")
  target = trim(target)

  local function handle_result(result, source_label)
    if not result or (#result.specs == 0 and #result.mason == 0) then
      return UI.notify("No plugin installer snippets found in " .. source_label, vim.log.levels.WARN)
    end

    if #result.mason > 0 and #result.specs == 0 then
      UI.notify(("Found Mason packages in %s: %s"):format(source_label, table.concat(result.mason, ", ")))
      require("installer.mason").install_many(result.mason)
      return
    end

    -- Deduplicate specs by repo (keeping highest-scoring form per repo)
    local by_repo = {}
    local unique = {}
    for _, s in ipairs(result.specs) do
      local key = s.repo:lower()
      if not by_repo[key] then
        local merged_form = select_and_merge_primary(result.specs, result.setup_calls, s.repo)
        local item = { repo = s.repo, manager = s.manager, form = merged_form or s.form, score = s.score }
        by_repo[key] = item
        unique[#unique + 1] = item
      end
    end

    if #unique == 1 or (target ~= "" and Spec.parse_repo(target) and result.primary) then
      local form = result.primary or unique[1].form
      local mgr = result.primary_manager or unique[1].manager
      UI.notify(("Parsed %s spec for %s from %s"):format(mgr, form.repo, source_label))
      if opts.bang then
        installer.add(form, { force = true })
      else
        installer.open(form)
      end
      return
    end

    -- Multiple distinct plugins discovered in README/file: let the user pick one or install all
    local items = {}
    if #unique > 1 then
      items[#items + 1] = {
        all = true,
        label = ("★ Install all %d parsed plugins"):format(#unique),
      }
    end
    for _, u in ipairs(unique) do
      items[#items + 1] = {
        spec = u,
        label = string.format("%-34s [%s]", u.repo, u.manager),
      }
    end
    vim.ui.select(items, {
      prompt = ("Parsed %d plugin(s) from %s"):format(#unique, source_label),
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.all then
        for _, u in ipairs(unique) do
          installer.add(u.form, { force = opts.bang })
        end
      elseif opts.bang then
        installer.add(choice.spec.form, { force = true })
      else
        installer.open(choice.spec.form)
      end
    end)
  end

  -- 1. Visual range in current buffer
  if opts.range and opts.range.line1 and opts.range.line2 then
    local lines = vim.api.nvim_buf_get_lines(0, opts.range.line1 - 1, opts.range.line2, false)
    return handle_result(M.parse(table.concat(lines, "\n")), "selection")
  end

  -- 2. Explicit target: file path vs GitHub `owner/repo`
  if target ~= "" then
    local uv = vim.uv or vim.loop
    local expanded = vim.fn.expand(target)
    if uv.fs_stat(expanded) then
      local res, err = M.parse_file(expanded)
      if not res then
        return UI.notify(err or "Failed to parse file", vim.log.levels.ERROR)
      end
      return handle_result(res, target)
    end
    local parsed_repo = Spec.parse_repo(target)
    if parsed_repo and parsed_repo.short then
      UI.notify("Fetching and parsing README.md for " .. parsed_repo.short .. "…")
      return M.parse_github(parsed_repo.short, function(err, res)
        if err then
          return UI.notify(err, vim.log.levels.ERROR)
        end
        handle_result(res, parsed_repo.short .. "/README.md")
      end)
    end
    -- Otherwise treat `target` as inline snippet text
    return handle_result(M.parse(target), "input")
  end

  -- 3. No target: try current buffer if non-empty, else ./README.md
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local buf_text = table.concat(buf_lines, "\n")
  if trim(buf_text) ~= "" then
    local res = M.parse(buf_text)
    if #res.specs > 0 or #res.mason > 0 then
      local name = vim.api.nvim_buf_get_name(0)
      return handle_result(res, name ~= "" and vim.fn.fnamemodify(name, ":t") or "current buffer")
    end
  end

  local res, err = M.parse_file("README.md")
  if not res then
    return UI.notify("Usage: :Installer parse [owner/repo | README.md] (" .. tostring(err) .. ")", vim.log.levels.WARN)
  end
  handle_result(res, "README.md")
end

return M
