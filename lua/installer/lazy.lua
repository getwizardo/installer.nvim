-- Integration with lazy.nvim (https://github.com/folke/lazy.nvim).
--
-- lazy.nvim discovers specs through `{ import = "<module>" }` entries: every
-- `lua/<module>/*.lua` file on the runtimepath is merged into the final spec.
-- Writing a new file into that directory and calling
-- `require("lazy.core.plugin").load()` is enough for lazy.nvim to pick it up;
-- `require("lazy").install()` then clones it.
local Config = require("installer.config")

local M = {}

local uv = vim.uv or vim.loop

---@return boolean
function M.available()
  return package.loaded["lazy"] ~= nil or pcall(require, "lazy.core.config")
end

---@param path string
---@return boolean
local function is_dir(path)
  if not uv or not uv.fs_stat then
    return vim.fn.isdirectory(path) == 1
  end
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

--- Return the list of spec modules lazy.nvim imports (e.g. `{ "plugins" }`).
---@return string[]
function M.spec_modules()
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if not ok or not LazyConfig.spec then
    return {}
  end
  local mods = {}
  for _, mod in ipairs(LazyConfig.spec.modules or {}) do
    -- skip modules that come from installed plugins (LazyVim extras etc.)
    if type(mod) == "string" and not mod:match("^lazyvim%.") then
      mods[#mods + 1] = mod
    end
  end
  return mods
end

--- Clear cached Lua modules for a plugin spec file so lazy.nvim reloads updated files from disk.
---@param file? string
function M.invalidate_spec_cache(file)
  local mods = M.spec_modules()
  local seen = {}
  for _, m in ipairs(mods) do
    seen[m] = true
  end
  if not seen["plugins"] then
    mods[#mods + 1] = "plugins"
  end

  for _, mod in ipairs(mods) do
    package.loaded[mod] = nil
    if file and file ~= "" then
      local clean = file:gsub("%.lua$", "")
      package.loaded[mod .. "." .. clean] = nil
      package.loaded[mod .. "/" .. clean] = nil
    end
  end
end

--- Resolve the directory where new spec files should be written.
---@param explicit? string
---@return string dir, string source  -- source: "config" | "lazy" | "default"
function M.plugins_dir(explicit)
  local opt = explicit or Config.options.plugins_dir
  if type(opt) == "function" then
    opt = opt()
  end
  if type(opt) == "string" and opt ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(opt), ":p"):gsub("/$", ""), "config"
  end

  local config_lua = vim.fn.stdpath("config") .. "/lua"
  for _, mod in ipairs(M.spec_modules()) do
    local rel = mod:gsub("%.", "/")
    -- prefer the user's own config dir
    local candidate = config_lua .. "/" .. rel
    if is_dir(candidate) then
      return candidate, "lazy"
    end
    -- `lua/plugins.lua` exists but `lua/plugins/` does not: lazy.nvim merges
    -- both, so creating the directory next to it works too.
    if uv and uv.fs_stat and uv.fs_stat(candidate .. ".lua") then
      return candidate, "lazy"
    end
    -- otherwise ask lazy where the module actually lives (other rtp paths)
    local ok, Util = pcall(require, "lazy.core.util")
    if ok and Util.find_root then
      local root = Util.find_root(mod)
      if root and is_dir(root) then
        return root, "lazy"
      end
    end
  end

  return config_lua .. "/plugins", "default"
end

--- Whether a plugin with this name is already part of the lazy spec.
---@param name string
---@return table|nil plugin
function M.find_plugin(name)
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if not ok or not LazyConfig.plugins then
    return nil
  end
  if LazyConfig.plugins[name] then
    return LazyConfig.plugins[name]
  end
  -- match by short url as well (`owner/repo`)
  for _, plugin in pairs(LazyConfig.plugins) do
    if plugin[1] == name or (plugin.url and plugin.url:find(name, 1, true)) then
      return plugin
    end
  end
  return nil
end

--- Reload lazy.nvim specs so a freshly written file is known, then install.
---@param name string plugin name (as lazy.nvim derives it)
---@param on_done? fun(plugin: table|nil) called when the install runner finishes
---@param file? string optional spec filename to invalidate in package.loaded
---@return boolean ok, string? err
function M.install(name, on_done, file)
  if not M.available() then
    return false, "lazy.nvim is not loaded; restart Neovim to install the plugin"
  end
  M.invalidate_spec_cache(file)
  local ok, err = pcall(function()
    require("lazy.core.plugin").load()
  end)
  if not ok then
    return false, "failed to reload lazy.nvim specs: " .. tostring(err)
  end

  local LazyConfig = require("lazy.core.config")
  local plugin = LazyConfig.plugins[name] or M.find_plugin(name)
  local target_name = (plugin and plugin.name) or name
  ok, err = pcall(function()
    local runner
    if plugin then
      runner = require("lazy").install({ plugins = { target_name }, show = true })
    else
      -- name derivation differs (e.g. custom url) - install everything missing
      runner = require("lazy").install({ show = true })
    end
    -- Plugins that are not lazy-loaded would normally be loaded at startup;
    -- load them now so the user can use them right away (like lazy does for
    -- missing plugins installed during startup).
    if type(runner) == "table" and runner.wait then
      runner:wait(function()
        vim.schedule(function()
          local p = LazyConfig.plugins[target_name] or M.find_plugin(name)
          if p and p._ and p._.installed and not p._.loaded and p.lazy == false then
            pcall(require("lazy.core.loader").load, p, { cmd = "Installer" })
          end
          if on_done then
            on_done(p)
          end
        end)
      end)
    elseif on_done then
      vim.schedule(function()
        on_done(LazyConfig.plugins[target_name] or M.find_plugin(name))
      end)
    end
  end)
  if not ok then
    return false, "lazy.nvim install failed: " .. tostring(err)
  end
  return true
end

return M
