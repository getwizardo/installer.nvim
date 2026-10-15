-- Context-aware autocomplete for installer.nvim:
--   1. Modal form completion (`omnifunc` / `completefunc` + auto-popup on typing)
--   2. Command-line `:Installer <Tab>` completion (subcommands, repos, Mason servers,
--      lspconfig names, SFTP profiles/files, AI presets, cache entries, README files)
local Spec = require("installer.spec")

local M = {}

-- Popular Neovim plugins for repository & dependency completion
M.popular_repos = {
  { word = "folke/noice.nvim", menu = "[UI] cmdline, messages & popupmenu" },
  { word = "folke/snacks.nvim", menu = "[QoL] collection of small QoL plugins" },
  { word = "folke/which-key.nvim", menu = "[Keymaps] keybinding popup helper" },
  { word = "folke/tokyonight.nvim", menu = "[Colorscheme] clean dark/light theme" },
  { word = "folke/flash.nvim", menu = "[Motion] fast search/jump navigation" },
  { word = "folke/trouble.nvim", menu = "[Diagnostics] pretty diagnostics list" },
  { word = "folke/todo-comments.nvim", menu = "[Comments] highlight & search TODOs" },
  { word = "folke/lazydev.nvim", menu = "[Lua] Neovim Lua API LSP completion" },
  { word = "nvim-telescope/telescope.nvim", menu = "[Fuzzy Finder] extensible picker" },
  { word = "ibhagwan/fzf-lua", menu = "[Fuzzy Finder] fast fzf powered picker" },
  { word = "nvim-treesitter/nvim-treesitter", menu = "[Syntax] tree-sitter configurations" },
  { word = "neovim/nvim-lspconfig", menu = "[LSP] official LSP configurations" },
  { word = "mason-org/mason.nvim", menu = "[Mason] LSP/DAP/linter/formatter installer" },
  { word = "mason-org/mason-lspconfig.nvim", menu = "[Mason] mason <-> lspconfig bridge" },
  { word = "stevearc/conform.nvim", menu = "[Formatter] lightweight formatter plugin" },
  { word = "mfussenegger/nvim-lint", menu = "[Linter] async linter plugin" },
  { word = "mfussenegger/nvim-dap", menu = "[DAP] Debug Adapter Protocol client" },
  { word = "rcarriga/nvim-dap-ui", menu = "[DAP] UI for nvim-dap" },
  { word = "saghen/blink.cmp", menu = "[Completion] performant completion plugin" },
  { word = "hrsh7th/nvim-cmp", menu = "[Completion] completion engine in Lua" },
  { word = "L3MON4D3/LuaSnip", menu = "[Snippets] snippet engine written in Lua" },
  { word = "stevearc/oil.nvim", menu = "[Files] edit filesystem like a buffer" },
  { word = "nvim-neo-tree/neo-tree.nvim", menu = "[Files] file explorer tree" },
  { word = "nvim-tree/nvim-tree.lua", menu = "[Files] file explorer tree in Lua" },
  { word = "lewis6991/gitsigns.nvim", menu = "[Git] git decorations & hunk actions" },
  { word = "tpope/vim-fugitive", menu = "[Git] premier Git wrapper" },
  { word = "kdheepak/lazygit.nvim", menu = "[Git] lazygit floating window" },
  { word = "nvim-lualine/lualine.nvim", menu = "[Statusline] fast statusline" },
  { word = "akinsho/bufferline.nvim", menu = "[Bufferline] snazzy buffer line" },
  { word = "akinsho/toggleterm.nvim", menu = "[Terminal] manage multiple terminals" },
  { word = "echasnovski/mini.nvim", menu = "[Mini] 40+ independent Lua modules" },
  { word = "catppuccin/nvim", menu = "[Colorscheme] soothing pastel theme" },
  { word = "rebelot/kanagawa.nvim", menu = "[Colorscheme] Hokusai-inspired theme" },
  { word = "rose-pine/neovim", menu = "[Colorscheme] Soho vibes for Neovim" },
  { word = "ThePrimeagen/harpoon", menu = "[Navigation] quick file marks" },
  { word = "kylechui/nvim-surround", menu = "[Editing] surround selections stylishly" },
  { word = "windwp/nvim-autopairs", menu = "[Editing] autopairs in Lua" },
  { word = "MeanderingProgrammer/render-markdown.nvim", menu = "[Markdown] in-buffer rendering" },
}

