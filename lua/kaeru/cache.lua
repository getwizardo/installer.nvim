-- Local plugin cache.
--
-- Installed plugins are archived into `cache.dir`:
--   <name>.nvimpack  zip archive of the whole plugin directory (any files and
--                    folders inside it, `.git` included) - default
--   <name>.pack      git bundle (`git bundle create --all`), used when the plugin
--                    directory is larger than `cache.pack_threshold`; a bundle only
--                    stores git objects, so it is far smaller for big repositories
--   index.json       metadata (format, size, commit, url, date)
--
-- `restore` recreates the plugin directory from the archive before lazy.nvim
-- clones it, which makes re-installs fast and possible offline. Falls back to
-- `tar` when `zip`/`unzip` are missing (still saved as .nvimpack).
local Config = require("kaeru.config")
local Process = require("kaeru.process")
local UI = require("kaeru.ui")
local Compat = require("kaeru.compat")

local M = {}

local uv = vim.uv or vim.loop

---@class KaeruCacheEntry
---@field name string
---@field format "zip"|"tar"|"bundle"
---@field file string          file name inside cache.dir
---@field size integer         archive size in bytes
---@field dir_size integer     plugin directory size when packed
---@field url? string
---@field commit? string
---@field created_at integer

---@return string
function M.dir()
  local dir = vim.fn.expand(Config.options.cache.dir)
  vim.fn.mkdir(dir, "p")
  return (dir:gsub("[/\\]+$", ""))
end

local function index_path()
  return M.dir() .. "/index.json"
end

---@return table<string, KaeruCacheEntry>
function M.index()
  local fd = io.open(index_path(), "r")
  if not fd then
    return {}
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  return ok and type(data) == "table" and data or {}
end

---@param index table<string, KaeruCacheEntry>
local function save_index(index)
  local fd = assert(io.open(index_path(), "w"))
  fd:write(vim.json.encode(index))
  fd:close()
end

---@param name string
---@return KaeruCacheEntry|nil
function M.get(name)
  local entry = M.index()[name]
  if entry and uv.fs_stat(M.dir() .. "/" .. entry.file) then
    return entry
  end
  return nil
end

--- Size of a directory tree in bytes (synchronous walk).
---@param path string
---@return integer
function M.dir_size(path)
  local total = 0
  local function walk(p)
    local handle = uv.fs_scandir(p)
    if not handle then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local full = p .. "/" .. name
      if typ == "directory" then
        walk(full)
      elseif typ == "file" then
        local st = uv.fs_stat(full)
        total = total + (st and st.size or 0)
      end
    end
  end
  walk(path)
  return total
end

---@param n integer
---@return string
function M.human(n)
  if n >= 1024 * 1024 * 1024 then
    return string.format("%.1f GiB", n / 1024 / 1024 / 1024)
  elseif n >= 1024 * 1024 then
    return string.format("%.1f MiB", n / 1024 / 1024)
  elseif n >= 1024 then
    return string.format("%.1f KiB", n / 1024)
  end
  return n .. " B"
end

---@param name string
---@return table|nil plugin lazy.nvim plugin object
local function lazy_plugin(name)
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if not ok or not LazyConfig.plugins then
    return nil
  end
  return LazyConfig.plugins[name]
end

---@param name string
---@return string|nil dir, string|nil url
function M.plugin_dir(name)
  local plugin = lazy_plugin(name)
  if plugin and plugin.dir then
    return plugin.dir, plugin.url
  end
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  local root = ok and LazyConfig.options and LazyConfig.options.root or (vim.fn.stdpath("data") .. "/lazy")
  local dir = root .. "/" .. name
  if uv.fs_stat(dir) then
    return dir, nil
  end
  return nil, nil
end

---@param dir string
---@param cb fun(commit: string|nil)
local function head_commit(dir, cb)
  Process.run({ "git", "-C", dir, "rev-parse", "HEAD" }, function(res)
    cb(res.code == 0 and Compat.trim(res.stdout) or nil)
  end)
end

