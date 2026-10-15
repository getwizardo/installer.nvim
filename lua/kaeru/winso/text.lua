-- Winso text: word wrap, chapter layout, search and book facts. Pure Lua (no editor calls
-- except the optional display-width helper), so the lupa test runner can load it.

local M = {}

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

--- Text of the nearest non-blank line to `row`, searching outward. Empty if the buffer has none.
---@param buf integer
---@param row integer  1-based
---@return string
function M.nearest_text(buf, row)
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

return M
