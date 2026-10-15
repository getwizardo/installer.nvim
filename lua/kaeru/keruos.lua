-- KeruOS: a launcher dashboard for the kaeru.nvim tools (`:KeruOS`).
--
-- One floating window lists the tools, each on a number key (1-7). Pressing the key runs
-- the tool's command and closes the dashboard. Narrow windows (phones, Termux) get a
-- one-line-per-tool layout that fits 40 columns.
--
-- The menu and the renderer are pure functions, so tests can check them without a
-- window. `M.open` is the only function that touches the editor.

local M = {}

---@class KeruOSItem
---@field key string       key pressed in the dashboard
---@field label string     short name
---@field hint string      one-line description
---@field cmd string       Ex command run when the key is pressed

--- The menu, in display order.
---@return KeruOSItem[]
function M.items()
  return {
    { key = "1", label = "Kikru", hint = "music player and cast queue", cmd = "Kikru" },
    { key = "2", label = "Winso", hint = "ebook library and reader", cmd = "Winso library" },
    { key = "3", label = "Starsky", hint = "web IDE for the running Neovim", cmd = "Kaeru starsky start" },
    { key = "4", label = "CVE", hint = "CVE advisories for dependencies", cmd = "Kaeru cve scan" },
    { key = "5", label = "Upgrator", hint = "check outdated packages", cmd = "Kaeru upgrade check" },
    { key = "6", label = "Plugins", hint = "install and manage plugin specs", cmd = "Kaeru modal" },
    { key = "7", label = "Receiver", hint = "Cast receiver status", cmd = "Kikru receive status" },
  }
end

--- Layout for a window `cols` columns wide.
---@param cols integer
---@return "compact"|"wide"
function M.layout(cols)
  return cols < 60 and "compact" or "wide"
end

--- Dashboard width: leaves a margin on phones, caps the width on desktops.
---@param cols integer
---@return integer
function M.width(cols)
  if M.layout(cols) == "compact" then
    return math.max(24, cols - 2)
  end
  return math.min(56, cols - 4)
end

--- Lines for the dashboard. `receiver` is the receiver state shown next to its entry.
---@param items KeruOSItem[]
---@param opts? {layout?: "compact"|"wide", receiver?: string, width?: integer}
---@return string[] lines
---@return table<integer, KeruOSItem> by_line  line number (1-based) → item
function M.render(items, opts)
  opts = opts or {}
  local layout = opts.layout or "wide"
  local width = opts.width or 40
  local lines, by_line = { "KeruOS", string.rep("-", math.min(width, 40)) }, {}
  for _, item in ipairs(items) do
    local label = item.label
    if item.key == "7" and opts.receiver then
      label = label .. " (" .. opts.receiver .. ")"
    end
    local row
    if layout == "compact" then
      row = ("[%s] %s"):format(item.key, label)
      lines[#lines + 1] = row
      lines[#lines + 1] = "    " .. item.hint
    else
      row = ("[%s]  %-22s %s"):format(item.key, label, item.hint)
      lines[#lines + 1] = row
    end
    by_line[#lines - (layout == "compact" and 1 or 0)] = item
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "press a key to open, q to close"
  return lines, by_line
end

--- Receiver state for the dashboard: "running", "off", or "unavailable".
---@return string
function M.receiver_state()
  local ok, Karu = pcall(require, "kaeru.karu")
  if not ok or type(Karu) ~= "table" or type(Karu.receiver_running) ~= "function" then
    return "unavailable"
  end
  local ran, running = pcall(Karu.receiver_running)
  if not ran then
    return "unavailable"
  end
  return running and "running" or "off"
end

--- Open the dashboard in a floating window.
function M.open()
  local UI = require("kaeru.ui")
  local cols = vim.o.columns
  local width = M.width(cols)
  local layout = M.layout(cols)
  local items = M.items()
  local lines, by_line = M.render(items, { layout = layout, width = width, receiver = M.receiver_state() })

  local buf, win = UI.open({
    width = width,
    height = math.min(#lines + 1, vim.o.lines - 4),
    title = "KeruOS",
    filetype = "keruos",
  })
  vim.bo[buf].modifiable = true
  UI.set_lines(buf, lines)
  vim.bo[buf].modifiable = false

  local function run(item)
    UI.close(win)
    vim.schedule(function()
      local ok, err = pcall(vim.cmd, item.cmd)
      if not ok then
        UI.notify("KeruOS · " .. item.label .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
  for _, item in ipairs(items) do
    UI.map(buf, item.key, function()
      run(item)
    end, "n", "KeruOS: " .. item.label)
  end
  UI.map(buf, "q", function()
    UI.close(win)
  end, "n", "KeruOS: close")
  UI.map(buf, "<Esc>", function()
    UI.close(win)
  end, "n", "KeruOS: close")
  UI.map(buf, "<CR>", function()
    local item = by_line[vim.api.nvim_win_get_cursor(win)[1]]
    if item then
      run(item)
    end
  end, "n", "KeruOS: open the tool on this line")
  return buf, win
end

return M
