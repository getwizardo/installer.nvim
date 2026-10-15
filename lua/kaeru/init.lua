-- kaeru.nvim - add plugins to a lazy.nvim config from inside Neovim.
--
--   :Kaeru                 open the modal form
--   :Kaeru browse [query]  browse Neovim plugins on GitHub
--   :Kaeru add owner/repo  write a bare spec and install right away
--   :Kaeru save owner/repo write a spec file without running :Lazy install
--   :Kaeru parse [target]  parse any installer snippet / README.md into a spec
--   :Kaeru ai              curated AI coding plugins & Clina AI Coding IDE
--   :Kaeru login|whoami    GitHub account
--   :Kaeru sftp [action]   SFTP UI / upload / download / sync over SFTP
--   :Kaeru starsky         SvelteKit Starsky webclient
--   :Clina [action]            TypeScript AI Coding IDE for Neovim
local Config = require("kaeru.config")
local Spec = require("kaeru.spec")
local Lazy = require("kaeru.lazy")
local UI = require("kaeru.ui")

local M = {}

local uv = vim.uv or vim.loop

M._setup_done = false

---@param opts? KaeruOptions
function M.setup(opts)
  Config.setup(opts)
  M._setup_done = true
  require("kaeru.sftp").setup_autocmd()
  pcall(function()
    require("kaeru.complete").setup_cmdline()
  end)
  require("kaeru.kikru").ensure()
  if Config.options.mason and Config.options.mason.auto_ensure then
    vim.schedule(function()
      local mason = require("kaeru.mason")
      if mason.available() then
        mason.ensure()
      end
    end)
  end
end

--- Make sure configuration files were loaded even when setup() was never called.
function M.ensure_setup()
  if not M._setup_done then
    M.setup()
  end
end

--- Re-read kaeru.yaml files.
function M.reload()
  Config.reload()
  require("kaeru.sftp").setup_autocmd()
  local files = {}
  for _, f in ipairs(Config.loaded_files) do
    files[#files + 1] = ("%s: %s%s"):format(f.kind, vim.fn.fnamemodify(f.path, ":~"), f.err and (" (" .. f.err .. ")") or "")
  end
  UI.notify("Configuration reloaded" .. (#files > 0 and ("\n" .. table.concat(files, "\n")) or "\n(no kaeru.yaml found)"))
end

--- Lazily loaded sub-modules.
M.account = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.account")[k]
  end,
})
M.ai = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.ai")[k]
  end,
})
M.clina = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.clina")[k]
  end,
})
M.kikru = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.kikru")[k]
  end,
})
-- `require("kaeru").music` is the pre-2.0 name of the player façade.
M.music = M.kikru
M.boot = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.boot")[k]
  end,
})
M.sftp = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.sftp")[k]
  end,
})
M.cache = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.cache")[k]
  end,
})
M.mason = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.mason")[k]
  end,
})
M.parser = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.parser")[k]
  end,
})
M.complete = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.complete")[k]
  end,
})
M.starsky = setmetatable({}, {
  __index = function(_, k)
    return require("kaeru.starsky")[k]
  end,
})
M.config = Config

--- Open the modal form. `values` prefill fields (e.g. `{ repo = "folke/noice.nvim" }`).
---@param values? KaeruForm|string
function M.open(values)
  M.ensure_setup()
  if type(values) == "string" and values ~= "" then
    values = { repo = values }
  end
  require("kaeru.form").open({
    values = values,
    on_submit = function(form, action_opts)
      return M.add(form, action_opts)
    end,
  })
end

--- Open the GitHub browser.
---@param opts? KaeruBrowserOpts
function M.browse(opts)
  M.ensure_setup()
  require("kaeru.browser").open(opts)
end

--- Search GitHub and pick a plugin with `vim.ui.select` (works with any picker UI).
---@param query? string
function M.search(query)
  M.ensure_setup()
  local GitHub = require("kaeru.github")
  UI.notify("Searching GitHub for " .. (query and query ~= "" and ("%q"):format(query) or "Neovim plugins") .. "…")
  GitHub.search({ query = query, per_page = 50 }, function(err, result)
    if err then
      return UI.notify(err, vim.log.levels.ERROR)
    end
    if #result.items == 0 then
      return UI.notify("No plugins found", vim.log.levels.WARN)
    end
    vim.ui.select(result.items, {
      prompt = "Neovim plugins on GitHub",
      format_item = function(item)
        return string.format("%6s  %-34s %s", GitHub.format_stars(item.stars), item.full_name, item.description)
      end,
    }, function(item)
      if item then
        M.open({ repo = item.full_name })
      end
    end)
  end)
end

---@param path string
---@return boolean
local function exists(path)
  if uv and uv.fs_stat then
    return uv.fs_stat(path) ~= nil
  end
  return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

---@return boolean
local function is_interactive()
  return vim and vim.fn and vim.fn.confirm and vim.api and vim.api.nvim_list_uis and #vim.api.nvim_list_uis() > 0
end

--- Write a spec file without running `:Lazy install` (saves only).
---@param form KaeruForm
---@param opts? {force?: boolean, overwrite?: boolean}
---@return boolean ok, string? path, table? generated
function M.save(form, opts)
  opts = vim.tbl_extend("force", opts or {}, { after_write = "none" })
  return M.add(form, opts)
end

