-- Winso reader: one book per tab. The text column follows the window, and a status bar
-- shows the title, chapter, progress and the time (CrossMux-style). Progress is saved on
-- every chapter change and when the reader closes.

local Config = require("kaeru.winso.config")
local Library = require("kaeru.winso.library")
local Loader = require("kaeru.winso.loader")
local Platform = require("kaeru.winso.platform")
local Text = require("kaeru.winso.text")
local Theme = require("kaeru.winso.theme")

local M = {}

-- bufnr -> { book, chapter, line, width, buf }
M.buffers = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

--- Text column for a new reader: session override, saved setting, then automatic.
---@return integer
function M.reader_width()
  local session = vim.g.winso_width
  if type(session) == "number" then
    return session
  end
  local saved = Library.setting("width", nil)
  if type(saved) == "number" then
    return saved
  end
  if Config.defaults.width then
    return Config.defaults.width
  end
  local cols = vim.o.columns or 80
  local cap = Platform.is_termux() and Config.defaults.termux_width or Config.defaults.max_width
  return math.max(20, math.min(cols - 2, cap))
end

--- The reader state of the current buffer, or nil outside a reader.
---@return table|nil
function M.current()
  return M.buffers[vim.api.nvim_get_current_buf()]
end

--- Save the reading position of a reader.
---@param st table
function M.save_progress(st)
  if not st or not st.book then
    return
  end
  -- the cursor is the truth while the reader is open
  local win = st.buf and vim.fn.bufwinid(st.buf) or -1
  if win ~= -1 then
    st.line = vim.api.nvim_win_get_cursor(win)[1]
  end
  Library.record_progress(st.book.path, {
    title = st.book.title,
    chapter = st.chapter,
    line = st.line or 1,
    width = st.width,
    chapters = #st.book.chapters,
  })
end

--- Status bar text: title, chapter, percentage and clock.
---@param st table
---@return string
function M.status_text(st)
  local count = #st.book.chapters
  local pct = count > 0 and math.floor((st.chapter / count) * 100 + 0.5) or 0
  local title = st.book.title:gsub("%%", "%%%%")
  return ("%%#KaeruWinsoBar# %s · %d/%d · %d%%%% · %s %%*"):format(title, st.chapter, count, pct, os.date("%H:%M"))
end

local function refresh_status(st)
  local win = vim.fn.bufwinid(st.buf)
  if win ~= -1 then
    vim.wo[win].winbar = M.status_text(st)
  end
end

--- Draw the current chapter into the reader buffer.
---@param st table
function M.render(st)
  local lines = Text.render_chapter(st.book, st.chapter, st.width)
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  refresh_status(st)
end

--- Show a chapter and place the cursor on a line.
---@param st table
---@param index integer
---@param line? integer
function M.goto_chapter(st, index, line)
  index = math.max(1, math.min(#st.book.chapters, index))
  st.chapter = index
  M.render(st)
  local win = vim.fn.bufwinid(st.buf)
  local total = vim.api.nvim_buf_line_count(st.buf)
  local target = math.max(1, math.min(total, line or 1))
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
  st.line = target
  M.save_progress(st)
end

--- Make the text column wider or narrower, keeping the reading position.
---@param st table
---@param delta integer
function M.resize(st, delta)
  local ratio = vim.api.nvim_win_get_cursor(0)[1] / math.max(1, vim.api.nvim_buf_line_count(st.buf))
  st.width = math.max(20, math.min(160, st.width + delta))
  vim.g.winso_width = st.width
  M.render(st)
  local line = math.max(1, math.floor(ratio * vim.api.nvim_buf_line_count(st.buf)))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
end

--- Open a loaded book in a new tab at its saved position.
---@param book table
---@param opts? {chapter?: integer, line?: integer}
---@return table st
function M.show(book, opts)
  opts = opts or {}
  local saved = Library.read_library().books[book.path] or {}
  local st = {
    book = book,
    chapter = opts.chapter or saved.chapter or 1,
    line = opts.line or saved.line or 1,
    width = M.reader_width(),
  }
  st.chapter = math.max(1, math.min(#book.chapters, st.chapter))
  vim.cmd("tabnew")
  local buf = vim.api.nvim_create_buf(false, true)
  st.buf = buf
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "winso"
  pcall(vim.api.nvim_buf_set_name, buf, "winso://" .. book.title)
  M.buffers[buf] = st
  require("kaeru.winso.reader_keys").attach(buf, M)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M.save_progress(M.buffers[buf])
      M.buffers[buf] = nil
    end,
  })
  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.cursorline = false
  Theme.apply(Library.setting("theme", Theme.default), 0)
  M.goto_chapter(st, st.chapter, st.line)
  return st
end

--- Load a book file and open it. Shows a message when it cannot be read.
---@param path string
---@param opts? {chapter?: integer, line?: integer}
function M.open(path, opts)
  notify("Opening " .. vim.fn.fnamemodify(path, ":t") .. " …")
  Loader.load(path, function(err, book)
    if err then
      return notify("Winso: " .. err, vim.log.levels.ERROR)
    end
    M.show(book, opts)
  end)
end

return M
