-- ASCII welcome screen for Neovim startup (`welcome.enabled` in setup()).
-- Reuses the boot logo from kaeru.boot and shows it in a nofile, nomodifiable
-- scratch buffer when Neovim starts without file arguments.
local Boot = require("kaeru.boot")

local M = {}

--- Lines of the welcome screen. The whole block is centered with one shared
--- offset, so the logo and the hint columns keep their alignment.
---@param width? integer
---@return string[]
function M.lines(width)
  width = width or 80
  local raw = { "" }
  for _, l in ipairs(Boot.ascii_logo) do
    raw[#raw + 1] = l
  end
  raw[#raw + 1] = ""
  raw[#raw + 1] = "kaeru.nvim"
  raw[#raw + 1] = ""
  raw[#raw + 1] = "e              new buffer"
  raw[#raw + 1] = ":Kaeru         plugin manager"
  raw[#raw + 1] = ":Kaeru boot    intro"
  raw[#raw + 1] = ""

  local block_w = 0
  for _, l in ipairs(raw) do
    block_w = math.max(block_w, vim.fn.strdisplaywidth(l))
  end
  local pad = string.rep(" ", math.max(0, math.floor((width - block_w) / 2)))

  local out = {}
  for _, l in ipairs(raw) do
    out[#out + 1] = l == "" and "" or (pad .. l)
  end
  return out
end

--- Show the welcome screen in the current window.
function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "kaeru-welcome"
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(vim.api.nvim_win_get_width(0)))
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.cursorline = false
  vim.wo.list = false
  vim.wo.foldcolumn = "0"
  vim.wo.colorcolumn = ""
  for _, lhs in ipairs({ "e", "q" }) do
    vim.keymap.set("n", lhs, "<Cmd>enew<CR>", { buffer = buf, nowait = true, desc = "kaeru: start editing" })
  end
end

--- True when the welcome screen should appear: enabled, no file arguments,
--- a UI is attached and the current buffer is the untouched empty start buffer.
---@return boolean
function M.should_show()
  local Config = require("kaeru.config")
  local cfg = (Config.options or Config.defaults or {}).welcome or {}
  if cfg.enabled == false then
    return false
  end
  if vim.fn.argc() > 0 or #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

--- Called on VimEnter from plugin/kaeru.lua.
function M.maybe_show()
  if M.should_show() then
    M.show()
  end
end

--- Show the welcome screen once Neovim has entered (immediately if it already has).
function M.attach()
  if not (vim.v and vim.api and vim.api.nvim_create_autocmd) then
    return
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(M.maybe_show)
  else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, nested = true, callback = M.maybe_show })
  end
end

return M
