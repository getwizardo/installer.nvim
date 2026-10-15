-- kaeru.nvim · completion for every command Neovim itself has.
--
-- `complete.lua` knows our own commands (`:Kaeru`, `:Kikru`, `:Clina`). This
-- module knows *every other* `:` command: for each of them the argument
-- position decides what can follow, exactly like Neovim's own `<Tab>` but with
-- fuzzy ranking, descriptions and a single flat item list.
--
--   :set <Tab>            → every option (+ `no…`, `inv…` variants)
--   :set number=<Tab>     → the values Neovim accepts for that option
--   :au BufW<Tab>         → autocmd events
--   :au BufWritePost <Tab>→ `*`, patterns, then the command to run
--   :colorscheme <Tab>    → installed colorschemes
--   :e ++<Tab>            → `++enc=`, `++ff=`, `++bin`, …
--   :help <Tab>           → help tags
--   :lua <Tab> / :call <Tab> / :packadd <Tab> / :checkhealth <Tab> / …
--
-- Anything outside those tables still completes: `complete.any = true` falls
-- back to `everything()` in `complete.lua`, which merges every category
-- `getcompletion()` supports (files, buffers, options, events, filetypes,
-- colorschemes, help tags, mappings, syntax items, functions, environment,
-- augroups, tags, menu items, …).
--
-- Every `vim.fn.*` and `getcompletion` access is guarded, so the module loads
-- and degrades to an empty list in bare Lua (the test harness) too.
local Compat = require("kaeru.compat")

local M = {}

---@class KaeruNativePlan
---@field type string   `getcompletion()` category (or a local pseudo category)
---@field menu string   what the popup shows in the menu column
---@field prefix? string prepended to the completion (e.g. `++`)

-- ---------------------------------------------------------------------------
-- command tables
-- ---------------------------------------------------------------------------

local FILE_COMMANDS = {
  "e", "edit", "ex", "vi", "vim", "view", "visual",
  "sp", "split", "vs", "vsplit", "sview", "tabnew", "tabe", "tabedit", "tabview",
  "new", "vnew", "enew", "read", "r", "write", "w", "wq", "x", "xit", "saveas",
  "badd", "drop", "pedit", "tcl", "perl", "python", "ruby", "lua?", "source", "so",
  "mksession", "ms", "mkvimrc", "scriptnames", "diffsplit", "diffpatch", "tabfind",
  "hardcopy", "tohtml", "saveas",
}

local FILE_IN_PATH = { "find", "sfind", "tabfind", "grep", "vimgrep", "lgrep", "lvimgrep", "vimgrepadd" }
local DIR_COMMANDS = { "cd", "lcd", "tcd", "chdir", "lchdir", "tchdir" }
local OPTION_COMMANDS = { "set", "setl", "setlocal", "setg", "setglobal", "setfiletype" }
local EVENT_COMMANDS = { "au", "autocmd" }
local COLOR_COMMANDS = { "colo", "colorscheme" }
local HELP_COMMANDS = { "h", "help", "helpfind", "helpgrep" }
local BUFFER_COMMANDS = { "b", "buffer", "sb", "sbuffer", "bdel", "bdelete", "bw", "bwipeout", "bunload" }
local FUNCTION_COMMANDS = { "call", "delf", "delfunction" }
local LUA_COMMANDS = { "lua", "luado", "luafile" }
local SYNTAX_COMMANDS = { "syn", "syntax" }
local HIGHLIGHT_COMMANDS = { "hi", "highlight" }
local AUGROUP_COMMANDS = { "aug", "augroup" }
local SIGN_COMMANDS = { "sign" }
local PACKADD_COMMANDS = { "packadd", "packdel", "packloadall" }
local MENU_COMMANDS = { "menu", "noremenu", "an", "amenu", "nmenu", "vmenu", "imenu", "cmenu", "tmenu", "aunmenu", "nunmenu", "iunmenu", "vunmenu", "cunmenu", "tunmenu" }
local COMPILER_COMMANDS = { "compiler", "comp" }
local CHECKHEALTH_COMMANDS = { "checkhealth", "che" }
local RUNTIME_COMMANDS = { "runtime", "ru" }
local HISTORY_COMMANDS = { "history", "his" }
local MESSAGE_COMMANDS = { "messages", "mes" }
local COMMAND_COMMANDS = { "command", "com", "delcommand", "delc", "comclear" }
local SHELL_COMMANDS = { "!", "terminal", "term", "make", "lmake", "grep", "grepadd", "lgrep", "lgrepadd", "copen" }
local VAR_COMMANDS = { "let", "unlet", "const" }
local TAG_COMMANDS = { "tag", "tjump", "tselect", "tnext", "tprevious", "ptag" }
local LSP_COMMANDS = { "lsp", "lspconfig", "checkhealth" }