M.common_dependencies = {
  { word = "nvim-lua/plenary.nvim", menu = "[Dep] Lua utility functions" },
  { word = "nvim-tree/nvim-web-devicons", menu = "[Dep] file type icons" },
  { word = "echasnovski/mini.icons", menu = "[Dep] icon provider" },
  { word = "MunifTanjim/nui.nvim", menu = "[Dep] UI component library" },
  { word = "rcarriga/nvim-notify", menu = "[Dep] notification manager" },
  { word = "nvim-treesitter/nvim-treesitter", menu = "[Dep] tree-sitter parsers" },
  { word = "nvim-neotest/nvim-nio", menu = "[Dep] async I/O library" },
  { word = "folke/snacks.nvim", menu = "[Dep] snacks UI / terminal / picker" },
  { word = "stevearc/dressing.nvim", menu = "[Dep] vim.ui.select / input hooks" },
  { word = "hrsh7th/nvim-cmp", menu = "[Dep] completion engine" },
  { word = "saghen/blink.cmp", menu = "[Dep] blink completion engine" },
  { word = "neovim/nvim-lspconfig", menu = "[Dep] LSP configurations" },
  { word = "mason-org/mason.nvim", menu = "[Dep] Mason package manager" },
  { word = "kkharji/sqlite.lua", menu = "[Dep] SQLite LuaJIT bindings" },
  { word = "HakonHarnes/img-clip.nvim", menu = "[Dep] clipboard image pasting" },
}

M.events = {
  { word = "VeryLazy", menu = "[lazy.nvim] after startup & UI render" },
  { word = "LazyFile", menu = "[LazyVim] BufReadPost / BufNewFile / BufWritePre" },
  { word = "BufReadPre", menu = "[Event] before reading an existing file" },
  { word = "BufReadPost", menu = "[Event] after reading an existing file" },
  { word = "BufNewFile", menu = "[Event] when creating a new file" },
  { word = "BufEnter", menu = "[Event] after entering a buffer" },
  { word = "BufWritePre", menu = "[Event] before writing a buffer" },
  { word = "BufWritePost", menu = "[Event] after writing a buffer" },
  { word = "InsertEnter", menu = "[Event] when entering Insert mode" },
  { word = "InsertLeave", menu = "[Event] when leaving Insert mode" },
  { word = "CmdlineEnter", menu = "[Event] when entering command-line" },
  { word = "LspAttach", menu = "[Event] when an LSP client attaches" },
  { word = "LspDetach", menu = "[Event] when an LSP client detaches" },
  { word = "FileType", menu = "[Event] when filetype option is set" },
  { word = "VimEnter", menu = "[Event] after all startup initialization" },
  { word = "UIEnter", menu = "[Event] after UI connects" },
  { word = "ColorScheme", menu = "[Event] after loading a colorscheme" },
  { word = "CursorMoved", menu = "[Event] cursor moved in Normal mode" },
  { word = "CursorMovedI", menu = "[Event] cursor moved in Insert mode" },
  { word = "CursorHold", menu = "[Event] cursor held still in Normal mode" },
  { word = "TermOpen", menu = "[Event] when a terminal buffer is created" },
  { word = "DiagnosticChanged", menu = "[Event] when diagnostics change" },
  { word = "DirChanged", menu = "[Event] working directory changed" },
  { word = "User", menu = "[Event] custom user event" },
}

M.filetypes = {
  "lua", "python", "typescript", "typescriptreact", "javascript", "javascriptreact",
  "rust", "go", "gomod", "c", "cpp", "cs", "java", "kotlin", "scala", "zig",
  "markdown", "json", "jsonc", "yaml", "toml", "xml", "html", "css", "scss",
  "vue", "svelte", "astro", "php", "ruby", "elixir", "erlang", "haskell",
  "ocaml", "nix", "sh", "bash", "zsh", "fish", "vim", "dockerfile", "terraform",
  "sql", "graphql", "proto", "dart", "swift", "r", "julia", "tex", "typst",
  "gitcommit", "make", "cmake", "glsl", "solidity", "prisma",
}

M.commands = {
  "Telescope", "Neotree", "NvimTreeToggle", "Oil", "Lazy", "Mason", "ConformInfo",
  "Trouble", "Noice", "Flash", "Gitsigns", "Git", "LazyGit", "ToggleTerm",
  "Copilot", "CodeCompanion", "CodeCompanionChat", "CopilotChat", "ClaudeCode",
  "AvanteAsk", "MCPHub", "DBUI", "Octo", "ZenMode", "Twilight", "MarkdownPreview",
}

