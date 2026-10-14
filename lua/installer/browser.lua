-- `:Installer browse` - search GitHub for Neovim plugins and pick one.
local UI = require("installer.ui")
local Config = require("installer.config")
local GitHub = require("installer.github")

local M = {}

local uv = vim.uv or vim.loop

local SORTS = { "stars", "updated", "best-match" }

---@class InstallerBrowserState
---@field prompt_buf integer
---@field prompt_win integer
---@field list_buf integer
---@field list_win integer
---@field preview_win? integer
---@field query string
---@field page integer
---@field sort string
---@field broad boolean
---@field items InstallerRepo[]
---@field total integer
---@field loading boolean
---@field error? string
---@field request integer
---@field timer? uv_timer_t
---@field on_choose fun(repo: InstallerRepo)
---@field closing boolean
local State = nil

local function valid()
  return State
    and vim.api.nvim_buf_is_valid(State.list_buf)
    and vim.api.nvim_win_is_valid(State.list_win)
    and vim.api.nvim_win_is_valid(State.prompt_win)
end

local NAME_WIDTH = 34

---@param n integer
---@return string
local function thousands(n)
  local s = tostring(n)
  repeat
    local k
    s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return s
end

local function status_text()
  local s = State
  if s.loading then
    return "  Searching GitHub…"
  elseif s.error then
    return "  " .. s.error
  end
  local per_page = math.min(Config.options.github.per_page, 100)
  local pages = math.max(1, math.ceil(math.min(s.total, 1000) / per_page))
  return string.format(
    "  %s results · page %d/%d · sort: %s · scope: %s",
    thousands(s.total),
    s.page,
    pages,
    s.sort,
    s.broad and "all of GitHub" or Config.options.github.topic_query
  )
end

