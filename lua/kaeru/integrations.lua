-- kaeru.nvim — integrations with the rest of the Neovim ecosystem.
--
-- kaeru.nvim stays dependency-free: every module here degrades gracefully, so
-- the plugin works with nothing but Neovim itself and then *uses* whatever it
-- finds. The integrations are:
--
--   pickers      telescope.nvim · fzf-lua · snacks.nvim · mini.pick ·
--                fzf (binary) · vim.ui.select        → `:Kaeru pick <what>`
--   completion   nvim-cmp · blink.cmp                (see kaeru.complete)
--   statusline   lualine.nvim · heirline · plain     → current track / queue
--   notify       nvim-notify · fidget.nvim · builtin
--   jobs         plenary.nvim · luv · vim.fn.system
--   themes       the active colorscheme picks the Kikru UI theme
--   binaries     yt-dlp · mpv · ffmpeg/ffplay · vlc · mpc · playerctl · curl ·
--                gh · fzf · deno/bun/node · …
--
-- `:Kaeru integrations` prints what was detected, `:Kaeru pick …` opens a
-- picker in whatever plugin you actually use.
local Compat = require("kaeru.compat")

local M = {}

--- `pcall(require, …)` that returns nil instead of raising.
---@param name string
---@return table|nil module
function M.try(name)
  local ok, module = pcall(require, name)
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

---@param name string
---@return boolean
function M.has(name)
  return M.try(name) ~= nil
end

---@param bin string
---@return boolean
function M.bin_available(bin)
  return Compat.executable(bin)
end

-- External binaries ---------------------------------------------------------------

--- Everything kaeru.nvim can drive from the outside, grouped by purpose.
---@type table<string, string[]>
M.binaries = {
  audio = { "mpv", "ffplay", "vlc", "cvlc", "mpc", "playerctl", "pactl", "pulseaudio" },
  media = { "yt-dlp", "youtube-dl", "ffmpeg", "ffprobe", "sox", "chafa" },
  network = { "curl", "wget", "git", "ssh", "sftp", "scp", "rsync", "socat" },
  github = { "gh", "git" },
  runtimes = { "node", "deno", "bun", "python3", "luajit" },
  misc = { "fzf", "rg", "fd", "open", "xdg-open", "xdg-mime" },
}

---@return table<string, table<string, boolean>>
function M.binaries_report()
  local report = {}
  for group, names in pairs(M.binaries) do
    report[group] = {}
    for _, name in ipairs(names) do
      report[group][name] = M.bin_available(name)
    end
  end
  return report
end

-- Pickers -------------------------------------------------------------------------

--- Which pickers are available, best first.
---@return {id: string, name: string, fn: fun(items: table, opts: table, on_choice: fun(item: table|nil))}[]
function M.pickers()
  local list = {}

  list[#list + 1] = {
    id = "snacks",
    name = "snacks.nvim picker",
    fn = function(items, opts, on_choice)
      local snacks = require("snacks")
      snacks.picker.pick({
        title = opts.title,
        items = items,
        format_item = function(item)
          return (item.label or item.word or tostring(item)) .. (item.menu and ("  " .. item.menu) or "")
        end,
        confirm = function(picker, item)
          picker:close()
          on_choice(item)
        end,
      })
    end,
  }

  list[#list + 1] = {
    id = "fzf_lua",
    name = "fzf-lua",
    fn = function(items, opts, on_choice)
      local fzf = require("fzf-lua")
      fzf.fzf_exec(items, {
        prompt = (opts.title or "kaeru") .. "> ",
        actions = {
          ["default"] = function(selected)
            local entry = selected and selected[1]
            if not entry then
              return on_choice(nil)
            end
            on_choice(entry)
          end,
        },
      })
    end,
  }

  list[#list + 1] = {
    id = "telescope",
    name = "telescope.nvim",
    fn = function(items, opts, on_choice)
      require("kaeru.integrations.telescope").picker(items, opts, on_choice)
    end,
  }

  list[#list + 1] = {
    id = "mini_pick",
    name = "mini.pick",
    fn = function(items, opts, on_choice)
      local pick = require("mini.pick")
      local choices = {}
      pick.start({
        source = {
          name = opts.title or "kaeru",
          items = items,
          choose = function(item)
            on_choice(item)
          end,
        },
      })
      return choices
    end,
  }

  list[#list + 1] = {
    id = "select",
    name = "vim.ui.select",
    fn = function(items, opts, on_choice)
      vim.ui.select(items, {
        prompt = opts.title,
        format_item = function(item)
          return (item.label or item.word or tostring(item)) .. (item.menu and ("  " .. item.menu) or "")
        end,
      }, on_choice)
    end,
  }

  return list
