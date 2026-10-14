-- installer.nvim - add plugins to a lazy.nvim config from inside Neovim.
--
--   :Installer                 open the modal form
--   :Installer browse [query]  browse Neovim plugins on GitHub
--   :Installer add owner/repo  write a bare spec and install right away
local Config = require("installer.config")
local Spec = require("installer.spec")
local Lazy = require("installer.lazy")
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

---@param opts? InstallerOptions
function M.setup(opts)
  Config.setup(opts)
end

--- Open the modal form. `values` prefill fields (e.g. `{ repo = "folke/noice.nvim" }`).
---@param values? InstallerForm
function M.open(values)
  require("installer.form").open({
    values = values,
    on_submit = function(form)
      return M.add(form)
    end,
  })
end

--- Open the GitHub browser.
---@param opts? InstallerBrowserOpts
function M.browse(opts)
  require("installer.browser").open(opts)
end

--- Search GitHub and pick a plugin with `vim.ui.select` (works with any picker UI).
---@param query? string
function M.search(query)
  local GitHub = require("installer.github")
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
  return uv.fs_stat(path) ~= nil
end

--- Write a spec file and (optionally) let lazy.nvim install the plugin.
---@param form InstallerForm
---@param opts? {after_write?: "install"|"edit"|"none", force?: boolean}
---@return boolean ok, string? path
function M.add(form, opts)
  opts = opts or {}
  local generated, err = Spec.generate(form, { header = Config.options.header })
  if not generated then
    UI.notify(err or "invalid spec", vim.log.levels.ERROR)
    return false
  end

  local existing = Lazy.find_plugin(generated.name) or (generated.short and Lazy.find_plugin(generated.short))
  if existing and not opts.force then
    local choice = vim.fn.confirm(
      ("%s is already in your lazy.nvim config (%s).\nWrite a new spec file anyway?"):format(
        generated.short or generated.name,
        existing.name
      ),
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return false
    end
  end

  local dir, source = Lazy.plugins_dir()
  if not exists(dir) then
    local okdir = pcall(vim.fn.mkdir, dir, "p")
    if not okdir then
      UI.notify("Could not create " .. dir, vim.log.levels.ERROR)
      return false
    end
  end

  local path = dir .. "/" .. generated.file .. ".lua"
  if exists(path) and Config.options.confirm_overwrite and not opts.force then
    local choice = vim.fn.confirm(path .. " already exists.", "&Overwrite\n&Rename\n&Cancel", 3)
    if choice == 3 or choice == 0 then
      return false
    elseif choice == 2 then
      local new = vim.fn.input("File name: ", generated.file)
      if new == "" then
        return false
      end
      form = vim.deepcopy(form)
      form.file = new
      return M.add(form, opts)
    end
  end

  local fd, open_err = io.open(path, "w")
  if not fd then
    UI.notify("Could not write " .. path .. ": " .. tostring(open_err), vim.log.levels.ERROR)
    return false
  end
  fd:write(generated.source)
  fd:close()

  local rel = vim.fn.fnamemodify(path, ":~")
  local after = opts.after_write or Config.options.after_write

  if source == "default" and not Lazy.available() then
    UI.notify(
      ("Wrote %s\nlazy.nvim is not loaded: make sure your setup imports the `plugins` module."):format(rel),
      vim.log.levels.WARN
    )
    if after == "edit" then
      vim.cmd.edit(path)
    end
    return true, path
  end

  if after == "install" then
    local ok, ierr = Lazy.install(generated.name)
    if ok then
      UI.notify(("Wrote %s\nInstalling %s with lazy.nvim…"):format(rel, generated.short or generated.name))
    else
      UI.notify(("Wrote %s\n%s"):format(rel, ierr), vim.log.levels.WARN)
    end
  elseif after == "edit" then
    vim.cmd.edit(path)
  else
    UI.notify("Wrote " .. rel)
  end
  return true, path
end

--- Preview the Lua source the form would generate (no file is written).
---@param form InstallerForm
---@return string|nil source, string? err
function M.preview(form)
  local generated, err = Spec.generate(form, { header = Config.options.header })
  if not generated then
    return nil, err
  end
  return generated.source
end

--- Directory where spec files are written (resolved the same way `add()` does).
---@return string
function M.plugins_dir()
  return (Lazy.plugins_dir())
end

return M