--- Archive one plugin.
---@param name string
---@param cb? fun(ok: boolean, msg: string)
---@param opts? {force?: boolean}
function M.pack(name, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local dir, url = M.plugin_dir(name)
  if not dir then
    return cb(false, name .. " is not installed")
  end
  local existing = M.get(name)
  local dir_size = M.dir_size(dir)
  local has_git = uv.fs_stat(dir .. "/.git") ~= nil
  local use_bundle = has_git and dir_size > (Config.options.cache.pack_threshold or math.huge)

  head_commit(dir, function(commit)
    if existing and not opts.force and existing.commit and existing.commit == commit then
      return cb(true, ("%s is already cached at %s"):format(name, commit:sub(1, 7)))
    end
    local cache_dir = M.dir()
    local file, args, format
    if use_bundle then
      format = "bundle"
      file = name .. ".pack"
      args = { "git", "-C", dir, "bundle", "create", cache_dir .. "/" .. file, "--all" }
    elseif vim.fn.executable("zip") == 1 then
      format = "zip"
      file = name .. ".nvimpack"
      os.remove(cache_dir .. "/" .. file)
      args = { "zip", "-q", "-r", "-y", cache_dir .. "/" .. file, "." }
    else
      format = "tar"
      file = name .. ".nvimpack"
      args = { "tar", "-czf", cache_dir .. "/" .. file, "-C", dir, "." }
    end
    local run_opts = format == "zip" and { cwd = dir } or {}
    Process.run(args, run_opts, function(res)
      if res.code ~= 0 then
        return cb(false, ("packing %s failed: %s"):format(name, Compat.trim(res.stderr)))
      end
      local st = uv.fs_stat(cache_dir .. "/" .. file)
      local index = M.index()
      -- drop an older archive in the other format
      if existing and existing.file ~= file then
        os.remove(cache_dir .. "/" .. existing.file)
      end
      index[name] = {
        name = name,
        format = format,
        file = file,
        size = st and st.size or 0,
        dir_size = dir_size,
        url = url,
        commit = commit,
        created_at = os.time(),
      }
      save_index(index)
      cb(true, ("Cached %s as %s (%s, %s)"):format(name, file, format, M.human(st and st.size or 0)))
    end)
  end)
end

--- Archive every installed plugin (2 at a time).
---@param cb? fun(ok: integer, failed: string[])
function M.pack_all(cb)
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if not ok or not LazyConfig.plugins then
    UI.notify("lazy.nvim is not loaded", vim.log.levels.ERROR)
    return cb and cb(0, {})
  end
  local tasks = {}
  for name, plugin in pairs(LazyConfig.plugins) do
    if plugin._ and plugin._.installed and name ~= "lazy.nvim" then
      tasks[#tasks + 1] = function(done)
        M.pack(name, function(pok, msg)
          done({ ok = pok, msg = msg, name = name })
        end)
      end
    end
  end
  UI.notify(("Caching %d plugin(s)…"):format(#tasks))
  Process.pool(tasks, 2, function(results)
    local good, failed = 0, {}
    for _, r in ipairs(results) do
      if r.ok then
        good = good + 1
      else
        failed[#failed + 1] = r.msg
      end
    end
    UI.notify(
      ("Cached %d plugin(s) in %s%s"):format(good, M.dir(), #failed > 0 and ("\nFailed:\n" .. table.concat(failed, "\n")) or ""),
      #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    )
    if cb then
      cb(good, failed)
    end
  end)
end

--- Recreate a plugin directory from the cache.
---@param name string
---@param cb? fun(ok: boolean, msg: string)
---@param opts? {force?: boolean}
function M.restore(name, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local entry = M.get(name)
  if not entry then
    return cb(false, name .. " is not in the cache")
  end
  local dir = M.plugin_dir(name)
  local okc, LazyConfig = pcall(require, "lazy.core.config")
  local root = okc and LazyConfig.options and LazyConfig.options.root or (vim.fn.stdpath("data") .. "/lazy")
  dir = dir or (root .. "/" .. name)
  if uv.fs_stat(dir) then
    if not opts.force then
      return cb(true, name .. " is already installed")
    end
    vim.fn.delete(dir, "rf")
  end
  local archive = M.dir() .. "/" .. entry.file
  local args, run_opts
  if entry.format == "bundle" then
    args = { "git", "clone", "--quiet", archive, dir }
  else
    vim.fn.mkdir(dir, "p")
    run_opts = { cwd = dir }
    local fd = io.open(archive, "rb")
    local magic = fd and fd:read(2) or ""
    if fd then
      fd:close()
    end
    if magic == "PK" then
      if vim.fn.executable("unzip") ~= 1 then
        return cb(false, "`unzip` is required to restore " .. entry.file)
      end
      args = { "unzip", "-q", "-o", archive, "-d", dir }
    else
      args = { "tar", "-xzf", archive, "-C", dir }
    end
  end
  Process.run(args, run_opts or {}, function(res)
    if res.code ~= 0 then
      vim.fn.delete(dir, "rf")
      return cb(false, ("restoring %s failed: %s"):format(name, Compat.trim(res.stderr)))
    end
    local function finish()
      cb(true, ("Restored %s from %s (%s)"):format(name, entry.file, entry.format))
    end
    if entry.format == "bundle" and entry.url then
      -- point origin back at the real repository so lazy.nvim can update it
      Process.run({ "git", "-C", dir, "remote", "set-url", "origin", entry.url }, function()
        finish()
      end)
    else
      finish()
    end
  end)
end

--- Remove one archive.
---@param name string
function M.remove(name)
  local index = M.index()
  local entry = index[name]
  if not entry then
    return UI.notify(name .. " is not in the cache", vim.log.levels.WARN)
  end
  os.remove(M.dir() .. "/" .. entry.file)
  index[name] = nil
  save_index(index)
  UI.notify("Removed " .. entry.file)
end

--- Drop archives of plugins that are no longer part of the lazy.nvim spec.
function M.clean()
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  local index = M.index()
  local removed = {}
  for name, entry in pairs(index) do
    local keep = ok and LazyConfig.plugins and LazyConfig.plugins[name] ~= nil
    if not keep then
      os.remove(M.dir() .. "/" .. entry.file)
      index[name] = nil
      removed[#removed + 1] = name
    end
  end
  save_index(index)
  UI.notify(#removed > 0 and ("Removed %d archive(s): %s"):format(#removed, table.concat(removed, ", ")) or "Cache is clean")
end

--- Floating list of cached plugins.
function M.list()
  local index = M.index()
  local names = vim.tbl_keys(index)
  table.sort(names)
  local lines = { ("  %s"):format(M.dir()) }
  local total = 0
  for _, name in ipairs(names) do
    local e = index[name]
    total = total + (e.size or 0)
    lines[#lines + 1] = string.format(
      "  %-32s %-7s %10s  %-8s %s",
      name,
      e.format,
      M.human(e.size or 0),
      e.commit and e.commit:sub(1, 7) or "-",
      os.date("%Y-%m-%d %H:%M", e.created_at or 0)
    )
  end
  if #names == 0 then
    lines[#lines + 1] = "  (empty)  run :Kaeru cache pack all"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("  %d archive(s), %s   <CR> restore  p re-pack  D remove  q close"):format(#names, M.human(total))
  local buf, win = UI.open({
    title = "kaeru.nvim · plugin cache",
    width = math.min(vim.o.columns - 4, 96),
    height = math.min(#lines, vim.o.lines - 6),
  })
  UI.set_lines(buf, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].cursorline = true
  vim.api.nvim_buf_set_extmark(buf, UI.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  vim.api.nvim_buf_set_extmark(buf, UI.ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "Comment" })
  local function current()
    return names[vim.api.nvim_win_get_cursor(win)[1] - 1]
  end
  local function close()
    UI.close(win)
  end
  UI.map(buf, "q", close)
  UI.map(buf, "<Esc>", close)
  UI.map(buf, "<CR>", function()
    local name = current()
    if name then
      close()
      M.restore(name, function(ok, msg)
        UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      end, { force = true })
    end
  end)
  UI.map(buf, "p", function()
    local name = current()
    if name then
      close()
      M.pack(name, function(ok, msg)
        UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      end, { force = true })
    end
  end)
  UI.map(buf, "D", function()
    local name = current()
    if name then
      close()
      M.remove(name)
    end
  end)
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
end

return M
