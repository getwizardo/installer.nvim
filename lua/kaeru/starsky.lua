-- Starsky for Neovim Webclient integration (`:Kaeru starsky` / `:Kaeru web`).
--
-- Manages the SvelteKit (Vite + TypeScript, mobile-first) webclient located in
-- `starsky/` inside the kaeru.nvim repository (or a custom directory configured
-- in `options.starsky.dir`). Everything runs through the npm/Vite CLI:
--   dev    -> npm run dev -- --host 0.0.0.0 --port <port> --strictPort
--   build  -> npm run build            (vite build + @sveltejs/adapter-node)
--   serve  -> node build               (run by hand: PORT=… HOST=0.0.0.0 node build)
local Config = require("kaeru.config")
local Process = require("kaeru.process")
local UI = require("kaeru.ui")

local M = {}

local uv = vim.uv or vim.loop

---@type integer|nil
M._job = nil
M._port = 5173

--- Resolve the `starsky` directory path.
---@return string
function M.dir()
  local cfg = Config.options.starsky or {}
  if cfg.dir and cfg.dir ~= "" then
    return vim.fn.expand(cfg.dir)
  end
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":p:h:h:h")
  return root .. "/starsky"
end

---@return string
function M.url()
  local cfg = Config.options.starsky or {}
  local host = cfg.host or "localhost"
  local port = cfg.port or M._port
  return ("http://%s:%d"):format(host, port)
end

---@return boolean
function M.running()
  return M._job ~= nil
end

--- The argv that starts the Vite dev server on every interface, so the
--- preview proxy and phones on the LAN can reach it.
---@param port integer
---@return string[]
function M.dev_command(port)
  return { "npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", tostring(port), "--strictPort" }
end

--- The argv for the production build (`vite build` through the npm script).
---@return string[]
function M.build_command()
  return { "npm", "run", "build" }
end

--- True when the directory is a SvelteKit project (vite.config.ts uses the kit plugin).
---@param dir string
---@return boolean
function M.is_sveltekit(dir)
  local f = io.open(dir .. "/vite.config.ts", "r")
  if not f then
    return false
  end
  local src = f:read("*a") or ""
  f:close()
  return src:find("@sveltejs/kit/vite", 1, true) ~= nil
end

--- Open the Starsky webclient URL in the system browser.
function M.open_browser()
  local url = M.url()
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
  elseif vim.fn.exists("*netrw#BrowseX") == 1 then
    vim.fn["netrw#BrowseX"](url, 0)
  end
  UI.notify("Starsky SvelteKit webclient: " .. url)
end

function M.open()
  return M.start({ open = true })
end

--- Start the Starsky dev server (`npm run dev -- --host 0.0.0.0 --port <port>`).
---@param opts? {open?: boolean}
function M.start(opts)
  opts = opts or {}
  if M.running() then
    UI.notify("Starsky webclient is already running at " .. M.url())
    if opts.open ~= false then
      M.open_browser()
    end
    return
  end

  local dir = M.dir()
  if not uv.fs_stat(dir .. "/package.json") then
    return UI.notify("Starsky directory not found at " .. dir, vim.log.levels.ERROR)
  end
  if vim.fn.executable("npm") ~= 1 then
    return UI.notify("`npm` is required to run the Starsky webclient", vim.log.levels.ERROR)
  end
  if not uv.fs_stat(dir .. "/node_modules") then
    return UI.notify("Run `:Kaeru starsky build` after `npm install` in " .. dir, vim.log.levels.WARN)
  end

  local cfg = Config.options.starsky or {}
  M._port = cfg.port or 5173

  UI.notify(("Starting Starsky SvelteKit webclient on %s…"):format(M.url()))
  local job = vim.fn.jobstart(M.dev_command(M._port), {
    cwd = dir,
    on_exit = function()
      M._job = nil
    end,
  })
  if job <= 0 then
    return UI.notify("Failed to start the Starsky webclient", vim.log.levels.ERROR)
  end
  M._job = job
  if opts.open ~= false then
    vim.defer_fn(function()
      if M.running() then
        M.open_browser()
      end
    end, 1500)
  end
end

--- Stop the running Starsky dev server.
function M.stop()
  if not M._job then
    return UI.notify("Starsky webclient is not running", vim.log.levels.WARN)
  end
  pcall(vim.fn.jobstop, M._job)
  M._job = nil
  UI.notify("Stopped Starsky webclient")
end

--- Build the production bundle with `npm run build` (Vite CLI + adapter-node).
function M.build()
  local dir = M.dir()
  if vim.fn.executable("npm") ~= 1 then
    return UI.notify("`npm` is required to build the Starsky webclient", vim.log.levels.ERROR)
  end
  UI.notify("Building Starsky SvelteKit webclient (`npm run build`)…")
  Process.run(M.build_command(), { cwd = dir }, function(res)
    if res.code == 0 then
      UI.notify("Starsky webclient built in " .. dir .. "/build (run with `node build`)")
    else
      UI.notify("Starsky build failed:\n" .. (res.stderr or res.stdout or ""), vim.log.levels.ERROR)
    end
  end)
