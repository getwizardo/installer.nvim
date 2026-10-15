-- kaeru.nvim — autocomplete for everything the plugin exposes.
--
--   1. `:` command-line completion (`:Kaeru <Tab>`, `:Kikru <Tab>`, …)
--      * fuzzy, case- and separator-insensitive matching (`fole/laz` → `folke/lazy.nvim`)
--      * every candidate carries a `menu`/`info` description, so the popup
--        explains what each subcommand does instead of showing a bare word
--      * contextual arguments: repositories, Mason packages, SFTP profiles and
--        hosts, cache entries, AI presets, EQ presets, radio stations, source
--        ids, engines, IPCs, 2-Neovim devices, files, …
--      * a live popup while you type + `<Tab>`/`<S-Tab>` cycling
--      * nvim-cmp / blink.cmp cmdline sources (opt-in)
--   2. the modal form completion (`omnifunc` / `completefunc`), including the
--      live GitHub repository lookup.
local Compat = require("kaeru.compat")
local Native = require("kaeru.native")
local Spec = require("kaeru.spec")
local Config = require("kaeru.config")

local M = {}

-- Static suggestion data -------------------------------------------------------

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

-- Fuzzy matcher ------------------------------------------------------------------

--- Score `candidate` against `query` (higher is better, nil = no match).
--- Smart-case, separator aware (`/`, `-`, `_`, `.`, camelCase boundaries), and
--- with a bonus for prefix matches and consecutive characters, like fzf.
---@param query string
---@param candidate string
---@return number|nil score, integer[] positions
function M.fuzzy_score(query, candidate)
  if query == "" then
    return 0, {}
  end
  local lquery = query:lower()
  local lcandidate = candidate:lower()
  local positions = {}
  local score = 0
  local cand_index = 1
  local last_match = 0
  for i = 1, #lquery do
    local char = lquery:sub(i, i)
    local found
    if char == "/" or char == "-" or char == "_" or char == " " or char == ":" then
      -- separators may match any separator-ish character in the candidate
      found = lcandidate:find("[%s/_%.:-]", cand_index)
    else
      found = lcandidate:find(char, cand_index, true)
    end
    if not found then
      return nil
    end
    local bonus = 1
    if found == 1 then
      bonus = bonus + 12
    elseif i == 1 then
      bonus = bonus + 6
    elseif found == last_match + 1 then
      bonus = bonus + 8
    end
    local previous = candidate:sub(found - 1, found - 1)
    local current = candidate:sub(found, found)
    if previous:match("[/%s_%-%.:]") then
      bonus = bonus + 5
    end
    if current:match("%u") then
      bonus = bonus + 2
    end
    score = score + bonus + math.max(0, 20 - (found - cand_index))
    positions[#positions + 1] = found
    last_match = found
    cand_index = found + 1
  end
  -- exact prefix and full matches rank highest
  if lcandidate:sub(1, #lquery) == lquery then
    score = score + 40
  end
  if lcandidate == lquery then
    score = score + 200
  end
  if #lcandidate > #lquery then
    score = score - math.floor((#lcandidate - #lquery) / 4)
  end
  return score, positions
end

---@class KaeruCompletionItem
---@field word string
---@field menu? string
---@field info? string
---@field kind? string
---@field score? number

--- Filter + rank a candidate list for `arglead`.
---@param candidates (string|KaeruCompletionItem)[]
---@param arglead string
---@param opts? {limit?: integer, prefix_only?: boolean}
---@return KaeruCompletionItem[]
function M.rank(candidates, arglead, opts)
  -- `rank(list, arglead)` is the documented order, but accepting the swapped
  -- `rank(arglead, list)` keeps ad-hoc calls (and old code) working.
  if type(candidates) == "string" and type(arglead) == "table" then
    candidates, arglead = arglead, candidates
  end
  opts = opts or {}
  local limit = opts.limit or 400
  local out = {}
  for index, item in ipairs(candidates or {}) do
    local entry = type(item) == "string" and { word = item } or Compat.deepcopy(item)
    if entry.word and entry.word ~= "" then
      local score = M.fuzzy_score(arglead or "", entry.word)
      if score then
        entry.score = score
        entry.index = index
        out[#out + 1] = entry
      end
    end
  end
  -- Stable: fuzzy score first, then the order the candidates were handed in
  -- (menus put actions before data, so typing `:` alone shows the verbs).
  table.sort(out, function(a, b)
    if a.score == b.score then
      return (a.index or 0) < (b.index or 0)
    end
    return (a.score or 0) > (b.score or 0)
  end)
  while #out > limit do
    table.remove(out)
  end
  return out
end

--- Shortcut: candidate words only (used by `complete_field` and tests).
---@param candidates (string|KaeruCompletionItem)[]
---@param arglead string
---@param opts? {limit?: integer}
---@return string[]
function M.rank_words(candidates, arglead, opts)
  local words = {}
  for _, item in ipairs(M.rank(candidates, arglead, opts)) do
    words[#words + 1] = item.word
  end
  return words
end

-- Command specifications ----------------------------------------------------------

---@type table<string, {desc: string, subs: table<string, string>, usage?: string}>
M.command_specs = {
  Kaeru = {
    desc = "kaeru.nvim: manage lazy.nvim plugins, Mason, SFTP, cache & the Starsky web client",
    usage = ":Kaeru <subcommand> [args]",
  },
  Kikru = {
    desc = ":Kikru — Winamp-style player: 10-band EQ, NodeLink filters, radio & 2-Neovim sync",
    usage = ":Kikru <subcommand> [args]",
  },
}

M.subcommands = {
  { word = "modal", menu = "open the lazy.nvim spec form", info = ":Kaeru modal [owner/repo]" },
  { word = "browse", menu = "browse Neovim plugins on GitHub", info = ":Kaeru browse [query]" },
  { word = "search", menu = "search GitHub with vim.ui.select", info = ":Kaeru search [query]" },
  { word = "add", menu = "write a spec file and install", info = ":Kaeru add <owner/repo>" },
  { word = "save", menu = "write a spec file only", info = ":Kaeru save <owner/repo>" },
  { word = "parse", menu = "parse a README / installer snippet", info = ":Kaeru parse [owner/repo|file]" },
  { word = "readme", menu = "alias of parse", info = ":Kaeru readme [owner/repo|file]" },
  { word = "dir", menu = "print the spec directory", info = ":Kaeru dir" },
  { word = "ai", menu = "curated AI coding plugin presets", info = ":Kaeru ai [preset]" },
  { word = "music", menu = "open the :Kikru", info = ":Kaeru music [action]" },
  { word = "karu", menu = "Google Cast (receive casts, cast to devices)", info = ":Kaeru karu <action>" },
  { word = "googlecast", menu = "alias of karu (Google Cast)" },
  { word = "boot", menu = "play the ASCII boot animation", info = ":Kaeru boot" },
  { word = "login", menu = "sign in to GitHub", info = ":Kaeru login [gh|token|device]" },
  { word = "logout", menu = "forget the GitHub token", info = ":Kaeru logout" },
  { word = "whoami", menu = "show the GitHub account + rate limit", info = ":Kaeru whoami" },
  { word = "sftp", menu = "SFTP studio, uploads, remote commands", info = ":Kaeru sftp <action>" },
  { word = "cache", menu = "plugin archive (zip / git bundle)", info = ":Kaeru cache <action>" },
  { word = "config", menu = "edit/reload kaeru.yaml", info = ":Kaeru config [edit|project|reload|show]" },
  { word = "mason", menu = "LSP/DAP/linter/formatter packages", info = ":Kaeru mason <action>" },
  { word = "starsky", menu = "SvelteKit Starsky web client", info = ":Kaeru starsky [start|stop|open|status|build|info]" },
  { word = "upgrade", menu = "update outdated packages in this project (npm, pip, cargo, go, lazy)", info = ":Kaeru upgrade [check|apply [latest]]" },
  { word = "cve", menu = "known CVEs for the packages in this project", info = ":Kaeru cve [scan [dir]|check <npm|pip|rust|go> <name> [version]]" },
  { word = "web", menu = "alias of starsky", info = ":Kaeru web [action]" },
  { word = "pick", menu = "open a picker in telescope / fzf-lua / snacks / mini.pick", info = ":Kaeru pick [plugins|mason|sftp|cache|radio|queue|cast]" },
  { word = "integrations", menu = "what is installed and wired up", info = ":Kaeru integrations" },
  { word = "complete", menu = "complete *anything* — pick from every candidate and run it", info = ":Kaeru complete [partial command line]" },
}

M.mason_actions = {
  { word = "pick", menu = "picker over every Mason package" },
  { word = "install", menu = "install packages" },
  { word = "uninstall", menu = "uninstall packages" },
  { word = "update", menu = "update a package" },
  { word = "upgrade", menu = "refresh the registry + update all" },
  { word = "ensure", menu = "install mason.ensure_installed" },
  { word = "export", menu = "write installed packages to kaeru.yaml" },
  { word = "list", menu = "list installed packages" },
  { word = "ft", menu = "packages for the current filetype" },
  { word = "lsp", menu = "LSP servers" },
  { word = "dap", menu = "debug adapters" },
  { word = "linter", menu = "linters" },
  { word = "formatter", menu = "formatters" },
  { word = "compiler", menu = "compilers" },
  { word = "runtime", menu = "runtimes" },
  { word = "scaffold", menu = "write ready-made specs (lsp|dap|tools)" },
  { word = "ui", menu = "open :Mason" },
  { word = "registry", menu = "open mason-registry.dev" },
}

M.mason_scaffolds = { "lsp", "dap", "tools" }

M.sftp_actions = {
  { word = "ui", menu = "dual-pane SFTP studio" },
  { word = "upload", menu = "upload the current file" },
  { word = "upload-project", menu = "parallel project upload" },
  { word = "sync", menu = "upload changed files only" },
  { word = "download", menu = "download the current file" },
  { word = "download-project", menu = "download the whole remote tree" },
  { word = "init", menu = "create .nvim-sftp.json" },
  { word = "status", menu = "connection / profile status" },
  { word = "select", menu = "switch the active profile" },
  { word = "browse", menu = "remote file browser" },
  { word = "diff", menu = "buffer vs remote copy" },
  { word = "test", menu = "connection test" },
  { word = "shell", menu = "interactive sftp split" },
  { word = "ssh", menu = "interactive ssh split" },
  { word = "run", menu = "run a command over ssh" },
  { word = "exec", menu = "raw sftp batch" },
  { word = "ls", menu = "list a remote directory", kind = "sftp" },
  { word = "mkdir", menu = "create a remote directory" },
  { word = "rmdir", menu = "remove a remote directory" },
  { word = "rm", menu = "remove a remote file" },
  { word = "rename", menu = "rename a remote path" },
  { word = "chmod", menu = "change permissions" },
  { word = "chown", menu = "change owner" },
  { word = "chgrp", menu = "change group" },
  { word = "ln", menu = "create a remote link" },
  { word = "symlink", menu = "create a remote symlink" },
  { word = "df", menu = "remote disk usage" },
  { word = "pwd", menu = "remote working directory" },
  { word = "version", menu = "remote sftp version" },
}

M.cache_actions = {
  { word = "pack", menu = "archive a plugin (zip / git bundle)" },
  { word = "restore", menu = "restore a plugin from the cache" },
  { word = "list", menu = "list cached plugins" },
  { word = "remove", menu = "delete one archive" },
  { word = "clean", menu = "drop archives of removed plugins" },
  { word = "dir", menu = "print the cache directory" },
}

M.config_actions = {
  { word = "edit", menu = "open ~/.config/nvim/kaeru.yaml" },
  { word = "project", menu = "open ./kaeru.yaml" },
  { word = "reload", menu = "re-read the YAML files" },
  { word = "show", menu = "show the effective configuration" },
  { word = "dump", menu = "alias of show" },
}

M.starsky_actions = {
  { word = "start", menu = "run the Vite dev server (npm run dev)" },
  { word = "stop", menu = "stop the dev server" },
  { word = "open", menu = "open the web client" },
  { word = "status", menu = "server status" },
  { word = "build", menu = "production build" },
  { word = "info", menu = "KIT splash with an animated pixel 3" },
}

-- :Kikru -------------------------------------------------------------------

M.pick_sources = { "plugins", "mason", "sftp", "cache", "radio", "queue", "cast", "karu", "commands", "files" }
M.completion_categories = {
  "karu",
  "command",
  "file",
  "dir",
  "buffer",
  "event",
  "filetype",
  "help",
  "option",
  "color",
  "shellcmd",
  "environment",
  "augroup",
  "mapping",
  "tag",
}

-- `:Karu` (Google Cast, the TypeScript implementation in karu/)
M.karu_actions = {
  { word = "discover", menu = "list Cast devices on the network", info = ":Karu discover [host:port]" },
  { word = "devices", menu = "alias of discover" },
  { word = "cast", menu = "cast a URL or search to a device", info = ":Karu cast <url|query> [device]" },
  { word = "play", menu = "resume on the device" },
  { word = "pause", menu = "pause on the device" },
  { word = "toggle", menu = "play/pause" },
  { word = "stop", menu = "stop playback" },
  { word = "quit", menu = "close the receiver app on the device" },
  { word = "seek", menu = "absolute position in seconds", info = ":Karu seek <seconds> [device]" },
  { word = "volume", menu = "device volume", info = ":Karu volume <0-100|+10|-10|mute|unmute> [device]" },
  { word = "status", menu = "what the device is playing" },
  { word = "probe", menu = "reachability test", info = ":Karu probe <host[:port]>" },
  { word = "receive", menu = "be a Cast device — casts land in Kikru", info = ":Karu receive [--name N] [--port P] [--no-mdns]" },
  { word = "off", menu = "stop the receiver" },
  { word = "bridge", menu = "receiver + Kikru bridge status" },
  { word = "info", menu = "protocol/environment report" },
  { word = "help", menu = "usage" },
}

M.karu_receive_flags = {
  { word = "--name", menu = "friendly name in the Cast list", info = "--name 'Karu · Neovim'" },
  { word = "--port", menu = "CASTV2 port (default 8009)", info = "--port 8009" },
  { word = "--no-mdns", menu = "do not advertise over mDNS" },
  { word = "--bridge", menu = "Kikru cast server URL", info = "--bridge http://127.0.0.1:8722" },
  { word = "--token", menu = "shared secret for the Kikru bridge" },
  { word = "--fallback", menu = "play locally when Kikru is down", info = "--fallback mpv|ffplay|none" },
  { word = "--address", menu = "address to advertise" },
}

--- Devices discovered by `:Karu discover`, as completion items.
---@return KaeruCompletionItem[]
function M.karu_devices()
  local ok, karu = pcall(require, "kaeru.karu")
  if not ok or type(karu.devices) ~= "function" then
    return {}
  end
  local items = {}
  for _, device in ipairs(karu.devices()) do
    items[#items + 1] = {
      word = device.name or device.address,
      menu = "[cast device]",
      info = ("%s:%s · %s"):format(device.address or "?", device.port or "?", device.model or "Cast device"),
    }
  end
  for _, entry in ipairs((Config.options.karu or {}).devices or {}) do
    items[#items + 1] = { word = entry, menu = "[cast device]", info = "from karu.devices" }
  end
  return items
end

M.kikru_cast_targets = { "youtube", "youtube-music", "ytmusic", "ytm", "playlist", "video", "radio", "app", "mpris", "browser" }
M.kikru_cast_actions = {
  { word = "play", menu = "resolve the link and start playing (default)" },
  { word = "queue", menu = "append the link to the queue (--queue)" },
  { word = "next", menu = "play the link right after the current track (--next)" },
  { word = "server", menu = "start the HTTP cast server (browser / phone / Stream Deck)" },
  { word = "stop", menu = "stop the cast server" },
  { word = "scheme", menu = "install the kikru:// URL scheme handler" },
  { word = "uninstall", menu = "remove the kikru:// handler" },
  { word = "status", menu = "show server, endpoint and yt-dlp status" },
  { word = "log", menu = "recent cast activity" },
}

M.kikru_actions = {
  { word = "ui", menu = "open the player window" },
  { word = "play", menu = "play (or resolve a source)", info = ":Kikru play <path|url|query>" },
  { word = "pause", menu = "pause" },
  { word = "toggle", menu = "toggle playback" },
  { word = "stop", menu = "stop playback" },
  { word = "send", menu = "send playback to a Cast device (Karu)", info = ":Kikru send [device|off|stop|status|devices]" },
  { word = "next", menu = "next track" },
  { word = "prev", menu = "previous track" },
  { word = "volume", menu = "set the volume 0-130", info = ":Kikru volume 65" },
  { word = "mute", menu = "mute" },
  { word = "unmute", menu = "unmute" },
  { word = "seek", menu = "seek ±/<seconds>", info = ":Kikru seek +30" },
  { word = "speed", menu = "playback speed", info = ":Kikru speed 1.25" },
  { word = "eq", menu = "10-band EQ preset or <band> <gain>", info = ":Kikru eq synthwave" },
  { word = "band", menu = "adjust one EQ band", info = ":Kikru band 1 +3" },
  { word = "presets", menu = "list every EQ preset" },
  { word = "filter", menu = "NodeLink/LavaLink effect filters", info = ":Kikru filter nightcore" },
  { word = "filters", menu = "alias of filter" },
  { word = "visualizer", menu = "spectrum|wave|vu|matrix|starfield" },
  { word = "theme", menu = "player theme", info = ":Kikru theme nord" },
  { word = "radio", menu = "search Radio Browser stations", info = ":Kikru radio lofi" },
  { word = "stream", menu = "alias of radio" },
  { word = "station", menu = "play a curated station", info = ":Kikru station somafm-defcon" },
  { word = "search", menu = "search a source", info = ":Kikru search <query> [source]" },
  { word = "cast", menu = "cast a YouTube / YouTube Music link or search" },
  { word = "youtube", menu = "YouTube search → play" },
  { word = "ytmusic", menu = "YouTube Music search → play" },
  { word = "appcast", menu = "continue the YouTube/YT Music app currently playing (MPRIS)" },
  { word = "sources", menu = "list the available sources (NodeLink style)" },
  { word = "library", menu = "index a local directory", info = ":Kikru library ~/Kikru" },
  { word = "index", menu = "alias of library" },
  { word = "lyrics", menu = "lyrics pane / provider tools", info = ":Kikru lyrics [providers|refresh|search|save]" },
  { word = "queue", menu = "queue operations", info = ":Kikru queue list|clear|save|load" },
  { word = "playlist", menu = "playlist files", info = ":Kikru playlist save|load|list|dir" },
  { word = "engine", menu = "audio backend", info = ":Kikru engine mpv|ffplay|vlc|mpd|mpris" },
  { word = "server", menu = "start the 2-Neovim server", info = ":Kikru server 41999" },
  { word = "connect", menu = "connect as a 2-Neovim client", info = ":Kikru connect 127.0.0.1:41999" },
  { word = "disconnect", menu = "leave the 2-Neovim session" },
  { word = "devices", menu = "list paired Neovim devices" },
  { word = "send", menu = "send playback to a Cast device (Karu)", info = ":Kikru send [device|off|stop|status|devices]" },
  { word = "receive", menu = "be a Cast device; casts land in Kikru (Karu receiver)", info = ":Kikru receive [start|stop|status]" },
  { word = "handoff", menu = "route the audio output to a device" },
  { word = "daemon", menu = "local IPC daemon", info = ":Kikru daemon start|stop|status" },
  { word = "ipc", menu = "send a command to the daemon", info = ":Kikru ipc play" },
  { word = "remote", menu = "send a command to the server" },
  { word = "status", menu = "show the player state" },
  { word = "info", menu = "alias of status" },
  { word = "config", menu = "open kaeru.yaml" },
  { word = "reset", menu = "forget the saved queue/EQ" },
}

M.kikru_eq_presets = {
  "lofi-coding", "synthwave", "focus", "bass-boost", "electronic", "vocal", "classical", "night",
  "flat", "treble-boost", "podcast", "rock", "pop", "jazz", "hiphop", "party", "soft", "treblebass",
  "bass_and_treble", "fullbass", "fulltreble", "fullbasstreble", "loudness", "movies", "rich",
  "speech", "headphone", "live", "vocalboost", "metal", "piano", "boost",
}

M.kikru_filters = {
  "nightcore", "vaporwave", "daycore", "bassboost", "8d", "karaoke", "tremolo", "vibrato",
  "compressor", "echo", "reverb", "chorus", "phaser", "lowpass", "soft", "treble",
}

M.kikru_visualizers = { "spectrum", "bars", "wave", "vu", "matrix", "starfield", "oscilloscope" }
M.kikru_themes = { "winamp", "tokyonight", "nord", "dracula", "gruvbox", "catppuccin" }
M.kikru_engines = { "auto", "mpv", "ffplay", "vlc", "mpd", "mpris" }
M.kikru_queue_actions = { "list", "clear", "save", "load", "remove", "move", "shuffle", "repeat", "play" }
M.kikru_playlist_actions = { "list", "save", "load", "open", "dir" }
M.kikru_ipc_actions = { "play", "pause", "toggle", "stop", "next", "prev", "volume", "seek", "status", "queue", "eq", "filter", "station" }
M.kikru_sources = { "auto", "youtube", "youtube_music", "soundcloud", "bandcamp", "mixcloud", "bilibili", "twitch", "spotify", "deezer", "apple_music", "yandex_music", "radio", "subsonic", "rss", "mpd" }
M.kikru_lyrics_actions = { "providers", "refresh", "search", "save" }

-- Dynamic data sources ------------------------------------------------------------

---@return string[]
function M.kikru_station_ids()
  local ok, Radio = pcall(require, "kaeru.kikru.radio")
  if not ok then
    return {}
  end
  local ids = {}
  for _, station in ipairs(Radio.stations) do
    ids[#ids + 1] = station.id
  end
  return ids
end

---@return string[]
function M.kikru_engines_available()
  local ok, Backend = pcall(require, "kaeru.kikru.backend")
  if not ok then
    return M.kikru_engines
  end
  local out = { "auto" }
  for _, engine in ipairs(Backend.available_engines()) do
    out[#out + 1] = engine.id
  end
  return out
end

---@return string[]
function M.sftp_profiles()
  local names = {}
  for name in pairs((Config.options.sftp and Config.options.sftp.profiles) or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---@return string[]
function M.cache_names()
  local names, seen = {}, {}
  local ok_cache, Cache = pcall(require, "kaeru.cache")
  if ok_cache and Cache.index then
    for name in pairs(Cache.index()) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  local ok_lazy, LazyConfig = pcall(require, "lazy.core.config")
  if ok_lazy and LazyConfig.plugins then
    for name in pairs(LazyConfig.plugins) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

---@return (string|KaeruCompletionItem)[]
function M.ai_preset_items()
  local ok, AI = pcall(require, "kaeru.ai")
  if not ok or not AI.presets then
    return {}
  end
  local out = {}
  for _, preset in ipairs(AI.presets) do
    out[#out + 1] = { word = preset.repo, menu = "[AI] " .. (preset.desc or "") }
  end
  return out
end

--- Collect all known repository names (live GitHub API + popular + AI presets + installed).
---@return KaeruCompletionItem[]
function M.collect_repos()
  local out = {}
  local seen = {}
  local function add(word, menu)
    if not word or word == "" or seen[word:lower()] then
      return
    end
    seen[word:lower()] = true
    out[#out + 1] = { word = word, menu = menu or "", kind = "Repo" }
  end

  for _, dyn in pairs(M.dynamic_repos) do
    add(dyn.word, dyn.menu)
  end

  local ok_gh, GitHub = pcall(require, "kaeru.github")
  if ok_gh and GitHub._cache then
    for _, cached in pairs(GitHub._cache) do
      for _, item in ipairs(cached.items or {}) do
        add(item.full_name, ("[★%s] %s"):format(GitHub.format_stars(item.stars or 0), item.description or ""))
      end
    end
  end

  for _, repo in ipairs(M.popular_repos) do
    add(repo.word, repo.menu)
  end

  for _, item in ipairs(M.ai_preset_items()) do
    add(item.word, item.menu)
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

-- Live GitHub repository completion (async, cached) ------------------------------

M.github_cache = {}
M.dynamic_repos = {}
M._github_inflight = {}

--- Register repository items returned from the GitHub API into the live cache.
---@param query string
---@param items {full_name: string, stars?: number, description?: string}[]
function M.add_github_results(query, items)
  local ok_gh, GitHub = pcall(require, "kaeru.github")
  local format_stars = (ok_gh and GitHub.format_stars) or function(n)
    return tostring(n or 0)
  end
  local formatted = {}
  for _, item in ipairs(items or {}) do
    if item and item.full_name then
      local entry = {
        word = item.full_name,
        menu = ("[GitHub ★%s] %s"):format(format_stars(item.stars or item.stargazers_count or 0), item.description or ""),
        kind = "Repo",
      }
      formatted[#formatted + 1] = entry
      M.dynamic_repos[item.full_name] = entry
    end
  end
  if query and query ~= "" then
    M.github_cache[query:lower()] = { items = formatted, ts = os.time() }
  end
  return formatted
end

--- Query the live GitHub Search API asynchronously (used while typing a repo).
---@param query string
---@param cb? fun(items: KaeruCompletionItem[])
function M.search_github_async(query, cb)
  query = Compat.trim(tostring(query or ""))
  if #query < 2 then
    if cb then
      cb({})
    end
    return
  end
  local key = query:lower()
  local cached = M.github_cache[key]
  if cached and (os.time() - (cached.ts or 0)) < 300 then
    if cb then
      cb(cached.items)
    end
    return
  end
  if M._github_inflight[key] then
    return
  end
  M._github_inflight[key] = true

  local ok_gh, GitHub = pcall(require, "kaeru.github")
  if not ok_gh or not GitHub.search then
    M._github_inflight[key] = false
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

  GitHub.search({ query = gh_query, per_page = 15, include_all = owner ~= nil }, function(err, res)
    M._github_inflight[key] = false
    if err or not res or not res.items then
      if cb then
        cb({})
      end
      return
    end
    local formatted = M.add_github_results(key, res.items)
    if cb then
      cb(formatted)
    end
  end)
end

-- Mason names ------------------------------------------------------------------------

--- Collect Mason package names + lspconfig names (live registry or built-in data).
---@param opts? {installed_only?: boolean, category?: string}
---@return string[]
function M.mason_names(opts)
  opts = opts or {}
  local names = {}
  local seen = {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  local ok_reg, registry = pcall(require, "mason-registry")
  if ok_reg then
    if opts.installed_only and registry.get_installed_package_names then
      for _, name in ipairs(registry.get_installed_package_names()) do
        add(name)
      end
      table.sort(names)
      return names
    end
    if registry.get_all_package_specs then
      local ok_specs, specs = pcall(registry.get_all_package_specs)
      if ok_specs and type(specs) == "table" and #specs > 0 then
        for _, spec in ipairs(specs) do
          local keep = true
          if opts.category and spec.categories then
            keep = false
            for _, category in ipairs(spec.categories) do
              if category:lower() == opts.category:lower() then
                keep = true
                break
              end
            end
          end
          if keep then
            add(spec.name)
            local lspconfig = spec.neovim and spec.neovim.lspconfig
            if lspconfig then
              add(lspconfig)
            end
          end
        end
        table.sort(names)
        return names
      end
    end
  end

  if not opts.installed_only then
    local ok_data, data = pcall(require, "kaeru.mason_data")
    if ok_data and data.packages then
      for _, package in ipairs(data.packages) do
        local keep = true
        if opts.category and package.categories then
          keep = false
          for _, category in ipairs(package.categories) do
            if category:lower() == opts.category:lower() then
              keep = true
              break
            end
          end
        end
        if keep then
          add(package.name)
          if package.lspconfig then
            add(package.lspconfig)
          end
        end
      end
    end
  end

  table.sort(names)
  return names
end

--- Turn a list of completion items into a plain word list (for messages,
--- pickers and `vim.tbl_contains` checks).
---@param list (string|KaeruCompletionItem)[]
---@return string[]
function M.words(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    out[#out + 1] = type(item) == "string" and item or item.word
  end
  return out
end

-- Native (Neovim) completion categories -----------------------------------------------

--- Candidates straight out of Neovim (`getcompletion`), so our popup can offer
--- files, buffers, options, events, colorschemes, help tags, … exactly like
--- `:e <Tab>` does — but fuzzy ranked and described.
---@param category string
---@param base string
---@return KaeruCompletionItem[]
--- Items for the lyrics provider names, from `kaeru.kikru.lyrics` when loaded.
---@return {word: string, menu: string}[]
function M.kikru_provider_items()
  local items = {}
  local ok, lyrics = pcall(require, "kaeru.kikru.lyrics")
  local providers = (ok and lyrics and lyrics.providers) and lyrics.providers() or nil
  if type(providers) == "table" then
    for _, provider in ipairs(providers) do
      items[#items + 1] = { word = provider.name, menu = provider.label or "lyrics provider" }
    end
  end
  if #items == 0 then
    for _, name in ipairs({ "lrc.red", "lrclib", "netease", "synclrc", "lyrics.ovh" }) do
      items[#items + 1] = { word = name, menu = "lyrics provider" }
    end
  end
  return items
end

function M.native_items(category, base, menu)
  local items = {}
  for _, word in ipairs(Compat.getcompletion(base or "", category)) do
    if word ~= "" then
      items[#items + 1] = { word = word, menu = menu or ("[" .. category .. "]"), kind = category }
    end
  end
  return items
end

--- Every native (Neovim) completion category we surface, keyed by the
--- `getcompletion()` name and mapped to the menu label shown in the popup.
---@return table<string, string>
function M.native_categories()
  return {
    command = "command",
    file = "file",
    dir = "directory",
    buffer = "buffer",
    arglist = "arglist",
    color = "colorscheme",
    event = "autocmd event",
    filetype = "filetype",
    help = "help tag",
    option = "option",
    environment = "environment",
    augroup = "augroup",
    mapping = "mapping",
    mapclear = "mapping",
    tag = "tag",
    highlight = "highlight",
    ["function"] = "function",
    lua = "lua",
    menu = "menu item",
    sign = "sign",
    syntax = "syntax",
    compiler = "compiler",
    checkhealth = "checkhealth",
    packadd = "package",
    runtime = "runtime file",
    history = "history",
    messages = "message",
    var = "variable",
    user = "user command",
    file_in_path = "file in path",
  }
end

--- Everything a `:` line could possibly complete to: our own commands first,
--- then every native category Neovim knows about. This is what
--- `:Kaeru complete <prefix>` (and `complete.any = true`) uses.
---@param prefix? string
---@return KaeruCompletionItem[]
function M.everything(prefix)
  prefix = prefix or ""
  local items = {}
  local seen = {}
  local function push(item)
    if item and item.word and item.word ~= "" and not seen[item.word] then
      seen[item.word] = true
      items[#items + 1] = item
    end
  end
  for _, name in ipairs({ "Kaeru", "Kikru", "Karu" }) do
    push({ word = name, menu = "[" .. name .. "] command" })
  end
  for _, name in ipairs({ "Kaeru", "Kikru", "Karu" }) do
    for _, item in ipairs(M.rank(M.resolve_for(name, { name, "" }), "")) do
      push({ word = name .. " " .. item.word, menu = item.menu, kind = item.kind })
    end
  end
  for category, menu in pairs(M.native_categories()) do
    for _, item in ipairs(M.native_items(category, prefix, "[" .. menu .. "]")) do
      push(item)
    end
  end
  return M.rank(items, prefix, { limit = 800 })
end

-- Command line parsing ---------------------------------------------------------------

--- Strip the leading range / `:` / bang and split chained commands on `|`.
---@param line string
---@return string[] tokens, string command, string arglead
local RANGE_PATTERNS = {
  "^'[%w<>],'[%w<>]", -- '<,'>  'a,'b
  "^%d+,%d+", -- 1,5
  "^%d+", -- 5
  "^%%", -- %
  "^%$", -- $
  "^'[%w<>]", -- 'a
  "^[%.%$][%+%-]?%d*", -- . .+2 $ -3
}

---@param text string
---@return string
local function strip_range(text)
  local changed = true
  while changed do
    changed = false
    for _, pattern in ipairs(RANGE_PATTERNS) do
      local matched = text:match(pattern)
      if matched then
        text = text:sub(#matched + 1):gsub("^%s+", "")
        changed = true
        break
      end
    end
  end
  return text
end

function M.parse_cmdline(line)
  line = tostring(line or "")
  -- only work on the last `|` segment (commands can be chained)
  local segments = {}
  for segment in line:gmatch("[^|]+") do
    segments[#segments + 1] = segment
  end
  local active = segments[#segments] or line
  active = strip_range(active:gsub("^[:%s]*", ""))
  local tokens = {}
  local trailing_space = active:match("%s$") ~= nil
  for word in active:gmatch("%S+") do
    tokens[#tokens + 1] = word
  end
  local command = (tokens[1] or ""):gsub("!$", "")
  local arglead = trailing_space and "" or (tokens[#tokens] or "")
  if #tokens == 1 and not trailing_space then
    arglead = tokens[1]
    command = tokens[1]
  end
  if trailing_space then
    tokens[#tokens + 1] = ""
  end
  return tokens, command, arglead
end

--- Which of our commands does the line start with (abbreviations included)?
---@param line string
---@return string|nil
function M.detect_command(line)
  local _, command = M.parse_cmdline(line)
  if command == "" then
    return nil
  end
  local names = { "Kaeru", "Kikru", "Karu" }
  for _, name in ipairs(names) do
    if command == name then
      return name
    end
    if #command >= 3 and name:lower():sub(1, #command) == command:lower() then
      return name
    end
  end
  return nil
end

--- Argument position = how many arguments were typed before the current one.
---@param tokens string[]
---@param command string
---@return integer
local function arg_position(tokens, command)
  local count = 0
  for index = 2, #tokens do
    if index == #tokens and tokens[index] == "" then
      break
    end
    count = count + 1
  end
  local _ = command
  return count
end

---@param tokens string[]
---@return string|nil
local function previous(tokens)
  -- tokens[#tokens] is the (possibly empty) arglead
  local index = #tokens - 1
  if index >= 2 then
    return tokens[index]
  end
  return nil
end

local function none()
  return {}
end

--- Resolve candidate items for `:Kaeru`.
---@param tokens string[]
---@return (string|KaeruCompletionItem)[]
local function resolve_kaeru(tokens)
  local argc = #tokens -- tokens[1] = command, tokens[#tokens] = arglead
  local sub = tokens[2]
  local prev = previous(tokens)

  if sub == nil or (argc == 2 and prev == nil) then
    local items = {}
    vim.list_extend(items, M.subcommands)
    for _, repo in ipairs(M.collect_repos()) do
      items[#items + 1] = repo
    end
    return items
  end

  if sub == "add" or sub == "save" or sub == "modal" then
    if argc <= 3 then
      local items = {}
      vim.list_extend(items, M.collect_repos())
      return items
    end
    return none()
  elseif sub == "browse" or sub == "search" then
    return none()
  elseif sub == "parse" or sub == "readme" then
    if argc <= 3 then
      local items = { { word = "README.md", menu = "current directory" } }
      vim.list_extend(items, M.collect_repos())
      if vim.fn.getcompletion then
        local ok, files = pcall(vim.fn.getcompletion, tokens[#tokens], "file")
        if ok and type(files) == "table" then
          for _, file in ipairs(files) do
            items[#items + 1] = { word = file, menu = "[file]" }
          end
        end
      end
      return items
    end
  elseif sub == "music" then
    return { { word = "ui" }, { word = "eq" }, { word = "radio" }, { word = "server" }, { word = "connect" } }
  elseif sub == "karu" or sub == "googlecast" then
    -- `:Kaeru karu …` mirrors `:Karu …`
    local inner = tokens[3]
    if inner == nil or (argc == 3 and prev == nil) then
      return M.karu_actions
    end
    if inner == "receive" then
      return M.karu_receive_flags
    end
    if inner == "cast" then
      return M.karu_devices()
    end
    return M.karu_devices()
  elseif sub == "ai" then
    if argc <= 3 then
      return M.ai_preset_items()
    end
  elseif sub == "login" and argc <= 3 then
    return { { word = "gh", menu = "use the GitHub CLI token" }, { word = "token", menu = "paste a personal access token" }, { word = "device", menu = "browser device flow" } }
  elseif sub == "sftp" then
    if argc <= 3 then
      return M.sftp_actions
    end
    local action = tokens[3]
    if action == "select" then
      return M.sftp_profiles()
    end
    if action == "upload" or action == "download" or action == "browse" or action == "diff" then
      local base = tokens[#tokens] or ""
      local items = M.native_items("file", base, "[local file]")
      vim.list_extend(items, M.native_items("dir", base, "[local dir]"))
      return items
    end
    if action == "profile" or action == "connect" or action == "exec" or action == "test" then
      return M.sftp_profiles()
    end
    if action == "init" or action == "config" then
      return M.native_items("file", tokens[#tokens] or "", "[config file]")
    end
    return none()
  elseif sub == "cache" then
    if argc <= 3 then
      return M.cache_actions
    end
    local action = tokens[3]
    if action == "pack" then
      local items = { { word = "all", menu = "archive every installed plugin" } }
      for _, name in ipairs(M.cache_names()) do
        items[#items + 1] = { word = name }
      end
      return items
    elseif action == "restore" or action == "remove" then
      return M.cache_names()
    end
    return none()
  elseif sub == "mason" then
    if argc <= 3 then
      local items = {}
      vim.list_extend(items, M.mason_actions)
      for _, name in ipairs(M.mason_names()) do
        items[#items + 1] = { word = name, menu = "[package]" }
      end
      return items
    end
    local action = tokens[3]
    if action == "scaffold" and argc == 4 then
      return M.mason_scaffolds
    end
    if action == "uninstall" or action == "update" then
      return M.mason_names({ installed_only = true })
    end
    local categories = { lsp = "LSP", dap = "DAP", linter = "Linter", formatter = "Formatter", compiler = "Compiler", runtime = "Runtime" }
    if categories[action] then
      return M.mason_names({ category = categories[action] })
    end
    return M.mason_names()
  elseif sub == "pick" then
    if argc <= 3 then
      local items = {}
      for _, source in ipairs(M.pick_sources) do
        items[#items + 1] = { word = source, menu = "picker source" }
      end
      vim.list_extend(items, M.native_items(tokens[#tokens] or "", "file", "[file]"))
      return items
    end
    return {}
  elseif sub == "integrations" then
    return {}
  elseif sub == "complete" then
    -- `:Kaeru complete <partial command line>` — complete the partial line.
    local partial = table.concat(Compat.list_slice(tokens, 3), " ")
    return M.everything(partial)
  elseif sub == "config" and argc <= 3 then
    return M.config_actions
  elseif (sub == "starsky" or sub == "web") and argc <= 3 then
    return M.starsky_actions
  end
  return none()
end

--- Resolve candidate items for `:Kikru`.
---@param tokens string[]
---@return (string|KaeruCompletionItem)[]
local function resolve_kikru(tokens)
  local argc = #tokens
  local first = tokens[2]
  if first == nil then
    return M.kikru_actions
  end
  local action = first:lower()
  if argc <= 2 then
    return M.kikru_actions
  end
  if action == "cast" then
    local modes = { { word = "--queue", menu = "append to the queue" }, { word = "--next", menu = "play right after the current track" }, { word = "--play", menu = "start playing immediately (default)" } }
    if argc == 3 then
      local items = {}
      vim.list_extend(items, M.kikru_cast_actions)
      vim.list_extend(items, M.kikru_cast_targets)
      vim.list_extend(items, modes)
      return items
    end
    if argc == 4 then
      local sub_action = (tokens[3] or ""):lower()
      if sub_action == "server" then
        return { { word = tostring((function()
          local ok, Cast = pcall(require, "kaeru.kikru.cast")
          return ok and Cast.default_port or 8722
        end)()), menu = "default port" } }
      end
      if sub_action == "uninstall" or sub_action == "stop" or sub_action == "log" or sub_action == "status" then
        return {}
      end
      if Compat.tbl_contains(M.kikru_cast_targets, sub_action) then
        return modes
      end
      -- a YouTube/YouTube Music URL or search term: offer recent casts
      local items = vim.deepcopy(modes)
      if vim.fn.getcompletion then
        for _, file in ipairs(Compat.getcompletion(tokens[#tokens], "file")) do
          items[#items + 1] = { word = file, menu = "[file]" }
        end
      end
      return items
    end
    if argc >= 5 and Compat.tbl_contains(M.kikru_cast_targets, (tokens[3] or ""):lower()) then
      return modes
    end
  end
  if argc >= 5 and (action == "playlist" or action == "playlists") then
    local sub_action = (tokens[3] or ""):lower()
    if sub_action == "load" or sub_action == "open" or sub_action == "save" then
      local items = {}
      for _, name in ipairs((function()
        local ok, playlist = pcall(require, "kaeru.kikru.playlist")
        return ok and playlist.available() or {}
      end)()) do
        items[#items + 1] = { word = name, menu = "[playlist]" }
      end
      vim.list_extend(items, M.native_items("file", tokens[#tokens] or "", "[file]"))
      return items
    end
  end
  if argc == 5 and (action == "queue" or action == "enqueue") then
    local sub_action = (tokens[3] or ""):lower()
    if sub_action == "load" or sub_action == "save" then
      return M.native_items("file", tokens[#tokens] or "", "[playlist file]")
    end
  end
  if argc == 3 or argc == 4 then
    if action == "eq" or action == "presets" then
      return M.kikru_eq_presets
    elseif action == "filter" or action == "filters" then
      return M.kikru_filters
    elseif action == "visualizer" or action == "vis" then
      return M.kikru_visualizers
    elseif action == "theme" then
      return M.kikru_themes
    elseif action == "engine" then
      return M.kikru_engines_available()
    elseif action == "station" then
      return M.kikru_station_ids()
    elseif action == "search" and argc == 4 then
      return M.kikru_sources
    elseif action == "queue" or action == "enqueue" then
      return M.kikru_queue_actions
    elseif action == "playlist" or action == "playlists" then
      return M.kikru_playlist_actions
    elseif action == "ipc" or action == "remote" then
      return M.kikru_ipc_actions
    elseif action == "daemon" then
      return { "start", "stop", "status" }
    elseif action == "lyrics" then
      local sub_action = (tokens[3] or ""):lower()
      if sub_action == "" then
        return M.kikru_lyrics_actions
      end
      if sub_action == "search" then
        local items = vim.deepcopy(M.kikru_sources)
        vim.list_extend(items, M.kikru_provider_items())
        return items
      end
      if sub_action == "providers" or sub_action == "sources" or sub_action == "refresh"
        or sub_action == "reload" or sub_action == "update" then
        return none()
      end
      return M.native_items("file", tokens[#tokens] or "", "[local file]")
    elseif action == "play" or action == "add" then
      local items = vim.deepcopy(M.kikru_sources)
      vim.list_extend(items, M.native_items("file", tokens[#tokens] or "", "[local file]"))
      return items
    elseif action == "library" or action == "index" then
      return M.native_items("dir", tokens[#tokens] or "", "[local dir]")
    elseif action == "band" then
      local items = {}
      for band = 1, 10 do
        items[#items + 1] = { word = tostring(band), menu = ("%s Hz"):format(({ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 })[band]) }
      end
      return items
    elseif action == "volume" or action == "vol" or action == "seek" or action == "speed" or action == "preamp" then
      return {}
    end
  end
  return none()
end

-- Public completion API ----------------------------------------------------------------

--- Rich completion items for a whole `:` command line (used by the user
--- commands and by the live popup).
---@param cmdline string  the raw command line (`:Kaeru add fol`)
---@param cursorpos? integer
---@return KaeruCompletionItem[]
function M.complete_items(cmdline, cursorpos)
  local line = cursorpos and tostring(cmdline):sub(1, cursorpos) or tostring(cmdline)
  local name = M.detect_command(line)
  if not name then
    -- Not one of our commands: complete it like Neovim would (`:set`, `:au`,
    -- `:colorscheme`, `:e ++`, `:lua`, `:normal`, every file-taking command…).
    -- With `complete.any = true` *everything* Neovim can complete is offered
    -- for unknown commands too.
    local settings = (Config.options.complete or {})
    local items = Native.items(line, { any = settings.any == true })
    if #items > 0 then
      for _, item in ipairs(items) do
        item.kind = item.kind or "i"
        item.score = nil
      end
      return items
    end
    if settings.any then
      local _, _, arglead = M.parse_cmdline(line)
      local everything = M.everything(arglead)
      for _, item in ipairs(everything) do
        item.kind = item.kind or "i"
        item.score = nil
      end
      return everything
    end
    return {}
  end
  local tokens, command, arglead = M.parse_cmdline(line)
  local _ = command
  local candidates
  if name == "Kaeru" then
    candidates = resolve_kaeru(tokens)
  elseif name == "Kikru" then
    candidates = resolve_kikru(tokens)
  elseif name == "Karu" then
    candidates = M.resolve_karu(tokens)
  else
    candidates = {}
  end

  -- Live GitHub search for repository arguments (results are cached for 5 min).
  if name == "Kaeru" then
    local sub = tokens[2]
    local is_repo_arg = sub == "add" or sub == "save" or sub == "modal" or sub == "parse" or sub == "readme"
    if is_repo_arg and #arglead >= 2 then
      M.search_github_async(arglead)
    end
  end

  local items = M.rank(candidates, arglead)
  -- `complete()` wants a `kind` for the icon column.
  for _, item in ipairs(items) do
    item.kind = item.kind or "i"
    item.score = nil
  end
  return items
end

--- Resolve candidates for a `:Karu` command line.
---@param tokens string[]
---@return (string|KaeruCompletionItem)[]
function M.resolve_karu(tokens)
  local argc = #tokens -- tokens[1] = command, tokens[#tokens] = arglead
  local sub = tokens[2]
  if sub == nil or sub == "" or (argc == 2 and previous(tokens) == nil) then
    -- `:Karu <Tab>` — offer the actions plus the devices found last time.
    local items = {}
    vim.list_extend(items, M.karu_actions)
    vim.list_extend(items, M.karu_devices())
    return items
  end
  if sub == "receive" or sub == "start" or sub == "on" then
    return M.karu_receive_flags
  end
  if sub == "cast" or sub == "status" or sub == "stop" or sub == "play" or sub == "pause"
    or sub == "toggle" or sub == "quit" or sub == "seek" or sub == "volume" then
    return M.karu_devices()
  end
  return none()
end

--- Plain word list (backwards compatible API, used by tests and pickers).
---@param arglead string
---@param cmdline string
---@param cursorpos? integer
---@return string[]
function M.cmdline(arglead, cmdline, cursorpos)
  local _ = arglead
  local words = {}
  for _, item in ipairs(M.complete_items(cmdline, cursorpos)) do
    words[#words + 1] = item.word
  end
  return words
end

---@param arglead string
---@param cmdline string
---@param cursorpos? integer
---@return string[]
function M.kikru_cmdline(arglead, cmdline, cursorpos)
  local _ = arglead
  local words = {}
  for _, item in ipairs(M.complete_items(cmdline, cursorpos)) do
    words[#words + 1] = item.word
  end
  return words
end

-- Live `:` autocomplete ----------------------------------------------------------------

M._cmdline_timer = nil
M._cmdline_generation = 0

--- Trigger the command-line popup for the current cmdline (best effort).
---@return boolean shown
function M.trigger_cmdline_popup()
  local ctype = Compat.cmdtype()
  if ctype ~= nil and ctype ~= ":" then
    return false
  end
  if vim.fn.pumvisible and vim.fn.pumvisible() == 1 then
    return false
  end
  if vim.fn.wildmenumode and vim.fn.wildmenumode() == 1 then
    return false
  end
  local line = Compat.cmdline()
  if line == "" or not M.detect_command(":" .. line) then
    return false
  end
  local _, _, arglead = M.parse_cmdline(":" .. line)
  if #arglead < 1 then
    return false
  end
  -- Neovim >= 0.11 can re-run the command's own completion directly.
  if vim.fn.wildtrigger then
    local ok = pcall(vim.fn.wildtrigger)
    return ok
  end
  local items = M.complete_items(":" .. line, #line + 1)
  if #items == 0 then
    return false
  end
  local col = Compat.cmdpos() - 1
  local ok = pcall(vim.fn.complete, col, items)
  return ok
end

--- Install the live popup + `<Tab>` cycling for `:` command lines.
---@param opts? {popup?: boolean, tab?: boolean}
function M.setup_cmdline(opts)
  opts = opts or {}
  local settings = (Config.options.complete or {})
  local popup = opts.popup
  if popup == nil then
    popup = settings.cmdline ~= false
  end
  local tab = opts.tab
  if tab == nil then
    tab = settings.cmdline_tab ~= false
  end

  if popup and vim.api.nvim_create_autocmd then
    local group = vim.api.nvim_create_augroup("KaeruCmdlineComplete", { clear = true })
    vim.api.nvim_create_autocmd("CmdlineEnter", {
      group = group,
      pattern = ":",
      callback = function()
        pcall(function()
          vim.opt.wildmenu = true
          vim.opt.wildmode = { "longest:full", "full" }
          if vim.fn.has("nvim-0.9") == 1 then
            pcall(function()
              vim.opt.wildoptions = { "pum", "fuzzy" }
            end)
          end
        end)
      end,
      desc = "kaeru.nvim: prepare the `:` completion popup",
    })
    vim.api.nvim_create_autocmd({ "CmdlineChanged", "CmdlineEnter" }, {
      group = group,
      pattern = ":",
      callback = function()
        if not M.detect_command(":" .. Compat.cmdline()) then
          return
        end
        if M._cmdline_timer and vim.uv and vim.uv.timer_stop then
          M._cmdline_timer:stop()
        end
        M._cmdline_generation = M._cmdline_generation + 1
        local generation = M._cmdline_generation
        Compat.defer_fn(function()
          if generation ~= M._cmdline_generation then
            return
          end
          pcall(M.trigger_cmdline_popup)
        end, 45)
      end,
      desc = "kaeru.nvim: live `:` completion popup",
    })
  end

  if tab then
    local function cycle(delta)
      return function()
        local keys = delta > 0 and "<C-n>" or "<C-p>"
        return keys
      end
    end
    pcall(vim.keymap.set, "c", "<Tab>", cycle(1), { expr = true, desc = "kaeru.nvim: next candidate" })
    pcall(vim.keymap.set, "c", "<S-Tab>", cycle(-1), { expr = true, desc = "kaeru.nvim: previous candidate" })
  end
end

-- nvim-cmp / blink.cmp cmdline source adapters --------------------------------------------

--- nvim-cmp source for `:` (register with
--- `require("cmp").register_source("kaeru", require("kaeru.complete").cmp_source())`).
---@return table
function M.cmp_source()
  return {
    name = "kaeru",
    is_available = function()
      return Compat.cmdtype() == ":"
    end,
    complete = function(_, _, callback)
      local line = Compat.cmdline()
      if not M.detect_command(":" .. line) then
        return callback({})
      end
      local items = M.complete_items(":" .. line, #line + 1)
      local out = {}
      for _, item in ipairs(items) do
        out[#out + 1] = {
          label = item.word,
          labelDetails = item.menu and { description = item.menu } or nil,
          kind = 1,
          insertText = item.word,
        }
      end
      callback(out)
    end,
  }
end

--- blink.cmp source: `require("kaeru.complete").blink_source()` then
--- `providers.kaeru = ...` in the `cmdline` provider config.
---@return table
function M.blink_source()
  return {
    name = "kaeru",
    enabled = function()
      return Compat.cmdtype() == ":"
    end,
    get_trigger_characters = function()
      return { ":" }
    end,
    get_completions = function(_, _, callback)
      local line = Compat.cmdline()
      if not M.detect_command(":" .. line) then
        return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
      end
      local items = {}
      for _, item in ipairs(M.complete_items(":" .. line, #line + 1)) do
        items[#items + 1] = {
          label = item.word,
          labelDetails = item.menu and { description = item.menu } or nil,
          insertText = item.word,
          kind = 9,
        }
      end
      callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = false })
    end,
  }
end

--- Legacy aliases (the module used to live inside `kaeru.music`).
M.music_cmdline = M.kikru_cmdline
M.music_actions = M.kikru_actions
M.music_eq_presets = M.kikru_eq_presets
M.music_filters = M.kikru_filters
M.music_visualizers = M.kikru_visualizers
M.music_themes = M.kikru_themes
M.music_engines = M.kikru_engines
M.music_queue_actions = M.kikru_queue_actions
M.music_playlist_actions = M.kikru_playlist_actions
M.music_ipc_actions = M.kikru_ipc_actions
M.music_sources = M.kikru_sources

-- Modal form completion ---------------------------------------------------------------

--- Register `omnifunc`/`completefunc` + the auto popup in the form buffer.
---@param buf integer
function M.attach_form(buf)
  vim.bo[buf].omnifunc = "v:lua.require'kaeru.complete'.omnifunc"
  vim.bo[buf].completefunc = "v:lua.require'kaeru.complete'.omnifunc"
end

--- Compute completion candidates for a given form field `key` and token `base`.
---@param key string
---@param base string
---@param form? KaeruForm
---@return KaeruCompletionItem[]
function M.complete_field(key, base, form)
  base = base or ""
  local candidates = {}

  local function push(word, menu, kind)
    if not word or word == "" then
      return
    end
    candidates[#candidates + 1] = { word = word, menu = menu or "", kind = kind or key }
  end

  if key == "repo" then
    for _, item in ipairs(M.collect_repos()) do
      push(item.word, item.menu, "Repo")
    end
  elseif key == "file" then
    if form and form.repo and form.repo ~= "" then
      local parsed = Spec.parse_repo(form.repo)
      if parsed then
        local default = Spec.default_filename(parsed.base)
        push(default, "[Auto] default spec file name", "File")
        push("ui-" .. default, "[UI] grouped spec file", "File")
        push("lsp-" .. default, "[LSP] grouped spec file", "File")
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
  elseif key == "lazy" or key == "pin" or key == "cond" or key == "enabled" then
    push("true", "Boolean true", "Bool")
    push("false", "Boolean false", "Bool")
  elseif key == "event" then
    for _, event in ipairs(M.events) do
      push(event.word, event.menu, "Event")
    end
  elseif key == "ft" then
    local seen = {}
    for _, filetype in ipairs(M.filetypes) do
      seen[filetype] = true
      push(filetype, "[Filetype]", "Ft")
    end
    if vim.fn.getcompletion then
      local ok, runtime_filetypes = pcall(vim.fn.getcompletion, base, "filetype")
      if ok and type(runtime_filetypes) == "table" then
        for _, filetype in ipairs(runtime_filetypes) do
          if not seen[filetype] then
            seen[filetype] = true
            push(filetype, "[Filetype]", "Ft")
          end
        end
      end
    end
  elseif key == "cmd" then
    local seen = {}
    for _, command in ipairs(M.commands) do
      seen[command] = true
      push(command, "[Command]", "Cmd")
    end
    if vim.fn.getcompletion and #base >= 1 then
      local ok, runtime_commands = pcall(vim.fn.getcompletion, base, "command")
      if ok and type(runtime_commands) == "table" then
        for i = 1, math.min(#runtime_commands, 40) do
          local command = runtime_commands[i]
          if not seen[command] then
            seen[command] = true
            push(command, "[Command]", "Cmd")
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
    for _, item in ipairs(key_items) do
      push(item.word, item.menu, "Keys")
    end
  elseif key == "dependencies" then
    local seen = {}
    for _, dependency in ipairs(M.common_dependencies) do
      seen[dependency.word:lower()] = true
      push(dependency.word, dependency.menu, "Dep")
    end
    for _, repo in ipairs(M.collect_repos()) do
      if not seen[repo.word:lower()] then
        seen[repo.word:lower()] = true
        push(repo.word, repo.menu, "Dep")
      end
    end
  elseif key == "version" then
    push("*", "Latest stable semver release", "Ver")
    push("false", "Always use latest branch HEAD", "Ver")
    push("^1.0.0", "Semver compatible with 1.x", "Ver")
    push("~0.1.0", "Semver patch range", "Ver")
  elseif key == "branch" then
    for _, branch in ipairs({ "main", "master", "canary", "nightly", "release", "v2", "0.1.x" }) do
      push(branch, "[Git branch]", "Branch")
    end
  elseif key == "priority" then
    push("1000", "Recommended for colorschemes", "Priority")
    push("500", "High startup priority", "Priority")
    push("100", "Above default priority", "Priority")
    push("50", "Default lazy.nvim priority", "Priority")
  elseif key == "build" then
    for _, build in ipairs(M.builds) do
      push(build.word, build.menu, "Build")
    end
  elseif key == "opts" then
    push("{}", "Empty opts table (calls setup({}))", "Opts")
    push("{ }", "Opts table literal", "Opts")
  elseif key == "config" then
    push("true", "Run require(MAIN).setup(opts) automatically", "Config")
    push("function", "Generate function(_, opts) skeleton", "Config")
    if form and form.repo and form.repo ~= "" then
      local parsed = Spec.parse_repo(form.repo)
      local module = parsed and Spec.default_filename(parsed.base) or "plugin"
      push(('function(_, opts) require(%q).setup(opts) end'):format(module), "Inline config function", "Config")
    end
  elseif key == "init" then
    push("function() end", "Startup init hook", "Init")
  end

  return M.rank(candidates, base)
end

--- Compute the byte index (0-based) where completion starts on a form line.
---@param line string
---@param col integer  0-based cursor byte column
---@param row integer  1-based buffer row
---@return integer start_col, string key, string base
function M.find_form_start(line, col, row)
  local Form = require("kaeru.form")
  local field = Form.fields[row]
  local key = field and field.key or ""
  local separator = line:find(" : ", 1, true)
  local min_col = separator and (separator + 2) or 18
  local before = line:sub(1, math.max(min_col, col))

  local start_col = min_col
  if M.CSV_FIELDS[key] and not before:sub(min_col + 1):match("^%s*{") then
    local last_comma = before:sub(min_col + 1):match("^.*(),")
    if last_comma then
      start_col = min_col + last_comma
    end
  end

  while start_col < col and line:sub(start_col + 1, start_col + 1):match("%s") do
    start_col = start_col + 1
  end

  local base = line:sub(start_col + 1, col)
  return start_col, key, base
end

--- Neovim `omnifunc` / `completefunc` implementation for the modal buffer.
---@param findstart integer 1|0
---@param base string
---@return integer|table
function M.omnifunc(findstart, base)
  local Form = require("kaeru.form")
  if not Form.is_open() then
    return findstart == 1 and -3 or {}
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

  local start_col, key = M.find_form_start(line, col, row)
  if findstart == 1 then
    return start_col
  end
  local form = Form.read()
  return M.complete_field(key, base, form)
end

--- Trigger the popup menu in the form buffer (with the live GitHub lookup).
---@param buf integer
---@param win integer
---@param explicit? boolean
function M.trigger(buf, win, explicit)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not vim.api.nvim_get_mode().mode:match("^i") then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local start_col, key, base = M.find_form_start(line, col, row)
  if not explicit and base == "" then
    return
  end
  local Form = require("kaeru.form")
  local items = M.complete_field(key, base, Form.read())

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
      local cursor2 = vim.api.nvim_win_get_cursor(win)
      local line2 = vim.api.nvim_buf_get_lines(buf, cursor2[1] - 1, cursor2[1], false)[1] or ""
      local start2, key2, base2 = M.find_form_start(line2, cursor2[2], cursor2[1])
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
  if not explicit and #items == 1 and items[1].word == base then
    return
  end
  vim.fn.complete(start_col + 1, items)
end

--- Resolve candidates for one of our commands by name (used by
--- `M.everything` / `:Kaeru complete`).
---@param name string  "Kaeru" | "Kikru" | "Karu"
---@param tokens string[]
---@return (string|KaeruCompletionItem)[]
function M.resolve_for(name, tokens)
  if name == "Kaeru" then
    return resolve_kaeru(tokens)
  elseif name == "Kikru" then
    return resolve_kikru(tokens)
  end
  return {}
end


return M
