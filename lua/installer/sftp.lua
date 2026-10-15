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
--     "privateKeyPath": "~/.ssh/id_ed25519",   // optional
--     "password": "…",                         // optional, needs `sshpass`
--     "ignore": [".git", "node_modules"],      // optional, merged with sftp.ignore
--     "uploadOnSave": false                    // optional
--   }
--
-- The file may also be a JSON array of such objects.
local Config = require("installer.config")
local Process = require("installer.process")
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

---@class InstallerSftpProfile
---@field name string
---@field host string
---@field port? integer
---@field username? string
---@field remotePath string
---@field privateKeyPath? string
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

---@param profile InstallerSftpProfile
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

---@param profile InstallerSftpProfile
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
---@return InstallerSftpProfile[]|nil, string? err
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
---@return InstallerSftpProfile[], string? err
function M.profiles(file)
  local start = file and file ~= "" and vim.fn.fnamemodify(file, ":p:h") or vim.fn.getcwd()
  local list, err = {}, nil
  local cfg = find_config(start)
  if cfg then
    local found
    found, err = read_config(cfg)
    vim.list_extend(list, found or {})
  end
  for name, p in pairs(Config.options.sftp.profiles or {}) do
    local prof = vim.deepcopy(p)
    prof.name = prof.name or name
    prof.root = norm(prof.localPath or vim.fn.getcwd())
    prof.source = "global"
    list[#list + 1] = prof
  end
  return list, err
end

--- Pick a profile (asks when several match).
---@param file? string
---@param cb fun(profile: InstallerSftpProfile|nil)
function M.select(file, cb)
  local list, err = M.profiles(file)
  if err then
    UI.notify(err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    UI.notify(
      ("No SFTP profile found. Create %s with :Installer sftp init"):format(Config.options.sftp.config_file),
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

---@param profile InstallerSftpProfile
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
  if profile.port and tonumber(profile.port) and tonumber(profile.port) ~= 22 then
    vim.list_extend(args, { cmd == "ssh" and "-p" or "-P", tostring(profile.port) })
  end
  if profile.privateKeyPath and profile.privateKeyPath ~= "" then
    vim.list_extend(args, { "-i", vim.fn.expand(profile.privateKeyPath) })
  end
  vim.list_extend(args, Config.options.sftp.extra_args or {})
  return args
end

---@param profile InstallerSftpProfile
---@return string
function M.target(profile)
  if profile.username and profile.username ~= "" then
    return profile.username .. "@" .. profile.host
  end
  return profile.host
end

--- Build the contents of an sftp batch file that uploads `rels`.
---@param profile InstallerSftpProfile
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

-- File discovery ---------------------------------------------------------------------

--- List project files relative to the profile root (git-aware, ignore-filtered).
---@param profile InstallerSftpProfile
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

---@class InstallerSftpResult
---@field ok boolean
---@field files integer
---@field err? string

--- Upload `rels` with up to `sftp.concurrency` parallel sftp processes.
---@param profile InstallerSftpProfile
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
---@param profile InstallerSftpProfile
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
      cb(false, "Download failed: " .. vim.trim(res.stderr))
    end
  end)
end

--- Download the whole remote tree into the project root (uses scp -r).
---@param profile InstallerSftpProfile
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
      cb(false, "Download failed: " .. vim.trim(res.stderr))
    end
  end)
end

-- Sync state ----------------------------------------------------------------------------

local function state_file(profile)
  local key = vim.fn.sha256(profile.root .. "|" .. profile.host .. "|" .. profile.remotePath)
  local dir = vim.fn.stdpath("state") .. "/installer/sftp"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. key:sub(1, 16) .. ".json"
end

---@param profile InstallerSftpProfile
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

---@param profile InstallerSftpProfile
---@param t number
function M.set_last_sync(profile, t)
  local fd = io.open(state_file(profile), "w")
  if fd then
    fd:write(vim.json.encode({ synced_at = t, profile = profile.name }))
    fd:close()
  end
end

--- Files changed since the last sync.
---@param profile InstallerSftpProfile
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

local function report(ok, msg)
  UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end

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
    return UI.notify("No SFTP profiles for this project (:Installer sftp init)", vim.log.levels.WARN)
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
  local group = vim.api.nvim_create_augroup("installer.sftp", { clear = true })
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

M._glob_to_pattern = glob_to_pattern
M._ignored = ignored
M._relative = relative

return M
