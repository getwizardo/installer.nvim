-- Winso: a built-in eBook reader for Neovim.
--
-- Reads epub, fb2 (also .fb2.zip), mobi/azw/azw3 (needs Calibre's ebook-convert), pdf (needs
-- pdftotext), docx, html, md and txt. Book parsing happens in `winso/extract.py` (Python
-- standard library only); plain text and Markdown also work without Python.
--
-- Reader keys (inside the Winso tab):
--   n / p      next / previous chapter       t   table of contents
--   /          search the whole book         b   add a bookmark here
--   B          list this book's bookmarks    + / -  wider / narrower text
--   i          book info                     q   close (progress is saved)
--
-- Progress and bookmarks are stored in stdpath("data")/winso/library.json.
-- On Termux (`TERMUX_VERSION` set) the reader uses a narrower column and a full tab.

local Json = require("kaeru.json")

local M = {}

M.formats = { "epub", "fb2", "fb2.zip", "mobi", "azw", "azw3", "pdf", "docx", "html", "htm", "md", "markdown", "txt" }

M.defaults = {
  width = nil,     -- text column; nil = automatic
  max_width = 80,  -- desktop cap
  termux_width = 60,
}

local state = {
  buffers = {},  -- bufnr -> { book=, chapter=, width=, starts= }
}

-- ---------------------------------------------------------------------------------------
-- environment

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

-- ---------------------------------------------------------------------------------------
-- text layout (pure)

-- one UTF-8 character (works without the utf8 library, e.g. in LuaJIT test runs)
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function text_width(s)
  if not s:find("[\128-\255]") then
    return #s
  end
  if vim and vim.fn and vim.fn.strdisplaywidth then
    return vim.fn.strdisplaywidth(s)
  end
  local _, n = s:gsub(CHAR, "")
  return n
end

