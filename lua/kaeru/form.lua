-- The `:Kaeru` modal: a floating form whose fields map to a lazy.nvim spec.
local UI = require("kaeru.ui")
local Spec = require("kaeru.spec")
local Config = require("kaeru.config")

local M = {}

---@class KaeruField
---@field key string
---@field label string
---@field hint string

---@type KaeruField[]
M.fields = {
  { key = "repo", label = "Repository", hint = "owner/repo or a git URL (required)" },
  { key = "file", label = "File", hint = "lua/plugins/<file>.lua  (auto from repo)" },
  { key = "name", label = "Name", hint = "custom plugin name (optional)" },
  { key = "lazy", label = "Lazy", hint = "true / false" },
  { key = "event", label = "Event", hint = "VeryLazy, BufReadPre, InsertEnter ...  (comma separated)" },
  { key = "cmd", label = "Cmd", hint = "Telescope, Neotree ...  (lazy-load on command)" },
  { key = "ft", label = "Ft", hint = "lua, markdown ...  (lazy-load on filetype)" },
  { key = "keys", label = "Keys", hint = "<leader>ff, <C-n> ...  (lazy-load on keys)" },
  { key = "dependencies", label = "Dependencies", hint = "nvim-lua/plenary.nvim, ..." },
  { key = "version", label = "Version", hint = "semver range, * = latest release, false = branch head" },
  { key = "branch", label = "Branch", hint = "git branch" },
  { key = "tag", label = "Tag", hint = "git tag" },
  { key = "commit", label = "Commit", hint = "git commit" },
  { key = "priority", label = "Priority", hint = "number, e.g. 1000 for colorschemes" },
  { key = "build", label = "Build", hint = ":TSUpdate, make, ...  (runs after install/update)" },
  { key = "opts", label = "Opts", hint = "{ } Lua table -> require(main).setup(opts)" },
  { key = "config", label = "Config", hint = "true, `function` for a skeleton, or raw function(...) end" },
  { key = "init", label = "Init", hint = "raw function() ... end, runs at startup (vim.g.* settings)" },
  { key = "pin", label = "Pin", hint = "true to exclude from updates" },
}

local LABEL_WIDTH = 13
local PREFIX_LEN = 2 + LABEL_WIDTH + 3 -- "  " .. label .. " : "

---@class KaeruFormState
---@field buf integer
---@field win integer
---@field on_submit fun(form: KaeruForm): boolean
local State = nil

--- Collapse newlines into spaces so `nvim_buf_set_lines` never errors on multi-line values.
---@param value? string
---@return string
function M.sanitize_value(value)
  local s = tostring(value or "")
  s = s:gsub("\r\n", "\n"):gsub("%s*\n%s*", " ")
  return s
end

---@param field KaeruField
---@param value string
---@return string
local function format_line(field, value)
  return string.format("  %-" .. LABEL_WIDTH .. "s : %s", field.label, M.sanitize_value(value))
end

---@param line string
---@return string
local function value_of(line)
  local sep = line:find(" : ", 1, true)
  if sep then
    return line:sub(sep + 3)
  end
  -- label was mangled; treat the whole line as the value
  return (line:gsub("^%s+", ""))
end

local function valid()
  return State and vim.api.nvim_buf_is_valid(State.buf) and vim.api.nvim_win_is_valid(State.win)
end

--- Read the current field values from the buffer.
---@return KaeruForm
function M.read()
  local form = {}
  if not valid() then
    return form
  end
  local lines = vim.api.nvim_buf_get_lines(State.buf, 0, -1, false)
  for i, field in ipairs(M.fields) do
    form[field.key] = lines[i] and value_of(lines[i]) or ""
  end
  return form
end

