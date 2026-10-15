-- Small floating-window helpers shared by the modal form and the browser.
local Config = require("kaeru.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("kaeru.nvim")

local has_title = vim.fn.has("nvim-0.9") == 1
local has_footer = vim.fn.has("nvim-0.10") == 1

---@param value number
---@param total integer
---@return integer
function M.size(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---@class KaeruFloatOpts
---@field title? string
---@field footer? string
---@field width? integer
---@field height? integer
---@field row? integer
---@field col? integer
---@field filetype? string
---@field enter? boolean
---@field zindex? integer

--- Create a scratch buffer + floating window.
---@param opts KaeruFloatOpts
---@return integer buf, integer win
function M.open(opts)
  opts = opts or {}
  local ui = Config.options.ui
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local width = opts.width or M.size(ui.width, cols)
  local height = opts.height or M.size(ui.height, lines)
  width = math.max(20, math.min(width, cols - 4))
  height = math.max(3, math.min(height, lines - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  local win_opts = {
    relative = "editor",
    style = "minimal",
    border = ui.border,
    width = width,
    height = height,
    row = opts.row or math.floor((lines - height) / 2),
    col = opts.col or math.floor((cols - width) / 2),
    zindex = opts.zindex,
  }
  if has_title and opts.title then
    win_opts.title = " " .. opts.title .. " "
    win_opts.title_pos = "center"
  end
  if has_footer and opts.footer then
    win_opts.footer = " " .. opts.footer .. " "
    win_opts.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, win_opts)
  vim.wo[win].winblend = ui.winblend
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  return buf, win
end

---@param win integer|nil
function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

---@param buf integer
---@param lhs string
---@param rhs fun()|string
---@param modes? string|string[]
---@param desc? string
function M.map(buf, lhs, rhs, modes, desc)
  vim.keymap.set(modes or "n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end

---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "kaeru.nvim" })
end

return M