--- Split one word that is wider than `width` into pieces of at most `width` characters.
local function split_long(word, width)
  local pieces, current, count = {}, "", 0
  for ch in word:gmatch(CHAR) do
    if count >= width then
      pieces[#pieces + 1] = current
      current, count = "", 0
    end
    current = current .. ch
    count = count + 1
  end
  if current ~= "" then
    pieces[#pieces + 1] = current
  end
  return pieces
end

--- Word-wrap plain text. Paragraphs are separated by blank lines in the output.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(10, width or 60)
  local out = {}
  local paragraphs = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then
      paragraphs[#paragraphs + 1] = line
    elseif #paragraphs > 0 and paragraphs[#paragraphs] ~= "" then
      paragraphs[#paragraphs + 1] = ""
    end
  end
  for index, para in ipairs(paragraphs) do
    local image = para:match("^%[%[image: (.-)%]%]$")
    if para == "" then
      out[#out + 1] = ""
    elseif image then
      -- a picture is one line, never wrapped, so `o` can find its name
      out[#out + 1] = "[image: " .. image .. "]"
    else
      -- `current_width` is tracked incrementally: measuring each whole candidate line
      -- again made wrapping a long book several times slower.
      local current, current_width = "", 0
      for word in para:gmatch("%S+") do
        local word_width = text_width(word)
        local pieces = { word }
        if word_width > width then
          pieces = split_long(word, width)
        end
        for piece_index, piece in ipairs(pieces) do
          if piece_index > 1 then
            out[#out + 1] = current
            current, current_width = "", 0
          end
          local piece_width = #pieces == 1 and word_width or text_width(piece)
          if current == "" then
            current, current_width = piece, piece_width
          elseif current_width + 1 + piece_width > width then
            out[#out + 1] = current
            current, current_width = piece, piece_width
          else
            current, current_width = current .. " " .. piece, current_width + 1 + piece_width
          end
        end
      end
      if current ~= "" then
        out[#out + 1] = current
      end
      if index < #paragraphs and paragraphs[index + 1] ~= "" then
        out[#out + 1] = ""
      end
    end
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

--- Lines for one chapter, with a heading. `starts` is not needed by callers; `line_of` maps
--- a paragraph-line index in the chapter to its line in the returned table.
---@param book table
---@param index integer
---@param width integer
---@return string[] lines
function M.render_chapter(book, index, width)
  local chapter = book.chapters[index]
  local title = chapter.title or ("Chapter " .. index)
  local body = chapter.text or ""
  -- books often repeat the chapter title as the first paragraph; the heading already shows it
  local first, rest = body:match("^([^\n]*)\n*(.*)$")
  if first and first:gsub("%s+$", "") == title then
    body = rest
  end
  local lines = { ("== %s =="):format(title), "" }
  for _, line in ipairs(M.wrap(body, width)) do
    lines[#lines + 1] = line
  end
  return lines
end

--- Search every chapter, case-insensitive. Returns up to `limit` hits.
---@param book table
---@param query string
---@param limit? integer
---@return {chapter:integer, line:integer, text:string}[]
function M.search(book, query, limit)
  limit = limit or 200
  local hits = {}
  local needle = query:lower()
  if needle == "" then
    return hits
  end
  for ci, chapter in ipairs(book.chapters) do
    local n = 0
    for line in ((chapter.text or "") .. "\n"):gmatch("([^\n]*)\n") do
      n = n + 1
      if line:lower():find(needle, 1, true) then
        hits[#hits + 1] = { chapter = ci, line = n, text = line }
        if #hits >= limit then
          return hits
        end
      end
    end
  end
  return hits
end

--- Book facts for `:Winso info`.
---@param book table
---@return string[]
function M.info_lines(book)
  local words = 0
  for _, chapter in ipairs(book.chapters) do
    for _ in (chapter.text or ""):gmatch("%S+") do
      words = words + 1
    end
  end
  return {
    "Title:    " .. (book.title ~= "" and book.title or "(untitled)"),
    "Author:   " .. (book.author ~= "" and book.author or "(unknown)"),
    "Format:   " .. (book.format or "?"),
    "Chapters: " .. #book.chapters,
    ("Words:    about %d"):format(words),
    "Images:   " .. #(book.images or {}),
    "File:     " .. (book.path or "?"),
  }
end

-- ---------------------------------------------------------------------------------------
-- library: progress and bookmarks

--- Read the library file. Missing or broken files give an empty library.
---@param path? string
---@return table
function M.read_library(path)
  path = path or M.library_path()
  local fd = io.open(path, "r")
  if not fd then
    return { books = {}, bookmarks = {} }
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= "table" then
    return { books = {}, bookmarks = {} }
  end
  data.books = data.books or {}
  data.bookmarks = data.bookmarks or {}
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

-- ---------------------------------------------------------------------------------------
-- loading

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
    local hint = M.install_hints(M.is_termux())
    return cb("Winso needs python3 to read books (" .. hint.python .. ")", nil)
  end
  local image_dir = M.image_cache_dir(path)
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

-- ---------------------------------------------------------------------------------------
-- reader window

local function reader_width()
  local lib_width = vim.g.winso_width
  if type(lib_width) == "number" then
    return lib_width
  end
  if M.defaults.width then
    return M.defaults.width
  end
  local cols = vim.o.columns or 80
  local cap = M.is_termux() and M.defaults.termux_width or M.defaults.max_width
  return math.max(20, math.min(cols - 2, cap))
end

local function save_progress(st)
  if not st or not st.book then
    return
  end
  -- the cursor is the truth while the reader is open
  local win = st.buf and vim.fn.bufwinid(st.buf) or -1
  if win ~= -1 then
    st.line = vim.api.nvim_win_get_cursor(win)[1]
  end
  local lib = M.read_library()
  lib.books[st.book.path] = {
    title = st.book.title,
    chapter = st.chapter,
    line = st.line or 1,
    width = st.width,
    last = os.time(),
  }
  M.write_library(lib)
end

local function refresh_winbar(st, win)
  local count = #st.book.chapters
  local pct = count > 0 and math.floor((st.chapter / count) * 100 + 0.5) or 0
  local text = (" Winso · %s · %d/%d · %d%% "):format(st.book.title, st.chapter, count, pct)
  -- winbar is a statusline format: a literal % must be doubled
  text = text:gsub("%%", "%%%%")
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].winbar = text
    end)
  end
end

local function render_into(st)
  local lines = M.render_chapter(st.book, st.chapter, st.width)
  local buf = st.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  refresh_winbar(st, vim.fn.bufwinid(buf))
end

local function goto_chapter(st, index, line)
  index = math.max(1, math.min(#st.book.chapters, index))
  st.chapter = index
  render_into(st)
  local win = vim.fn.bufwinid(st.buf)
  local total = vim.api.nvim_buf_line_count(st.buf)
  local target = math.max(1, math.min(total, line or 1))
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
  st.line = target
  save_progress(st)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Winso: " .. desc })
end

--- Text of the nearest non-blank line to `row`, searching outward. Empty if the book has none.
---@param buf integer
---@param row integer  1-based
---@return string
local function nearest_text(buf, row)
  local total = vim.api.nvim_buf_line_count(buf)
  for offset = 0, total - 1 do
    for _, r in ipairs({ row + offset, row - offset }) do
      if r >= 1 and r <= total then
        local text = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1]
        if text:match("%S") then
          return text
        end
      end
    end
  end
  return ""
end

local function attach_keys(buf)
  local function st()
    return state.buffers[buf]
  end
  map(buf, "n", function()
    goto_chapter(st(), st().chapter + 1, 1)
  end, "next chapter")
  map(buf, "p", function()
    goto_chapter(st(), st().chapter - 1, 1)
  end, "previous chapter")
  map(buf, "t", function()
    local s = st()
    local titles = {}
    for i, chapter in ipairs(s.book.chapters) do
      titles[#titles + 1] = ("%3d  %s"):format(i, chapter.title)
    end
    vim.ui.select(titles, { prompt = "Contents" }, function(_, idx)
      if idx then
        goto_chapter(s, idx, 1)
      end
    end)
  end, "table of contents")
  map(buf, "b", function()
    local s = st()
    local line = nearest_text(buf, vim.api.nvim_win_get_cursor(0)[1])
    local lib = M.read_library()
    lib.bookmarks[s.book.path] = lib.bookmarks[s.book.path] or {}
    table.insert(lib.bookmarks[s.book.path], {
      chapter = s.chapter,
      line = vim.api.nvim_win_get_cursor(0)[1],
      label = line:sub(1, 60),
      created = os.time(),
    })
    M.write_library(lib)
    notify("Bookmark added")
  end, "add bookmark")
  map(buf, "B", function()
    local s = st()
    local lib = M.read_library()
    local marks = lib.bookmarks[s.book.path] or {}
    if #marks == 0 then
      return notify("No bookmarks in this book yet (press b to add one)")
    end
    local labels = {}
    for _, m in ipairs(marks) do
      labels[#labels + 1] = ("ch %d: %s"):format(m.chapter, m.label)
    end
    vim.ui.select(labels, { prompt = "Bookmarks" }, function(_, idx)
      if idx then
        goto_chapter(s, marks[idx].chapter, marks[idx].line)
      end
    end)
  end, "list bookmarks")
  map(buf, "/", function()
    local s = st()
    vim.ui.input({ prompt = "Search book: " }, function(query)
      if not query or query == "" then
        return
      end
      local hits = M.search(s.book, query, 200)
      if #hits == 0 then
        return notify("No matches for '" .. query .. "'")
      end
      local labels = {}
      for _, h in ipairs(hits) do
        labels[#labels + 1] = ("ch %d: %s"):format(h.chapter, h.text:sub(1, 70))
      end
      vim.ui.select(labels, { prompt = #hits .. " match(es)" }, function(_, idx)
        if idx then
          goto_chapter(s, hits[idx].chapter, hits[idx].line + 2)
        end
      end)
    end)
  end, "search")
  local function resize(delta)
    local s = st()
    local ratio = (vim.api.nvim_win_get_cursor(0)[1]) / math.max(1, vim.api.nvim_buf_line_count(buf))
    s.width = math.max(20, math.min(160, s.width + delta))
    vim.g.winso_width = s.width
    render_into(s)
    local line = math.max(1, math.floor(ratio * vim.api.nvim_buf_line_count(buf)))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end
  map(buf, "+", function()
    resize(4)
  end, "wider text")
  map(buf, "-", function()
    resize(-4)
  end, "narrower text")
  map(buf, "o", function()
    local s = st()
    local name = vim.api.nvim_get_current_line():match("^%[image: (.-)%]$")
    if not name then
      return notify("No picture on this line (picture lines look like [image: name])")
    end
    M.open_external(s.book.image_dir .. "/" .. name)
  end, "open picture")
  map(buf, "i", function()
    local s = st()
    local lines = M.info_lines(s.book)
    notify(table.concat(lines, "\n"))
  end, "book info")
  map(buf, "q", function()
    local s = st()
    save_progress(s)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.cmd("bdelete")
    end
  end, "close")
end

--- Open a loaded book in a new tab at its saved position.
---@param book table
---@param opts? {chapter?: integer, line?: integer}
function M.show(book, opts)
  opts = opts or {}
  local lib = M.read_library()
  local saved = lib.books[book.path] or {}
  local st = {
    book = book,
    chapter = opts.chapter or saved.chapter or 1,
    line = opts.line or saved.line or 1,
    width = reader_width(),
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
  state.buffers[buf] = st
  attach_keys(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      save_progress(state.buffers[buf])
      state.buffers[buf] = nil
    end,
  })
  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.cursorline = false
  goto_chapter(st, st.chapter, st.line)
end

--- Load and open a book file, showing a message on failure.
---@param path string
function M.open(path)
  notify("Opening " .. vim.fn.fnamemodify(path, ":t") .. " …")
  M.load(path, function(err, book)
    if err then
      return notify("Winso: " .. err, vim.log.levels.ERROR)
    end
    M.show(book)
  end)
end

--- Recently read books from the library, newest first.
---@return table[]
function M.recent()
  local lib = M.read_library()
  local items = {}
  for path, entry in pairs(lib.books) do
    items[#items + 1] = { path = path, title = entry.title or path, chapter = entry.chapter or 1, last = entry.last or 0 }
  end
  table.sort(items, function(a, b)
    return a.last > b.last
  end)
  return items
end

-- ---------------------------------------------------------------------------------------
-- command

--- `:Winso [open <path>|library|bookmarks|search <text>|info|<path>]`
---@param args string[]
function M.command(args)
  local action = args[1]
  if action == nil or action == "" or action == "library" then
    local items = M.recent()
    if #items == 0 then
      return notify("Library is empty. Open a book with :Winso <path>")
    end
    local labels = {}
    for _, item in ipairs(items) do
      labels[#labels + 1] = ("%s  (chapter %d)"):format(item.title, item.chapter)
    end
    return vim.ui.select(labels, { prompt = "Winso library" }, function(_, idx)
      if idx then
        M.open(items[idx].path)
      end
    end)
  elseif action == "open" then
    local path = table.concat(vim.list_slice(args, 2), " ")
    if path == "" then
      return notify("usage: :Winso open <path>", vim.log.levels.ERROR)
    end
    return M.open(path)
  elseif action == "bookmarks" then
    local lib = M.read_library()
    local all = {}
    for path, marks in pairs(lib.bookmarks) do
      for _, m in ipairs(marks) do
        all[#all + 1] = { path = path, mark = m }
      end
    end
    if #all == 0 then
      return notify("No bookmarks yet (press b while reading)")
    end
    local labels = {}
    for _, item in ipairs(all) do
      labels[#labels + 1] = ("%s · ch %d: %s"):format(vim.fn.fnamemodify(item.path, ":t"), item.mark.chapter, item.mark.label)
    end
    return vim.ui.select(labels, { prompt = "Bookmarks" }, function(_, idx)
      if idx then
        M.load(all[idx].path, function(err, book)
          if err then
            return notify(err, vim.log.levels.ERROR)
          end
          M.show(book, { chapter = all[idx].mark.chapter, line = all[idx].mark.line })
        end)
      end
    end)
  elseif action == "images" or action == "cover" then
    local buf = vim.api.nvim_get_current_buf()
    local st = state.buffers[buf]
    if not st or not st.book then
      return notify("Open a book first", vim.log.levels.WARN)
    end
    local images = st.book.images or {}
    if #images == 0 then
      return notify("This book has no embedded pictures")
    end
    if action == "cover" then
      local pick = images[1]
      for _, img in ipairs(images) do
        if img.name:lower():find("cover", 1, true) then
          pick = img
          break
        end
      end
      return M.open_external(st.book.image_dir .. "/" .. pick.name)
    end
    local labels = {}
    for _, img in ipairs(images) do
      labels[#labels + 1] = ("%s  %dx%d"):format(img.name, img.width, img.height)
    end
    return vim.ui.select(labels, { prompt = "Pictures" }, function(_, idx)
      if idx then
        M.open_external(st.book.image_dir .. "/" .. images[idx].name)
      end
    end)
  elseif action == "info" then
    local buf = vim.api.nvim_get_current_buf()
    local st = state.buffers[buf]
    if not st then
      return notify("Open a book first", vim.log.levels.WARN)
    end
    return notify(table.concat(M.info_lines(st.book), "\n"))
  elseif action == "search" then
    local buf = vim.api.nvim_get_current_buf()
    local st = state.buffers[buf]
    if not st then
      return notify("Open a book first", vim.log.levels.WARN)
    end
    local query = table.concat(vim.list_slice(args, 2), " ")
    local hits = M.search(st.book, query, 200)
    if #hits == 0 then
      return notify("No matches for '" .. query .. "'")
    end
    local labels = {}
    for _, h in ipairs(hits) do
      labels[#labels + 1] = ("ch %d: %s"):format(h.chapter, h.text:sub(1, 70))
    end
    return vim.ui.select(labels, { prompt = #hits .. " match(es)" }, function(_, idx)
      if idx then
        goto_chapter(st, hits[idx].chapter, hits[idx].line + 2)
      end
    end)
  else
    return M.open(table.concat(args, " "))
  end
end

M._state = state

return M