--- Write a spec file and (optionally) let lazy.nvim install the plugin.
---@param form KaeruForm
---@param opts? {after_write?: "install"|"edit"|"none", force?: boolean, overwrite?: boolean}
---@return boolean ok, string? path, table? generated
function M.add(form, opts)
  M.ensure_setup()
  opts = opts or {}
  local force = opts.force or opts.overwrite
  local generated, err = Spec.generate(form, { header = Config.options.header })
  if not generated then
    UI.notify(err or "invalid spec", vim.log.levels.ERROR)
    return false, err
  end

  local existing = Lazy.find_plugin(generated.name) or (generated.short and Lazy.find_plugin(generated.short))
  if existing and not force and is_interactive() then
    local ok_c, choice = pcall(
      vim.fn.confirm,
      ("%s is already in your lazy.nvim config (%s).\nWrite a new spec file anyway?"):format(
        generated.short or generated.name,
        existing.name or generated.name
      ),
      "&Yes\n&No",
      2
    )
    if ok_c and choice ~= 1 then
      return false, "cancelled"
    end
  end

  local dir, source = Lazy.plugins_dir()
  if not exists(dir) then
    local okdir, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
    if not okdir or not exists(dir) then
      local msg = "Could not create " .. dir .. (mkdir_err and (": " .. tostring(mkdir_err)) or "")
      UI.notify(msg, vim.log.levels.ERROR)
      return false, msg
    end
  end

  local path = dir .. "/" .. generated.file .. ".lua"
  if exists(path) and Config.options.confirm_overwrite and not force and is_interactive() then
    local ok_c, choice = pcall(vim.fn.confirm, path .. " already exists.", "&Overwrite\n&Rename\n&Cancel", 3)
    if ok_c then
      if choice == 3 or choice == 0 then
        return false, "cancelled"
      elseif choice == 2 then
        local new = vim.fn.input("File name: ", generated.file)
        if new == "" then
          return false, "cancelled"
        end
        form = vim.deepcopy(form)
        form.file = new
        return M.add(form, opts)
      end
    end
  end

  local fd, open_err = io.open(path, "w")
  if not fd then
    local msg = "Could not write " .. path .. ": " .. tostring(open_err)
    UI.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end
  local ok_write, write_err = fd:write(generated.source)
  if not ok_write then
    fd:close()
    local msg = "Failed writing " .. path .. ": " .. tostring(write_err)
    UI.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end
  fd:flush()
  fd:close()

  -- Invalidate Lua require cache for this spec file so subsequent reloads see the latest content
  Lazy.invalidate_spec_cache(generated.file)

  local rel = vim.fn.fnamemodify(path, ":~")
  local after = opts.after_write or Config.options.after_write

  if not Lazy.available() then
    if after == "install" then
      UI.notify(
        ("Wrote %s\nlazy.nvim is not loaded: make sure your setup imports the `%s` module."):format(
          rel,
          source == "default" and "plugins" or source:gsub("^lazy:", "")
        ),
        vim.log.levels.INFO
      )
    elseif after == "edit" then
      UI.notify("Wrote " .. rel)
      vim.cmd.edit(path)
    else
      UI.notify("Wrote " .. rel)
    end
    return true, path, generated
  end

  if after == "install" then
    local cache_opts = Config.options.cache or {}
    local function install(restored)
      local ok, ierr = Lazy.install(generated.name, function(plugin)
        if cache_opts.enabled and cache_opts.auto_pack and plugin and plugin._ and plugin._.installed then
          require("kaeru.cache").pack(generated.name, function(pok, pmsg)
            if not pok then
              UI.notify(pmsg, vim.log.levels.WARN)
            end
          end)
        end
      end, generated.file)
      if ok then
        UI.notify(
          ("Wrote %s\n%s%s with lazy.nvim…"):format(
            rel,
            restored and "Restored from cache, finishing " or "Installing ",
            generated.short or generated.name
          )
        )
      else
        UI.notify(("Wrote %s\n%s"):format(rel, tostring(ierr)), vim.log.levels.WARN)
      end
    end
    local Cache = require("kaeru.cache")
    if cache_opts.enabled and cache_opts.auto_restore and Cache.get(generated.name) and not Cache.plugin_dir(generated.name) then
      Cache.restore(generated.name, function(rok, rmsg)
        if not rok then
          UI.notify(rmsg, vim.log.levels.WARN)
        end
        install(rok)
      end)
    else
      install(false)
    end
  elseif after == "edit" then
    UI.notify("Wrote " .. rel)
    vim.cmd.edit(path)
  else
    UI.notify("Wrote " .. rel)
  end
  return true, path, generated
end

--- Preview the Lua source the form would generate (no file is written).
---@param form KaeruForm
---@return string|nil source, string? err, table? generated
function M.preview(form)
  M.ensure_setup()
  local generated, err = Spec.generate(form, { header = Config.options.header })
  if not generated then
    return nil, err
  end
  return generated.source, nil, generated
end

--- Parse any plugin manager snippet or README markdown into `KaeruForm` tables
--- and lazy.nvim specs (deduplicated, best guess first).
---@param text string
---@param opts? {repo?: string}
---@return table[] results, string? err
function M.parse(text, opts)
  return require("kaeru.parser").parse_all(text, opts)
end

--- Directory where spec files are written (resolved the same way `add()` does).
---@return string dir, string source
function M.plugins_dir()
  M.ensure_setup()
  return Lazy.plugins_dir()
end

return M
