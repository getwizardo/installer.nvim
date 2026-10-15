-- Winso loader: runs the Python extractor (winso/extract.py) and parses its JSON.

local Json = require("kaeru.json")
local Platform = require("kaeru.winso.platform")

local M = {}

--- Parse extractor output (vim.json when available, Lua decoder otherwise).
---@param text string
---@return table|nil book, string|nil err
function M.parse_extract(text)
  local ok, data
  if vim.json and vim.json.decode then
    ok, data = pcall(vim.json.decode, text)
  else
    ok, data = pcall(Json.decode, text)
  end
  if not ok or type(data) ~= "table" or type(data.chapters) ~= "table" then
    return nil, "could not read the book (extractor output was not valid)"
  end
  return data, nil
end

local function extractor_path()
  local found = vim.api.nvim_get_runtime_file("lua/kaeru/winso/extract.py", false)
  return found[1]
end

local function python()
  return vim.fn.exepath("python3") ~= "" and "python3" or (vim.fn.exepath("python") ~= "" and "python" or nil)
end

M.python = python
M.extractor_path = extractor_path

--- Load a book. `cb(err, book)`.
---@param path string
---@param cb fun(err: string|nil, book: table|nil)
function M.load(path, cb)
  path = vim.fn.fnamemodify(path, ":p")
  local fd = io.open(path, "rb")
  if not fd then
    return cb("cannot open " .. path, nil)
  end
  fd:close()
  local py = python()
  local script = extractor_path()
  if not py or not script then
    local hint = Platform.install_hints(Platform.is_termux())
    return cb("Winso needs python3 to read books (" .. hint.python .. ")", nil)
  end
  local image_dir = Platform.image_cache_dir(path)
  require("kaeru.process").run({ py, script, path, "--images", image_dir }, function(res)
    if res.code ~= 0 then
      local msg = (res.stderr ~= "" and res.stderr or res.stdout):gsub("%s+$", "")
      return cb(msg ~= "" and msg or ("extractor failed (" .. res.code .. ")"), nil)
    end
    local book, err = M.parse_extract(res.stdout)
    if not book then
      return cb(err, nil)
    end
    book.path = path
    book.image_dir = image_dir
    book.title = (book.title and book.title ~= "") and book.title or vim.fn.fnamemodify(path, ":t:r")
    book.author = book.author or ""
    book.format = book.format or ""
    cb(nil, book)
  end)
end

return M