M.builds = {
  { word = ":TSUpdate", menu = "Update tree-sitter parsers" },
  { word = "make", menu = "Run Makefile build" },
  { word = "make tiktoken", menu = "Build tiktoken (CopilotChat)" },
  { word = "cargo build --release", menu = "Build Rust binary with Cargo" },
  { word = "npm install", menu = "Install npm dependencies" },
  { word = "yarn install", menu = "Install yarn dependencies" },
  { word = ":UpdateRemotePlugins", menu = "Register remote plugins" },
  { word = ":MasonUpdate", menu = "Update Mason registry" },
}

M.CSV_FIELDS = {
  event = true,
  cmd = true,
  ft = true,
  keys = true,
  dependencies = true,
}

-- Live GitHub API repository completion cache (`query -> { items = ..., ts = ... }`)
M.github_cache = {}
M.dynamic_repos = {}
M._github_inflight = {}

--- Register repository items returned from the GitHub API into the live autocomplete cache.
---@param query string
---@param items {full_name: string, stars?: number, description?: string}[]
function M.add_github_results(query, items)
  local ok_gh, GitHub = pcall(require, "installer.github")
  local fmt_stars = (ok_gh and GitHub.format_stars) or function(n)
    return tostring(n or 0)
  end
  local formatted = {}
  for _, item in ipairs(items or {}) do
    if item and item.full_name then
      local menu = ("[GitHub ★%s] %s"):format(fmt_stars(item.stars or 0), item.description or "")
      local entry = { word = item.full_name, menu = menu, stars = item.stars or 0 }
      formatted[#formatted + 1] = entry
      M.dynamic_repos[item.full_name] = entry
    end
  end
  if query and query ~= "" then
    M.github_cache[query:lower()] = {
      items = formatted,
      ts = os.time(),
    }
  end
  return formatted
end

--- Query the live GitHub Search API (`api.github.com/search/repositories`) asynchronously for plugin autocomplete.
---@param query string
---@param cb? fun(items: {word: string, menu: string}[])
function M.search_github_async(query, cb)
  query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #query < 2 then
    if cb then
      cb({})
    end
    return
  end
  local q_key = query:lower()
  local cached = M.github_cache[q_key]
  if cached and (os.time() - (cached.ts or 0)) < 300 then
    if cb then
      cb(cached.items)
    end
    return
  end
  if M._github_inflight[q_key] then
    return
  end
  M._github_inflight[q_key] = true

  local ok_gh, GitHub = pcall(require, "installer.github")
  if not ok_gh or not GitHub.search then
    M._github_inflight[q_key] = false
    if cb then
      cb({})
    end
    return
  end

  local gh_query = query
  local owner, repo_part = query:match("^([%w_.-]+)/([%w_.-]*)$")
  if owner then
    gh_query = repo_part ~= "" and (repo_part .. " user:" .. owner) or ("user:" .. owner .. " nvim")
  end

  GitHub.search({
    query = gh_query,
    per_page = 15,
    include_all = owner ~= nil,
  }, function(err, res)
    M._github_inflight[q_key] = false
    if err or not res or not res.items then
      if cb then
        cb({})
      end
      return
    end
    local formatted = M.add_github_results(q_key, res.items)
    if cb then
      cb(formatted)
    end
  end)
end

--- Collect all known repository names (live GitHub API + popular + AI presets + cached + installed).
---@return {word: string, menu: string}[]
function M.collect_repos()
  local out = {}
  local seen = {}
  local function add(word, menu)
    if not word or word == "" or seen[word:lower()] then
      return
    end
    seen[word:lower()] = true
    out[#out + 1] = { word = word, menu = menu or "" }
  end

  for _, dyn in pairs(M.dynamic_repos) do
    add(dyn.word, dyn.menu)
  end

  local ok_gh, GitHub = pcall(require, "installer.github")
  if ok_gh and GitHub._cache then
    for _, cached in pairs(GitHub._cache) do
      for _, item in ipairs(cached.items or {}) do
        add(item.full_name, ("[★%s] %s"):format(GitHub.format_stars(item.stars or 0), item.description or ""))
      end
    end
  end

  for _, r in ipairs(M.popular_repos) do
    add(r.word, r.menu)
  end

  local ok_ai, AI = pcall(require, "installer.ai")
  if ok_ai and AI.presets then
    for _, p in ipairs(AI.presets) do
      add(p.repo, "[AI] " .. p.desc)
    end
  end

  local ok_lazy, LazyConfig = pcall(require, "lazy.core.config")
  if ok_lazy and LazyConfig.plugins then
    for _, plugin in pairs(LazyConfig.plugins) do
      if type(plugin[1]) == "string" and plugin[1]:find("/", 1, true) then
        add(plugin[1], "[Installed]")
      end
    end
  end

  return out
end

--- Compute completion candidates for a given form field `key` and token `base`.
---@param key string
---@param base string
---@param form? InstallerForm
---@return {word: string, abbr?: string, menu?: string, kind?: string}[]
function M.complete_field(key, base, form)
  base = base or ""
  local b_lower = base:lower()
  local candidates = {}

  local function push(word, menu, kind)
    if b_lower == "" or word:lower():find(b_lower, 1, true) == 1 or ( #b_lower >= 2 and word:lower():find(b_lower, 1, true) ) then
      candidates[#candidates + 1] = {
        word = word,
        menu = menu or "",
        kind = kind or key,
      }
    end
  end

  if key == "repo" then
    for _, item in ipairs(M.collect_repos()) do
      push(item.word, item.menu, "Repo")
    end
  elseif key == "file" then
    if form and form.repo and form.repo ~= "" then
      local parsed = Spec.parse_repo(form.repo)
      if parsed then
        local def = Spec.default_filename(parsed.base)
        push(def, "[Auto] default spec file name", "File")
        push("ui-" .. def, "[UI] grouped spec file", "File")
        push("lsp-" .. def, "[LSP] grouped spec file", "File")
      end
    end
  elseif key == "name" then
    if form and form.repo and form.repo ~= "" then
      local parsed = Spec.parse_repo(form.repo)
      if parsed then
        push(parsed.base, "[Repo] repository basename", "Name")
        push(Spec.default_filename(parsed.base), "[Short] stripped plugin name", "Name")
      end
    end
  elseif key == "lazy" or key == "pin" then
    push("true", "Boolean true", "Bool")
    push("false", "Boolean false", "Bool")
  elseif key == "event" then
    for _, ev in ipairs(M.events) do
      push(ev.word, ev.menu, "Event")
    end
  elseif key == "ft" then
    local seen = {}
    for _, ft in ipairs(M.filetypes) do
      seen[ft] = true
      push(ft, "[Filetype]", "Ft")
    end
    if vim and vim.fn and vim.fn.getcompletion then
      local ok, runtime_fts = pcall(vim.fn.getcompletion, base, "filetype")
      if ok and type(runtime_fts) == "table" then
        for _, ft in ipairs(runtime_fts) do
          if not seen[ft] then
            seen[ft] = true
            push(ft, "[Filetype]", "Ft")
          end
        end
      end
    end
  elseif key == "cmd" then
    local seen = {}
    for _, c in ipairs(M.commands) do
      seen[c] = true
      push(c, "[Command]", "Cmd")
    end
    if vim and vim.fn and vim.fn.getcompletion and #base >= 1 then
      local ok, runtime_cmds = pcall(vim.fn.getcompletion, base, "command")
      if ok and type(runtime_cmds) == "table" then
        for i = 1, math.min(#runtime_cmds, 40) do
          local c = runtime_cmds[i]
          if not seen[c] then
            seen[c] = true
            push(c, "[Command]", "Cmd")
          end
        end
      end
    end
  elseif key == "keys" then
    local key_items = {
      { word = "<leader>", menu = "Leader key prefix" },
      { word = "<localleader>", menu = "Local leader key prefix" },
      { word = "<C-", menu = "Control key modifier" },
      { word = "<M-", menu = "Alt/Meta key modifier" },
      { word = "<S-", menu = "Shift key modifier" },
      { word = "<CR>", menu = "Enter / Return" },
      { word = "<Esc>", menu = "Escape" },
      { word = "<Tab>", menu = "Tab" },
      { word = "<Space>", menu = "Space" },
      { word = '{ { "<leader>", function() end, desc = "" } }', menu = "LazyKeysSpec table" },
    }
    for _, k in ipairs(key_items) do
      push(k.word, k.menu, "Keys")
    end
  elseif key == "dependencies" then
    local seen = {}
    for _, dep in ipairs(M.common_dependencies) do
      seen[dep.word:lower()] = true
      push(dep.word, dep.menu, "Dep")
    end
    for _, r in ipairs(M.collect_repos()) do
      if not seen[r.word:lower()] then
        seen[r.word:lower()] = true
        push(r.word, r.menu, "Dep")
      end
    end
  elseif key == "version" then
    push("*", "Latest stable semver release", "Ver")
    push("false", "Always use latest branch HEAD", "Ver")
    push("^1.0.0", "Semver compatible with 1.x", "Ver")
    push("~0.1.0", "Semver patch range", "Ver")
  elseif key == "branch" then
    for _, br in ipairs({ "main", "master", "canary", "nightly", "release", "v2", "0.1.x" }) do
      push(br, "[Git branch]", "Branch")
    end
  elseif key == "priority" then
    push("1000", "Recommended for colorschemes", "Priority")
    push("500", "High startup priority", "Priority")
    push("100", "Above default priority", "Priority")
    push("50", "Default lazy.nvim priority", "Priority")
  elseif key == "build" then
    for _, b in ipairs(M.builds) do
      push(b.word, b.menu, "Build")
    end
  elseif key == "opts" then
    push("{}", "Empty opts table (calls setup({}))", "Opts")
    push("{ }", "Opts table literal", "Opts")
  elseif key == "config" then
    push("true", "Run require(MAIN).setup(opts) automatically", "Config")
    push("function", "Generate function(_, opts) skeleton", "Config")
    if form and form.repo and form.repo ~= "" then
      local parsed = Spec.parse_repo(form.repo)
      local mod = parsed and Spec.default_filename(parsed.base) or "plugin"
      push(('function(_, opts) require(%q).setup(opts) end'):format(mod), "Inline config function", "Config")
    end
  elseif key == "init" then
    push("function() end", "Startup init hook", "Init")
  end

  -- Sort prefix matches ahead of substring matches
  table.sort(candidates, function(a, b)
    local ap = a.word:lower():find(b_lower, 1, true) == 1
    local bp = b.word:lower():find(b_lower, 1, true) == 1
    if ap ~= bp then
      return ap
    end
    return a.word < b.word
  end)

  return candidates
end

--- Compute the byte index (0-based) where completion starts on a form line, and the field key.
---@param line string
---@param col integer  0-based cursor byte column
---@param row integer  1-based buffer row
---@return integer start_col, string key, string base
function M.find_form_start(line, col, row)
  local Form = require("installer.form")
  local field = Form.fields[row]
  local key = field and field.key or ""
  local sep = line:find(" : ", 1, true)
  local min_col = sep and (sep + 2) or 18
  local before = line:sub(1, math.max(min_col, col))

  local start_col = min_col
  if M.CSV_FIELDS[key] and not before:sub(min_col + 1):match("^%s*{") then
    -- Complete after the last comma
    local last_comma = before:sub(min_col + 1):match("^.*(),")
    if last_comma then
      start_col = min_col + last_comma
    end
  end

  -- Skip leading spaces after ` : ` or `,`
  while start_col < col and line:sub(start_col + 1, start_col + 1):match("%s") do
    start_col = start_col + 1
  end

  local base = line:sub(start_col + 1, col)
  return start_col, key, base
end

--- Neovim `omnifunc` / `completefunc` implementation for the `:Installer` modal buffer.
---@param findstart integer 1|0
---@param base string
---@return integer|table
function M.omnifunc(findstart, base)
  local Form = require("installer.form")
  if not Form.is_open() then
    return findstart == 1 and -3 or {}
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

  local start_col, key = M.find_form_start(line, col, row)
  if findstart == 1 then
    return start_col
  end
  local form = Form.read()
  return M.complete_field(key, base, form)
end

--- Trigger popup menu completion in the `:Installer` form buffer (with live GitHub API lookup for repo/dependencies).
---@param buf integer
---@param win integer
---@param explicit? boolean  true when user pressed <C-Space> / <Tab> (show even when base is empty)
function M.trigger(buf, win, explicit)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("^i") then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local start_col, key, base = M.find_form_start(line, col, row)
  if not explicit and base == "" then
    return
  end
  local Form = require("installer.form")
  local items = M.complete_field(key, base, Form.read())

  -- Query live GitHub Search API when completing repository or dependencies
  if (key == "repo" or key == "dependencies") and #base >= 2 then
    M.search_github_async(base, function(gh_items)
      if not gh_items or #gh_items == 0 then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        return
      end
      if not vim.api.nvim_get_mode().mode:match("^i") then
        return
      end
      local cur2 = vim.api.nvim_win_get_cursor(win)
      local line2 = vim.api.nvim_buf_get_lines(buf, cur2[1] - 1, cur2[1], false)[1] or ""
      local start2, key2, base2 = M.find_form_start(line2, cur2[2], cur2[1])
      if key2 == key and #base2 >= 2 then
        local refreshed = M.complete_field(key2, base2, Form.read())
        if #refreshed > 0 then
          pcall(vim.fn.complete, start2 + 1, refreshed)
        end
      end
    end)
  end

  if #items == 0 then
    return
  end
  -- If the only match is already identical to `base`, don't re-open the popup unless explicit
  if not explicit and #items == 1 and items[1].word == base then
    return
  end
  vim.fn.complete(start_col + 1, items)
end

-- Command-line `:Installer` completion -------------------------------------------------

M.subcommands = {
  "modal", "browse", "search", "add", "save", "parse", "readme", "dir",
  "ai", "clina", "music", "boot", "login", "logout", "whoami", "sftp", "cache", "config",
  "mason", "starsky", "web",
}

M.mason_actions = {
  "pick", "install", "uninstall", "update", "upgrade", "ensure", "export", "list", "ft",
  "lsp", "dap", "linter", "formatter", "compiler", "runtime", "scaffold", "ui", "registry",
}

M.mason_scaffolds = { "lsp", "dap", "tools" }

M.sftp_actions = {
  "ui", "upload", "upload-project", "sync", "download", "download-project", "init", "status",
  "select", "browse", "diff", "test", "shell", "ssh", "run", "exec", "ls", "mkdir",
  "rmdir", "rm", "rename", "chmod", "chown", "chgrp", "ln", "symlink", "df", "pwd", "version",
}

M.clina_actions = {
  "ide", "neocodeium", "setup", "accept", "accept_word", "accept_line",
  "cycle", "complete", "clear", "auth", "enable", "disable", "toggle",
  "enable_buffer", "disable_buffer", "toggle_buffer", "chat", "restart", "log",
  "install", "agent", "ask", "edit", "spec", "mcp", "apply", "diff", "status", "web",
}

M.clina_providers = {
  "neocodeium", "clina-ts", "anthropic", "openai", "gemini", "deepseek", "ollama",
}

M.music_actions = {
  "ui", "play", "pause", "toggle", "stop", "next", "prev", "volume",
  "eq", "visualizer", "radio", "stream", "server", "connect", "disconnect",
  "devices", "remote", "status",
}

M.music_eq_presets = {
  "flat", "bass-boost", "lofi-coding", "synthwave", "vocal", "electronic", "classical", "night",
}

M.cache_actions = { "pack", "restore", "list", "remove", "clean", "dir" }
M.config_actions = { "edit", "project", "reload", "show", "dump" }
M.starsky_actions = { "start", "stop", "open", "status", "build" }

--- Collect Mason package names + lspconfig names (from live registry or built-in mason_data).
---@param opts? {installed_only?: boolean, category?: string}
---@return string[]
function M.mason_names(opts)
  opts = opts or {}
  local names = {}
  local seen = {}
  local function add(n)
    if n and n ~= "" and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end

  local ok_reg, registry = pcall(require, "mason-registry")
  if ok_reg then
    if opts.installed_only and registry.get_installed_package_names then
      for _, n in ipairs(registry.get_installed_package_names()) do
        add(n)
      end
      table.sort(names)
      return names
    end
    if registry.get_all_package_specs then
      local ok_specs, specs = pcall(registry.get_all_package_specs)
      if ok_specs and type(specs) == "table" and #specs > 0 then
        for _, s in ipairs(specs) do
          local keep = true
          if opts.category and s.categories then
            keep = false
            for _, c in ipairs(s.categories) do
              if c:lower() == opts.category:lower() then
                keep = true
                break
              end
            end
          end
          if keep then
            add(s.name)
            local lspc = s.neovim and s.neovim.lspconfig
            if lspc then
              add(lspc)
            end
          end
        end
        table.sort(names)
        return names
      end
    end
  end

  -- Built-in fallback from `installer.mason_data` (all 601 Mason packages + 296 lspconfig names)
  if not opts.installed_only then
    local ok_data, data = pcall(require, "installer.mason_data")
    if ok_data and data.packages then
      for _, p in ipairs(data.packages) do
        local keep = true
        if opts.category and p.categories then
          keep = false
          for _, c in ipairs(p.categories) do
            if c:lower() == opts.category:lower() then
              keep = true
              break
            end
          end
        end
        if keep then
          add(p.name)
          if p.lspconfig then
            add(p.lspconfig)
          end
        end
      end
    end
  end

  table.sort(names)
  return names
end

--- Command-line completion handler for `:Installer`.
---@param arglead string
---@param cmdline string
---@param cursorpos? integer
---@return string[]
function M.cmdline(arglead, cmdline, cursorpos)
  arglead = arglead or ""
  local line = cursorpos and cmdline:sub(1, cursorpos) or cmdline
  -- Strip leading `:'<,'>` or whitespace and command name
  line = line:gsub("^%s*:'?<?,?'?>?%s*", ""):gsub("^%s*", "")

  -- Split into tokens; if `line` ends with whitespace, append an empty token for the current arg
  local tokens = {}
  for w in line:gmatch("%S+") do
    tokens[#tokens + 1] = w
  end
  if line:match("%s$") then
    tokens[#tokens + 1] = ""
  end

  local lead_lower = arglead:lower()
  local function filter(list)
    local prefix, substr = {}, {}
    for _, s in ipairs(list) do
      local sl = s:lower()
      if lead_lower == "" or sl:find(lead_lower, 1, true) == 1 then
        prefix[#prefix + 1] = s
      elseif #lead_lower >= 2 and sl:find(lead_lower, 1, true) then
        substr[#substr + 1] = s
      end
    end
    for _, s in ipairs(substr) do
      prefix[#prefix + 1] = s
    end
    return prefix
  end

  local argc = #tokens -- tokens[1] is "Installer" or "Installer!"
  local sub = tokens[2]

  if argc <= 2 then
    -- Complete subcommands; if user typed a slash (e.g. `folke/`), also complete repos!
    local list = {}
    for _, s in ipairs(M.subcommands) do
      list[#list + 1] = s
    end
    if arglead:find("/", 1, true) or #arglead >= 2 then
      M.search_github_async(arglead)
      for _, r in ipairs(M.collect_repos()) do
        list[#list + 1] = r.word
      end
    end
    return filter(list)
  end

  if sub == "add" or sub == "save" or sub == "modal" then
    if argc == 3 then
      if #arglead >= 2 then
        M.search_github_async(arglead)
      end
      local repos = {}
      for _, r in ipairs(M.collect_repos()) do
        repos[#repos + 1] = r.word
      end
      return filter(repos)
    end
  elseif sub == "music" then
    if argc == 3 then
      return filter(M.music_actions)
    elseif argc == 4 and tokens[3] == "eq" then
      return filter(M.music_eq_presets)
    end
  elseif sub == "clina" then
    if argc == 3 then
      return filter(M.clina_actions)
    elseif argc == 4 and (tokens[3] == "provider" or tokens[3] == "model") then
      return filter(M.clina_providers)
    end
  elseif sub == "parse" or sub == "readme" then
    if argc == 3 then
      local items = { "README.md" }
      for _, r in ipairs(M.collect_repos()) do
        items[#items + 1] = r.word
      end
      if vim and vim.fn and vim.fn.getcompletion then
        local ok, files = pcall(vim.fn.getcompletion, arglead, "file")
        if ok and type(files) == "table" then
          for _, f in ipairs(files) do
            items[#items + 1] = f
          end
        end
      end
      return filter(items)
    end
  elseif sub == "sftp" then
    if argc == 3 then
      return filter(M.sftp_actions)
    elseif argc == 4 and tokens[3] == "select" then
      local ok_cfg, Config = pcall(require, "installer.config")
      local names = {}
      if ok_cfg and Config.options and Config.options.sftp and Config.options.sftp.profiles then
        for k in pairs(Config.options.sftp.profiles) do
          names[#names + 1] = k
        end
      end
      table.sort(names)
      return filter(names)
    elseif argc == 4 and tokens[3] == "upload" and vim and vim.fn and vim.fn.getcompletion then
      local ok, files = pcall(vim.fn.getcompletion, arglead, "file")
      return ok and files or {}
    end
  elseif sub == "cache" then
    if argc == 3 then
      return filter(M.cache_actions)
    elseif argc == 4 then
      local seen = {}
      local names = {}
      if tokens[3] == "pack" then
        names[#names + 1] = "all"
        seen["all"] = true
      end
      local ok_c, Cache = pcall(require, "installer.cache")
      if ok_c then
        for k in pairs(Cache.index()) do
          if not seen[k] then
            seen[k] = true
            names[#names + 1] = k
          end
        end
      end
      local ok_l, LazyConfig = pcall(require, "lazy.core.config")
      if ok_l and LazyConfig.plugins then
        for name in pairs(LazyConfig.plugins) do
          if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
          end
        end
      end
      table.sort(names)
      return filter(names)
    end
  elseif sub == "mason" then
    local action = tokens[3]
    if argc == 3 then
      local list = {}
      for _, a in ipairs(M.mason_actions) do
        list[#list + 1] = a
      end
      -- Also allow direct package names if the user is typing a package shortcut
      if #arglead >= 2 then
        for _, n in ipairs(M.mason_names()) do
          list[#list + 1] = n
        end
      end
      return filter(list)
    elseif action == "scaffold" and argc == 4 then
      return filter(M.mason_scaffolds)
    elseif action == "uninstall" or action == "update" then
      return filter(M.mason_names({ installed_only = true }))
    elseif action == "lsp" or action == "dap" or action == "linter" or action == "formatter" or action == "compiler" or action == "runtime" then
      return filter(M.mason_names({ category = action }))
    elseif argc >= 4 then
      return filter(M.mason_names())
    end
  elseif sub == "config" and argc == 3 then
    return filter(M.config_actions)
  elseif sub == "login" and argc == 3 then
    return filter({ "gh", "token", "device" })
  elseif sub == "ai" and argc == 3 then
    local ok_ai, AI = pcall(require, "installer.ai")
    if ok_ai and AI.presets then
      local list = {}
      for _, p in ipairs(AI.presets) do
        list[#list + 1] = p.repo
      end
      return filter(list)
    end
  elseif (sub == "starsky" or sub == "web") and argc == 3 then
    return filter(M.starsky_actions)
  end

  return {}
end

--- Command-line completion handler for `:Clina`.
---@param arglead string
---@param cmdline string
---@param cursorpos? integer
---@return string[]
function M.clina_cmdline(arglead, cmdline, cursorpos)
  arglead = arglead or ""
  local line = cursorpos and cmdline:sub(1, cursorpos) or cmdline
  line = line:gsub("^%s*:'?<?,?'?>?%s*", ""):gsub("^%s*", "")
  local tokens = {}
  for w in line:gmatch("%S+") do
    tokens[#tokens + 1] = w
  end
  if line:match("%s$") then
    tokens[#tokens + 1] = ""
  end

  local lead_lower = arglead:lower()
  local function filter(list)
    local out = {}
    for _, s in ipairs(list) do
      if lead_lower == "" or s:lower():find(lead_lower, 1, true) then
        out[#out + 1] = s
      end
    end
    return out
  end

  local argc = #tokens
  if argc <= 2 then
    return filter(M.clina_actions)
  elseif argc == 3 and (tokens[2] == "provider" or tokens[2] == "model") then
    return filter(M.clina_providers)
  end
  return {}
end

--- Command-line completion handler for `:MusicPlayer`.
---@param arglead string
---@param cmdline string
---@param cursorpos? integer
---@return string[]
function M.music_cmdline(arglead, cmdline, cursorpos)
  arglead = arglead or ""
  local line = cursorpos and cmdline:sub(1, cursorpos) or cmdline
  line = line:gsub("^%s*:'?<?,?'?>?%s*", ""):gsub("^%s*", "")
  local tokens = {}
  for w in line:gmatch("%S+") do
    tokens[#tokens + 1] = w
  end
  if line:match("%s$") then
    tokens[#tokens + 1] = ""
  end

  local lead_lower = arglead:lower()
  local function filter(list)
    local out = {}
    for _, s in ipairs(list) do
      if lead_lower == "" or s:lower():find(lead_lower, 1, true) then
        out[#out + 1] = s
      end
    end
    return out
  end

  local argc = #tokens
  if argc <= 2 then
    return filter(M.music_actions)
  elseif argc == 3 and tokens[2] == "eq" then
    return filter(M.music_eq_presets)
  elseif argc == 3 and tokens[2] == "visualizer" then
    return filter({ "spectrum", "wave", "vu", "matrix", "starfield" })
  end
  return {}
end

return M
