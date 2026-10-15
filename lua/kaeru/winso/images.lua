-- Winso pictures: the system viewer, and colored ASCII views inside Neovim.

local Ascii = require("kaeru.winso.ascii")
local Config = require("kaeru.winso.config")
local Library = require("kaeru.winso.library")
local Loader = require("kaeru.winso.loader")
local Platform = require("kaeru.winso.platform")
local Theme = require("kaeru.winso.theme")

local M = {}

local NS = vim.api.nvim_create_namespace("kaeru.winso.picture")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Winso" })
end

--- Path of a picture extracted for a book.
---@param book table
---@param name string  placeholder name, e.g. 001-cover.png
---@return string
function M.picture_path(book, name)
  return book.image_dir .. "/" .. name
end

--- Open a picture in the system viewer.
---@param path string
function M.open_external(path)
  Platform.open_external(path)
end

--- Grid columns for a picture view in a window `width` cells wide.
---@param width integer
---@return integer
function M.cols(width)
  return math.max(16, math.min(Config.defaults.picture_cols, (width or 80) - 4))
end

--- Color grid of one picture from the extractor. `cb(err, grid)`.
---@param path string
---@param cols integer
---@param cb fun(err: string|nil, grid: table|nil)
function M.grid(path, cols, cb)
  local py = Loader.python()
  if not py then
    return cb("Winso needs python3 to draw pictures", nil)
  end
  require("kaeru.process").run({ py, Loader.extractor_path(), "--ascii", path, "--cols", tostring(cols) }, function(res)
    if res.code ~= 0 then
      local msg = (res.stderr ~= "" and res.stderr or res.stdout):gsub("%s+$", "")
      return cb(msg ~= "" and msg or ("extractor failed (" .. res.code .. ")"), nil)
    end
    local ok, grid = pcall(vim.json.decode, res.stdout)
    if not ok or type(grid) ~= "table" then
      return cb("could not read the picture grid", nil)
    end
    cb(nil, grid)
  end)
end

--- Open a picture as colored ASCII in a new tab.
---@param book table
---@param name string
---@param width? integer  window width the view should fit
function M.view(book, name, width)
  local path = M.picture_path(book, name)
  local cols = M.cols(width)
  M.grid(path, cols, function(err, grid)
    if err then
      return notify("Winso: " .. err, vim.log.levels.ERROR)
    end
    local theme = Theme.get(Library.setting("theme", Theme.default))
    local art, render_err = Ascii.render(grid, { invert = theme.invert })
    if not art then
      return notify("Winso: " .. render_err, vim.log.levels.ERROR)
    end
    local cubes = {}
    for _, run in ipairs(art.runs) do
      cubes[run.cube] = true
    end
    Ascii.define_groups(cubes)

    vim.cmd("tabnew")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "winso-picture"
    pcall(vim.api.nvim_buf_set_name, buf, "winso://picture/" .. name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, art.lines)
    for _, run in ipairs(art.runs) do
      vim.api.nvim_buf_add_highlight(buf, NS, Ascii.group_name(run.cube), run.row - 1, run.start, run.finish)
    end
    vim.bo[buf].modifiable = false
    vim.wo.wrap = false
    vim.wo.number = false
    vim.wo.cursorline = false
    vim.wo.winbar = ("%%#KaeruWinsoBar# Picture · %s · %dx%d (%d cells wide) %%*"):format(
      (name:gsub("%%", "%%%%")), grid.width or 0, grid.height or 0, #art.lines[1] or 0
    )
    Theme.apply(Library.setting("theme", Theme.default), 0)

    local function close()
      if #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd("tabclose")
      else
        vim.cmd("bdelete")
      end
    end
    local opts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Winso: close picture" }))
    vim.keymap.set("n", "o", function()
      M.open_external(path)
    end, vim.tbl_extend("force", opts, { desc = "Winso: open picture in the system viewer" }))
  end)
end

return M
