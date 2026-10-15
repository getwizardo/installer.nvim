-- Starsky for Neovim Webclient integration (`:Installer starsky` / `:Clina web`).
--
-- Manages the Next.js TypeScript webclient & API server located in `starsky/`
-- inside the installer.nvim repository (or a custom directory configured in
-- `options.starsky.dir`).
local Config = require("installer.config")
local Process = require("installer.process")
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

---@type integer|nil
M._job = nil
M._port = 3000

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

--- Open the Starsky Next.js Webclient URL in the system browser.
function M.open_browser()
  local url = M.url()
  if vim.ui and vim.ui.open then
    vim.ui.open(url)
  elseif vim.fn.exists("*netrw#BrowseX") == 1 then
    vim.fn["netrw#BrowseX"](url, 0)
  end
  UI.notify("Starsky Next.js Webclient: " .. url)
end

function M.open()
  return M.start({ open = true })
end

--- Start the Next.js TypeScript Starsky Webclient (`yarn dev --hostname 0.0.0.0 --port <port>`).
---@param opts? {open?: boolean}
function M.start(opts)
  opts = opts or {}
  if M.running() then
    UI.notify("Starsky Next.js Webclient is already running at " .. M.url())
    if opts.open ~= false then
      M.open_browser()
    end
    return
  end

  local dir = M.dir()
  if not uv.fs_stat(dir .. "/package.json") then
    return UI.notify("Starsky directory not found at " .. dir, vim.log.levels.ERROR)
  end
  if vim.fn.executable("yarn") ~= 1 then
    return UI.notify("`yarn` is required to run Starsky Webclient", vim.log.levels.ERROR)
  end

  local cfg = Config.options.starsky or {}
  M._port = cfg.port or 3000

  UI.notify(("Starting Starsky Next.js TypeScript Webclient on %s…"):format(M.url()))
  local job = vim.fn.jobstart(
    { "yarn", "dev", "--hostname", "0.0.0.0", "--port", tostring(M._port) },
    {
      cwd = dir,
      env = {
        PORT = tostring(M._port),
      },
      on_exit = function()
        M._job = nil
      end,
    }
  )
  if job <= 0 then
    return UI.notify("Failed to start Starsky Next.js Webclient", vim.log.levels.ERROR)
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

--- Stop the running Starsky Webclient process.
function M.stop()
  if not M._job then
    return UI.notify("Starsky Next.js Webclient is not running", vim.log.levels.WARN)
  end
  pcall(vim.fn.jobstop, M._job)
  M._job = nil
  UI.notify("Stopped Starsky Next.js Webclient")
end

--- Build the Next.js production bundle with `yarn build`.
function M.build()
  local dir = M.dir()
  UI.notify("Building Starsky Next.js Webclient (`yarn build`)…")
  Process.run({ "yarn", "build" }, { cwd = dir }, function(res)
    if res.code == 0 then
      UI.notify("Starsky Next.js Webclient built in " .. dir .. "/.next")
    else
      UI.notify("Starsky build failed:\n" .. (res.stderr or res.stdout or ""), vim.log.levels.ERROR)
    end
  end)
end

--- Show status of the Starsky Next.js Webclient.
function M.status()
  local dir = M.dir()
  local has_pkg = uv.fs_stat(dir .. "/package.json") ~= nil
  local has_next = uv.fs_stat(dir .. "/next.config.ts") ~= nil
  local lines = {
    "Starsky for Neovim · Next.js TypeScript Webclient",
    ("  directory: %s (%s)"):format(dir, has_pkg and "found" or "missing"),
    ("  framework: %s"):format(has_next and "Next.js (TypeScript App Router)" or "unknown"),
    ("  status:    %s"):format(M.running() and ("running at " .. M.url()) or "stopped"),
  }
  UI.notify(table.concat(lines, "\n"))
end

return M
