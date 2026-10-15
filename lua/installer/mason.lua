-- mason.nvim integration: install LSP servers, DAP adapters, linters, formatters,
-- compilers and runtimes from the Mason registry.
--
-- Uses only `mason-registry` (https://github.com/mason-org/mason.nvim):
--   registry.get_all_package_specs()  -> name, description, categories, languages,
--                                        homepage, deprecation, neovim.lspconfig
--   registry.get_package(name):install(opts, cb) / :uninstall()
--   registry.refresh(cb) / registry.update(cb)
local Config = require("installer.config")
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

M.categories = { "LSP", "DAP", "Linter", "Formatter", "Compiler", "Runtime" }

M.REGISTRY_WEB_URL = "https://mason-registry.dev"
M.REGISTRY_LIST_URL = "https://mason-registry.dev/registry/list"

--- Return the official https://mason-registry.dev URL for a Mason package (or the registry list).
---@param name? string
---@return string
function M.package_url(name)
  if name and name ~= "" then
    return M.REGISTRY_LIST_URL .. "#/" .. name
  end
  return M.REGISTRY_LIST_URL
end

--- Open https://mason-registry.dev in the system browser (or for a specific package).
---@param name? string
---@return string url
function M.open_registry(name)
  local url = M.package_url(name)
  if vim and vim.ui and vim.ui.open then
    vim.ui.open(url)
  end
  UI.notify("Opened " .. url)
  return url
end

---@class InstallerMasonPackage
---@field name string
---@field description string
---@field categories string[]
---@field languages string[]
---@field homepage string
---@field installed boolean
---@field deprecated string|nil
---@field lspconfig string|nil
---@field aliases string[]

---@return boolean
function M.available()
  return pcall(require, "mason-registry")
end

--- Offer to install mason.nvim when it is missing.
local function missing()
  local choice = vim.fn.confirm(
    "mason.nvim is not installed.\nAdd mason.nvim (+ mason-lspconfig, nvim-lspconfig) to your lazy.nvim config now?",
    "&Yes\n&No",
    1
  )
  if choice == 1 then
    M.scaffold("lsp")
  end
end

--- Make sure the registry is loaded (refreshes it once per session).
---@param cb fun(ok: boolean)
function M.ensure_registry(cb)
  if not M.available() then
    missing()
    return cb(false)
  end
  local registry = require("mason-registry")
  if M._refreshed or not Config.options.mason.refresh_registry then
    return cb(true)
  end
  registry.refresh(function(ok)
    M._refreshed = true
    vim.schedule(function()
      if not ok then
        UI.notify("Could not refresh the Mason registry (offline?) - using cached data", vim.log.levels.WARN)
      end
      cb(true)
    end)
  end)
end

---@param spec table
---@param has_reg boolean
---@param registry? table
---@return InstallerMasonPackage
local function to_pkg(spec, has_reg, registry)
  return {
    name = spec.name,
    description = (spec.description or ""):gsub("%s+", " "),
    categories = spec.categories or {},
    languages = spec.languages or {},
    homepage = spec.homepage or "",
    installed = has_reg and registry.is_installed(spec.name) or false,
    deprecated = spec.deprecated or (spec.deprecation and (spec.deprecation.message or spec.deprecation.since)) or nil,
    lspconfig = spec.lspconfig or vim.tbl_get(spec, "neovim", "lspconfig"),
    aliases = (has_reg and registry.get_package_aliases and registry.get_package_aliases(spec.name)) or {},
  }
end

--- Return raw package specs from `mason-registry` when loaded, or from `installer.mason_data`.
---@return table[] specs, boolean has_reg, table? registry
local function raw_specs()
  local ok, registry = pcall(require, "mason-registry")
  if ok and registry and registry.get_all_package_specs then
    local ok_s, specs = pcall(registry.get_all_package_specs)
    if ok_s and type(specs) == "table" and #specs > 0 then
      return specs, true, registry
    end
  end
  local ok_d, data = pcall(require, "installer.mason_data")
  if ok_d and data and data.packages then
    return data.packages, false, nil
  end
  return {}, false, nil
end

--- All packages (optionally filtered).
---@param opts? {category?: string, query?: string, installed?: boolean, language?: string}
---@return InstallerMasonPackage[]
function M.packages(opts)
  opts = opts or {}
  local specs, has_reg, registry = raw_specs()
  local out = {}
  local q = opts.query and opts.query:lower() or ""
  local lang = opts.language and opts.language:lower() or nil
  for _, spec in ipairs(specs) do
    local p = to_pkg(spec, has_reg, registry)
    local keep = true
    if opts.category and not vim.tbl_contains(p.categories, opts.category) then
      keep = false
    end
    if keep and opts.installed and not p.installed then
      keep = false
    end
    if keep and lang then
      keep = false
      for _, l in ipairs(p.languages) do
        if l:lower() == lang then
          keep = true
        end
      end
    end
    if keep and q ~= "" then
      local hay = (p.name .. " " .. (p.lspconfig or "") .. " " .. table.concat(p.languages, " ") .. " " .. p.description):lower()
      for word in q:gmatch("%S+") do
        if not hay:find(word, 1, true) then
          keep = false
          break
        end
      end
    end
    if keep then
      out[#out + 1] = p
    end
  end
  table.sort(out, function(a, b)
    if a.installed ~= b.installed then
      return a.installed
    end
    return a.name < b.name
  end)
  return out
end

-- filetype -> Mason language name
M.ft_languages = {
  sh = "Bash",
  bash = "Bash",
  zsh = "Bash",
  cpp = "C++",
  c = "C",
  cs = "C#",
  javascriptreact = "JavaScript",
  typescriptreact = "TypeScript",
  jsx = "JavaScript",
  tsx = "TypeScript",
  py = "Python",
  rs = "Rust",
  rb = "Ruby",
  kt = "Kotlin",
  objc = "Objective-C",
  tex = "LaTeX",
  plaintex = "LaTeX",
  dockerfile = "Docker",
  md = "Markdown",
  ps1 = "PowerShell",
  yml = "YAML",
  yaml = "YAML",
  json = "JSON",
  jsonc = "JSON",
  toml = "TOML",
  html = "HTML",
  css = "CSS",
  scss = "SCSS",
  less = "Less",
  vue = "Vue",
  svelte = "Svelte",
  sql = "SQL",
  php = "PHP",
  go = "Go",
  gomod = "Go",
  lua = "Lua",
  vim = "VimScript",
  java = "Java",
  scala = "Scala",
  elixir = "Elixir",
  erlang = "Erlang",
  haskell = "Haskell",
  ocaml = "OCaml",
  nix = "Nix",
  zig = "Zig",
  dart = "Dart",
  swift = "Swift",
  terraform = "Terraform",
  hcl = "Terraform",
  proto = "Protobuf",
  graphql = "GraphQL",
  xml = "XML",
  make = "Makefile",
  cmake = "CMake",
  r = "R",
  julia = "Julia",
  perl = "Perl",
  nim = "Nim",
  clojure = "Clojure",
  fennel = "Fennel",
  elm = "Elm",
  fsharp = "F#",
  gleam = "Gleam",
  groovy = "Groovy",
  helm = "Helm",
  astro = "Astro",
  prisma = "Prisma",
  solidity = "Solidity",
  typst = "Typst",
  asm = "Assembly",
  ada = "Ada",
  crystal = "Crystal",
  d = "D",
  v = "V",
  vala = "Vala",
}

---@param ft? string
---@return string|nil
function M.language_for(ft)
  ft = ft or (vim.bo and vim.bo.filetype)
  if not ft or ft == "" then
    return nil
  end
  if M.ft_languages[ft] then
    return M.ft_languages[ft]
  end
  -- Title-case the filetype and look for a registry language with that name
  local specs = raw_specs()
  local wanted = ft:lower()
  for _, spec in ipairs(specs) do
    for _, l in ipairs(spec.languages or {}) do
      if l:lower() == wanted then
        return l
      end
    end
  end
  return nil
end

-- Install / uninstall -----------------------------------------------------------------

---@param name string
---@param cb? fun(ok: boolean, msg: string)
function M.install(name, cb)
  cb = cb or function(ok, msg)
    UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
  M.ensure_registry(function(ready)
    if not ready then
      return
    end
    local registry = require("mason-registry")
    if not registry.has_package(name) then
      -- maybe an lspconfig name (e.g. "lua_ls" -> "lua-language-server") or an alias
      local resolved = M.resolve(name)
      if not resolved then
        return cb(false, ("Mason has no package named %q"):format(name))
      end
      name = resolved
    end
    local pkg = registry.get_package(name)
    if pkg:is_installed() then
      return cb(true, name .. " is already installed (use `update` to reinstall)")
    end
    UI.notify("Mason: installing " .. name .. "…")
    local ok, err = pcall(function()
      pkg:install({}, function(success, result)
        vim.schedule(function()
          if success then
            cb(true, "Mason: installed " .. name)
            if Config.options.mason.open_ui_on_install then
              pcall(vim.cmd, "Mason")
            end
          else
            cb(false, ("Mason: failed to install %s: %s"):format(name, tostring(result)))
          end
        end)
      end)
    end)
    if not ok then
      cb(false, ("Mason: %s"):format(tostring(err)))
    end
  end)
end

---@param name string
---@param cb? fun(ok: boolean, msg: string)
function M.uninstall(name, cb)
  cb = cb or function(ok, msg)
    UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
  if not M.available() then
    return missing()
  end
  local registry = require("mason-registry")
  name = M.resolve(name) or name
  if not registry.has_package(name) then
    return cb(false, ("Mason has no package named %q"):format(name))
  end
  local pkg = registry.get_package(name)
  if not pkg:is_installed() then
    return cb(true, name .. " is not installed")
  end
  local done = false
  local function finish(success, uerr)
    if done then
      return
    end
    done = true
    cb(success == true, success and ("Mason: uninstalled " .. name) or ("Mason: failed to uninstall " .. name .. ": " .. tostring(uerr)))
  end
  local ok, err = pcall(function()
    -- mason 2.x: async with callback; mason 1.x: synchronous, no callback
    pkg:uninstall({}, function(success, uerr)
      vim.schedule(function()
        finish(success, uerr)
      end)
    end)
  end)
  if not ok then
    return finish(false, err)
  end
  if not pkg:is_installed() then
    finish(true)
  end
end

--- Reinstall a package (mason has no in-place update).
---@param name string
function M.update(name)
  M.uninstall(name, function(ok, msg)
    if not ok then
      return UI.notify(msg, vim.log.levels.ERROR)
    end
    M.install(name)
  end)
end

--- Translate an lspconfig server name or alias into a Mason package name.
---@param name string
---@return string|nil
function M.resolve(name)
  local specs, has_reg, registry = raw_specs()
  if has_reg and registry.has_package(name) then
    return name
  end
  for _, spec in ipairs(specs) do
    if spec.name == name then
      return spec.name
    end
    local lspc = spec.lspconfig or vim.tbl_get(spec, "neovim", "lspconfig")
    if lspc == name then
      return spec.name
    end
    local aliases = (has_reg and registry.get_package_aliases and registry.get_package_aliases(spec.name)) or {}
    if vim.tbl_contains(aliases, name) then
      return spec.name
    end
  end
  return nil
end

--- Install several packages, `concurrency` at a time.
---@param names string[]
---@param cb? fun(installed: integer, failed: string[])
function M.install_many(names, cb)
  local Process = require("installer.process")
  local tasks = {}
  for _, name in ipairs(names) do
    tasks[#tasks + 1] = function(done)
      M.install(name, function(ok, msg)
        done({ ok = ok, msg = msg, name = name })
      end)
    end
  end
  Process.pool(tasks, Config.options.mason.concurrency or 2, function(results)
    local good, failed = 0, {}
    for _, r in ipairs(results) do
      if r.ok then
        good = good + 1
      else
        failed[#failed + 1] = r.msg
      end
    end
    UI.notify(
      ("Mason: %d/%d package(s) ready%s"):format(good, #names, #failed > 0 and ("\n" .. table.concat(failed, "\n")) or ""),
      #failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    )
    if cb then
      cb(good, failed)
    end
  end)
end

--- Install everything listed in `mason.ensure_installed` (installer.yaml / setup).
function M.ensure()
  local list = Config.options.mason.ensure_installed or {}
  if #list == 0 then
    return UI.notify("mason.ensure_installed is empty (installer.yaml / setup)", vim.log.levels.WARN)
  end
  M.ensure_registry(function(ready)
    if not ready then
      return
    end
    local registry = require("mason-registry")
    local todo = {}
    for _, name in ipairs(list) do
      local resolved = M.resolve(name)
      if not resolved then
        UI.notify(("ensure_installed: unknown package %q"):format(name), vim.log.levels.WARN)
      elseif not registry.is_installed(resolved) then
        todo[#todo + 1] = resolved
      end
    end
    if #todo == 0 then
      return UI.notify("Mason: everything in ensure_installed is installed")
    end
    M.install_many(todo)
  end)
end

--- Write the installed package names into the global installer.yaml (`mason.ensure_installed`).
function M.export()
  if not M.available() then
    return missing()
  end
  local registry = require("mason-registry")
  local names = registry.get_installed_package_names()
  table.sort(names)
  local Yaml = require("installer.yaml")
  local path = Config.options.config.global
  local data = {}
  if uv.fs_stat(path) then
    data = Config.read_yaml(path, true) or {}
  end
  data.mason = data.mason or {}
  data.mason.ensure_installed = names
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(Yaml.encode(data))
  fd:close()
  Config.reload()
  UI.notify(("Wrote %d package(s) to %s (mason.ensure_installed)"):format(#names, vim.fn.fnamemodify(path, ":~")))
end

--- Update the registry and reinstall packages that have a newer version.
function M.upgrade()
  if not M.available() then
    return missing()
  end
  local registry = require("mason-registry")
  UI.notify("Mason: updating registry…")
  registry.update(function(ok, err)
    vim.schedule(function()
      if not ok then
        return UI.notify("Mason registry update failed: " .. tostring(err), vim.log.levels.ERROR)
      end
      M._refreshed = true
      local outdated = {}
      local pending = 0
      local pkgs = registry.get_installed_packages()
      if #pkgs == 0 then
        return UI.notify("Mason: registry updated, nothing installed")
      end
      for _, pkg in ipairs(pkgs) do
        if pkg.get_latest_version and pkg.get_installed_version then
          pending = pending + 1
          -- mason >= 2: async getters
          local function check()
            local ok_inst, installed = pcall(pkg.get_installed_version, pkg)
            local ok_latest, latest = pcall(pkg.get_latest_version, pkg)
            if ok_inst and ok_latest and installed and latest and installed ~= latest then
              outdated[#outdated + 1] = pkg.name
            end
            pending = pending - 1
            if pending == 0 then
              if #outdated == 0 then
                UI.notify("Mason: registry updated, all packages are up to date")
              else
                UI.notify(("Mason: reinstalling %d outdated package(s): %s"):format(#outdated, table.concat(outdated, ", ")))
                for _, name in ipairs(outdated) do
                  M.update(name)
                end
              end
            end
          end
          vim.schedule(check)
        end
      end
      if pending == 0 then
        UI.notify("Mason: registry updated. Use :Installer mason update <name> to reinstall a package")
      end
    end)
  end)
end

-- Scaffolding --------------------------------------------------------------------------

local SCAFFOLDS = {
  lsp = {
    file = "mason",
    title = "mason.nvim + mason-lspconfig + nvim-lspconfig",
    source = function(installed)
      local servers = {}
      for _, p in ipairs(installed) do
        if p.lspconfig and vim.tbl_contains(p.categories, "LSP") then
          servers[#servers + 1] = ("      %q,"):format(p.lspconfig)
        end
      end
      return table.concat({
        "return {",
        "  {",
        '    "mason-org/mason.nvim",',
        '    cmd = { "Mason", "MasonInstall", "MasonUpdate" },',
        '    build = ":MasonUpdate",',
        "    opts = {},",
        "  },",
        "  {",
        '    "mason-org/mason-lspconfig.nvim",',
        '    event = { "BufReadPre", "BufNewFile" },',
        '    dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig" },',
        "    opts = {",
        "      -- servers installed through installer.nvim / :Mason",
        "      ensure_installed = {",
        table.concat(servers, "\n"),
        "      },",
        "      -- mason-lspconfig >= 2 enables installed servers via vim.lsp.enable()",
        "      automatic_enable = true,",
        "    },",
        "  },",
        "}",
        "",
      }, "\n")
    end,
  },
  dap = {
    file = "dap",
    title = "nvim-dap + mason-nvim-dap + nvim-dap-ui",
    source = function(installed)
      local adapters = {}
      for _, p in ipairs(installed) do
        if vim.tbl_contains(p.categories, "DAP") then
          adapters[#adapters + 1] = ("      %q,"):format(p.name)
        end
      end
      return table.concat({
        "return {",
        "  {",
        '    "mfussenegger/nvim-dap",',
        "    dependencies = {",
        '      { "rcarriga/nvim-dap-ui", dependencies = { "nvim-neotest/nvim-nio" }, opts = {} },',
        "      {",
        '        "jay-babu/mason-nvim-dap.nvim",',
        '        dependencies = { "mason-org/mason.nvim" },',
        "        opts = {",
        "          ensure_installed = {",
        table.concat(adapters, "\n"),
        "          },",
        "          handlers = {}, -- default setup for every adapter",
        "        },",
        "      },",
        "    },",
        "    keys = {",
        '      { "<F5>", function() require("dap").continue() end, desc = "DAP Continue" },',
        '      { "<F10>", function() require("dap").step_over() end, desc = "DAP Step Over" },',
        '      { "<F11>", function() require("dap").step_into() end, desc = "DAP Step Into" },',
        '      { "<leader>db", function() require("dap").toggle_breakpoint() end, desc = "DAP Breakpoint" },',
        '      { "<leader>du", function() require("dapui").toggle() end, desc = "DAP UI" },',
        "    },",
        "    config = function()",
        '      local dap, dapui = require("dap"), require("dapui")',
        "      dap.listeners.after.event_initialized.dapui_config = function() dapui.open() end",
        "      dap.listeners.before.event_terminated.dapui_config = function() dapui.close() end",
        "    end,",
        "  },",
        "}",
        "",
      }, "\n")
    end,
  },
  tools = {
    file = "tools",
    title = "conform.nvim + nvim-lint + mason-tool-installer",
    source = function(installed)
      local tools = {}
      for _, p in ipairs(installed) do
        if vim.tbl_contains(p.categories, "Linter") or vim.tbl_contains(p.categories, "Formatter") then
          tools[#tools + 1] = ("      %q,"):format(p.name)
        end
      end
      return table.concat({
        "return {",
        "  {",
        '    "WhoIsSethDaniel/mason-tool-installer.nvim",',
        '    dependencies = { "mason-org/mason.nvim" },',
        '    event = "VeryLazy",',
        "    opts = {",
        "      ensure_installed = {",
        table.concat(tools, "\n"),
        "      },",
        "    },",
        "  },",
        "  {",
        '    "stevearc/conform.nvim",',
        '    event = "BufWritePre",',
        '    cmd = "ConformInfo",',
        "    opts = {",
        "      -- map filetypes to the formatters you installed, e.g.",
        '      -- formatters_by_ft = { lua = { "stylua" }, python = { "ruff_format" } },',
        "      formatters_by_ft = {},",
        "      format_on_save = { timeout_ms = 1000, lsp_format = \"fallback\" },",
        "    },",
        "  },",
        "  {",
        '    "mfussenegger/nvim-lint",',
        '    event = { "BufReadPost", "BufWritePost" },',
        "    config = function()",
        '      local lint = require("lint")',
        '      -- lint.linters_by_ft = { python = { "ruff" }, sh = { "shellcheck" } }',
        '      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {',
        "        callback = function() lint.try_lint() end,",
        "      })",
        "    end,",
        "  },",
        "}",
        "",
      }, "\n")
    end,
  },
}

--- Write a lazy.nvim spec file wiring Mason into LSP / DAP / tools and install it.
---@param kind "lsp"|"dap"|"tools"
function M.scaffold(kind)
  local def = SCAFFOLDS[kind or "lsp"]
  if not def then
    return UI.notify("Usage: :Installer mason scaffold lsp|dap|tools", vim.log.levels.WARN)
  end
  local installed = {}
  if M.available() then
    installed = M.packages({ installed = true })
  end
  local Lazy = require("installer.lazy")
  local dir = Lazy.plugins_dir()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. def.file .. ".lua"
  if uv.fs_stat(path) and vim.fn.confirm(path .. " exists. Overwrite?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  local fd = assert(io.open(path, "w"))
  if Config.options.header then
    fd:write("-- Generated by installer.nvim (:Installer mason scaffold " .. kind .. ")\n")
  end
  fd:write(def.source(installed))
  fd:close()
  UI.notify(("Wrote %s (%s)"):format(vim.fn.fnamemodify(path, ":~"), def.title))
  if Lazy.available() then
    local ok, err = pcall(function()
      require("lazy.core.plugin").load()
      require("lazy").install({ show = true })
    end)
    if not ok then
      UI.notify("lazy.nvim install failed: " .. tostring(err), vim.log.levels.WARN)
    end
  else
    vim.cmd.edit(path)
  end
end

-- Picker UI ------------------------------------------------------------------------------

local CAT_ICON = { LSP = "LSP", DAP = "DAP", Linter = "LNT", Formatter = "FMT", Compiler = "CMP", Runtime = "RUN" }

---@class InstallerMasonPickerOpts
---@field query? string
---@field category? string
---@field language? string
---@field installed?

--- Floating package picker (`:Installer mason`).
---@param opts? InstallerMasonPickerOpts
function M.pick(opts)
  opts = opts or {}
  M.ensure_registry(function(ready)
    if not ready then
      return
    end
    local state = {
      query = opts.query or "",
      category = opts.category,
      language = opts.language,
      installed = opts.installed or false,
      marked = {},
      items = {},
      origin_ft = vim.bo.filetype, -- filetype of the buffer the picker was opened from
    }

    local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
    local width = math.min(cols - 4, 110)
    local height = math.max(12, math.min(UI.size(Config.options.ui.height, lines), lines - 4))
    local row, col = math.floor((lines - height) / 2), math.floor((cols - width) / 2)

    local list_buf, list_win = UI.open({
      title = "Mason · LSP / DAP / linters / formatters",
      width = width,
      height = height - 3,
      row = row + 3,
      col = col,
      filetype = "installer-mason",
      enter = false,
    })
    vim.wo[list_win].cursorline = true
    vim.bo[list_buf].modifiable = false
    local prompt_buf, prompt_win = UI.open({ title = "Filter", width = width, height = 1, row = row, col = col })
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { state.query })

    local closing = false
    local function close()
      if closing then
        return
      end
      closing = true
      vim.cmd("stopinsert")
      UI.close(prompt_win)
      UI.close(list_win)
    end
    local function valid()
      return not closing and vim.api.nvim_win_is_valid(list_win) and vim.api.nvim_win_is_valid(prompt_win)
    end

    local function render()
      if not valid() then
        return
      end
      state.items = M.packages({
        query = state.query,
        category = state.category,
        language = state.language,
        installed = state.installed,
      })
      local marked = vim.tbl_count(state.marked)
      local out = {
        ("  %d packages · category: %s · language: %s · %s%s"):format(
          #state.items,
          state.category or "all",
          state.language or "all",
          state.installed and "installed only" or "all",
          marked > 0 and (" · " .. marked .. " marked") or ""
        ),
      }
      local w = vim.api.nvim_win_get_width(list_win)
      for _, p in ipairs(state.items) do
        local cats = {}
        for _, c in ipairs(p.categories) do
          cats[#cats + 1] = CAT_ICON[c] or c
        end
        local line = string.format(
          " %s%s %-34s %-11s %s",
          state.marked[p.name] and "*" or " ",
          p.installed and "●" or " ",
          p.name .. (p.lspconfig and p.lspconfig ~= p.name and (" (" .. p.lspconfig .. ")") or ""),
          table.concat(cats, ","),
          (p.deprecated and "[deprecated] " or "") .. p.description
        )
        if vim.fn.strdisplaywidth(line) > w then
          line = vim.fn.strcharpart(line, 0, w - 1) .. "…"
        end
        out[#out + 1] = line
      end
      if #state.items == 0 then
        out[#out + 1] = "  nothing matches"
      end
      UI.set_lines(list_buf, out)
      vim.api.nvim_buf_clear_namespace(list_buf, UI.ns, 0, -1)
      vim.api.nvim_buf_set_extmark(list_buf, UI.ns, 0, 0, { end_col = #out[1], hl_group = "Comment" })
      for i, p in ipairs(state.items) do
        if p.installed then
          vim.api.nvim_buf_set_extmark(list_buf, UI.ns, i, 2, { end_col = 2 + #"●", hl_group = "DiagnosticOk", strict = false })
        end
        if state.marked[p.name] then
          vim.api.nvim_buf_set_extmark(list_buf, UI.ns, i, 1, { end_col = 2, hl_group = "Special", strict = false })
        end
        vim.api.nvim_buf_set_extmark(list_buf, UI.ns, i, 6, { end_col = 6 + #p.name, hl_group = "Title", strict = false })
        vim.api.nvim_buf_set_extmark(list_buf, UI.ns, i, 41, { end_col = 52, hl_group = "Type", strict = false })
        if p.deprecated then
          vim.api.nvim_buf_set_extmark(list_buf, UI.ns, i, 53, { end_col = 53 + #"[deprecated]", hl_group = "WarningMsg", strict = false })
        end
      end
      local cur = vim.api.nvim_win_get_cursor(list_win)[1]
      pcall(vim.api.nvim_win_set_cursor, list_win, { math.max(2, math.min(cur, #out)), 0 })
    end

    local function current()
      return state.items[vim.api.nvim_win_get_cursor(list_win)[1] - 1]
    end
    local function targets()
      local names = vim.tbl_keys(state.marked)
      if #names > 0 then
        table.sort(names)
        return names
      end
      local p = current()
      return p and { p.name } or {}
    end
    local function after(ok, msg)
      UI.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      if valid() then
        render()
      end
    end

    local function focus_prompt()
      vim.api.nvim_set_current_win(prompt_win)
      vim.cmd("startinsert!")
    end
    local function focus_list()
      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(list_win)
    end
    local function move(delta)
      local r = vim.api.nvim_win_get_cursor(list_win)[1] + delta
      pcall(vim.api.nvim_win_set_cursor, list_win, { math.max(2, math.min(r, #state.items + 1)), 0 })
    end

    -- prompt keys
    for _, lhs in ipairs({ "<CR>", "<Tab>", "<Down>" }) do
      UI.map(prompt_buf, lhs, focus_list, { "i", "n" })
    end
    UI.map(prompt_buf, "<C-n>", function()
      move(1)
    end, { "i", "n" })
    UI.map(prompt_buf, "<C-p>", function()
      move(-1)
    end, { "i", "n" })
    UI.map(prompt_buf, "<Esc>", close, "n")
    UI.map(prompt_buf, "q", close, "n")
    UI.map(prompt_buf, "<C-c>", close, { "i", "n" })

    -- list keys
    local lmap = function(lhs, fn, desc)
      UI.map(list_buf, lhs, fn, "n", desc)
    end
    lmap("q", close)
    lmap("<Esc>", close)
    lmap("/", focus_prompt)
    lmap("<Tab>", focus_prompt)
    lmap("<CR>", function()
      local names = targets()
      state.marked = {}
      if #names == 1 then
        M.install(names[1], after)
      elseif #names > 1 then
        M.install_many(names, function()
          if valid() then
            render()
          end
        end)
      end
    end, "Install")
    lmap("i", function()
      local names = targets()
      state.marked = {}
      if #names == 1 then
        M.install(names[1], after)
      elseif #names > 1 then
        M.install_many(names, function()
          if valid() then
            render()
          end
        end)
      end
    end, "Install")
    lmap("x", function()
      for _, name in ipairs(targets()) do
        M.uninstall(name, after)
      end
      state.marked = {}
    end, "Uninstall")
    lmap("u", function()
      local p = current()
      if p then
        M.update(p.name)
      end
    end, "Reinstall / update")
    lmap("<Space>", function()
      local p = current()
      if p then
        state.marked[p.name] = not state.marked[p.name] or nil
        render()
        move(1)
      end
    end, "Mark")
    lmap("f", function()
      local idx = 0
      for i, c in ipairs(M.categories) do
        if c == state.category then
          idx = i
        end
      end
      state.category = M.categories[idx + 1] -- nil after the last one = all
      render()
    end, "Cycle category")
    lmap("l", function()
      if state.language then
        state.language = nil
      else
        state.language = M.language_for(state.origin_ft)
        if not state.language then
          UI.notify("No Mason language known for filetype " .. tostring(state.origin_ft), vim.log.levels.WARN)
        end
      end
      render()
    end, "Toggle current filetype")
    lmap("t", function()
      state.installed = not state.installed
      render()
    end, "Toggle installed only")
    lmap("K", function()
      local p = current()
      if not p then
        return
      end
      local registry = require("mason-registry")
      local pkg = registry.get_package(p.name)
      local path = pkg:is_installed() and pkg:get_install_path() or "-"
      UI.notify(table.concat({
        p.name .. (p.installed and "  (installed)" or ""),
        p.description,
        "categories: " .. table.concat(p.categories, ", "),
        "languages:  " .. table.concat(p.languages, ", "),
        p.lspconfig and ("lspconfig:  " .. p.lspconfig) or nil,
        #p.aliases > 0 and ("aliases:    " .. table.concat(p.aliases, ", ")) or nil,
        "homepage:   " .. p.homepage,
        "path:       " .. path,
        p.deprecated and ("DEPRECATED: " .. p.deprecated) or nil,
      }, "\n"))
    end, "Details")
    lmap("o", function()
      local p = current()
      if p and p.homepage ~= "" and vim.ui.open then
        vim.ui.open(p.homepage)
      end
    end, "Open homepage")
    lmap("y", function()
      local p = current()
      if p then
        vim.fn.setreg("+", p.name)
        vim.fn.setreg('"', p.name)
        UI.notify("Yanked " .. p.name)
      end
    end, "Yank name")
    lmap("U", function()
      M._refreshed = false
      UI.notify("Mason: refreshing registry…")
      M.ensure_registry(function()
        if valid() then
          render()
        end
      end)
    end, "Refresh registry")
    lmap("M", function()
      close()
      pcall(vim.cmd, "Mason")
    end, "Open :Mason")
    lmap("?", function()
      UI.notify(table.concat({
        "Mason picker keys:",
        "  <CR> / i   install (marked packages or the current one)",
        "  x          uninstall        u   reinstall / update",
        "  <Space>    mark / unmark    f   cycle category (LSP, DAP, Linter, …)",
        "  l          only packages for the current filetype",
        "  t          installed only   K   details    o  homepage    y  yank",
        "  U          refresh registry M   open :Mason    / <Tab>  filter prompt",
      }, "\n"))
    end, "Help")

    local group = vim.api.nvim_create_augroup("installer.mason", { clear = true })
    local timer
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
      group = group,
      buffer = prompt_buf,
      callback = function()
        local plines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
        if #plines > 1 then
          vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { table.concat(plines, " ") })
        end
        if timer then
          timer:stop()
        else
          timer = assert(uv.new_timer())
        end
        timer:start(120, 0, function()
          vim.schedule(function()
            if valid() then
              state.query = vim.trim(vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or "")
              render()
            end
          end)
        end)
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = { tostring(prompt_win), tostring(list_win) },
      callback = function()
        vim.schedule(close)
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = list_buf,
      callback = function()
        if valid() and vim.api.nvim_win_get_cursor(list_win)[1] < 2 and #state.items > 0 then
          pcall(vim.api.nvim_win_set_cursor, list_win, { 2, 0 })
        end
      end,
    })

    render()
    if state.query == "" then
      focus_prompt()
    else
      focus_list()
    end
  end)
end

--- Packages for the current buffer's filetype.
function M.for_filetype()
  local lang = M.language_for(vim.bo.filetype)
  if not lang then
    return UI.notify("No Mason language known for filetype " .. tostring(vim.bo.filetype), vim.log.levels.WARN)
  end
  M.pick({ language = lang })
end

--- Installed packages as a notification.
function M.list()
  if not M.available() then
    return missing()
  end
  local pkgs = M.packages({ installed = true })
  if #pkgs == 0 then
    return UI.notify("Mason: nothing installed")
  end
  local lines = {}
  for _, p in ipairs(pkgs) do
    lines[#lines + 1] = ("%-30s %s"):format(p.name, table.concat(p.categories, ","))
  end
  UI.notify(("Mason: %d installed\n%s"):format(#pkgs, table.concat(lines, "\n")))
end

return M
