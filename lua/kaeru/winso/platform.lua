-- Winso platform helpers: Termux detection, install hints, the system viewer and cache paths.

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

--- True on Termux (Android), where the screen is narrow and the tools come from `pkg`.
---@param env? table  defaults to vim.env
---@return boolean
function M.is_termux(env)
  env = env or (vim and vim.env) or {}
  if env.TERMUX_VERSION and env.TERMUX_VERSION ~= "" then
    return true
  end
  local prefix = env.PREFIX or ""
  return prefix:find("com.termux", 1, true) ~= nil
end

--- Install hints for the external tools, shown when a format needs one.
---@param termux boolean
---@return table<string, string>
function M.install_hints(termux)
  if termux then
    return {
      pdf = "pkg install poppler",
      mobi = "Calibre is not in Termux: convert the book to EPUB elsewhere, then open the .epub",
      python = "pkg install python",
    }
  end
  return {
    pdf = "apt install poppler-utils (or brew install poppler)",
    mobi = "install Calibre (its ebook-convert command)",
    python = "install python3",
  }
end

--- The command that opens a file in the system viewer. Termux first, then the desktop tools.
---@param path string
---@param env? table
---@param executable? fun(name: string): boolean
---@return string[]|nil argv
function M.opener_command(path, env, executable)
  env = env or (vim and vim.env) or {}
  executable = executable or function(name)
    return vim.fn.executable(name) == 1
  end
  if M.is_termux(env) and executable("termux-open") then
    return { "termux-open", path }
  end
  if env.OS == "Windows_NT" then
    return { "cmd", "/c", "start", "", path }
  end
  if executable("xdg-open") then
    return { "xdg-open", path }
  end
  if executable("open") then
    return { "open", path }
  end
  return nil
end

--- Open an image (or any file) in the system viewer.
---@param path string
function M.open_external(path)
  local argv = M.opener_command(path)
  if not argv then
    return notify("No image viewer found. On Termux install termux-api; on desktop install xdg-open.", vim.log.levels.WARN)
  end
  vim.fn.jobstart(argv, { detach = true })
  notify("Opened " .. vim.fn.fnamemodify(path, ":t"))
end

--- Cache directory for one book's images (stable per path).
---@param path string
---@return string
function M.image_cache_dir(path)
  local hash = 5381
  for i = 1, #path do
    hash = (hash * 33 + path:byte(i)) % 4294967296
  end
  return vim.fn.stdpath("cache") .. "/winso/" .. ("%08x"):format(hash)
end

return M
