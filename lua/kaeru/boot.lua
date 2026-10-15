-- ASCII boot animation for kaeru.nvim (`:Kaeru boot`)
local UI = require("kaeru.ui")

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

-- Steps are user-facing feature names only: no paths, module names, hosts or
-- library versions. The sequence is cosmetic; it does not probe anything.
M.boot_steps = {
  { id = "specs", label = "Plugin specs" },
  { id = "search", label = "Repository search" },
  { id = "servers", label = "Language servers" },
  { id = "ai", label = "AI presets" },
  { id = "music", label = "Music player" },
  { id = "files", label = "Remote files" },
  { id = "web", label = "Web IDE" },
}

--- Render a single frame `step_idx` (1..#M.boot_steps + 1) of the ASCII boot sequence.
--- Steps before `step_idx` are done, `step_idx` is running, the rest are pending.
---@param step_idx integer
---@param width? integer
---@return string[]
function M.render_frame(step_idx, width)
  width = width or 88
  local total = #M.boot_steps
  local done = math.min(total, math.max(0, step_idx - 1))
  local pct = math.floor(done / total * 100)
  local bar_width = 40
  local filled = math.floor(pct / 100 * bar_width)
  local bar = string.rep("#", filled) .. string.rep(".", bar_width - filled)

  local lines = { "" }
  for _, l in ipairs(M.ascii_logo) do
    lines[#lines + 1] = "  " .. l
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  kaeru.nvim"
  lines[#lines + 1] = "  " .. string.rep("-", math.max(10, width - 4))
  lines[#lines + 1] = string.format("  [%s] %3d%%", bar, pct)
  lines[#lines + 1] = ""

  for i, step in ipairs(M.boot_steps) do
    local mark = "    "
    if i < step_idx then
      mark = "ok  "
    elseif i == step_idx then
      mark = "... "
    end
    lines[#lines + 1] = string.format("  %s%s", mark, step.label)
  end

  lines[#lines + 1] = ""
  if step_idx > total then
    lines[#lines + 1] = "  Ready. <CR> plugin manager, m music, q close."
  else
    lines[#lines + 1] = "  q, <Esc> or <Space> skips."
  end
  return lines
end

--- Play the interactive ASCII boot animation in a floating Neovim window.
---@param opts? {auto_close?: boolean, interval_ms?: integer, on_done?: fun()}
function M.play(opts)
  opts = opts or {}
  local width = 90
  local height = #M.render_frame(#M.boot_steps + 1, width)
  local buf, win = UI.open({
    title = " kaeru.nvim ",
    width = width,
    height = height,
    filetype = "kaeru-boot",
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
    require("kaeru").open()
  end)
  UI.map(buf, "m", function()
    close_boot()
    require("kaeru.kikru").ui()
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