end

---@return {id: string, name: string}|nil
--- Is a picker plugin actually installed *and* loaded?
---@param id string
---@return boolean
function M.picker_available(id)
  if id == "select" then
    return true
  elseif id == "snacks" then
    local snacks = M.try("snacks")
    return snacks ~= nil and snacks.picker ~= nil
  elseif id == "fzf_lua" then
    return M.has("fzf-lua")
  elseif id == "telescope" then
    return M.has("telescope")
  elseif id == "mini_pick" then
    return M.has("mini.pick")
  end
  return false
end

--- The picker `:Kaeru pick` will use: explicit config wins, then availability.
---@return {id: string, name: string}
function M.best_picker()
  local ok, Config = pcall(require, "kaeru.config")
  local preferred = ok and Compat.tbl_get(Config.options, "ui", "picker") or nil
  if preferred and M.picker_available(preferred) then
    for _, picker in ipairs(M.pickers()) do
      if picker.id == preferred then
        return picker
      end
    end
  end
  for _, picker in ipairs(M.pickers()) do
    if picker.id ~= "select" and M.picker_available(picker.id) then
      return picker
    end
  end
  return { id = "select", name = "vim.ui.select" }
end

--- Open a picker for `items` using whichever plugin is installed.
---@param items table[]
---@param opts {title: string, picker?: string, on_choice?: fun(item: table|nil)}
---@return string picker_id
function M.pick(items, opts)
  opts = opts or { title = "kaeru" }
  local pickers = M.pickers()
  local choice = opts.picker and opts.picker or M.best_picker().id
  for _, picker in ipairs(pickers) do
    if picker.id == choice then
      local ok, err = pcall(picker.fn, items, opts, opts.on_choice or function() end)
      if not ok then
        Compat.notify(("kaeru.nvim · picker %s failed (%s), falling back"):format(picker.id, tostring(err)), vim.log.levels.WARN)
      else
        return picker.id
      end
    end
  end
  -- last resort
  local callback = opts.on_choice or function() end
  if vim.ui and vim.ui.select then
    vim.ui.select(items, { prompt = opts.title }, callback)
  else
    callback(items[1])
  end
  return "select"
end

-- nvim-cmp / blink.cmp -------------------------------------------------------------

---@return table|nil
function M.cmp()
  local cmp = M.try("cmp")
  if not cmp then
    return nil
  end
  local ok = pcall(cmp.register_source, "kaeru", require("kaeru.complete").cmp_source())
  return ok and cmp or nil
end

---@return table|nil
function M.blink()
  local blink = M.try("blink.cmp")
  if not blink then
    return nil
  end
  return blink
end

-- Statusline ------------------------------------------------------------------------

--- Compact "▶ track — artist" or the queue summary, for any statusline.
---@param opts? {width?: integer, icon?: boolean}
---@return string
function M.statusline(opts)
  opts = opts or {}
  local ok, kikru = pcall(require, "kaeru.kikru")
  if not ok then
    return ""
  end
  local icon = opts.icon == false and "" or (kikru.state.playing and not kikru.state.paused and "▶ " or "⏸ ")
  local track = kikru.visible_track and kikru.visible_track() or kikru.current_track()
  local label = track and require("kaeru.kikru.tags").label(track) or "—"
  local width = opts.width or 40
  if #label > width then
    label = label:sub(1, width - 1) .. "…"
  end
  local queued = #kikru.playlist.items
  return ("%s%s%s"):format(icon, label, queued > 0 and (" (%d)"):format(queued) or "")
end

--- A lualine component factory: `require("kaeru.integrations").lualine()`.
---@return fun(self: table): string
function M.lualine()
  return function()
    return M.statusline({ width = 44 })
  end
end

--- Wire the track into lualine (`lualine_x` unless a section is given).
---@param opts? {section?: string}
---@return boolean
function M.setup_lualine(opts)
  opts = opts or {}
  if not M.has("lualine") then
    return false
  end
  local lualine = require("lualine")
  local section = opts.section or "lualine_x"
  local config = lualine.get_config and lualine.get_config() or {}
  config.sections = config.sections or {}
  config.sections[section] = config.sections[section] or {}
  table.insert(config.sections[section], M.lualine())
  lualine.setup(config)
  return true
end