end

--- Show status of the Starsky SvelteKit webclient.
function M.status()
  local dir = M.dir()
  local has_pkg = uv.fs_stat(dir .. "/package.json") ~= nil
  local has_modules = uv.fs_stat(dir .. "/node_modules") ~= nil
  local lines = {
    "Starsky for Neovim · SvelteKit TypeScript Webclient",
    ("  directory: %s (%s)"):format(dir, has_pkg and "found" or "missing"),
    ("  framework: %s"):format(M.is_sveltekit(dir) and "SvelteKit (Vite · TypeScript · adapter-node)" or "unknown"),
    ("  packages:  %s"):format(has_modules and "installed" or "run `npm install` in starsky/"),
    ("  status:    %s"):format(M.running() and ("running at " .. M.url()) or "stopped"),
  }
  UI.notify(table.concat(lines, "\n"))
end

-- `:Kaeru starsky info` -----------------------------------------------------

-- 5x5 pixel glyphs; "1" is a lit pixel. Each pixel is drawn 2x2 characters.
M.pixel_font = {
  K = { "10001", "10010", "11100", "10010", "10001" },
  I = { "11111", "00100", "00100", "00100", "11111" },
  T = { "11111", "00100", "00100", "00100", "00100" },
  ["3"] = { "11110", "00001", "01110", "00001", "11110" },
}

-- Colors picked at random for the "KIT" splash.
M.info_palette = { "#ff5f87", "#5fd7ff", "#ffd75f", "#87ff5f", "#d787ff", "#ff8700", "#5fffd7" }

M.info_frame_ms = 160

--- Draw one glyph as 10 rows of text. `scan` is a pixel row (1..5) that is
--- drawn brighter, which is how the animated "3" sweeps down.
---@param ch string
---@param scan? integer
---@return string[]
function M.pixel_glyph(ch, scan)
  local rows = {}
  for r, bits in ipairs(M.pixel_font[ch]) do
    local line = {}
    for c = 1, #bits do
      if bits:sub(c, c) == "1" then
        line[#line + 1] = (scan == r) and "▓▓" or "██"
      else
        line[#line + 1] = "  "
      end
    end
    local text = table.concat(line)
    rows[#rows + 1] = text
    rows[#rows + 1] = text
  end
  return rows
end

--- Join glyph rows side by side with `gap` spaces between glyphs.
---@param glyphs string[][]
---@param gap integer
---@return string[]
local function join_glyphs(glyphs, gap)
  local out = {}
  local spacer = string.rep(" ", gap)
  for r = 1, #glyphs[1] do
    local parts = {}
    for i, g in ipairs(glyphs) do
      parts[#parts + 1] = g[r]
      if i < #glyphs then
        parts[#parts + 1] = spacer
      end
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

--- Lines of the splash for animation frame `frame` (0-based).
---@param frame integer
---@return string[]
function M.info_lines(frame)
  local scan = (frame % 5) + 1
  local kit = join_glyphs({ M.pixel_glyph("K"), M.pixel_glyph("I"), M.pixel_glyph("T") }, 2)
  local three = M.pixel_glyph("3", scan)

  local lines = { "" }
  for _, row in ipairs(kit) do
    lines[#lines + 1] = "  " .. row .. "    "
  end
  -- The animated "3" sits to the right of KIT, aligned with its top row.
  for i, row in ipairs(three) do
    lines[i + 1] = lines[i + 1] .. row
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  STARSKY · KIT · NEOCODEIUM"
  lines[#lines + 1] = "  q / <Esc> to close"
  return lines
end

--- Open the "KIT" splash: a floating window with a random color and an animated
--- pixel "3". The animation timer stops when the window or buffer goes away.
function M.info()
  local uv = vim.uv or vim.loop
  math.randomseed(math.floor(uv.hrtime() % 2147483647))
  local color = M.info_palette[math.random(#M.info_palette)]
  local hl = "KaeruStarskyInfo"
  vim.api.nvim_set_hl(0, hl, { fg = color, bold = true })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "kaeru-starsky-info"

  local function draw(frame)
    if not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.info_lines(frame))
    vim.bo[buf].modifiable = false
    return true
  end

  local lines = M.info_lines(0)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width + 2, vim.o.columns - 2),
    height = math.min(height, vim.o.lines - 4),
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].winhighlight = "Normal:" .. hl .. ",FloatBorder:" .. hl
  draw(0)

  local timer = uv.new_timer()
  local frame = 0
  local function stop()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end
  timer:start(
    M.info_frame_ms,
    M.info_frame_ms,
    vim.schedule_wrap(function()
      frame = frame + 1
      if not draw(frame) then
        stop()
      end
    end)
  )

  local function close()
    stop()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = buf,
    once = true,
    callback = stop,
  })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "close kaeru starsky info" })
  end
  return win
end

return M
