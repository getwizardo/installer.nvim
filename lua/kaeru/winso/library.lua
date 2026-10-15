-- Winso library: reading progress, bookmarks and settings in stdpath("data")/winso/library.json.

local Json = require("kaeru.json")

local M = {}

--- Read the library file. Missing or broken files give an empty library.
---@param path? string
---@return table
function M.read_library(path)
  path = path or M.library_path()
  local fd = io.open(path, "r")
  if not fd then
    return { books = {}, bookmarks = {}, settings = {} }
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= "table" then
    return { books = {}, bookmarks = {}, settings = {} }
  end
  data.books = data.books or {}
  data.bookmarks = data.bookmarks or {}
  data.settings = data.settings or {}
  return data
end

--- Write the library file, creating its directory.
---@param lib table
---@param path? string
---@return boolean ok, string? err
function M.write_library(lib, path)
  path = path or M.library_path()
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local fd, err = io.open(path, "w")
  if not fd then
    return false, tostring(err)
  end
  fd:write(Json.encode(lib))
  fd:close()
  return true
end

function M.library_path()
  return vim.fn.stdpath("data") .. "/winso/library.json"
end

--- Save where the reader is in a book. `chapters` is the book's chapter count, so the
--- shelf can show a percentage without opening the book.
---@param path string
---@param fields {title: string, chapter: integer, line: integer, width: integer|nil, chapters: integer}
function M.record_progress(path, fields)
  local lib = M.read_library()
  lib.books[path] = {
    title = fields.title,
    chapter = fields.chapter,
    line = fields.line or 1,
    width = fields.width,
    chapters = fields.chapters,
    last = os.time(),
  }
  return M.write_library(lib)
end

--- Reading progress as a fraction in [0, 1], or nil when the book was never opened.
---@param entry table|nil  a library entry
---@return number|nil
function M.fraction(entry)
  if not entry or not entry.chapters or entry.chapters < 1 then
    return nil
  end
  return math.min(1, math.max(0, (entry.chapter or 1) / entry.chapters))
end

--- Add a bookmark for a book.
---@param path string
---@param mark {chapter: integer, line: integer, label: string}
---@return boolean ok, string|nil err
function M.add_bookmark(path, mark)
  local lib = M.read_library()
  lib.bookmarks[path] = lib.bookmarks[path] or {}
  table.insert(lib.bookmarks[path], {
    chapter = mark.chapter,
    line = mark.line,
    label = mark.label,
    created = os.time(),
  })
  return M.write_library(lib)
end

--- Every bookmark, as { path, mark } pairs.
---@return {path: string, mark: table}[]
function M.all_bookmarks()
  local lib = M.read_library()
  local all = {}
  for path, marks in pairs(lib.bookmarks) do
    for _, mark in ipairs(marks) do
      all[#all + 1] = { path = path, mark = mark }
    end
  end
  table.sort(all, function(a, b)
    return (a.mark.created or 0) > (b.mark.created or 0)
  end)
  return all
end

--- Remove a book from the shelf. Its bookmarks stay; the file is not touched.
---@param path string
---@return boolean ok, string|nil err
function M.forget(path)
  local lib = M.read_library()
  lib.books[path] = nil
  return M.write_library(lib)
end

--- A setting, or `default` when it was never set.
---@param key string
---@param default any
---@return any
function M.setting(key, default)
  local value = M.read_library().settings[key]
  if value == nil then
    return default
  end
  return value
end

---@param key string
---@param value any
---@return boolean ok, string|nil err
function M.set_setting(key, value)
  local lib = M.read_library()
  lib.settings[key] = value
  return M.write_library(lib)
end

--- Recently read books from the library, newest first.
---@return table[]  { path, title, chapter, chapters, last }
function M.recent()
  local lib = M.read_library()
  local items = {}
  for path, entry in pairs(lib.books) do
    items[#items + 1] = {
      path = path,
      title = entry.title or path,
      chapter = entry.chapter or 1,
      chapters = entry.chapters,
      last = entry.last or 0,
    }
  end
  table.sort(items, function(a, b)
    return a.last > b.last
  end)
  return items
end

return M
