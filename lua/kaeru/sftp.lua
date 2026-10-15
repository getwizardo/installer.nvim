-- SFTP integration: upload / download / sync project files over OpenSSH `sftp`.
--
-- Project uploads are split across several `sftp` processes that run at the
-- same time (`sftp.concurrency`), so large trees transfer in parallel.
--
-- Profiles come from a `.nvim-sftp.json` file in the project (found by walking
-- up from the current file) and/or `sftp.profiles` in setup():
--
--   {
--     "name": "production",
--     "host": "example.com",
--     "port": 22,
--     "username": "deploy",
--     "remotePath": "/var/www/app",
--     "privateKeyPath": "~/.ssh/id_ed25519",   // optional, string or array
--     "privateKeyPaths": ["~/.ssh/a", "~/.ssh/b"], // optional, tried in order
--     "identitiesOnly": true,                  // optional, only use the keys above
--     "sshConfigFile": "~/.ssh/config",        // optional, `-F`
--     "proxyJump": "bastion.example.com",      // optional, `-o ProxyJump`
--     "options": {"ServerAliveInterval": 30},  // optional, extra `-o` options
--     "password": "…",                         // optional, needs `sshpass`
--     "ignore": [".git", "node_modules"],      // optional, merged with sftp.ignore
--     "uploadOnSave": false                    // optional
--   }
--
-- The file may also be a JSON array of such objects. The same profiles can be
-- written in `kaeru.yaml` under `sftp.profiles` (see :help kaeru-yaml).
-- `host` may be an alias from your ssh config.
local Config = require("kaeru.config")
local Process = require("kaeru.process")
local UI = require("kaeru.ui")
local Compat = require("kaeru.compat")

local M = {}

local uv = vim.uv or vim.loop

---@class KaeruSftpProfile
---@field name string
---@field host string
---@field port? integer
---@field username? string
---@field remotePath string
---@field privateKeyPath? string|string[]
---@field privateKeyPaths? string[]
---@field identitiesOnly? boolean
---@field sshConfigFile? string
---@field proxyJump? string
---@field options? table<string, string|number|boolean>
---@field password? string
---@field ignore? string[]
---@field uploadOnSave? boolean
---@field localPath? string  defaults to the directory of the config file / cwd
---@field root string        (resolved) local project root
---@field source string      (resolved) "project" | "global"

---@type table<string, string> root -> last chosen profile name
M._last = {}

-- Helpers -----------------------------------------------------------------------