--- A ready-made statusline for people who do not use a statusline plugin.
---@return boolean
function M.setup_statusline()
  vim.o.statusline = table.concat({
    "%<%f %h%m%r",
    "%=",
    "%{%v:lua.require'kaeru.integrations'.statusline({width=36})%}",
    " %{%v:lua.require'kaeru.integrations'.line_col()%} ",
  }, "")
  return true
end

---@return string
function M.line_col()
  return ("%d:%d"):format(vim.fn.line("."), vim.fn.col("."))
end

-- Notifications / progress -------------------------------------------------------------

--- Use nvim-notify when it is installed (nicer floats for long tasks).
---@return boolean
function M.setup_notify()
  local notify = M.try("notify")
  if not notify then
    return false
  end
  vim.notify = notify
  return true
end

--- Run `fn(done)` with a "loading" message that is withdrawn/updated when the
--- work finishes (fidget.nvim when available, plain notify otherwise).
---@param message string
---@param fn fun(done: fun(result: any))
---@param opts? {timeout?: integer}
function M.with_progress(message, fn, opts)
  opts = opts or {}
  local fidget = M.try("fidget")
  local progress
  if fidget and fidget.progress then
    progress = fidget.progress.handle.create({
      title = "kaeru.nvim",
      message = message,
      lsp_client = { name = "kaeru.nvim" },
    })
  else
    Compat.notify(("kaeru.nvim · %s"):format(message))
  end
  local done_called = false
  local function finish(result)
    if done_called then
      return
    end
    done_called = true
    if progress then
      progress:finish()
    end
    return result
  end
  return fn(finish)
end

-- Jobs / processes -------------------------------------------------------------------

