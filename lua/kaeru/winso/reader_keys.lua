-- Winso reader keys. Every key is buffer-local to a reader tab.

local M = {}

local HELP = {
  "n / p      next / previous chapter",
  "t          table of contents",
  "/          search the whole book",
  "b / B      add a bookmark / list bookmarks",
  "+ / -      wider / narrower text",
  "T          next theme (night, paper, sepia)",
  "o          open the picture on this line in the system viewer",
  "v          view the picture on this line as colored ASCII",
  "i          book info",
  "S          shelf (library, folders, settings)",
  "q          close (progress is saved)",
}

--- Bind the reader keys for a buffer.
---@param buf integer
---@param reader table  the kaeru.winso.reader module
function M.attach(buf, reader)
  local function st()
    return reader.buffers[buf]
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Winso: " .. desc })
  end
  local function notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
  end

  map("n", function()
    reader.goto_chapter(st(), st().chapter + 1, 1)
  end, "next chapter")
  map("p", function()
    reader.goto_chapter(st(), st().chapter - 1, 1)
  end, "previous chapter")
  map("t", function()
    local s = st()
    local titles = {}
    for i, chapter in ipairs(s.book.chapters) do
      titles[#titles + 1] = ("%3d  %s"):format(i, chapter.title)
    end
    vim.ui.select(titles, { prompt = "Contents" }, function(_, idx)
      if idx then
        reader.goto_chapter(s, idx, 1)
      end
    end)
  end, "table of contents")
  map("b", function()
    local s = st()
    local here = vim.api.nvim_win_get_cursor(0)[1]
    require("kaeru.winso.library").add_bookmark(s.book.path, {
      chapter = s.chapter,
      line = here,
      label = require("kaeru.winso.text").nearest_text(buf, here):sub(1, 60),
    })
    notify("Bookmark added")
  end, "add bookmark")
  map("B", function()
    require("kaeru.winso.shelf").pick_bookmark(st().book.path)
  end, "list bookmarks")
  map("/", function()
    local s = st()
    vim.ui.input({ prompt = "Search book: " }, function(query)
      if not query or query == "" then
        return
      end
      local hits = require("kaeru.winso.text").search(s.book, query, 200)
      if #hits == 0 then
        return notify("No matches for '" .. query .. "'")
      end
      local labels = {}
      for _, h in ipairs(hits) do
        labels[#labels + 1] = ("ch %d: %s"):format(h.chapter, h.text:sub(1, 70))
      end
      vim.ui.select(labels, { prompt = #hits .. " match(es)" }, function(_, idx)
        if idx then
          reader.goto_chapter(s, hits[idx].chapter, hits[idx].line + 2)
        end
      end)
    end)
  end, "search")
  map("+", function()
    reader.resize(st(), 4)
  end, "wider text")
  map("-", function()
    reader.resize(st(), -4)
  end, "narrower text")
  map("T", function()
    local library = require("kaeru.winso.library")
    local theme = require("kaeru.winso.theme")
    local current = library.setting("theme", theme.default)
    local next_name = theme.order[1]
    for i, name in ipairs(theme.order) do
      if name == current then
        next_name = theme.order[i % #theme.order + 1]
      end
    end
    library.set_setting("theme", next_name)
    theme.apply(next_name, 0)
    notify("Theme: " .. next_name)
  end, "next theme")
  map("o", function()
    local name = vim.api.nvim_get_current_line():match("^%[image: (.-)%]$")
    if not name then
      return notify("No picture on this line (picture lines look like [image: name])")
    end
    require("kaeru.winso.images").open_external(require("kaeru.winso.images").picture_path(st().book, name))
  end, "open picture")
  map("v", function()
    local name = vim.api.nvim_get_current_line():match("^%[image: (.-)%]$")
    if not name then
      return notify("No picture on this line (picture lines look like [image: name])")
    end
    require("kaeru.winso.images").view(st().book, name, vim.api.nvim_win_get_width(0))
  end, "view picture as ASCII")
  map("i", function()
    notify(table.concat(require("kaeru.winso.text").info_lines(st().book), "\n"))
  end, "book info")
  map("S", function()
    require("kaeru.winso.shelf").open()
  end, "shelf")
  map("?", function()
    notify("Winso keys:\n  " .. table.concat(HELP, "\n  "))
  end, "help")
  map("q", function()
    reader.save_progress(st())
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.cmd("bdelete")
    end
  end, "close")
end

return M