---@param path string
---@return string
local function norm(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  return (path:gsub("[/\\]+$", ""))
end

---@param path string
---@return boolean
local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param root string
---@param path string
---@return string|nil relative path (forward slashes) or nil when outside root
local function relative(root, path)
  path = norm(path)
  if path:sub(1, #root + 1) == root .. "/" then
    return (path:sub(#root + 2):gsub("\\", "/"))
  end
  return nil
end

--- Convert a glob (`*.log`, `dist/**`, `.git`) into a Lua pattern.
---@param glob string
---@return string
local function glob_to_pattern(glob)
  local p = glob:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
  p = p:gsub("%*%*", "\0"):gsub("%*", "[^/]*"):gsub("%z", ".*"):gsub("%?", ".")
  return "^" .. p .. "$"
end

---@param rel string relative path
---@param patterns string[] lua patterns
---@return boolean
local function ignored(rel, patterns)
  for _, pat in ipairs(patterns) do
    if rel:match(pat) then
      return true
    end
    for segment in rel:gmatch("[^/]+") do
      if segment:match(pat) then
        return true
      end
    end
  end
  return false
end

---@param profile KaeruSftpProfile
---@return string[]
local function ignore_patterns(profile)
  local globs = vim.list_extend({ Config.options.sftp.config_file }, Config.options.sftp.ignore or {})
  vim.list_extend(globs, profile.ignore or {})
  local out = {}
  for _, g in ipairs(globs) do
    out[#out + 1] = glob_to_pattern(g)
  end
  return out
end

---@param s string
---@return string
local function q(s)
  return '"' .. s:gsub('(["\\$`])', "\\%1") .. '"'
end

local function report(ok, msg)
  UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end

---@param profile KaeruSftpProfile
---@param rel string
---@return string
function M.remote_path(profile, rel)
  return (profile.remotePath:gsub("/+$", "")) .. "/" .. rel
end

-- Profiles ----------------------------------------------------------------------

---@param start string directory to start from
---@return string|nil path
local function find_config(start)
  local name = Config.options.sftp.config_file
  local found = vim.fs and vim.fs.find(name, { upward = true, path = start, type = "file" })[1]
  if found then
    return found
  end
  local f = vim.fn.findfile(name, start .. ";")
  return f ~= "" and vim.fn.fnamemodify(f, ":p") or nil
end

---@param path string
---@return KaeruSftpProfile[]|nil, string? err
local function read_config(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "cannot read " .. path
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  if not ok then
    return nil, path .. ": invalid JSON (" .. tostring(data) .. ")"
  end
  if data.host then
    data = { data }
  end
  local root = vim.fn.fnamemodify(path, ":h")
  local out = {}
  for i, p in ipairs(data) do
    p.name = p.name or ("profile" .. i)
    p.root = norm(p.localPath or root)
    p.source = "project"
    out[#out + 1] = p
  end
  return out
end

--- All profiles that apply to `file` (or cwd).
---@param file? string
---@return KaeruSftpProfile[], string? err
function M.profiles(file)
  local start = file and file ~= "" and vim.fn.fnamemodify(file, ":p:h") or vim.fn.getcwd()
  local list, err = {}, nil
  local cfg = find_config(start)
  if cfg then
    local found
    found, err = read_config(cfg)
    vim.list_extend(list, found or {})
  end
  local globals = {}
  for name, p in pairs(Config.options.sftp.profiles or {}) do
    if type(p) == "table" and p.host then
      local prof = vim.deepcopy(p)
      prof.name = prof.name or (type(name) == "string" and name) or ("profile" .. tostring(name))
      prof.root = norm(prof.localPath or vim.fn.getcwd())
      prof.source = "global"
      globals[#globals + 1] = prof
    end
  end
  table.sort(globals, function(a, b)
    return a.name < b.name
  end)
  vim.list_extend(list, globals)
  return list, err
end

--- Pick a profile (asks when several match).
---@param file? string
---@param cb fun(profile: KaeruSftpProfile|nil)
function M.select(file, cb)
  local list, err = M.profiles(file)
  if err then
    UI.notify(err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    UI.notify(
      ("No SFTP profile found. Create %s with :Kaeru sftp init"):format(Config.options.sftp.config_file),
      vim.log.levels.WARN
    )
    return cb(nil)
  end
  if #list == 1 then
    return cb(list[1])
  end
  local last = M._last[list[1].root]
  if last then
    for _, p in ipairs(list) do
      if p.name == last then
        return cb(p)
      end
    end
  end
  vim.ui.select(list, {
    prompt = "SFTP profile",
    format_item = function(p)
      return ("%s  (%s@%s:%s)"):format(p.name, p.username or "", p.host, p.remotePath)
    end,
  }, function(p)
    if p then
      M._last[p.root] = p.name
    end
    cb(p)
  end)
end

--- Force choosing a profile for the current project.
function M.choose()
  local list = M.profiles(vim.api.nvim_buf_get_name(0))
  if #list == 0 then
    return M.select(nil, function() end)
  end
  vim.ui.select(list, {
    prompt = "SFTP profile",
    format_item = function(p)
      return ("%s  (%s@%s:%s)"):format(p.name, p.username or "", p.host, p.remotePath)
    end,
  }, function(p)
    if p then
      M._last[p.root] = p.name
      UI.notify("Using SFTP profile " .. p.name)
    end
  end)
end

-- Command construction ------------------------------------------------------------

--- Private keys for a profile, in the order ssh should try them.
---@param profile KaeruSftpProfile
---@return string[]
function M.keys(profile)
  local keys = {}
  local function add(v)
    if type(v) == "string" and v ~= "" then
      keys[#keys + 1] = vim.fn.expand(v)
    elseif type(v) == "table" then
      for _, k in ipairs(v) do
        add(k)
      end
    end
  end
  add(profile.privateKeyPaths)
  add(profile.privateKeyPath)
  if #keys == 0 then
    add(Config.options.sftp.keys)
  end
  return keys
end

---@param v string|number|boolean
---@return string
local function opt_value(v)
  if v == true then
    return "yes"
  elseif v == false then
    return "no"
  end
  return tostring(v)
end

---@param profile KaeruSftpProfile
---@param cmd "sftp"|"scp"|"ssh"
---@return string[]|nil args, string? err
function M.base_cmd(profile, cmd)
  local args = {}
  local has_password = profile.password ~= nil and profile.password ~= ""
  if has_password then
    if vim.fn.executable("sshpass") ~= 1 then
      return nil, "profile uses a password but `sshpass` is not installed (prefer privateKeyPath / ssh-agent)"
    end
    vim.list_extend(args, { "sshpass", "-p", profile.password })
  end
  args[#args + 1] = cmd
  if not has_password then
    vim.list_extend(args, { "-o", "BatchMode=yes" })
  end
  vim.list_extend(args, { "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15" })
  if profile.sshConfigFile and profile.sshConfigFile ~= "" then
    vim.list_extend(args, { "-F", vim.fn.expand(profile.sshConfigFile) })
  end
  if profile.proxyJump and profile.proxyJump ~= "" then
    vim.list_extend(args, { "-o", "ProxyJump=" .. profile.proxyJump })
  end
  local options = Compat.tbl_extend("force", Config.options.sftp.options or {}, profile.options or {})
  local names = Compat.tbl_keys(options)
  table.sort(names)
  for _, name in ipairs(names) do
    vim.list_extend(args, { "-o", name .. "=" .. opt_value(options[name]) })
  end
  if profile.port and tonumber(profile.port) and tonumber(profile.port) ~= 22 then
    vim.list_extend(args, { cmd == "ssh" and "-p" or "-P", tostring(profile.port) })
  end
  local keys = M.keys(profile)
  for _, key in ipairs(keys) do
    vim.list_extend(args, { "-i", key })
  end
  if profile.identitiesOnly and #keys > 0 then
    vim.list_extend(args, { "-o", "IdentitiesOnly=yes" })
  end
  vim.list_extend(args, Config.options.sftp.extra_args or {})
  return args
end

---@param profile KaeruSftpProfile
---@return string
function M.target(profile)
  if profile.username and profile.username ~= "" then
    return profile.username .. "@" .. profile.host
  end
  return profile.host
end

--- Build the contents of an sftp batch file that uploads `rels`.
---@param profile KaeruSftpProfile
---@param rels string[] relative paths
---@return string
function M.upload_batch(profile, rels)
  local dirs, seen = {}, {}
  for _, rel in ipairs(rels) do
    local dir = rel:match("^(.*)/[^/]+$")
    local acc = nil
    for part in (dir or ""):gmatch("[^/]+") do
      acc = acc and (acc .. "/" .. part) or part
      if not seen[acc] then
        seen[acc] = true
        dirs[#dirs + 1] = acc
      end
    end
  end
  local lines = {}
  -- `-` prefix: ignore errors (directory probably exists already)
  lines[#lines + 1] = "-mkdir " .. q(profile.remotePath)
  for _, d in ipairs(dirs) do
    lines[#lines + 1] = "-mkdir " .. q(M.remote_path(profile, d))
  end
  for _, rel in ipairs(rels) do
    lines[#lines + 1] = ("put -p %s %s"):format(q(profile.root .. "/" .. rel), q(M.remote_path(profile, rel)))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Resolve a user supplied remote path: absolute stays, relative is under remotePath.
---@param profile KaeruSftpProfile
---@param path? string
---@return string
function M.resolve(profile, path)
  path = path and Compat.trim(path) or ""
  if path == "" or path == "." then
    return (profile.remotePath:gsub("/+$", ""))
  end
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
    return path
  end
  return M.remote_path(profile, (path:gsub("^%./", "")))
end

--- Run sftp batch commands and return the (echo-stripped) output.
---@param profile KaeruSftpProfile
---@param commands string[]
---@param cb fun(ok: boolean, output: string, err: string)
function M.batch(profile, commands, cb)
  local base, err = M.base_cmd(profile, "sftp")
  if not base then
    return cb(false, "", err)
  end
  local batch = Process.tempfile(table.concat(commands, "\n") .. "\n", ".sftp")
  local args = vim.deepcopy(base)
  vim.list_extend(args, { "-b", batch, M.target(profile) })
  Process.run(args, function(res)
    os.remove(batch)
    local out = {}
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
      if not line:match("^sftp> ") then
        out[#out + 1] = line
      end
    end
    cb(res.code == 0, table.concat(out, "\n"), Compat.trim(res.stderr or ""))
  end)
end

--- Run a shell command on the remote host (cwd = remotePath).
---@param profile KaeruSftpProfile
---@param command string
---@param cb fun(ok: boolean, output: string, err: string)
function M.ssh(profile, command, cb)
  local base, err = M.base_cmd(profile, "ssh")
  if not base then
    return cb(false, "", err)
  end
  local args = vim.deepcopy(base)
  vim.list_extend(args, { M.target(profile), ("cd %s && %s"):format(q(profile.remotePath), command) })
  Process.run(args, function(res)
    cb(res.code == 0, Compat.trim(res.stdout or ""), Compat.trim(res.stderr or ""))
  end)
end

--- Full argv for an interactive session (used by `shell` / `ssh` and `keys`).
---@param profile KaeruSftpProfile
---@param cmd "sftp"|"ssh"
---@return string[]|nil, string? err
function M.interactive_cmd(profile, cmd)
  local base, err = M.base_cmd(profile, cmd)
  if not base then
    return nil, err
  end
  -- BatchMode must be off for an interactive prompt
  local args, i = {}, 1
  while i <= #base do
    if base[i] == "-o" and base[i + 1] == "BatchMode=yes" then
      i = i + 2
    else
      args[#args + 1] = base[i]
      i = i + 1
    end
  end
  args[#args + 1] = M.target(profile)
  if cmd == "ssh" then
    vim.list_extend(args, { "-t", ("cd %s; exec $SHELL -l"):format(q(profile.remotePath)) })
  end
  return args
end

--- Parse `ls -la` output from sftp into entries.
---@param output string
---@return {name: string, type: "dir"|"file"|"link", size: integer, perms: string, mtime: string, target?: string}[]
function M.parse_ls(output)
  local entries = {}
  for line in output:gmatch("[^\r\n]+") do
    local perms, size, mtime, name = line:match("^([%-dlcbps][rwxsStT%-]+)%s+%S+%s+%S+%s+%S+%s+(%d+)%s+(%S+%s+%S+%s+%S+)%s+(.+)$")
    if perms and name ~= "." and name ~= ".." then
      local entry = { perms = perms, size = tonumber(size), mtime = mtime, name = name }
      local kind = perms:sub(1, 1)
      if kind == "d" then
        entry.type = "dir"
      elseif kind == "l" then
        entry.type = "link"
        local n, target = name:match("^(.-)%s+%->%s+(.+)$")
        if n then
          entry.name, entry.target = n, target
        end
      else
        entry.type = "file"
      end
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    if (a.type == "dir") ~= (b.type == "dir") then
      return a.type == "dir"
    end
    return a.name < b.name
  end)
  return entries
end

-- File discovery ---------------------------------------------------------------------

--- List project files relative to the profile root (git-aware, ignore-filtered).
---@param profile KaeruSftpProfile
---@return string[]
function M.list_files(profile)
  local root = profile.root
  local files = {}
  if vim.fn.executable("git") == 1 and is_dir(root .. "/.git") then
    local out = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z" })
    if vim.v.shell_error == 0 then
      local joined = table.concat(out, "\n")
      for f in joined:gmatch("[^%z]+") do
        files[#files + 1] = f
      end
    end
  end
  if #files == 0 then
    for _, f in ipairs(vim.fn.globpath(root, "**/*", true, true)) do
      if vim.fn.isdirectory(f) == 0 then
        files[#files + 1] = relative(root, f)
      end
    end
  end
  local patterns = ignore_patterns(profile)
  local out = {}
  for _, rel in ipairs(files) do
    if rel and not ignored(rel, patterns) and uv.fs_stat(root .. "/" .. rel) then
      out[#out + 1] = rel
    end
  end
  table.sort(out)
  return out
end

--- Split `items` into `n` round-robin chunks.
---@generic T
---@param items T[]
---@param n integer
---@return T[][]
function M.chunk(items, n)
  n = math.max(1, math.min(n, #items))
  local chunks = {}
  for i = 1, n do
    chunks[i] = {}
  end
  for i, item in ipairs(items) do
    local c = chunks[((i - 1) % n) + 1]
    c[#c + 1] = item
  end
  return chunks
end

-- Transfers ---------------------------------------------------------------------------

---@class KaeruSftpResult
---@field ok boolean
---@field files integer
---@field err? string

--- Upload `rels` with up to `sftp.concurrency` parallel sftp processes.
---@param profile KaeruSftpProfile
---@param rels string[]
---@param cb fun(ok: boolean, summary: string)
---@param opts? {quiet?: boolean}
function M.upload(profile, rels, cb, opts)
  opts = opts or {}
  if #rels == 0 then
    return cb(true, "nothing to upload")
  end
  local base, err = M.base_cmd(profile, "sftp")
  if not base then
    return cb(false, err)
  end
  local chunks = M.chunk(rels, Config.options.sftp.concurrency or 4)
  local started = uv.now()
  if not opts.quiet then
    UI.notify(("Uploading %d file(s) to %s with %d worker(s)…"):format(#rels, profile.name, #chunks))
  end

  local tasks = {}
  for i, chunk in ipairs(chunks) do
    tasks[i] = function(done)
      local batch = Process.tempfile(M.upload_batch(profile, chunk), ".sftp")
      local args = vim.deepcopy(base)
      vim.list_extend(args, { "-b", batch, M.target(profile) })
      Process.run(args, { cwd = profile.root }, function(res)
        os.remove(batch)
        local failed = {}
        for line in (res.stderr or ""):gmatch("[^\n]+") do
          if not line:match("^Couldn't create directory") and not line:match("mkdir") then
            failed[#failed + 1] = line
          end
        end
        done({
          ok = res.code == 0,
          files = #chunk,
          err = res.code ~= 0 and (#failed > 0 and table.concat(failed, "\n") or ("sftp exited with " .. res.code))
            or nil,
        })
      end)
    end
  end

  Process.pool(tasks, #chunks, function(results)
    local ok, uploaded, errors = true, 0, {}
    for _, r in ipairs(results) do
      if r.ok then
        uploaded = uploaded + r.files
      else
        ok = false
        errors[#errors + 1] = r.err
      end
    end
    local secs = (uv.now() - started) / 1000
    if ok then
      cb(true, ("Uploaded %d file(s) to %s in %.1fs"):format(uploaded, profile.name, secs))
    else
      cb(false, ("Upload to %s finished with errors:\n%s"):format(profile.name, table.concat(errors, "\n")))
    end
  end)
end

--- Download a single remote file (counterpart of the local `rel`).
---@param profile KaeruSftpProfile
---@param rel string
---@param cb fun(ok: boolean, msg: string)
function M.download(profile, rel, cb)
  local base, err = M.base_cmd(profile, "sftp")
  if not base then
    return cb(false, err)
  end
  local batch = Process.tempfile(("get -p %s %s\n"):format(q(M.remote_path(profile, rel)), q(profile.root .. "/" .. rel)), ".sftp")
  vim.fn.mkdir(vim.fn.fnamemodify(profile.root .. "/" .. rel, ":h"), "p")
  local args = vim.deepcopy(base)
  vim.list_extend(args, { "-b", batch, M.target(profile) })
  Process.run(args, function(res)
    os.remove(batch)
    if res.code == 0 then
      cb(true, "Downloaded " .. rel .. " from " .. profile.name)
    else
      cb(false, "Download failed: " .. Compat.trim(res.stderr))
    end
  end)
end

--- Download the whole remote tree into the project root (uses scp -r).
---@param profile KaeruSftpProfile
---@param cb fun(ok: boolean, msg: string)
function M.download_project(profile, cb)
  local base, err = M.base_cmd(profile, "scp")
  if not base then
    return cb(false, err)
  end
  local args = vim.deepcopy(base)
  vim.list_extend(args, { "-r", "-p", M.target(profile) .. ":" .. profile.remotePath:gsub("/+$", "") .. "/.", profile.root })
  UI.notify("Downloading " .. profile.remotePath .. " from " .. profile.name .. "…")
  Process.run(args, function(res)
    if res.code == 0 then
      cb(true, "Downloaded project from " .. profile.name)
    else
      cb(false, "Download failed: " .. Compat.trim(res.stderr))
    end
  end)
end

-- Sync state ----------------------------------------------------------------------------

local function state_file(profile)
  local key = vim.fn.sha256(profile.root .. "|" .. profile.host .. "|" .. profile.remotePath)
  local dir = vim.fn.stdpath("state") .. "/kaeru/sftp"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. key:sub(1, 16) .. ".json"
end

---@param profile KaeruSftpProfile
---@return number last sync time (seconds), 0 when never synced
function M.last_sync(profile)
  local fd = io.open(state_file(profile), "r")
  if not fd then
    return 0
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  return ok and tonumber(data.synced_at) or 0
end

---@param profile KaeruSftpProfile
---@param t number
function M.set_last_sync(profile, t)
  local fd = io.open(state_file(profile), "w")
  if fd then
    fd:write(vim.json.encode({ synced_at = t, profile = profile.name }))
    fd:close()
  end
end

--- Files changed since the last sync.
---@param profile KaeruSftpProfile
---@return string[]
function M.changed_files(profile)
  local since = M.last_sync(profile)
  local out = {}
  for _, rel in ipairs(M.list_files(profile)) do
    local st = uv.fs_stat(profile.root .. "/" .. rel)
    if st and (since == 0 or st.mtime.sec > since) then
      out[#out + 1] = rel
    end
  end
  return out
end

-- Commands --------------------------------------------------------------------------------

---@param quiet? boolean
function M.upload_current(quiet)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return UI.notify("Current buffer has no file", vim.log.levels.WARN)
  end
  M.select(file, function(profile)
    if not profile then
      return
    end
    local rel = relative(profile.root, file)
    if not rel then
      return UI.notify(("%s is outside the project root %s"):format(file, profile.root), vim.log.levels.WARN)
    end
    M.upload(profile, { rel }, function(ok, msg)
      if ok and quiet then
        UI.notify("↑ " .. rel .. " → " .. profile.name)
      else
        report(ok, msg)
      end
    end, { quiet = true })
  end)
end

function M.upload_project()
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local files = M.list_files(profile)
    M.upload(profile, files, function(ok, msg)
      if ok then
        M.set_last_sync(profile, os.time())
      end
      report(ok, msg)
    end)
  end)
end

--- Upload only files modified since the previous sync/upload.
function M.sync()
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local files = M.changed_files(profile)
    if #files == 0 then
      return UI.notify("Everything is up to date on " .. profile.name)
    end
    local started = os.time()
    M.upload(profile, files, function(ok, msg)
      if ok then
        M.set_last_sync(profile, started)
      end
      report(ok, msg)
    end)
  end)
end

function M.download_current()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return UI.notify("Current buffer has no file", vim.log.levels.WARN)
  end
  M.select(file, function(profile)
    if not profile then
      return
    end
    local rel = relative(profile.root, file)
    if not rel then
      return UI.notify(("%s is outside the project root %s"):format(file, profile.root), vim.log.levels.WARN)
    end
    M.download(profile, rel, function(ok, msg)
      report(ok, msg)
      if ok then
        vim.cmd("checktime")
      end
    end)
  end)
end

function M.download_all()
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    if vim.fn.confirm(("Overwrite local files in %s with %s?"):format(profile.root, profile.name), "&Yes\n&No", 2) ~= 1 then
      return
    end
    M.download_project(profile, function(ok, msg)
      report(ok, msg)
      if ok then
        vim.cmd("checktime")
      end
    end)
  end)
end

-- Generic sftp commands ------------------------------------------------------------------

---@param title string
---@param text string
local function show_output(title, text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= 3 then
    return UI.notify(title .. "\n" .. text)
  end
  local buf, win = UI.open({ title = title, width = math.min(vim.o.columns - 4, 110), height = math.min(#lines + 1, vim.o.lines - 6) })
  UI.set_lines(buf, lines)
  vim.bo[buf].modifiable = false
  UI.map(buf, "q", function()
    UI.close(win)
  end)
  UI.map(buf, "<Esc>", function()
    UI.close(win)
  end)
end

---@param profile KaeruSftpProfile
---@param cmd string
---@param args string[]
local function run_simple(profile, cmd, args)
  local line = cmd
  for _, a in ipairs(args) do
    line = line .. " " .. q(a)
  end
  M.batch(profile, { line }, function(ok, out, err)
    if ok then
      UI.notify(("%s: %s ✓%s"):format(profile.name, line, out ~= "" and ("\n" .. out) or ""))
    else
      UI.notify(("%s: %s failed\n%s"):format(profile.name, line, err), vim.log.levels.ERROR)
    end
  end)
end

--- Commands that map 1:1 to sftp batch commands. Values: { usage, min args, path arg indexes }.
M.commands = {
  ls = { usage = "ls [path]", min = 0, paths = { 1 } },
  mkdir = { usage = "mkdir <path>", min = 1, paths = { 1 } },
  rmdir = { usage = "rmdir <path>", min = 1, paths = { 1 } },
  rm = { usage = "rm <path>", min = 1, paths = { 1 } },
  rename = { usage = "rename <old> <new>", min = 2, paths = { 1, 2 } },
  chmod = { usage = "chmod <mode> <path>", min = 2, paths = { 2 } },
  chown = { usage = "chown <uid> <path>", min = 2, paths = { 2 } },
  chgrp = { usage = "chgrp <gid> <path>", min = 2, paths = { 2 } },
  ln = { usage = "ln [-s] <old> <new>", min = 2, paths = { -2, -1 } },
  symlink = { usage = "symlink <old> <new>", min = 2, paths = { 1, 2 } },
  df = { usage = "df [path]", min = 0, paths = { 1 } },
  pwd = { usage = "pwd", min = 0, paths = {} },
  version = { usage = "version", min = 0, paths = {} },
}

--- Run one sftp command with user supplied arguments (paths relative to remotePath).
---@param cmd string
---@param args string[]
function M.command(cmd, args)
  local def = M.commands[cmd]
  if not def then
    return UI.notify("Unknown sftp command: " .. cmd, vim.log.levels.ERROR)
  end
  if #args < def.min then
    return UI.notify("Usage: :Kaeru sftp " .. def.usage, vim.log.levels.WARN)
  end
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local resolved = vim.deepcopy(args)
    for _, idx in ipairs(def.paths) do
      local i = idx < 0 and (#resolved + idx + 1) or idx
      if i >= 1 and i <= #resolved and not resolved[i]:match("^%-") then
        resolved[i] = M.resolve(profile, resolved[i])
      elseif i == 1 and #resolved == 0 and (cmd == "ls" or cmd == "df") then
        resolved[1] = M.resolve(profile, nil)
      end
    end
    if cmd == "ls" and #resolved == 1 then
      table.insert(resolved, 1, "-la")
    end
    if cmd == "ls" or cmd == "df" then
      local line = cmd
      for _, a in ipairs(resolved) do
        line = line .. " " .. (a:match("^%-") and a or q(a))
      end
      M.batch(profile, { line }, function(ok, out, err)
        if ok then
          show_output(profile.name .. " · " .. line, out)
        else
          UI.notify(("%s: %s failed\n%s"):format(profile.name, line, err), vim.log.levels.ERROR)
        end
      end)
      return
    end
    run_simple(profile, cmd, resolved)
  end)
end

--- Run raw sftp batch commands, separated by `;`.
---@param text string
function M.exec(text)
  if not text or Compat.trim(text) == "" then
    return UI.notify("Usage: :Kaeru sftp exec <sftp commands separated by ;>", vim.log.levels.WARN)
  end
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local commands = {}
    for part in text:gmatch("[^;]+") do
      part = Compat.trim(part)
      if part ~= "" then
        commands[#commands + 1] = part
      end
    end
    M.batch(profile, commands, function(ok, out, err)
      show_output(profile.name .. " · sftp exec", (out ~= "" and out or "") .. (err ~= "" and ("\n" .. err) or "") .. (ok and "" or "\n(exit code ≠ 0)"))
    end)
  end)
end

--- Run a shell command on the remote host.
---@param text string
function M.run(text)
  if not text or Compat.trim(text) == "" then
    return UI.notify("Usage: :Kaeru sftp run <command>", vim.log.levels.WARN)
  end
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    M.ssh(profile, text, function(ok, out, err)
      show_output(("%s · $ %s%s"):format(profile.name, text, ok and "" or " (failed)"), (out ~= "" and out or "") .. (err ~= "" and ("\n" .. err) or ""))
    end)
  end)
end

--- Open an interactive sftp or ssh session in a terminal split.
---@param kind "sftp"|"ssh"
function M.shell(kind)
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local args, err = M.interactive_cmd(profile, kind)
    if not args then
      return UI.notify(err, vim.log.levels.ERROR)
    end
    vim.cmd("botright 15split")
    vim.fn.termopen(args, { cwd = profile.root })
    vim.cmd("startinsert")
  end)
end

--- Test the connection and print the resolved command line.
function M.test()
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local args = M.base_cmd(profile, "sftp") or {}
    local shown = Compat.tbl_map(function(a)
      return a == profile.password and "******" or a
    end, args)
    local keys = M.keys(profile)
    local started = uv.now()
    M.batch(profile, { "pwd" }, function(ok, out, err)
      local lines = {
        ("profile: %s (%s)"):format(profile.name, profile.source),
        ("target:  %s  remotePath: %s"):format(M.target(profile), profile.remotePath),
        ("keys:    %s"):format(#keys > 0 and table.concat(keys, ", ") or "(ssh-agent / defaults)"),
        ("command: %s"):format(table.concat(shown, " ")),
        ok and ("connected in %.1fs · %s"):format((uv.now() - started) / 1000, out) or ("FAILED: " .. err),
      }
      UI.notify(table.concat(lines, "\n"), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end)
end

--- Diff the current buffer against its remote counterpart.
function M.diff()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return UI.notify("Current buffer has no file", vim.log.levels.WARN)
  end
  M.select(file, function(profile)
    if not profile then
      return
    end
    local rel = relative(profile.root, file)
    if not rel then
      return UI.notify(("%s is outside the project root %s"):format(file, profile.root), vim.log.levels.WARN)
    end
    local tmp = vim.fn.tempname() .. "_" .. vim.fn.fnamemodify(file, ":t")
    M.batch(profile, { ("get %s %s"):format(q(M.remote_path(profile, rel)), q(tmp)) }, function(ok, _, err)
      if not ok then
        return UI.notify("Could not fetch remote file: " .. err, vim.log.levels.ERROR)
      end
      vim.cmd("diffthis")
      vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(tmp))
      vim.bo.readonly = true
      vim.bo.modifiable = false
      vim.api.nvim_buf_set_name(0, ("sftp://%s/%s"):format(profile.name, rel))
    end)
  end)
end

-- Remote browser ------------------------------------------------------------------------------

--- Floating remote file browser.
---@param start_path? string
function M.browse(start_path)
  M.select(vim.api.nvim_buf_get_name(0), function(profile)
    if not profile then
      return
    end
    local cwd = M.resolve(profile, start_path)
    local entries = {}
    local buf, win = UI.open({
      title = ("sftp · %s"):format(profile.name),
      width = math.min(vim.o.columns - 4, 100),
      height = math.min(vim.o.lines - 6, 30),
      filetype = "kaeru-sftp",
    })
    vim.wo[win].cursorline = true
    vim.bo[buf].modifiable = false

    local function render(status)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local lines = { "  " .. cwd .. (status and ("   " .. status) or "") }
      for _, e in ipairs(entries) do
        local icon = e.type == "dir" and "" or (e.type == "link" and "" or " ")
        local name = e.name .. (e.type == "dir" and "/" or "") .. (e.target and (" → " .. e.target) or "")
        lines[#lines + 1] = string.format("  %s %-40s %9s  %s", icon, name, e.type == "dir" and "" or tostring(e.size), e.mtime)
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  <CR> open  - up  d download  u upload file  m mkdir  R rename  D delete  r refresh  y yank path  q close"
      UI.set_lines(buf, lines)
      vim.api.nvim_buf_clear_namespace(buf, UI.ns, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, UI.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
      for i, e in ipairs(entries) do
        if e.type == "dir" then
          vim.api.nvim_buf_set_extmark(buf, UI.ns, i, 0, { end_col = #lines[i + 1], hl_group = "Directory", strict = false })
        end
      end
      vim.api.nvim_buf_set_extmark(buf, UI.ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "Comment" })
    end

    local function refresh()
      render("loading…")
      M.batch(profile, { "ls -la " .. q(cwd) }, function(ok, out, err)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        if not ok then
          entries = {}
          render("error: " .. err)
          return
        end
        entries = M.parse_ls(out)
        render(("%d entries"):format(#entries))
        pcall(vim.api.nvim_win_set_cursor, win, { math.min(2, #entries + 1), 0 })
      end)
    end

    local function current()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      return entries[row - 1]
    end
    local function join(name)
      return (cwd:gsub("/+$", "")) .. "/" .. name
    end
    local function close()
      UI.close(win)
    end

    UI.map(buf, "q", close)
    UI.map(buf, "<Esc>", close)
    UI.map(buf, "r", refresh)
    UI.map(buf, "-", function()
      cwd = cwd:match("^(.*)/[^/]+/?$") or "/"
      if cwd == "" then
        cwd = "/"
      end
      refresh()
    end)
    UI.map(buf, "<CR>", function()
      local e = current()
      if not e then
        return
      end
      if e.type == "dir" or (e.type == "link" and e.target and not e.target:match("%.%w+$")) then
        cwd = join(e.name)
        refresh()
      else
        local tmp = vim.fn.tempname() .. "_" .. e.name
        M.batch(profile, { ("get %s %s"):format(q(join(e.name)), q(tmp)) }, function(ok, _, err)
          if not ok then
            return UI.notify("Download failed: " .. err, vim.log.levels.ERROR)
          end
          close()
          vim.cmd.edit(vim.fn.fnameescape(tmp))
          vim.b.kaeru_sftp_remote = { profile = profile.name, path = join(e.name) }
          UI.notify("Opened remote copy of " .. e.name .. " (temporary file)")
        end)
      end
    end)
    UI.map(buf, "y", function()
      local e = current()
      local path = e and join(e.name) or cwd
      vim.fn.setreg("+", path)
      vim.fn.setreg('"', path)
      UI.notify("Yanked " .. path)
    end)
    UI.map(buf, "d", function()
      local e = current()
      if not e or e.type == "dir" then
        return UI.notify("Select a file to download", vim.log.levels.WARN)
      end
      local remote = join(e.name)
      local rel = remote:sub(#profile.remotePath:gsub("/+$", "") + 2)
      local local_path = remote:find(profile.remotePath:gsub("/+$", ""), 1, true) == 1 and (profile.root .. "/" .. rel)
        or (vim.fn.getcwd() .. "/" .. e.name)
      vim.fn.mkdir(vim.fn.fnamemodify(local_path, ":h"), "p")
      M.batch(profile, { ("get -p %s %s"):format(q(remote), q(local_path)) }, function(ok, _, err)
        UI.notify(ok and ("Downloaded to " .. local_path) or ("Download failed: " .. err), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
    end)
    UI.map(buf, "u", function()
      vim.ui.input({ prompt = "Local file to upload: ", completion = "file", default = vim.fn.expand("#:p") }, function(path)
        if not path or path == "" then
          return
        end
        path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        M.batch(profile, { ("put -p %s %s"):format(q(path), q(join(vim.fn.fnamemodify(path, ":t")))) }, function(ok, _, err)
          UI.notify(ok and ("Uploaded " .. path) or ("Upload failed: " .. err), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
          refresh()
        end)
      end)
    end)
    UI.map(buf, "m", function()
      vim.ui.input({ prompt = "New directory: " }, function(name)
        if name and name ~= "" then
          M.batch(profile, { "mkdir " .. q(join(name)) }, function(ok, _, err)
            if not ok then
              UI.notify("mkdir failed: " .. err, vim.log.levels.ERROR)
            end
            refresh()
          end)
        end
      end)
    end)
    UI.map(buf, "R", function()
      local e = current()
      if not e then
        return
      end
      vim.ui.input({ prompt = "Rename to: ", default = e.name }, function(name)
        if name and name ~= "" and name ~= e.name then
          M.batch(profile, { ("rename %s %s"):format(q(join(e.name)), q(join(name))) }, function(ok, _, err)
            if not ok then
              UI.notify("rename failed: " .. err, vim.log.levels.ERROR)
            end
            refresh()
          end)
        end
      end)
    end)
    UI.map(buf, "D", function()
      local e = current()
      if not e then
        return
      end
      if vim.fn.confirm(("Delete %s on %s?"):format(join(e.name), profile.name), "&Yes\n&No", 2) ~= 1 then
        return
      end
      local cmd = e.type == "dir" and "rmdir" or "rm"
      M.batch(profile, { cmd .. " " .. q(join(e.name)) }, function(ok, _, err)
        if not ok then
          UI.notify(cmd .. " failed: " .. err .. (e.type == "dir" and "\n(sftp can only remove empty directories; use `run rm -rf …`)" or ""), vim.log.levels.ERROR)
        end
        refresh()
      end)
    end)
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row < 2 and #entries > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
        elseif row > #entries + 1 and #entries > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { #entries + 1, 0 })
        end
      end,
    })
    refresh()
  end)
end

--- Upload / download with an explicit local path argument.
---@param path string
function M.upload_path(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  M.select(path, function(profile)
    if not profile then
      return
    end
    if is_dir(path) then
      local sub = relative(profile.root, path)
      local files = Compat.tbl_filter(function(rel)
        return sub == nil or rel:sub(1, #sub + 1) == sub .. "/"
      end, M.list_files(profile))
      return M.upload(profile, files, report)
    end
    local rel = relative(profile.root, path)
    if not rel then
      return UI.notify(path .. " is outside " .. profile.root, vim.log.levels.WARN)
    end
    M.upload(profile, { rel }, report, { quiet = true })
  end)
end

--- Write a template config into the current working directory and open it.
function M.init()
  local path = vim.fn.getcwd() .. "/" .. Config.options.sftp.config_file
  if uv.fs_stat(path) then
    return vim.cmd.edit(path)
  end
  local template = {
    "{",
    '  "name": "production",',
    '  "host": "example.com",',
    '  "port": 22,',
    '  "username": "deploy",',
    '  "remotePath": "/var/www/app",',
    '  "privateKeyPath": "~/.ssh/id_ed25519",',
    '  "ignore": [".git", "node_modules", "dist"],',
    '  "uploadOnSave": false',
    "}",
    "",
  }
  local fd = assert(io.open(path, "w"))
  fd:write(table.concat(template, "\n"))
  fd:close()
  vim.cmd.edit(path)
  UI.notify("Created " .. path .. " — add it to .gitignore if it contains secrets")
end

function M.status()
  local list, err = M.profiles(vim.api.nvim_buf_get_name(0))
  if err then
    UI.notify(err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    return UI.notify("No SFTP profiles for this project (:Kaeru sftp init)", vim.log.levels.WARN)
  end
  local lines = {}
  for _, p in ipairs(list) do
    local last = M.last_sync(p)
    lines[#lines + 1] = ("%s  %s@%s:%s  [%s]%s  last sync: %s"):format(
      p.name,
      p.username or "",
      p.host,
      p.remotePath,
      p.source,
      M._last[p.root] == p.name and " (selected)" or "",
      last > 0 and os.date("%Y-%m-%d %H:%M", last) or "never"
    )
  end
  UI.notify(table.concat(lines, "\n"))
end

--- Upload-on-save autocmd (installed by setup()).
function M.setup_autocmd()
  local group = vim.api.nvim_create_augroup("kaeru.sftp", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local file = ev.match
      if file == "" or vim.bo[ev.buf].buftype ~= "" then
        return
      end
      local list = M.profiles(file)
      if #list == 0 then
        return
      end
      local profile = list[1]
      local last = M._last[profile.root]
      if last then
        for _, p in ipairs(list) do
          if p.name == last then
            profile = p
          end
        end
      end
      local on_save = profile.uploadOnSave
      if on_save == nil then
        on_save = Config.options.sftp.upload_on_save
      end
      if not on_save then
        return
      end
      local rel = relative(profile.root, file)
      if rel and not ignored(rel, ignore_patterns(profile)) then
        M.upload(profile, { rel }, function(ok, msg)
          if ok then
            UI.notify("↑ " .. rel .. " → " .. profile.name)
          else
            report(false, msg)
          end
        end, { quiet = true })
      end
    end,
  })
end

--- List entries in a local directory with type, size, permissions, and mtime (for SFTP UI).
---@param dir string
---@return {name: string, type: "dir"|"file"|"link", size: integer, mtime: string, path: string}[]
function M.list_local_dir(dir)
  dir = vim.fn.fnamemodify(vim.fn.expand(dir or "."), ":p"):gsub("/+$", "")
  if dir == "" then
    dir = "/"
  end
  local out = {}
  local handle = uv and uv.fs_scandir and uv.fs_scandir(dir)
  if handle then
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if name ~= "." and name ~= ".." then
        local full = dir .. "/" .. name
        local st = uv.fs_stat(full)
        local entry_type = (st and st.type == "directory") and "dir" or (ftype == "link" and "link" or "file")
        out[#out + 1] = {
          name = name,
          type = entry_type,
          size = st and st.size or 0,
          mtime = st and st.mtime and os.date("%Y-%m-%d %H:%M", st.mtime.sec) or "",
          path = full,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.type == "dir") ~= (b.type == "dir") then
      return a.type == "dir"
    end
    return a.name < b.name
  end)
  return out
end

--- Dual-pane floating SFTP UI (Local Project Explorer <-> Remote SFTP Server Explorer).
---@param profile_name? string
function M.ui(profile_name)
  local file_hint = vim.api.nvim_buf_get_name(0)
  local profiles = M.profiles(file_hint)
  local profile = nil
  if profile_name and profile_name ~= "" then
    for _, p in ipairs(profiles) do
      if p.name == profile_name then
        profile = p
        break
      end
    end
  end
  if not profile then
    profile = profiles[1]
  end
  if not profile then
    local cwd = vim.fn.getcwd()
    profile = {
      name = "unconfigured",
      host = "example.com",
      port = 22,
      username = os.getenv("USER") or "deploy",
      remotePath = "/var/www/app",
      root = cwd,
      source = "unconfigured (press `i` to create sftp.json)",
      uploadOnSave = false,
      _unconfigured = true,
    }
  end

  local total_w = math.min(vim.o.columns - 4, 136)
  local total_h = math.min(vim.o.lines - 4, 34)
  local header_h = 4
  local pane_h = math.max(10, total_h - header_h - 4)
  local left_w = math.floor((total_w - 3) / 2)
  local right_w = total_w - left_w - 3
  local start_row = math.max(1, math.floor((vim.o.lines - total_h) / 2))
  local start_col = math.max(1, math.floor((vim.o.columns - total_w) / 2))

  local header_buf = vim.api.nvim_create_buf(false, true)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)
  for _, b in ipairs({ header_buf, left_buf, right_buf }) do
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].modifiable = false
  end

  local header_win = vim.api.nvim_open_win(header_buf, false, {
    relative = "editor",
    row = start_row,
    col = start_col,
    width = total_w,
    height = header_h,
    style = "minimal",
    border = Config.options.ui.border or "rounded",
    title = " kaeru.nvim · SFTP Studio ",
    title_pos = "center",
  })
  local left_win = vim.api.nvim_open_win(left_buf, true, {
    relative = "editor",
    row = start_row + header_h + 2,
    col = start_col,
    width = left_w,
    height = pane_h,
    style = "minimal",
    border = Config.options.ui.border or "rounded",
    title = " Local Project ",
    title_pos = "left",
  })
  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = "editor",
    row = start_row + header_h + 2,
    col = start_col + left_w + 2,
    width = right_w,
    height = pane_h,
    style = "minimal",
    border = Config.options.ui.border or "rounded",
    title = " Remote Server ",
    title_pos = "left",
  })
  vim.wo[left_win].cursorline = true
  vim.wo[right_win].cursorline = true

  local local_cwd = profile.root or vim.fn.getcwd()
  local remote_cwd = (profile.remotePath or "/"):gsub("/+$", "")
  if remote_cwd == "" then
    remote_cwd = "/"
  end
  local local_entries = {}
  local remote_entries = {}
  local active_pane = "local"
  local status_text = profile._unconfigured and "No sftp.json found — press `i` to initialize" or "Ready"
  local remote_status = "idle"
  local closed = false

  local function close_all()
    if closed then
      return
    end
    closed = true
    for _, w in ipairs({ header_win, left_win, right_win }) do
      if w and vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  local function render_header()
    if closed or not vim.api.nvim_buf_is_valid(header_buf) then
      return
    end
    local last = not profile._unconfigured and M.last_sync(profile) or 0
    local sync_str = last > 0 and os.date("%Y-%m-%d %H:%M", last) or "never"
    local line1 = string.format(
      "  Profile: %s (%s@%s:%s)  →  %s   [last sync: %s]   [%s]",
      profile.name,
      profile.username or "user",
      profile.host or "host",
      tostring(profile.port or 22),
      profile.remotePath or "/",
      sync_str,
      status_text
    )
    local line2 = string.format(
      "  Active Pane: %-7s │ Local: %-34s │ Remote: %s",
      active_pane:upper(),
      vim.fn.fnamemodify(local_cwd, ":~"),
      remote_cwd
    )
    local line3 = "  <Tab> pane  <CR> open  - up  u upload  d download  s sync  D diff  m mkdir  R rename  x del  ! ssh"
    local line4 = "  p switch profile  t test connection  i init/edit sftp.json  r refresh  y yank path  q close"
    UI.set_lines(header_buf, { line1, line2, line3, line4 })
    vim.api.nvim_buf_clear_namespace(header_buf, UI.ns, 0, -1)
    vim.api.nvim_buf_set_extmark(header_buf, UI.ns, 0, 0, { end_col = #line1, hl_group = "Title" })
    vim.api.nvim_buf_set_extmark(header_buf, UI.ns, 1, 0, { end_col = #line2, hl_group = "Identifier" })
    vim.api.nvim_buf_set_extmark(header_buf, UI.ns, 2, 0, { end_col = #line3, hl_group = "Comment" })
    vim.api.nvim_buf_set_extmark(header_buf, UI.ns, 3, 0, { end_col = #line4, hl_group = "Comment" })
  end

  local function render_local()
    if closed or not vim.api.nvim_buf_is_valid(left_buf) then
      return
    end
    local lines = { string.format("  📁 %s (%d items)", vim.fn.fnamemodify(local_cwd, ":~"), #local_entries) }
    for _, e in ipairs(local_entries) do
      local icon = e.type == "dir" and "▸ " or "  "
      local name = e.name .. (e.type == "dir" and "/" or "")
      local size_str = e.type == "dir" and "<DIR>" or tostring(e.size)
      lines[#lines + 1] = string.format("  %s%-30s %8s  %s", icon, name, size_str, e.mtime or "")
    end
    if #local_entries == 0 then
      lines[#lines + 1] = "  (empty directory)"
    end
    UI.set_lines(left_buf, lines)
    vim.api.nvim_buf_clear_namespace(left_buf, UI.ns, 0, -1)
    vim.api.nvim_buf_set_extmark(left_buf, UI.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
    for i, e in ipairs(local_entries) do
      if e.type == "dir" then
        vim.api.nvim_buf_set_extmark(left_buf, UI.ns, i, 0, { end_col = #lines[i + 1], hl_group = "Directory", strict = false })
      end
    end
  end

  local function render_remote()
    if closed or not vim.api.nvim_buf_is_valid(right_buf) then
      return
    end
    local lines = { string.format("  🌐 %s:%s (%s)", profile.host or "remote", remote_cwd, remote_status) }
    if profile._unconfigured then
      lines[#lines + 1] = "  No SFTP profile configured for this workspace."
      lines[#lines + 1] = "  Press `i` to create sftp.json or configure `sftp.profiles` in kaeru.yaml."
    else
      for _, e in ipairs(remote_entries) do
        local icon = e.type == "dir" and "▸ " or (e.type == "link" and "→ " or "  ")
        local name = e.name .. (e.type == "dir" and "/" or "")
        local size_str = e.type == "dir" and "<DIR>" or tostring(e.size or "")
        lines[#lines + 1] = string.format("  %s%-30s %8s  %s", icon, name, size_str, e.mtime or "")
      end
      if #remote_entries == 0 and remote_status == "ready" then
        lines[#lines + 1] = "  (empty remote directory)"
      end
    end
    UI.set_lines(right_buf, lines)
    vim.api.nvim_buf_clear_namespace(right_buf, UI.ns, 0, -1)
    vim.api.nvim_buf_set_extmark(right_buf, UI.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
    for i, e in ipairs(remote_entries) do
      if e.type == "dir" and lines[i + 1] then
        vim.api.nvim_buf_set_extmark(right_buf, UI.ns, i, 0, { end_col = #lines[i + 1], hl_group = "Directory", strict = false })
      end
    end
  end

  local function refresh_local()
    local_entries = M.list_local_dir(local_cwd)
    render_local()
    render_header()
    if vim.api.nvim_win_is_valid(left_win) and #local_entries > 0 then
      local row = vim.api.nvim_win_get_cursor(left_win)[1]
      if row < 2 then
        pcall(vim.api.nvim_win_set_cursor, left_win, { 2, 0 })
      end
    end
  end

  local function refresh_remote()
    if profile._unconfigured then
      remote_entries = {}
      remote_status = "unconfigured"
      render_remote()
      render_header()
      return
    end
    remote_status = "loading…"
    render_remote()
    M.batch(profile, { "ls -la " .. q(remote_cwd) }, function(ok, out, err)
      if closed then
        return
      end
      if not ok then
        remote_entries = {}
        remote_status = "offline: " .. (err ~= "" and err or "connection failed")
        status_text = "Remote unreachable (press `t` to diagnose)"
        render_remote()
        render_header()
        return
      end
      remote_entries = M.parse_ls(out)
      remote_status = string.format("%d items", #remote_entries)
      status_text = "Connected to " .. profile.name
      render_remote()
      render_header()
      if vim.api.nvim_win_is_valid(right_win) and #remote_entries > 0 then
        local row = vim.api.nvim_win_get_cursor(right_win)[1]
        if row < 2 then
          pcall(vim.api.nvim_win_set_cursor, right_win, { 2, 0 })
        end
      end
    end)
  end

  local function current_local()
    if not vim.api.nvim_win_is_valid(left_win) then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(left_win)[1]
    return local_entries[row - 1]
  end

  local function current_remote()
    if not vim.api.nvim_win_is_valid(right_win) then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(right_win)[1]
    return remote_entries[row - 1]
  end

  local function switch_pane()
    if active_pane == "local" then
      active_pane = "remote"
      if vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_set_current_win(right_win)
      end
    else
      active_pane = "local"
      if vim.api.nvim_win_is_valid(left_win) then
        vim.api.nvim_set_current_win(left_win)
      end
    end
    render_header()
  end

  local function bind_common(buf, pane_kind)
    UI.map(buf, "q", close_all)
    UI.map(buf, "<Esc>", close_all)
    UI.map(buf, "<Tab>", switch_pane)
    UI.map(buf, "r", function()
      refresh_local()
      refresh_remote()
    end)
    UI.map(buf, "i", function()
      close_all()
      M.init()
    end)
    UI.map(buf, "t", function()
      M.test()
    end)
    UI.map(buf, "p", function()
      local all = M.profiles(file_hint)
      if #all == 0 then
        return UI.notify("No SFTP profiles configured yet. Press `i` to create sftp.json.", vim.log.levels.WARN)
      end
      vim.ui.select(all, {
        prompt = "Select SFTP Profile",
        format_item = function(item)
          return string.format("%s — %s@%s:%s (%s)", item.name, item.username or "", item.host, item.remotePath, item.source)
        end,
      }, function(chosen)
        if chosen then
          profile = chosen
          M._last[chosen.root] = chosen.name
          local_cwd = chosen.root
          remote_cwd = (chosen.remotePath or "/"):gsub("/+$", "")
          refresh_local()
          refresh_remote()
        end
      end)
    end)
    UI.map(buf, "s", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      status_text = "Syncing modified files…"
      render_header()
      M.sync(false)
      vim.defer_fn(refresh_remote, 600)
    end)
    UI.map(buf, "S", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      status_text = "Syncing all files…"
      render_header()
      M.sync(true)
      vim.defer_fn(refresh_remote, 600)
    end)
    UI.map(buf, "u", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      local entry = current_local()
      if not entry then
        return UI.notify("Select a local file to upload in the left pane", vim.log.levels.WARN)
      end
      local dst = (remote_cwd:gsub("/+$", "")) .. "/" .. entry.name
      status_text = "Uploading " .. entry.name .. " → " .. dst
      render_header()
      local cmd = entry.type == "dir" and ("put -r %s %s"):format(q(entry.path), q(dst)) or ("put -p %s %s"):format(q(entry.path), q(dst))
      M.batch(profile, { cmd }, function(ok, _, err)
        status_text = ok and ("Uploaded " .. entry.name) or ("Upload failed: " .. err)
        UI.notify(status_text, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
        refresh_remote()
      end)
    end)
    UI.map(buf, "d", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      local entry = current_remote()
      if not entry then
        return UI.notify("Select a remote file to download in the right pane", vim.log.levels.WARN)
      end
      local src = (remote_cwd:gsub("/+$", "")) .. "/" .. entry.name
      local dst = (local_cwd:gsub("/+$", "")) .. "/" .. entry.name
      status_text = "Downloading " .. entry.name .. " → " .. dst
      render_header()
      local cmd = entry.type == "dir" and ("get -r %s %s"):format(q(src), q(dst)) or ("get -p %s %s"):format(q(src), q(dst))
      M.batch(profile, { cmd }, function(ok, _, err)
        status_text = ok and ("Downloaded " .. entry.name) or ("Download failed: " .. err)
        UI.notify(status_text, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
        refresh_local()
      end)
    end)
    UI.map(buf, "D", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      local entry = current_local()
      if not entry or entry.type == "dir" then
        return UI.notify("Select a local file to diff against remote", vim.log.levels.WARN)
      end
      local rel = relative(profile.root, entry.path) or entry.name
      local tmp = vim.fn.tempname() .. "_" .. entry.name
      M.batch(profile, { ("get %s %s"):format(q(M.remote_path(profile, rel)), q(tmp)) }, function(ok, _, err)
        if not ok then
          return UI.notify("Could not fetch remote file: " .. err, vim.log.levels.ERROR)
        end
        close_all()
        vim.cmd.edit(vim.fn.fnameescape(entry.path))
        vim.cmd("diffthis")
        vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(tmp))
        vim.bo.readonly = true
        vim.bo.modifiable = false
      end)
    end)
    UI.map(buf, "!", function()
      if profile._unconfigured then
        return UI.notify("Configure an SFTP profile first (`i`)", vim.log.levels.WARN)
      end
      vim.ui.input({ prompt = ("SSH (%s@%s): "):format(profile.username or "", profile.host or "") }, function(cmd)
        if not cmd or Compat.trim(cmd) == "" then
          return
        end
        status_text = "Running SSH: " .. cmd
        render_header()
        M.ssh(profile, cmd, function(ok, out, err)
          status_text = ok and "SSH command finished" or ("SSH error: " .. err)
          render_header()
          UI.notify((out ~= "" and out or err ~= "" and err or "(no output)"), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
          refresh_remote()
        end)
      end)
    end)
    UI.map(buf, "-", function()
      if pane_kind == "local" then
        local parent = vim.fn.fnamemodify(local_cwd, ":h")
        if parent and parent ~= "" then
          local_cwd = parent
          refresh_local()
        end
      else
        remote_cwd = remote_cwd:match("^(.*)/[^/]+/?$") or "/"
        if remote_cwd == "" then
          remote_cwd = "/"
        end
        refresh_remote()
      end
    end)
    UI.map(buf, "<CR>", function()
      if pane_kind == "local" then
        local e = current_local()
        if not e then
          return
        end
        if e.type == "dir" then
          local_cwd = e.path
          refresh_local()
        else
          close_all()
          vim.cmd.edit(vim.fn.fnameescape(e.path))
        end
      else
        local e = current_remote()
        if not e then
          return
        end
        local full_remote = (remote_cwd:gsub("/+$", "")) .. "/" .. e.name
        if e.type == "dir" then
          remote_cwd = full_remote
          refresh_remote()
        else
          local tmp = vim.fn.tempname() .. "_" .. e.name
          M.batch(profile, { ("get %s %s"):format(q(full_remote), q(tmp)) }, function(ok, _, err)
            if not ok then
              return UI.notify("Download failed: " .. err, vim.log.levels.ERROR)
            end
            close_all()
            vim.cmd.edit(vim.fn.fnameescape(tmp))
            vim.b.kaeru_sftp_remote = { profile = profile.name, path = full_remote }
            UI.notify("Opened remote copy of " .. e.name)
          end)
        end
      end
    end)
    UI.map(buf, "m", function()
      vim.ui.input({ prompt = ("New %s directory: "):format(pane_kind) }, function(name)
        if not name or Compat.trim(name) == "" then
          return
        end
        if pane_kind == "local" then
          vim.fn.mkdir(local_cwd .. "/" .. name, "p")
          refresh_local()
        else
          local dst = (remote_cwd:gsub("/+$", "")) .. "/" .. name
          M.batch(profile, { "mkdir " .. q(dst) }, function(ok, _, err)
            if not ok then
              UI.notify("mkdir failed: " .. err, vim.log.levels.ERROR)
            end
            refresh_remote()
          end)
        end
      end)
    end)
    UI.map(buf, "R", function()
      local e = pane_kind == "local" and current_local() or current_remote()
      if not e then
        return
      end
      vim.ui.input({ prompt = "Rename to: ", default = e.name }, function(new_name)
        if not new_name or new_name == "" or new_name == e.name then
          return
        end
        if pane_kind == "local" then
          uv.fs_rename(e.path, local_cwd .. "/" .. new_name)
          refresh_local()
        else
          local src = (remote_cwd:gsub("/+$", "")) .. "/" .. e.name
          local dst = (remote_cwd:gsub("/+$", "")) .. "/" .. new_name
          M.batch(profile, { ("rename %s %s"):format(q(src), q(dst)) }, function(ok, _, err)
            if not ok then
              UI.notify("rename failed: " .. err, vim.log.levels.ERROR)
            end
            refresh_remote()
          end)
        end
      end)
    end)
    UI.map(buf, "x", function()
      local e = pane_kind == "local" and current_local() or current_remote()
      if not e then
        return
      end
      if vim.fn.confirm(("Delete %s (%s)?"):format(e.name, pane_kind), "&Yes\n&No", 2) ~= 1 then
        return
      end
      if pane_kind == "local" then
        vim.fn.delete(e.path, e.type == "dir" and "rf" or "")
        refresh_local()
      else
        local target_path = (remote_cwd:gsub("/+$", "")) .. "/" .. e.name
        local cmd = e.type == "dir" and "rmdir" or "rm"
        M.batch(profile, { cmd .. " " .. q(target_path) }, function(ok, _, err)
          if not ok then
            UI.notify(cmd .. " failed: " .. err, vim.log.levels.ERROR)
          end
          refresh_remote()
        end)
      end
    end)
    UI.map(buf, "y", function()
      local e = pane_kind == "local" and current_local() or current_remote()
      local path = pane_kind == "local" and (e and e.path or local_cwd)
        or (e and ((remote_cwd:gsub("/+$", "")) .. "/" .. e.name) or remote_cwd)
      vim.fn.setreg("+", path)
      vim.fn.setreg('"', path)
      UI.notify("Yanked " .. path)
    end)
  end

  bind_common(left_buf, "local")
  bind_common(right_buf, "remote")

  refresh_local()
  refresh_remote()
end

M._glob_to_pattern = glob_to_pattern
M._ignored = ignored
M._relative = relative

return M