local MAP_PREFIXES = {
  "", "n", "v", "x", "s", "o", "i", "l", "c", "t",
}
local MAP_SUFFIXES = { "map", "noremap", "unmap", "mapclear", "abbrev", "noreabbrev", "unabbrev", "abclear" }

local MAP_ATTRIBUTES = {
  "<buffer>", "<nowait>", "<silent>", "<special>", "<script>", "<expr>", "<unique>",
  "<cmd>", "<Plug>", "<SID>", "<leader>", "<localleader>", "<C-", "<A-", "<M-",
}

local FILE_MODIFIERS = {
  "++bin", "++nobin", "++edit", "++ff=unix", "++ff=dos", "++ff=mac", "++enc=utf-8",
  "++enc=latin1", "++p", "++opt=", "++bad=", "++noswap", "++swapfile",
}

local OPTION_VALUES = {
  background = { "dark", "light" },
  ff = { "unix", "dos", "mac" },
  fileformat = { "unix", "dos", "mac" },
  fenc = { "utf-8", "utf-16", "latin1" },
  fileencoding = { "utf-8", "utf-16", "latin1" },
  encoding = { "utf-8", "utf-16" },
  clipboard = { "unnamed", "unnamedplus", "yes", "no" },
  mouse = { "a", "n", "v", "i", "c", "h" },
  foldmethod = { "manual", "indent", "syntax", "expr", "marker", "diff" },
  foldenable = { "on", "off" },
  number = { "on", "off" },
  relativenumber = { "on", "off" },
  wrap = { "on", "off" },
  spell = { "on", "off" },
  list = { "on", "off" },
  ignorecase = { "on", "off" },
  smartcase = { "on", "off" },
  hlsearch = { "on", "off" },
  incsearch = { "on", "off" },
  signcolumn = { "yes", "no", "auto", "auto:1", "auto:2", "auto:3", "number" },
  cursorline = { "on", "off" },
  termguicolors = { "on", "off" },
  backup = { "on", "off" },
  swapfile = { "on", "off" },
  undofile = { "on", "off" },
  expandtab = { "on", "off" },
  shiftwidth = { "0", "2", "4", "8" },
  tabstop = { "2", "4", "8" },
  softtabstop = { "0", "2", "4", "8" },
  textwidth = { "0", "72", "80", "100", "120" },
  syntax = { "on", "off", "enable", "clear" },
  conceallevel = { "0", "1", "2", "3" },
  title = { "on", "off" },
  linebreak = { "on", "off" },
  scrolloff = { "0", "3", "5", "8", "10" },
  sidescrolloff = { "0", "3", "5", "8", "10" },
  laststatus = { "0", "1", "2", "3" },
  cmdheight = { "0", "1", "2" },
  completeopt = { "menu", "menuone", "noselect", "noinsert", "preview", "fuzzy", "popup" },
  virtualedit = { "onemore", "block", "all", "insert", "none" },
  guicursor = { "a:block", "n:block", "i:ver25" },
}

local SYNTAX_KEYWORDS = {
  "on", "off", "enable", "clear", "reset", "case", "match", "keyword", "region", "sync",
  "list", "include", "cluster", "conceal", "foldlevel", "iskeyword", "spell", "cchar",
  "contained", "contains", "nextgroup", "transparent", "skipwhite", "concealends",
}

local SIGN_KEYWORDS = { "define", "undefine", "list", "place", "unplace", "jump", "group" }

local AUTO_PATTERNS = { "*", "*.lua", "*.vim", "*.md", "*.json", "*.py", "*.ts", "*.js", "*.rs", "*.go", "*.toml", "*.yaml" }

local COMMAND_ATTRIBUTES = {
  "-nargs=*", "-nargs=?", "-nargs=+", "-nargs=1", "-nargs=0",
  "-range", "-range=%", "-count", "-bang", "-bar", "-register",
  "-buffer", "-complete=file", "-complete=dir", "-complete=buffer", "-complete=option",
  "-complete=event", "-complete=color", "-complete=command", "-complete=filetype", "-complete=custom,",
  "-addr=lines", "-addr=buffers", "-keepscript", "-keepjumps", "-bar",
}

