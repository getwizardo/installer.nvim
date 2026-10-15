-- Winso shelf: the home screen. It lists books being read, with progress bars, and offers
-- bookmarks, folders and settings. Everything works from keys and pickers, so a phone
-- keyboard is enough.

local Config = require("kaeru.winso.config")
local Library = require("kaeru.winso.library")
local Reader = require("kaeru.winso.reader")
local Theme = require("kaeru.winso.theme")

local M = {}

local BAR = 10
local RULE_MAX = 40

-- buffer -> the actions behind each line of the shelf
local views = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

--- A text progress bar, e.g. "[#####-----]  50%", or "[----------]  new" when unread.
---@param fraction number|nil
---@return string
function M.bar(fraction)
  if not fraction then
    return "[" .. string.rep("-", BAR) .. "]  new"
  end
  local filled = math.floor(fraction * BAR + 0.5)
  return ("[%s%s] %3d%%"):format(
    string.rep("#", filled),
    string.rep("-", BAR - filled),
    math.floor(fraction * 100 + 0.5)
  )
end

--- Lines of the shelf, and what each line does when opened.
---@param opts {items: table[], bookmarks: integer, folder: string, theme: string, width: integer|nil, cols: integer}
---@return string[] lines, table<integer, table> actions  (actions are keyed by 1-based line)
function M.render(opts)
  local lines, actions = {}, {}
  local function add(text, action)
    lines[#lines + 1] = text
    if action then
      actions[#lines] = action
    end
  end
  add("WINSO")
  add(string.rep("-", math.min(opts.cols or RULE_MAX, RULE_MAX)))
  add("Continue reading")
  if #opts.items == 0 then
    add("  (nothing yet: a opens a file, f browses a folder)")
  end
  for i, item in ipairs(opts.items) do
    local action = { kind = "book", path = item.path }
    add(("  %d. %s"):format(i, item.title), action)
    add(("     %s  ch %d/%s"):format(M.bar(Library.fraction(item)), item.chapter, item.chapters or "?"), action)
  end
  add("")
  add(("Bookmarks: %d   (b lists them)"):format(opts.bookmarks), { kind = "bookmarks" })
  add("Folder: " .. opts.folder .. "   (f browses)", { kind = "folder" })
  add(
    ("Theme: %s   Width: %s   (s changes)"):format(opts.theme, opts.width and tostring(opts.width) or "auto"),
    { kind = "settings" }
  )
  add("")
  add("<CR> open   a open file   f folder   b bookmarks")
  add("s settings   x forget   r refresh   q close")
  return lines, actions
end

local function supported(name)
  local lower = name:lower()
  for _, ext in ipairs(Config.formats) do
    if lower:sub(-#ext - 1) == "." .. ext then
      return true
    end
  end
  return false
end

local function current_folder()
  return Library.setting("folder", vim.fn.expand("~"))
end

--- Gather what the shelf shows right now.
---@return table
local function snapshot()
  local bookmarks = Library.all_bookmarks()
  return {
    items = Library.recent(),
    bookmarks = #bookmarks,
    folder = current_folder(),
    theme = Library.setting("theme", Theme.default),
    width = Library.setting("width", nil),
    cols = vim.api.nvim_win_get_width(0),
  }
end

--- Redraw a shelf buffer.
---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines, actions = M.render(snapshot())
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  views[buf] = actions
end

--- Pick a file or folder to read, starting at `dir`.
---@param dir? string
function M.browse(dir)
  dir = dir or current_folder()
  Library.set_setting("folder", dir)
  local folders, files = {}, {}
  for _, name in ipairs(vim.fn.readdir(dir) or {}) do
    local full = dir .. "/" .. name
    if vim.fn.isdirectory(full) == 1 then
      if name:sub(1, 1) ~= "." then
        folders[#folders + 1] = { label = name .. "/", path = full, folder = true }
      end
    elseif supported(name) then
      files[#files + 1] = { label = name, path = full }
    end
  end
  table.sort(folders, function(a, b)
    return a.label < b.label
  end)
  table.sort(files, function(a, b)
    return a.label < b.label
  end)
  local choices = { { label = "../", path = vim.fn.fnamemodify(dir, ":h"), folder = true } }
  vim.list_extend(choices, folders)
  vim.list_extend(choices, files)
  vim.ui.select(choices, {
    prompt = dir,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.folder then
      M.browse(choice.path)
    else
      Reader.open(choice.path)
    end
  end)
end

--- Pick a bookmark, for one book (`path`) or for all of them.
---@param path? string
function M.pick_bookmark(path)
  local marks = {}
  local books = Library.read_library().books
  for _, entry in ipairs(Library.all_bookmarks()) do
    if not path or entry.path == path then
      local title = books[entry.path] and books[entry.path].title or vim.fn.fnamemodify(entry.path, ":t")
      marks[#marks + 1] = { path = entry.path, mark = entry.mark, title = title }
    end
  end
  if #marks == 0 then
    return notify("No bookmarks yet (press b while reading)")
  end
  vim.ui.select(marks, {
    prompt = "Bookmarks",
    format_item = function(entry)
      local label = entry.mark.label ~= "" and entry.mark.label or "(blank line)"
      return ("%s · ch %d: %s"):format(entry.title, entry.mark.chapter, label)
    end,
  }, function(entry)
    if entry then
      Reader.open(entry.path, { chapter = entry.mark.chapter, line = entry.mark.line })
    end
  end)
end

local SETTINGS = {
  { label = "Theme: night", apply = function() Library.set_setting("theme", "night") end },
  { label = "Theme: paper", apply = function() Library.set_setting("theme", "paper") end },
  { label = "Theme: sepia", apply = function() Library.set_setting("theme", "sepia") end },
  { label = "Width: automatic", apply = function() Library.set_setting("width", nil) end },
  { label = "Width: 40 columns", apply = function() Library.set_setting("width", 40) end },
  { label = "Width: 60 columns", apply = function() Library.set_setting("width", 60) end },
  { label = "Width: 80 columns", apply = function() Library.set_setting("width", 80) end },
}

--- Pick a reading setting. Calls `done` after a change.
---@param done fun()
function M.settings(done)
  vim.ui.select(SETTINGS, {
    prompt = "Winso settings",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      choice.apply()
      done()
    end
  end)
end

--- Open the shelf in a new tab.
function M.open()
  vim.cmd("tabnew")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "winso-shelf"
  pcall(vim.api.nvim_buf_set_name, buf, "winso://shelf")
  vim.wo.wrap = true
  vim.wo.number = false
  vim.wo.signcolumn = "no"
  vim.wo.cursorline = true
  Theme.apply(Library.setting("theme", Theme.default), 0)
  M.refresh(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      views[buf] = nil
    end,
  })

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Winso: " .. desc })
  end
  local function action_here()
    return (views[buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function changed()
    M.refresh(buf)
  end

  map("<CR>", function()
    local action = action_here()
    if not action then
      return
    end
    if action.kind == "book" then
      Reader.open(action.path)
    elseif action.kind == "bookmarks" then
      M.pick_bookmark(nil)
    elseif action.kind == "folder" then
      M.browse()
    elseif action.kind == "settings" then
      M.settings(changed)
    end
  end, "open")
  map("a", function()
    vim.ui.input({ prompt = "Book path: ", completion = "file" }, function(path)
      if path and path ~= "" then
        Reader.open(vim.fn.expand(path))
      end
    end)
  end, "open a file")
  map("f", function()
    M.browse()
  end, "browse folders")
  map("b", function()
    M.pick_bookmark(nil)
  end, "bookmarks")
  map("s", function()
    M.settings(changed)
  end, "settings")
  map("x", function()
    local action = action_here()
    if not action or action.kind ~= "book" then
      return notify("Move to a book line first")
    end
    vim.ui.select({ "Remove from shelf", "Cancel" }, { prompt = "Forget this book? Bookmarks stay." }, function(choice)
      if choice == "Remove from shelf" then
        Library.forget(action.path)
        changed()
      end
    end)
  end, "forget book")
  map("r", changed, "refresh")
  map("q", function()
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.cmd("bdelete")
    end
  end, "close")
  return buf
end

return M
