-- Winso command dispatch: `:Kaeru winso [action]`, `:Winso [action]`.

local Images = require("kaeru.winso.images")
local Reader = require("kaeru.winso.reader")
local Shelf = require("kaeru.winso.shelf")
local Text = require("kaeru.winso.text")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

--- The open reader, or a warning when the current tab is not a book.
---@return table|nil
local function reader_or_warn()
  local st = Reader.current()
  if not st then
    notify("Open a book first", vim.log.levels.WARN)
  end
  return st
end

--- Cover name: the first picture with "cover" in its name, else the first picture.
---@param images table[]
---@return table
local function cover_of(images)
  for _, img in ipairs(images) do
    if img.name:lower():find("cover", 1, true) then
      return img
    end
  end
  return images[1]
end

local function pick_picture(book, on_pick)
  local labels = {}
  for _, img in ipairs(book.images) do
    labels[#labels + 1] = ("%s  %dx%d"):format(img.name, img.width, img.height)
  end
  vim.ui.select(labels, { prompt = "Pictures" }, function(_, idx)
    if idx then
      on_pick(book.images[idx])
    end
  end)
end

--- Run a Winso command from its arguments (e.g. { "search", "dragon" }).
---@param args string[]
function M.command(args)
  local action = args[1]
  if action == nil or action == "" or action == "library" or action == "shelf" then
    return Shelf.open()
  elseif action == "open" then
    local path = table.concat(vim.list_slice(args, 2), " ")
    if path == "" then
      return notify("usage: :Winso open <path>", vim.log.levels.ERROR)
    end
    return Reader.open(path)
  elseif action == "bookmarks" then
    return Shelf.pick_bookmark(nil)
  elseif action == "images" then
    local st = reader_or_warn()
    if not st then
      return
    end
    if #(st.book.images or {}) == 0 then
      return notify("This book has no embedded pictures")
    end
    return pick_picture(st.book, function(img)
      Images.open_external(Images.picture_path(st.book, img.name))
    end)
  elseif action == "cover" then
    local st = reader_or_warn()
    if not st then
      return
    end
    if #(st.book.images or {}) == 0 then
      return notify("This book has no embedded pictures")
    end
    return Images.open_external(Images.picture_path(st.book, cover_of(st.book.images).name))
  elseif action == "ascii" then
    local st = reader_or_warn()
    if not st then
      return
    end
    if #(st.book.images or {}) == 0 then
      return notify("This book has no embedded pictures")
    end
    local wanted = args[2]
    if wanted then
      return Images.view(st.book, wanted, vim.api.nvim_win_get_width(0))
    end
    return pick_picture(st.book, function(img)
      Images.view(st.book, img.name, vim.api.nvim_win_get_width(0))
    end)
  elseif action == "info" then
    local st = reader_or_warn()
    if not st then
      return
    end
    return notify(table.concat(Text.info_lines(st.book), "\n"))
  elseif action == "search" then
    local st = reader_or_warn()
    if not st then
      return
    end
    local query = table.concat(vim.list_slice(args, 2), " ")
    local hits = Text.search(st.book, query, 200)
    if #hits == 0 then
      return notify("No matches for '" .. query .. "'")
    end
    local labels = {}
    for _, h in ipairs(hits) do
      labels[#labels + 1] = ("ch %d: %s"):format(h.chapter, h.text:sub(1, 70))
    end
    return vim.ui.select(labels, { prompt = #hits .. " match(es)" }, function(_, idx)
      if idx then
        Reader.goto_chapter(st, hits[idx].chapter, hits[idx].line + 2)
      end
    end)
  end
  return Reader.open(table.concat(args, " "))
end

return M