-- Commands before the real one that we must skip (`:silent! windo …`).
local MODIFIERS = {
  "silent", "silent!", "unsilent", "verbose", "debug", "noautocmd", "keepalt",
  "keepjumps", "keepmarks", "keeppatterns", "lockmarks", "sandbox", "confirm",
  "browse", "hide", "vertical", "aboveleft", "belowright", "topleft", "botright",
  "leftabove", "rightbelow", "windo", "bufdo", "tabdo", "argdo", "cdo", "ldo",
  "cfdo", "lfdo", "foldopen", "foldclose", "folddoopen", "folddoclosed", "legacy",
  "horizontal", "tab", "noswapfile", "noautocmd",
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function contains(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

local function map_command_prefix(command)
  -- `nnoremap` → prefix `n`, suffix `noremap`
  for _, prefix in ipairs(MAP_PREFIXES) do
    for _, suffix in ipairs(MAP_SUFFIXES) do
      if command == prefix .. suffix then
        return prefix, suffix
      end
    end
  end
  return nil
end

---@param base string
---@param category string
---@param menu string
---@return KaeruCompletionItem[]
local function items(base, category, menu)
  local out = {}
  for _, word in ipairs(Compat.getcompletion(base or "", category)) do
    if word ~= "" then
      out[#out + 1] = { word = word, menu = "[" .. menu .. "]", kind = category }
    end
  end
  return out
end

---@param words string[]
---@param menu string
---@return KaeruCompletionItem[]
local function words_items(words, menu, arglead)
  local out = {}
  local lead = (arglead or ""):lower()
  for _, word in ipairs(words) do
    if lead == "" or word:lower():sub(1, #lead) == lead or word:lower():find(lead, 1, true) then
      out[#out + 1] = { word = word, menu = "[" .. menu .. "]" }
    end
  end
  return out
end

--- Split a `:` line into the command and its arguments, skipping modifiers.
--- Handles ranges, `|` chaining, `:` prefixes and bang.
---@param line string
---@return string command, string[] args, string arglead
function M.parse(line)
  local text = tostring(line or ""):gsub("^%s*:?", "")
  -- a range / count before the command
  text = text:gsub("^%%", ""):gsub("^'?[%w<>%.,%$%+%-]*%s+", "%1", 1)
  text = text:gsub("^[%d%,%.%$%+%-'<>]+%s*", "")
  -- chained commands: only the last one matters
  local _, last = text:match("^(.-)|(.*)$")
  if last then
    text = last:gsub("^%s*:?", "")
  end
  local tokens = {}
  for token in text:gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  local command = table.remove(tokens, 1) or ""
  -- `silent! windo set nu` → keep unwrapping
  local guard = 0
  while command ~= "" and contains(MODIFIERS, command) and guard < 16 do
    command = table.remove(tokens, 1) or ""
    guard = guard + 1
  end
  local arglead = text:match("(%S*)$") or ""
  if arglead == command and #tokens == 0 then
    arglead = ""
  end
  return command, tokens, arglead
end

-- ---------------------------------------------------------------------------
-- the planner: what may follow the current command?
-- ---------------------------------------------------------------------------

---@param command string
---@param args string[]
---@param arglead string
---@return KaeruNativePlan[]|nil  nil = "unknown command"
function M.plan(command, args, arglead)
  local position = #args

  if command == "" then
    return { { type = "command", menu = "command" } }
  end

  if contains(OPTION_COMMANDS, command) then
    if arglead:find("=", 1, true) then
      local name = arglead:match("^([%w_%-]+)=")
      local values = name and OPTION_VALUES[name]
      if values then
        local out = {}
        for _, value in ipairs(values) do
          out[#out + 1] = { word = name .. "=" .. value, menu = "[value]" }
        end
        return { { type = "static", menu = "value", items = out } }
      end
      return { { type = "option", menu = "option value" } }
    end
    return { { type = "option", menu = "option" } }
  end

  if contains(EVENT_COMMANDS, command) then
    if arglead:match("^%u") or position == 0 then
      return { { type = "event", menu = "autocmd event" } }
    end
    if position == 1 then
      return {
        { type = "static", menu = "pattern", items = words_items(AUTO_PATTERNS, "pattern", arglead) },
        { type = "buffer", menu = "buffer" },
        { type = "filetype", menu = "filetype" },
      }
    end
    return { { type = "command", menu = "autocmd command" } }
  end

  if command == "doautocmd" or command == "doautoall" then
    return { { type = "event", menu = "autocmd event" } }
  end

  if contains(AUGROUP_COMMANDS, command) then
    return { { type = "augroup", menu = "augroup" } }
  end

  if contains(COLOR_COMMANDS, command) then
    return { { type = "color", menu = "colorscheme" } }
  end

  if contains(HELP_COMMANDS, command) then
    return { { type = "help", menu = "help tag" } }
  end

  if contains(BUFFER_COMMANDS, command) then
    return { { type = "buffer", menu = "buffer" } }
  end

  if contains(FUNCTION_COMMANDS, command) then
    return { { type = "function", menu = "function" } }
  end

  local lua_command = contains(LUA_COMMANDS, command)
  if lua_command then
    if command == "luafile" then
      return { { type = "file", menu = "lua file" } }
    end
    return { { type = "lua", menu = "lua" } }
  end

  if contains(SYNTAX_COMMANDS, command) then
    if position == 0 then
      return { { type = "static", menu = "syntax", items = words_items(SYNTAX_KEYWORDS, "syntax", arglead) } }
    end
    return { { type = "syntax", menu = "syntax group" } }
  end

  if contains(HIGHLIGHT_COMMANDS, command) then
    if position == 0 then
      return { { type = "highlight", menu = "highlight group" } }
    end
    return {
      { type = "highlight", menu = "highlight group" },
      { type = "static", menu = "highlight key", items = words_items({ "cterm", "ctermfg", "ctermbg", "ctermul", "gui", "guifg", "guibg", "guisp", "font", "default", "link", "clear", "NONE" }, "highlight key", arglead) },
    }
  end

  if contains(SIGN_COMMANDS, command) then
    if position == 0 then
      return { { type = "static", menu = "sign action", items = words_items(SIGN_KEYWORDS, "sign", arglead) } }
    end
    if args[1] == "group" then
      return { { type = "augroup", menu = "sign group" } }
    end
    return { { type = "file", menu = "file" }, { type = "buffer", menu = "buffer" } }
  end

  if contains(PACKADD_COMMANDS, command) then
    return { { type = "packadd", menu = "package" } }
  end

  if contains(MENU_COMMANDS, command) then
    return { { type = "menu", menu = "menu item" } }
  end

  if contains(COMPILER_COMMANDS, command) then
    return { { type = "compiler", menu = "compiler" } }
  end

  if contains(CHECKHEALTH_COMMANDS, command) then
    return { { type = "checkhealth", menu = "checkhealth" } }
  end

  if contains(RUNTIME_COMMANDS, command) then
    return { { type = "runtime", menu = "runtime file" } }
  end

  if contains(HISTORY_COMMANDS, command) then
    return { { type = "static", menu = "history", items = words_items({ "cmd", "search", "expr", "input", "debug", "all", ":", "/", "=", ">" }, "history", arglead) } }
  end

  if contains(MESSAGE_COMMANDS, command) then
    return { { type = "messages", menu = "message" } }
  end

  if contains(COMMAND_COMMANDS, command) then
    if arglead:match("^%-") then
      return { { type = "static", menu = "attribute", items = words_items(COMMAND_ATTRIBUTES, "attribute", arglead) } }
    end
    if position == 0 then
      return {
        { type = "static", menu = "attribute", items = words_items(COMMAND_ATTRIBUTES, "attribute", arglead) },
        { type = "user", menu = "user command" },
      }
    end
    return { { type = "command", menu = "command" }, { type = "file", menu = "file" } }
  end

  if contains(VAR_COMMANDS, command) then
    return { { type = "var", menu = "variable" }, { type = "environment", menu = "environment" } }
  end

  if contains(TAG_COMMANDS, command) then
    return { { type = "tag", menu = "tag" } }
  end

  if contains(SHELL_COMMANDS, command) then
    if command == "!" or command == "terminal" or command == "term" then
      return { { type = "shellcmd", menu = "shell command" }, { type = "file", menu = "file" } }
    end
    return { { type = "file_in_path", menu = "file in path" }, { type = "dir", menu = "directory" } }
  end

  if command == "lsp" then
    return { { type = "static", menu = "lsp", items = words_items({ "enable", "disable", "restart", "stop", "start", "info", "log", "status" }, "lsp", arglead) } }
  end
  local _ = LSP_COMMANDS

  local map_prefix, map_suffix = map_command_prefix(command)
  if map_prefix then
    if map_suffix == "mapclear" or map_suffix == "abclear" then
      return { { type = "buffer", menu = "buffer" } }
    end
    if map_suffix == "unmap" or map_suffix == "unabbrev" then
      return { { type = "mapping", menu = "mapping" } }
    end
    if arglead:sub(1, 1) == "<" then
      return { { type = "static", menu = "map attribute", items = words_items(MAP_ATTRIBUTES, "map attribute", arglead) } }
    end
    if position == 0 then
      return {
        { type = "mapping", menu = "mapping" },
        { type = "static", menu = "map attribute", items = words_items(MAP_ATTRIBUTES, "map attribute", arglead) },
      }
    end
    return { { type = "command", menu = "mapping rhs" }, { type = "function", menu = "function" } }
  end

  if contains(FILE_IN_PATH, command) then
    return { { type = "file_in_path", menu = "file in path" }, { type = "dir", menu = "directory" } }
  end

  if contains(DIR_COMMANDS, command) then
    return { { type = "dir", menu = "directory" }, { type = "file", menu = "file" } }
  end

  if contains(FILE_COMMANDS, command) then
    if arglead:sub(1, 2) == "++" then
      return { { type = "static", menu = "file modifier", items = words_items(FILE_MODIFIERS, "file modifier", arglead) } }
    end
    return { { type = "file", menu = "file" }, { type = "dir", menu = "directory" }, { type = "buffer", menu = "buffer" } }
  end

  -- Commands that plainly take a file or a buffer.
  if command:match("^tab") or command:match("^vert") then
    return { { type = "file", menu = "file" } }
  end

  if contains({ "nohlsearch", "noh", "diffupdate", "diffoff", "redraw", "redrawstatus", "mode", "stopinsert", "startinsert", "update" }, command) then
    return {}
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- execution
-- ---------------------------------------------------------------------------

--- Items for one plan entry.
---@param entry KaeruNativePlan
---@param arglead string
---@return KaeruCompletionItem[]
local function plan_items(entry, arglead)
  if entry.type == "static" then
    return entry.items or {}
  end
  return items(arglead, entry.type, entry.menu)
end

--- Complete **any** Neovim command line.
---@param line string
---@param opts? { any?: boolean }
---@return KaeruCompletionItem[] items, string? hint
function M.items(line, opts)
  opts = opts or {}
  local command, args, arglead = M.parse(line)
  local plan = M.plan(command, args, arglead)

  if not plan then
    if not opts.any then
      return {}, "no completion for :" .. tostring(command)
    end
    -- Unknown command (or no command at all): offer everything Neovim knows.
    plan = {
      { type = "file", menu = "file" },
      { type = "dir", menu = "directory" },
      { type = "buffer", menu = "buffer" },
      { type = "command", menu = "command" },
      { type = "option", menu = "option" },
      { type = "event", menu = "autocmd event" },
      { type = "color", menu = "colorscheme" },
      { type = "filetype", menu = "filetype" },
      { type = "help", menu = "help tag" },
      { type = "augroup", menu = "augroup" },
      { type = "mapping", menu = "mapping" },
      { type = "var", menu = "variable" },
      { type = "environment", menu = "environment" },
    }
  end

  if #plan == 0 then
    return {}, "no completion for :" .. command
  end

  local out = {}
  local seen = {}
  for _, entry in ipairs(plan) do
    for _, item in ipairs(plan_items(entry, arglead)) do
      if item.word and item.word ~= "" and not seen[item.word] then
        seen[item.word] = true
        out[#out + 1] = item
      end
    end
  end
  return out, nil
end

--- The categories this module can produce, for the docs / `:Kaeru complete`.
---@return string[]
function M.categories()
  return {
    "arglist", "augroup", "breakpoint", "buffer", "checkhealth", "color", "command",
    "compiler", "dir", "environment", "event", "expression", "file", "file_in_path",
    "filetype", "function", "help", "highlight", "history", "locale", "lua", "mapclear",
    "mapping", "menu", "messages", "option", "packadd", "runtime", "shellcmd",
    "shellcmdline", "sign", "syntax", "syntime", "tag", "user", "var",
  }
end

M.plan_for = M.plan

return M