local function render()
  if not valid() then
    return
  end
  local s = State
  local lines = { status_text() }
  local name_len = {}
  local width = vim.api.nvim_win_get_width(s.list_win)
  for i, item in ipairs(s.items) do
    local stars = string.format("%6s", GitHub.format_stars(item.stars))
    local name = item.full_name
    if #name > NAME_WIDTH then
      name = name:sub(1, NAME_WIDTH - 1) .. "…"
    end
    name_len[i] = #name
    local desc = item.description:gsub("%s+", " ")
    if item.archived then
      desc = "[archived] " .. desc
    end
    local line = string.format(" %s  %-" .. NAME_WIDTH .. "s  %s", stars, name, desc)
    if vim.fn.strdisplaywidth(line) > width then
      line = vim.fn.strcharpart(line, 0, width - 1) .. "…"
    end
    lines[#lines + 1] = line
  end
  if #s.items == 0 and not s.loading and not s.error then
    lines[#lines + 1] = "  No plugins found. Press `t` to search all of GitHub."
  end

  UI.set_lines(s.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(s.list_buf, UI.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.list_buf, UI.ns, 0, 0, {
    end_col = #lines[1],
    hl_group = s.error and "WarningMsg" or "Comment",
  })
  for i, item in ipairs(s.items) do
    local row = i -- 0-based row == i because of the status line
    vim.api.nvim_buf_set_extmark(s.list_buf, UI.ns, row, 0, { end_col = 7, hl_group = "Number" })
    vim.api.nvim_buf_set_extmark(s.list_buf, UI.ns, row, 9, {
      end_col = 9 + name_len[i],
      hl_group = "Title",
      strict = false,
    })
    if item.archived then
      vim.api.nvim_buf_set_extmark(s.list_buf, UI.ns, row, 9 + NAME_WIDTH + 2, {
        end_col = 9 + NAME_WIDTH + 2 + #"[archived]",
        hl_group = "WarningMsg",
        strict = false,
      })
    end
  end

  -- keep cursor on a result row
  local cur = vim.api.nvim_win_get_cursor(s.list_win)[1]
  local max = math.max(2, #lines)
  cur = math.max(2, math.min(cur, max))
  pcall(vim.api.nvim_win_set_cursor, s.list_win, { cur, 0 })
end

local function search()
  if not valid() then
    return
  end
  local s = State
  s.request = s.request + 1
  local id = s.request
  s.loading = true
  s.error = nil
  render()
  GitHub.search({ query = s.query, page = s.page, sort = s.sort, broad = s.broad }, function(err, result)
    if not valid() or State.request ~= id then
      return
    end
    State.loading = false
    if err then
      State.error = err
      State.items = {}
      State.total = 0
    else
      State.items = result.items
      State.total = result.total
    end
    render()
    if not err then
      pcall(vim.api.nvim_win_set_cursor, State.list_win, { 2, 0 })
    end
  end)
end

local function schedule_search()
  if not valid() then
    return
  end
  local s = State
  if s.timer then
    s.timer:stop()
  else
    s.timer = assert(uv.new_timer())
  end
  s.timer:start(Config.options.github.debounce, 0, function()
    vim.schedule(function()
      if not valid() then
        return
      end
      local text = vim.api.nvim_buf_get_lines(State.prompt_buf, 0, 1, false)[1] or ""
      text = vim.trim(text)
      if text ~= State.query then
        State.query = text
        State.page = 1
      end
      search()
    end)
  end)
end

---@return InstallerRepo|nil
local function current()
  if not valid() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(State.list_win)[1]
  return State.items[row - 1]
end

function M.close()
  if not State or State.closing then
    return
  end
  State.closing = true
  local s = State
  State = nil
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  UI.close(s.preview_win)
  UI.close(s.prompt_win)
  UI.close(s.list_win)
  vim.cmd("stopinsert")
end

local function focus_prompt()
  if valid() then
    vim.api.nvim_set_current_win(State.prompt_win)
    vim.cmd("startinsert!")
  end
end

local function focus_list()
  if valid() then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(State.list_win)
  end
end

---@param delta integer
local function move(delta)
  if not valid() then
    return
  end
  local s = State
  local row = vim.api.nvim_win_get_cursor(s.list_win)[1] + delta
  row = math.max(2, math.min(row, #s.items + 1))
  pcall(vim.api.nvim_win_set_cursor, s.list_win, { row, 0 })
end

---@param delta integer
local function change_page(delta)
  if not valid() then
    return
  end
  local s = State
  local per_page = math.min(Config.options.github.per_page, 100)
  local pages = math.max(1, math.ceil(math.min(s.total, 1000) / per_page))
  local page = math.max(1, math.min(s.page + delta, pages))
  if page ~= s.page then
    s.page = page
    search()
  end
end

local function choose()
  local repo = current()
  if not repo then
    return
  end
  local cb = State.on_choose
  M.close()
  cb(repo)
end

local function quick_install()
  local repo = current()
  if not repo then
    return
  end
  M.close()
  require("installer").add({ repo = repo.full_name })
end

local function open_in_browser()
  local repo = current()
  if not repo then
    return
  end
  if vim.ui.open then
    vim.ui.open(repo.url)
  else
    vim.fn["netrw#BrowseX"](repo.url, 0)
  end
end

local function yank()
  local repo = current()
  if repo then
    vim.fn.setreg('"', repo.full_name)
    vim.fn.setreg("+", repo.full_name)
    UI.notify("Yanked " .. repo.full_name)
  end
end

local function preview()
  local repo = current()
  if not repo or not valid() then
    return
  end
  local s = State
  UI.close(s.preview_win)
  local cfg = vim.api.nvim_win_get_config(s.list_win)
  local buf, win = UI.open({
    title = repo.full_name .. " · README",
    width = cfg.width,
    height = cfg.height,
    row = type(cfg.row) == "table" and cfg.row[false] or cfg.row,
    col = type(cfg.col) == "table" and cfg.col[false] or cfg.col,
    filetype = "markdown",
    zindex = 60,
  })
  s.preview_win = win
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  UI.set_lines(buf, { "Loading README…" })
  vim.bo[buf].modifiable = false
  local function close_preview()
    UI.close(win)
    if valid() then
      State.preview_win = nil
      vim.api.nvim_set_current_win(State.list_win)
    end
  end
  UI.map(buf, "q", close_preview)
  UI.map(buf, "<Esc>", close_preview)
  UI.map(buf, "<CR>", function()
    close_preview()
    choose()
  end)
  UI.map(buf, "i", function()
    close_preview()
    quick_install()
  end)
  GitHub.readme(repo.full_name, function(err, text)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.split(err or text or "", "\n", { plain = true })
    UI.set_lines(buf, lines)
  end)
end

local function cycle_sort()
  if not valid() then
    return
  end
  local s = State
  for i, sort in ipairs(SORTS) do
    if sort == s.sort then
      s.sort = SORTS[(i % #SORTS) + 1]
      break
    end
  end
  s.page = 1
  search()
end

local function toggle_broad()
  if not valid() then
    return
  end
  State.broad = not State.broad
  State.page = 1
  search()
end

local function show_help()
  UI.notify(table.concat({
    "GitHub browser keys:",
    "  <CR>      open the install modal with this plugin",
    "  i         quick install with a bare spec",
    "  K         preview README",
    "  o         open on GitHub",
    "  y         yank owner/repo",
    "  ]  / [    next / previous page",
    "  s         cycle sort (stars, updated, best-match)",
    "  t         toggle scope (topic:neovim-plugin / all of GitHub)",
    "  / <Tab>   focus the search prompt",
    "  q <Esc>   close",
  }, "\n"))
end

---@class InstallerBrowserOpts
---@field query? string
---@field on_choose? fun(repo: InstallerRepo)

---@param opts? InstallerBrowserOpts
function M.open(opts)
  opts = opts or {}
  M.close()

  local ui = Config.options.ui
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local width = math.max(60, math.min(UI.size(ui.width, cols), cols - 4))
  width = math.max(width, math.min(cols - 4, 100))
  local height = math.max(10, math.min(UI.size(ui.height, lines), lines - 4))
  local row = math.floor((lines - height) / 2)
  local col = math.floor((cols - width) / 2)

  local list_buf, list_win = UI.open({
    title = "GitHub · Neovim plugins",
    width = width,
    height = height - 3,
    row = row + 3,
    col = col,
    filetype = "installer-browser",
    enter = false,
  })
  vim.wo[list_win].cursorline = true
  vim.bo[list_buf].modifiable = false

  local prompt_buf, prompt_win = UI.open({
    title = "Search",
    width = width,
    height = 1,
    row = row,
    col = col,
    filetype = "installer-prompt",
  })
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { opts.query or "" })

  State = {
    prompt_buf = prompt_buf,
    prompt_win = prompt_win,
    list_buf = list_buf,
    list_win = list_win,
    query = vim.trim(opts.query or ""),
    page = 1,
    sort = Config.options.github.sort,
    broad = false,
    items = {},
    total = 0,
    loading = false,
    request = 0,
    closing = false,
    on_choose = opts.on_choose or function(repo)
      require("installer").open({ repo = repo.full_name })
    end,
  }

  -- prompt hint
  vim.api.nvim_buf_set_extmark(prompt_buf, UI.ns, 0, 0, {
    virt_text = { { "  type to search · <CR>/<Tab> results · <C-n>/<C-p> move · <Esc><Esc> close", "Comment" } },
    virt_text_pos = "eol",
    id = 1,
  })

  -- prompt keymaps --------------------------------------------------------
  local pmap = function(lhs, rhs, modes)
    UI.map(prompt_buf, lhs, rhs, modes)
  end
  pmap("<CR>", focus_list, { "i", "n" })
  pmap("<Tab>", focus_list, { "i", "n" })
  pmap("<Down>", focus_list, { "i", "n" })
  pmap("<C-n>", function()
    move(1)
  end, { "i", "n" })
  pmap("<C-p>", function()
    move(-1)
  end, { "i", "n" })
  pmap("<C-c>", M.close, { "i", "n" })
  pmap("<Esc>", M.close, "n")
  pmap("q", M.close, "n")

  -- list keymaps ----------------------------------------------------------
  local lmap = function(lhs, rhs, desc)
    UI.map(list_buf, lhs, rhs, "n", desc)
  end
  lmap("<CR>", choose, "Open install modal")
  lmap("i", quick_install, "Quick install")
  lmap("K", preview, "Preview README")
  lmap("o", open_in_browser, "Open on GitHub")
  lmap("y", yank, "Yank owner/repo")
  lmap("]", function()
    change_page(1)
  end, "Next page")
  lmap("[", function()
    change_page(-1)
  end, "Previous page")
  lmap("s", cycle_sort, "Cycle sort")
  lmap("t", toggle_broad, "Toggle scope")
  lmap("/", focus_prompt, "Focus prompt")
  lmap("<Tab>", focus_prompt, "Focus prompt")
  lmap("?", show_help, "Help")
  lmap("q", M.close, "Close")
  lmap("<Esc>", M.close, "Close")
  lmap("<C-c>", M.close, "Close")

  -- autocmds --------------------------------------------------------------
  local group = vim.api.nvim_create_augroup("installer.browser", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    group = group,
    buffer = prompt_buf,
    callback = function()
      -- keep the prompt single-line
      local plines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
      if #plines > 1 then
        vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { table.concat(plines, " ") })
      end
      schedule_search()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(prompt_win), tostring(list_win) },
    callback = function()
      vim.schedule(M.close)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = list_buf,
    callback = function()
      if valid() then
        local cur = vim.api.nvim_win_get_cursor(State.list_win)[1]
        if cur < 2 and #State.items > 0 then
          pcall(vim.api.nvim_win_set_cursor, State.list_win, { 2, 0 })
        end
      end
    end,
  })

  focus_prompt()
  search()
end

function M.is_open()
  return valid()
end

return M