--- Apply label highlights and hints.
local function decorate()
  if not valid() then
    return
  end
  local buf = State.buf
  vim.api.nvim_buf_clear_namespace(buf, UI.ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, field in ipairs(M.fields) do
    local line = lines[i] or ""
    local sep = line:find(" : ", 1, true)
    if sep then
      local label_hl = field.key == "repo" and "Title" or "Identifier"
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 0, { end_col = sep - 1, hl_group = label_hl })
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, sep - 1, { end_col = sep + 2, hl_group = "Delimiter" })
      if value_of(line) == "" then
        vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 0, {
          virt_text = { { field.hint, "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
  local last = #M.fields - 1
  vim.api.nvim_buf_set_extmark(buf, UI.ns, last, 0, {
    virt_lines = {
      { { "" } },
      {
        { "  <CR>/<C-s> ", "Special" },
        { "install  ", "Comment" },
        { "gs/:w ", "Special" },
        { "save  ", "Comment" },
        { "<Tab>/<S-Tab> ", "Special" },
        { "field/complete  ", "Comment" },
        { "<C-Space> ", "Special" },
        { "autocomplete  ", "Comment" },
        { "<C-r> ", "Special" },
        { "parse README  ", "Comment" },
        { "<C-b> ", "Special" },
        { "browse  ", "Comment" },
        { "q ", "Special" },
        { "close", "Comment" },
      },
    },
  })
end

--- Make sure there are exactly #fields lines and labels are intact.
local function repair()
  if not valid() then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(State.buf, 0, -1, false)
  if #lines == #M.fields then
    local ok = true
    for i, field in ipairs(M.fields) do
      if not lines[i]:find(format_line(field, ""), 1, true) then
        ok = false
        break
      end
    end
    if ok then
      return
    end
  end
  -- Rebuild preserving whatever values we can recover by label.
  local values = {}
  for _, line in ipairs(lines) do
    for _, field in ipairs(M.fields) do
      if line:find("^%s*" .. field.label .. "%s*:") and values[field.key] == nil then
        values[field.key] = value_of(line)
      end
    end
  end
  local new = {}
  for i, field in ipairs(M.fields) do
    new[i] = format_line(field, values[field.key] or "")
  end
  local cursor = vim.api.nvim_win_get_cursor(State.win)
  vim.api.nvim_buf_set_lines(State.buf, 0, -1, false, new)
  cursor[1] = math.min(cursor[1], #new)
  pcall(vim.api.nvim_win_set_cursor, State.win, cursor)
end

local function clamp_cursor()
  if not valid() then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(State.win)
  if cur[2] < PREFIX_LEN then
    pcall(vim.api.nvim_win_set_cursor, State.win, { cur[1], PREFIX_LEN })
  end
end

---@param delta integer
local function move_field(delta)
  if not valid() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(State.win)[1]
  row = ((row - 1 + delta) % #M.fields) + 1
  local line = vim.api.nvim_buf_get_lines(State.buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(State.win, { row, #line })
end

---@param row? integer
local function edit_field(row)
  if not valid() then
    return
  end
  row = row or vim.api.nvim_win_get_cursor(State.win)[1]
  local line = vim.api.nvim_buf_get_lines(State.buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(State.win, { row, #line })
  vim.cmd("startinsert!")
end

function M.close()
  if State then
    local win = State.win
    State = nil
    UI.close(win)
  end
end

---@param key string
---@param value string
function M.set(key, value)
  if not valid() then
    return
  end
  for i, field in ipairs(M.fields) do
    if field.key == key then
      vim.api.nvim_buf_set_lines(State.buf, i - 1, i, false, { format_line(field, value) })
      decorate()
      return
    end
  end
end

--- Apply multiple fields from a parsed form table without overwriting user-populated fields unless `overwrite` is true.
---@param values KaeruForm
---@param overwrite? boolean
function M.fill(values, overwrite)
  if not valid() or type(values) ~= "table" then
    return
  end
  local current = M.read()
  for _, field in ipairs(M.fields) do
    local k = field.key
    if values[k] and values[k] ~= "" then
      if overwrite or not current[k] or Spec._trim(current[k]) == "" then
        M.set(k, values[k])
      end
    end
  end
end

local function parse_readme_into_form()
  if not valid() then
    return
  end
  local repo = Spec._trim(M.read().repo)
  if repo == "" then
    UI.notify("Enter a repository (owner/repo) first, then press <C-r> to parse its README.md", vim.log.levels.WARN)
    return
  end
  local Parser = require("kaeru.parser")
  UI.notify("Parsing README.md for " .. repo .. "…")
  Parser.parse_github(repo, function(err, res)
    if not valid() then
      return
    end
    if err then
      return UI.notify("Could not fetch README: " .. err, vim.log.levels.ERROR)
    end
    if not res or not res.primary then
      return UI.notify("No install snippet found in " .. repo .. " README.md", vim.log.levels.WARN)
    end
    M.fill(res.primary, true)
    UI.notify(("Filled spec fields from %s README.md (%s)"):format(repo, res.primary_manager or "detected"))
  end)
end

local function submit(action_opts)
  if not valid() then
    return false
  end
  vim.cmd("stopinsert")
  local form = M.read()
  if Spec._trim(form.repo) == "" then
    UI.notify("Repository is required", vim.log.levels.WARN)
    edit_field(1)
    return false
  end
  local on_submit = State.on_submit
  local ok = on_submit(form, action_opts)
  if ok then
    vim.bo[State.buf].modified = false
    if not (action_opts and action_opts.keep_open) then
      M.close()
    end
  end
  return ok
end

local function save_only()
  return submit({ after_write = "none" })
end

local function browse()
  if not valid() then
    return
  end
  vim.cmd("stopinsert")
  local query = Spec._trim(M.read().repo)
  local win = State.win
  require("kaeru.browser").open({
    query = query,
    on_choose = function(repo)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        M.set("repo", repo.full_name)
        M.set("file", "")
        vim.api.nvim_win_set_cursor(win, { 2, PREFIX_LEN })
      end
    end,
  })
end

---@class KaeruFormOpenOpts
---@field values? KaeruForm       prefilled values
---@field on_submit fun(form: KaeruForm, action_opts?: table): boolean  return true to close the modal

---@param opts KaeruFormOpenOpts|KaeruForm
---@param on_submit_fn? fun(form: KaeruForm, action_opts?: table): boolean
function M.open(opts, on_submit_fn)
  opts = opts or {}
  if on_submit_fn or (opts.values == nil and opts.on_submit == nil and next(opts) ~= nil) then
    opts = { values = opts, on_submit = on_submit_fn }
  end
  M.close()

  local width = 84
  local height = #M.fields + 2
  local buf, win = UI.open({
    title = "kaeru.nvim · add a plugin to lazy.nvim",
    width = width,
    height = height,
    filetype = "kaeru-form",
  })
  State = { buf = buf, win = win, on_submit = opts.on_submit or function()
    return true
  end }

  local lines = {}
  for i, field in ipairs(M.fields) do
    lines[i] = format_line(field, (opts.values or {})[field.key] or "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = 100
  pcall(vim.api.nvim_buf_set_name, buf, "kaeru://spec")
  vim.bo[buf].omnifunc = "v:lua.require'kaeru.complete'.omnifunc"
  vim.bo[buf].completefunc = "v:lua.require'kaeru.complete'.omnifunc"
  decorate()

  local Complete = require("kaeru.complete")

  -- keymaps -------------------------------------------------------------
  local map = function(lhs, rhs, modes, desc)
    UI.map(buf, lhs, rhs, modes, desc)
  end
  map("<CR>", function()
    submit()
  end, "n", "Write spec & install")
  map("<C-s>", function()
    submit()
  end, { "n", "i" }, "Write spec & install")
  map("gs", save_only, "n", "Save spec file only")
  map("<C-w>", save_only, { "n", "i" }, "Save spec file only")
  map("q", M.close, "n", "Close")
  map("<Esc>", M.close, "n", "Close")
  map("<C-b>", browse, { "n", "i" }, "Browse GitHub")
  map("<C-r>", parse_readme_into_form, { "n", "i" }, "Parse README.md for repo")
  map("gp", parse_readme_into_form, "n", "Parse README.md for repo")
  map("<C-Space>", function()
    Complete.trigger(buf, win, true)
  end, "i", "Trigger autocomplete")
  map("<C-@>", function()
    Complete.trigger(buf, win, true)
  end, "i", "Trigger autocomplete")
  map("<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, false, true), "n", false)
    else
      move_field(1)
    end
  end, { "n", "i" }, "Next field / completion")
  map("<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, false, true), "n", false)
    else
      move_field(-1)
    end
  end, { "n", "i" }, "Previous field / completion")
  map("<CR>", function()
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-y>", true, false, true), "n", false)
    else
      move_field(1)
    end
  end, "i", "Confirm completion / next field")
  map("<Down>", function()
    move_field(1)
  end, "i", "Next field")
  map("<Up>", function()
    move_field(-1)
  end, "i", "Previous field")
  -- insert helpers: always edit the value, never the label
  for _, lhs in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    map(lhs, function()
      edit_field()
    end, "n", "Edit field")
  end
  map("dd", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    M.set(M.fields[row].key, "")
    vim.api.nvim_win_set_cursor(win, { row, PREFIX_LEN })
  end, "n", "Clear field")
  vim.keymap.set("i", "<BS>", function()
    local col = vim.api.nvim_win_get_cursor(win)[2]
    return col > PREFIX_LEN and "<BS>" or ""
  end, { buffer = buf, expr = true, nowait = true })

  -- autocmds ------------------------------------------------------------
  local group = vim.api.nvim_create_augroup("kaeru.form." .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      submit()
    end,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = buf,
    callback = function()
      repair()
      decorate()
      vim.bo[buf].modified = false
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      repair()
      decorate()
      vim.bo[buf].modified = false
      if Config.options.ui and Config.options.ui.autocomplete ~= false then
        if vim.fn.pumvisible() == 0 then
          Complete.trigger(buf, win, false)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    group = group,
    buffer = buf,
    callback = clamp_cursor,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if State and State.buf == buf then
        State = nil
      end
    end,
  })

  -- start editing the repository field
  edit_field(1)
end

function M.is_open()
  return valid()
end

return M
