-- Starsky for Neovim Webclient integration (`:Kaeru starsky` / `:Clina web`).
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

return M
