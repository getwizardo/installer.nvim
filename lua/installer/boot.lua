-- ASCII Boot Animation for installer.nvim & Starsky (`:Installer boot`)
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

M.ascii_logo = {
  "   _____ _______       _____   _____ _  ____     __  _   ___      _______ __  __ ",
  "  / ____|__   __|/\\   |  __ \\ / ____| |/ /\\ \\   / / | \\ | \\ \\    / /_   _|  \\/  |",
  " | (___    | |  /  \\  | |__) | (___ | ' /  \\ \\_/ /  |  \\| |\\ \\  / /  | | | \\  / |",
  "  \\___ \\   | | / /\\ \\ |  _  / \\___ \\|  <    \\   /   | . ` | \\ \\/ /   | | | |\\/| |",
  "  ____) |  | |/ ____ \\| | \\ \\ ____) | . \\    | |    | |\\  |  \\  /   _| |_| |  | |",
  " |_____/   |_/_/    \\_\\_|  \\_\\_____/|_|\\_\\   |_|    |_| \\_|   \\/   |_____|_|  |_|",
}

M.boot_steps = {
  { id = "spec", label = "Initializing lazy.nvim Spec Builder & Validator", detail = "lua/plugins/*.lua [OK]" },
  { id = "github", label = "Connecting GitHub Live Autocomplete API", detail = "api.github.com [READY]" },
  { id = "mason", label = "Mounting https://mason-registry.dev Catalog", detail = "601 pkgs / 296 LSPs [MOUNTED]" },
  { id = "clina", label = "Binding :Clina -> NeoCodeium (monkoose/neocodeium)", detail = "Ghost-Text + Windsurf [BOUND]" },
  { id = "music", label = "Starting :MusicPlayer 10-Band EQ & 2-Nvim RPC", detail = "Server<->Client TCP [ONLINE]" },
  { id = "sftp", label = "Loading Dual-Pane SFTP Studio & SSH Workers", detail = "Batch SFTP [READY]" },
  { id = "web", label = "Booting Starsky Web Code IDE (Web Components + Vaul)", detail = "Next.js 16 TS [READY]" },
}

--- Render a single frame `step_idx` (1..#M.boot_steps + 2) of the ASCII boot sequence.
---@param step_idx integer
---@param width? integer
---@return string[]
function M.render_frame(step_idx, width)
  width = width or 88
  local total = #M.boot_steps
  local progress = math.min(1.0, math.max(0.0, step_idx / total))
  local bar_width = 54
  local filled = math.floor(progress * bar_width)
  local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
  local pct = math.floor(progress * 100)

  local lines = { "" }
  for _, l in ipairs(M.ascii_logo) do
    lines[#lines + 1] = "  " .. l
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "    ★  INSTALLER.NVIM · STARSKY OS · NEOCODEIUM · MASON-REGISTRY.DEV · MUSICPLAYER  ★"
  lines[#lines + 1] = "  " .. string.rep("─", width - 4)
  lines[#lines + 1] = string.format("    BOOT PROGRESS [%s] %3d%%", bar, pct)
  lines[#lines + 1] = ""

  for i, step in ipairs(M.boot_steps) do
    if i < step_idx then
      lines[#lines + 1] = string.format("    [✓] %-50s %s", step.label, step.detail)
    elseif i == step_idx then
      lines[#lines + 1] = string.format("    [⟳] %-50s ...", step.label)
    else
      lines[#lines + 1] = string.format("    [·] %-50s", step.label)
    end
  end

  lines[#lines + 1] = ""
  if step_idx > total then
    lines[#lines + 1] = "    ⚡ SYSTEM ONLINE — Press <CR> for :Installer, `c` for :Clina, `m` for :MusicPlayer, `q` to close"
  else
    lines[#lines + 1] = "    Booting subsystems… (press any key to skip)"
  end
  return lines
end

--- Play the interactive ASCII boot animation in a floating Neovim window.
---@param opts? {auto_close?: boolean, interval_ms?: integer, on_done?: fun()}
function M.play(opts)
  opts = opts or {}
  local width = 90
  local height = #M.ascii_logo + #M.boot_steps + 9
  local buf, win = UI.open({
    title = " installer.nvim · ASCII Boot Sequence ",
    width = width,
    height = height,
    filetype = "installer-boot",
  })

  local step = 1
  local timer = nil
  local closed = false

  local function stop()
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
      timer = nil
    end
  end

  local function close_boot()
    if closed then
      return
    end
    closed = true
    stop()
    UI.close(win)
    if opts.on_done then
      opts.on_done()
    end
  end

  local function draw()
    if closed or not vim.api.nvim_buf_is_valid(buf) then
      stop()
      return
    end
    local lines = M.render_frame(step, width)
    UI.set_lines(buf, lines)
    vim.bo[buf].modifiable = false
  end

  UI.map(buf, "q", close_boot)
  UI.map(buf, "<Esc>", close_boot)
  UI.map(buf, "<Space>", close_boot)
  UI.map(buf, "<CR>", function()
    close_boot()
    require("installer").open()
  end)
  UI.map(buf, "c", function()
    close_boot()
    require("installer.clina").ide()
  end)
  UI.map(buf, "m", function()
    close_boot()
    require("installer.music").ui()
  end)

  draw()

  if uv and uv.new_timer then
    timer = uv.new_timer()
    timer:start(opts.interval_ms or 180, opts.interval_ms or 180, function()
      step = step + 1
      vim.schedule(function()
        if closed or not vim.api.nvim_buf_is_valid(buf) then
          stop()
          return
        end
        draw()
        if step > #M.boot_steps + 1 then
          stop()
          if opts.auto_close then
            vim.defer_fn(close_boot, 450)
          end
        end
      end)
    end)
  end
end

return M