--- Run a command and capture stdout, preferring plenary's job when available.
---@param args string[]
---@param opts? {cwd?: string, timeout?: integer, env?: table}
---@param cb fun(err: string|nil, stdout: string, code: integer|nil)
function M.job(args, opts, cb)
  opts = opts or {}
  local plenary = M.try("plenary.job")
  if plenary then
    local out, err_out = {}, {}
    local job
    job = plenary:new({
      command = args[1],
      args = vim.list_slice(args, 2),
      cwd = opts.cwd,
      env = opts.env,
      on_stdout = function(_, line)
        out[#out + 1] = line
      end,
      on_stderr = function(_, line)
        err_out[#err_out + 1] = line
      end,
      on_exit = function(_, code)
        local stdout = table.concat(out, "\n")
        local stderr = table.concat(err_out, "\n")
        cb(code ~= 0 and (stderr ~= "" and stderr or ("exit " .. tostring(code))) or nil, stdout, code)
      end,
    })
    job:start()
    if opts.timeout and job.shutdown then
      vim.defer_fn(function()
        pcall(function()
          job:shutdown()
        end)
      end, opts.timeout)
    end
    return
  end
  local process = require("kaeru.process")
  process.run(args, opts, cb)
end

-- Themes -----------------------------------------------------------------------------

--- Pick the Kikru UI theme that matches the active colorscheme.
---@return string
function M.theme_for_colorscheme()
  local name = tostring((vim.g and vim.g.colors_name) or ""):lower()
  local map = {
    tokyonight = "tokyonight",
    ["tokyonight-night"] = "tokyonight",
    nord = "nord",
    dracula = "dracula",
    gruvbox = "gruvbox",
    catppuccin = "catppuccin",
    ["catppuccin-mocha"] = "catppuccin",
    kanagawa = "tokyonight",
    onedark = "nord",
    everforest = "gruvbox",
    rose_pine = "dracula",
  }
  for pattern, theme in pairs(map) do
    if name:find(pattern, 1, true) then
      return theme
    end
  end
  return "winamp"
end

-- Report -------------------------------------------------------------------------------

--- Everything that is available right now (used by `:Kaeru integrations`).
---@return table
function M.report()
  local report = {
    pickers = {},
    binaries = M.binaries_report(),
    plugins = {},
  }
  for _, picker in ipairs(M.pickers()) do
    report.pickers[#report.pickers + 1] = { id = picker.id, name = picker.name, available = M.picker_available(picker.id) }
  end
  for _, name in ipairs({
    "telescope",
    "fzf-lua",
    "snacks",
    "mini.pick",
    "nvim-cmp",
    "blink.cmp",
    "lualine",
    "heirline",
    "notify",
    "fidget",
    "plenary",
    "lazy.nvim",
    "mason",
    "mason-registry",
    "treesitter",
    "gitsigns",
    "starsky",
  }) do
    report.plugins[name] = M.has(name)
  end
  report.karu = (function()
    local ok, karu = pcall(require, "kaeru.karu")
    if not ok then
      return { available = false, reason = "module missing" }
    end
    local available, reason = karu.available()
    return {
      available = available,
      reason = reason,
      running = karu.receiver_running(),
      devices = #karu.devices(),
      summary = karu.summary(),
    }
  end)()
  report.lyrics = (function()
    local ok, lyrics = pcall(require, "kaeru.kikru.lyrics")
    if not ok or type(lyrics.providers) ~= "function" then
      return {}
    end
    local out = {}
    for _, provider in ipairs(lyrics.providers()) do
      out[#out + 1] = { name = provider.name, enabled = provider.enabled ~= false }
    end
    return out
  end)()
  report.active = {
    picker = M.best_picker().id,
    theme = require("kaeru.kikru.ui").state.theme,
    colorscheme = (vim.g and vim.g.colors_name) or "",
    engine = (function()
      local ok, backend = pcall(require, "kaeru.kikru.backend")
      return ok and backend.pick_engine() or "none"
    end)(),
  }
  return report
end

---@return string
function M.report_text()
  local report = M.report()
  local lines = { ":Kaeru integrations" }
  lines[#lines + 1] = ("  picker      %s (config ui.picker)"):format(report.active.picker)
  lines[#lines + 1] = ("  engine      %s"):format(report.active.engine)
  lines[#lines + 1] = ("  theme       %s  (colorscheme: %s)"):format(report.active.theme, report.active.colorscheme ~= "" and report.active.colorscheme or "—")
  local plugin_names = Compat.tbl_keys(report.plugins)
  table.sort(plugin_names)
  local plugin_bits = {}
  for _, name in ipairs(plugin_names) do
    plugin_bits[#plugin_bits + 1] = ("%s%s"):format(report.plugins[name] and "✓ " or "· ", name)
  end
  lines[#lines + 1] = "  plugins     " .. table.concat(plugin_bits, "  ")
  if report.karu then
    local karu = report.karu
    lines[#lines + 1] = ("  cast        %s  %s"):format(
      karu.available and (karu.running and "receiving" or "ready") or "unavailable",
      karu.available and ("(" .. tostring(karu.devices or 0) .. " device(s))") or ("(" .. tostring(karu.reason or "?") .. ")")
    )
  end
  if type(report.lyrics) == "table" and #report.lyrics > 0 then
    local bits = {}
    for _, provider in ipairs(report.lyrics) do
      bits[#bits + 1] = (provider.enabled and "✓ " or "· ") .. provider.name
    end
    lines[#lines + 1] = "  lyrics      " .. table.concat(bits, "  ")
  end
  local groups = Compat.tbl_keys(report.binaries)
  table.sort(groups)
  for _, group in ipairs(groups) do
    local names = Compat.tbl_keys(report.binaries[group])
    table.sort(names)
    local bits = {}
    for _, name in ipairs(names) do
      bits[#bits + 1] = ("%s%s"):format(report.binaries[group][name] and "✓ " or "· ", name)
    end
    lines[#lines + 1] = ("  %-10s %s"):format(group, table.concat(bits, "  "))
  end
  return table.concat(lines, "\n")
end

-- Setup ---------------------------------------------------------------------------------

--- Wire every optional integration. Never raises; returns what was applied.
---@param opts? {lualine?: boolean, statusline?: boolean, notify?: boolean, cmp?: boolean, scheme?: boolean}
---@return table<string, boolean>
function M.setup(opts)
  opts = opts or {}
  local applied = {}
  if opts.notify ~= false then
    applied.notify = pcall(M.setup_notify)
  end
  if opts.cmp ~= false then
    applied.cmp = pcall(M.cmp)
  end
  if opts.lualine then
    applied.lualine = pcall(M.setup_lualine)
  end
  if opts.statusline then
    applied.statusline = pcall(M.setup_statusline)
  end
  if opts.scheme ~= false then
    -- Follow :colorscheme changes with the player theme.
    if vim.api and vim.api.nvim_create_autocmd then
      local group = vim.api.nvim_create_augroup("KaeruTheme", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
          pcall(function()
            require("kaeru.kikru.ui").set_theme(M.theme_for_colorscheme())
          end)
        end,
        desc = "kaeru.nvim: follow the colorscheme in the Kikru UI",
      })
      applied.scheme = true
    end
  end
  return applied
end

return M
