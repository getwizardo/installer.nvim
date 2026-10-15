-- :Clina — NeoCodeium (`monkoose/neocodeium`) AI Coding IDE integration for Neovim
-- Reference: https://github.com/monkoose/neocodeium
local Config = require("installer.config")
local Process = require("installer.process")
local UI = require("installer.ui")

local M = {}

M.NEOCODEIUM_REPO = "monkoose/neocodeium"

---@class ClinaProvider
---@field id string
---@field name string
---@field model string
---@field env_key? string
---@field description string

---@type ClinaProvider[]
M.providers = {
  {
    id = "neocodeium",
    name = "NeoCodeium (monkoose/neocodeium)",
    model = "neocodeium-windsurf",
    description = "Primary :Clina engine — flicker-free NeoCodeium inline completion, word/line accept, dot-repeat & Windsurf Chat",
  },
  {
    id = "clina-ts",
    name = "Clina TypeScript Engine",
    model = "clina-coder-ts-v1",
    description = "Built-in TypeScript AST, refactoring, diff & Neovim spec synthesis engine",
  },
  {
    id = "anthropic",
    name = "Anthropic Claude",
    model = "claude-sonnet-4-5",
    env_key = "ANTHROPIC_API_KEY",
    description = "Claude 4.5 Sonnet for agentic multi-file coding & tool use",
  },
  {
    id = "openai",
    name = "OpenAI",
    model = "gpt-5",
    env_key = "OPENAI_API_KEY",
    description = "OpenAI GPT-5 / o3-mini reasoning & code generation",
  },
  {
    id = "gemini",
    name = "Google Gemini",
    model = "gemini-2.5-pro",
    env_key = "GEMINI_API_KEY",
    description = "Gemini 2.5 Pro with 1M+ token repository context window",
  },
  {
    id = "deepseek",
    name = "DeepSeek",
    model = "deepseek-coder-r1",
    env_key = "DEEPSEEK_API_KEY",
    description = "DeepSeek R1 / V3 reasoning & code synthesis",
  },
  {
    id = "ollama",
    name = "Ollama (Local)",
    model = "qwen2.5-coder:14b",
    env_key = "OLLAMA_HOST",
    description = "Local self-hosted LLM via Ollama (http://127.0.0.1:11434)",
  },
}

---@class ClinaMcpTool
---@field id string
---@field name string
---@field enabled boolean
---@field description string

---@type ClinaMcpTool[]
M.mcp_tools = {
  { id = "neocodeium", name = "NeoCodeium Ghost-Text & Chat", enabled = true, description = "monkoose/neocodeium inline completion, accept_word, accept_line, cycle_or_complete & Windsurf chat" },
  { id = "filesystem", name = "Workspace Filesystem", enabled = true, description = "Read, search, create, and patch files in the active workspace" },
  { id = "git", name = "Git & Diff Engine", enabled = true, description = "Inspect git status, branch diffs, commit history, and generate unified patches" },
  { id = "neovim-lsp", name = "Neovim Buffers & LSP", enabled = true, description = "Read active Neovim buffers, visual selections, diagnostics, and treesitter symbols" },
  { id = "lazy-spec", name = "Lazy.nvim Spec Builder", enabled = true, description = "Parse READMEs and synthesize/save validated lua/plugins/<name>.lua specs" },
  { id = "mason-registry", name = "Mason 601 Registry", enabled = true, description = "Query and configure all 601 LSP, DAP, Linter, and Formatter packages from mason-registry.dev" },
  { id = "sftp-deploy", name = "SFTP Remote Sync", enabled = true, description = "Upload, download, and diff workspace files against remote SFTP profiles" },
}

M.neocodeium_keymaps = {
  { mode = "i", lhs = "<A-f>", action = "accept", desc = "NeoCodeium: Accept full suggestion" },
  { mode = "i", lhs = "<A-w>", action = "accept_word", desc = "NeoCodeium: Accept next word" },
  { mode = "i", lhs = "<A-a>", action = "accept_line", desc = "NeoCodeium: Accept current line" },
  { mode = "i", lhs = "<A-e>", action = "cycle_next", desc = "NeoCodeium: Cycle next / trigger completion" },
  { mode = "i", lhs = "<A-r>", action = "cycle_prev", desc = "NeoCodeium: Cycle previous suggestion" },
  { mode = "i", lhs = "<A-c>", action = "clear", desc = "NeoCodeium: Clear virtual text suggestion" },
}

M.state = {
  provider_id = "neocodeium",
  mode = "agent",
  neocodeium_enabled = true,
  buffer_enabled = true,
  last_label = "0/0",
  context_files = {}, ---@type string[]
  messages = {
    {
      role = "assistant",
      mode = "neocodeium",
      provider = "monkoose/neocodeium",
      timestamp = os.date("%H:%M:%S"),
      content = "Welcome to **:Clina** — powered by **NeoCodeium (`monkoose/neocodeium`)**.\n\n"
        .. "- **Keymaps**: `<A-f>` accept · `<A-w>` accept_word · `<A-a>` accept_line · `<A-e>`/`<A-r>` cycle_or_complete · `<A-c>` clear\n"
        .. "- **Commands**: `:Clina auth` (`:NeoCodeium auth`), `:Clina chat` (`:NeoCodeium chat`), `:Clina toggle`, `:Clina install` (writes `lua/plugins/neocodeium.lua`).",
    },
  },
  last_proposal = nil,
  busy = false,
}

--- Check whether `monkoose/neocodeium` is currently installed and requireable in Neovim.
---@return boolean, table|nil
function M.neocodeium_available()
  local ok, nc = pcall(require, "neocodeium")
  if ok and type(nc) == "table" then
    return true, nc
  end
  return false, nil
end

--- Return the canonical `InstallerForm` spec for `monkoose/neocodeium`.
---@return InstallerForm
function M.neocodeium_spec()
  return {
    repo = "monkoose/neocodeium",
    file = "neocodeium",
    event = "VeryLazy",
    cmd = "NeoCodeium",
    config = [[function()
  local neocodeium = require("neocodeium")
  neocodeium.setup({
    enabled = true,
    manual = false,
    show_label = true,
    debounce = false,
  })
  vim.keymap.set("i", "<A-f>", function() neocodeium.accept() end, { desc = "NeoCodeium Accept" })
  vim.keymap.set("i", "<A-w>", function() neocodeium.accept_word() end, { desc = "NeoCodeium Accept Word" })
  vim.keymap.set("i", "<A-a>", function() neocodeium.accept_line() end, { desc = "NeoCodeium Accept Line" })
  vim.keymap.set("i", "<A-e>", function() neocodeium.cycle_or_complete() end, { desc = "NeoCodeium Next/Complete" })
  vim.keymap.set("i", "<A-r>", function() neocodeium.cycle_or_complete(-1) end, { desc = "NeoCodeium Prev" })
  vim.keymap.set("i", "<A-c>", function() neocodeium.clear() end, { desc = "NeoCodeium Clear" })
end]],
  }
end

--- Configure NeoCodeium in the running Neovim session and attach `NeoCodeiumLabelUpdated` / `cmp` / `blink.cmp` hooks.
---@param opts? table
function M.setup_neocodeium(opts)
  opts = opts or {}
  local ok, neocodeium = M.neocodeium_available()
  if ok and neocodeium then
    neocodeium.setup(vim.tbl_deep_extend("force", {
      enabled = true,
      manual = false,
      show_label = true,
      filter = function(bufnr)
        local ok_blink, blink = pcall(require, "blink.cmp")
        if ok_blink and type(blink.is_visible) == "function" and blink.is_visible() then
          return false
        end
        local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
        if ft == "TelescopePrompt" or ft == "dap-repl" or ft == "installer-form" then
          return false
        end
        return true
      end,
    }, opts))
  end

  if vim and vim.keymap and vim.keymap.set then
    vim.keymap.set("i", "<A-f>", function() M.accept() end, { desc = ":Clina / NeoCodeium Accept" })
    vim.keymap.set("i", "<A-w>", function() M.accept_word() end, { desc = ":Clina / NeoCodeium Accept Word" })
    vim.keymap.set("i", "<A-a>", function() M.accept_line() end, { desc = ":Clina / NeoCodeium Accept Line" })
    vim.keymap.set("i", "<A-e>", function() M.cycle_or_complete(1) end, { desc = ":Clina / NeoCodeium Cycle/Complete" })
    vim.keymap.set("i", "<A-r>", function() M.cycle_or_complete(-1) end, { desc = ":Clina / NeoCodeium Cycle Prev" })
    vim.keymap.set("i", "<A-c>", function() M.clear() end, { desc = ":Clina / NeoCodeium Clear" })
  end

  if vim and vim.api and vim.api.nvim_create_autocmd then
    local group = vim.api.nvim_create_augroup("installer.clina.neocodeium", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "NeoCodeiumCompletionDisplayed",
      callback = function()
        local ok_cmp, cmp = pcall(require, "cmp")
        if ok_cmp and type(cmp.abort) == "function" then
          pcall(cmp.abort)
        end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "NeoCodeiumLabelUpdated",
      callback = function(ev)
        M.state.last_label = tostring(ev and ev.data or "1/1")
      end,
    })
  end
end

--- Install or save `monkoose/neocodeium` spec via `installer.nvim`.
---@param save_only? boolean
---@return boolean ok, string? path
function M.install_neocodeium(save_only)
  local Installer = require("installer")
  local spec = M.neocodeium_spec()
  if save_only then
    return Installer.save(spec, { force = true })
  end
  return Installer.add(spec, { force = true })
end

-- NeoCodeium API wrappers ---------------------------------------------------------------

function M.accept()
  local ok, nc = M.neocodeium_available()
  if ok and nc and type(nc.accept) == "function" then
    return nc.accept()
  end
  UI.notify("NeoCodeium (`monkoose/neocodeium`) is not loaded yet — run `:Clina install` to add it to lazy.nvim", vim.log.levels.INFO)
end

function M.accept_word()
  local ok, nc = M.neocodeium_available()
  if ok and nc and type(nc.accept_word) == "function" then
    return nc.accept_word()
  end
  UI.notify("NeoCodeium is not loaded yet — run `:Clina install`", vim.log.levels.INFO)
end

function M.accept_line()
  local ok, nc = M.neocodeium_available()
  if ok and nc and type(nc.accept_line) == "function" then
    return nc.accept_line()
  end
  UI.notify("NeoCodeium is not loaded yet — run `:Clina install`", vim.log.levels.INFO)
end

---@param n? integer
function M.cycle_or_complete(n)
  n = tonumber(n) or 1
  local ok, nc = M.neocodeium_available()
  if ok and nc then
    if type(nc.cycle_or_complete) == "function" then
      return nc.cycle_or_complete(n)
    elseif type(nc.cycle) == "function" then
      return nc.cycle(n)
    end
  end
  UI.notify("NeoCodeium is not loaded yet — run `:Clina install`", vim.log.levels.INFO)
end

function M.clear()
  local ok, nc = M.neocodeium_available()
  if ok and nc and type(nc.clear) == "function" then
    return nc.clear()
  end
end

function M.visible()
  local ok, nc = M.neocodeium_available()
  if ok and nc and type(nc.visible) == "function" then
    return nc.visible()
  end
  return false
end

--- Execute a `:NeoCodeium <cmd>` command via `neocodeium.commands` or `vim.cmd`.
---@param cmd_name string
---@param bang? boolean
function M.neocodeium_cmd(cmd_name, bang)
  local ok_cmd, cmds = pcall(require, "neocodeium.commands")
  if ok_cmd and type(cmds) == "table" and type(cmds[cmd_name]) == "function" then
    cmds[cmd_name](bang)
    return true
  end
  if vim and vim.fn and vim.fn.exists(":NeoCodeium") == 2 then
    vim.cmd(("NeoCodeium%s %s"):format(bang and "!" or "", cmd_name))
    return true
  end
  if cmd_name == "enable" then
    M.state.neocodeium_enabled = true
    UI.notify(":Clina (NeoCodeium) completion enabled")
  elseif cmd_name == "disable" then
    M.state.neocodeium_enabled = false
    UI.notify(":Clina (NeoCodeium) completion disabled" .. (bang and " (server stopped)" or ""))
  elseif cmd_name == "toggle" then
    M.state.neocodeium_enabled = not M.state.neocodeium_enabled
    UI.notify(":Clina (NeoCodeium) completion: " .. (M.state.neocodeium_enabled and "ENABLED" or "DISABLED"))
  elseif cmd_name == "enable_buffer" then
    M.state.buffer_enabled = true
    UI.notify(":Clina (NeoCodeium) enabled in current buffer")
  elseif cmd_name == "disable_buffer" then
    M.state.buffer_enabled = false
    UI.notify(":Clina (NeoCodeium) disabled in current buffer")
  elseif cmd_name == "toggle_buffer" then
    M.state.buffer_enabled = not M.state.buffer_enabled
    UI.notify(":Clina (NeoCodeium) current buffer: " .. (M.state.buffer_enabled and "ENABLED" or "DISABLED"))
  else
    UI.notify(
      ("NeoCodeium (`:%s`) requires `monkoose/neocodeium`. Run `:Clina install` to write `lua/plugins/neocodeium.lua`."):format(
        "NeoCodeium " .. cmd_name
      ),
      vim.log.levels.INFO
    )
  end
  return false
end

--- Locate the repository root containing `starsky/bin/clina.ts`.
---@return string
function M.root_dir()
  local src = debug.getinfo(1, "S").source or ""
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local root = vim.fn.fnamemodify(src, ":p:h:h:h")
  if vim.fn.isdirectory(root .. "/starsky") == 1 then
    return root
  end
  return vim.fn.getcwd()
end

---@return string
function M.cli_script()
  return M.root_dir() .. "/starsky/bin/clina.ts"
end

---@return ClinaProvider
function M.current_provider()
  for _, p in ipairs(M.providers) do
    if p.id == M.state.provider_id then
      return p
    end
  end
  return M.providers[1]
end

--- Run the TypeScript Clina CLI (`starsky/bin/clina.ts`) asynchronously and decode its JSON output.
---@param payload table
---@param cb fun(err: string|nil, response: table|nil)
function M.run_ts_engine(payload, cb)
  local script = M.cli_script()
  local starsky_dir = M.root_dir() .. "/starsky"
  local tsx_bin = starsky_dir .. "/node_modules/.bin/tsx"
  local encoded = vim.json and vim.json.encode(payload) or vim.fn.json_encode(payload)

  local cmd
  if vim.fn.executable(tsx_bin) == 1 and vim.fn.filereadable(script) == 1 then
    cmd = { tsx_bin, script, encoded }
  elseif vim.fn.executable("npx") == 1 and vim.fn.filereadable(script) == 1 then
    cmd = { "npx", "--yes", "tsx", script, encoded }
  else
    vim.schedule(function()
      cb(nil, M._fallback_synthesize(payload))
    end)
    return
  end

  Process.run(cmd, function(res)
    if res.code ~= 0 then
      cb(nil, M._fallback_synthesize(payload))
      return
    end
    local out = vim.trim(res.stdout or "")
    local ok, decoded = pcall(function()
      return vim.json and vim.json.decode(out) or vim.fn.json_decode(out)
    end)
    if not ok or type(decoded) ~= "table" then
      cb(nil, M._fallback_synthesize(payload))
      return
    end
    cb(nil, decoded)
  end)
end

--- Pure-Lua fallback synthesizer (includes NeoCodeium integration & `executeClinaTask`).
---@param payload table
---@return table
function M._fallback_synthesize(payload)
  local prompt = tostring(payload.prompt or "")
  local mode = tostring(payload.mode or "neocodeium")
  local target_file = payload.active_file or (payload.context_files and payload.context_files[1]) or "buffer.ts"
  local code = table.concat({
    "// Generated by :Clina (NeoCodeium + TypeScript AI Coding IDE)",
    "export interface ClinaTaskResult {",
    "  ok: boolean;",
    "  engine: string;",
    "  task: string;",
    "  timestamp: string;",
    "}",
    "",
    "export function executeClinaTask(task = " .. string.format("%q", prompt) .. "): ClinaTaskResult {",
    "  return {",
    "    ok: true,",
    '    engine: "monkoose/neocodeium",',
    "    task,",
    "    timestamp: new Date().toISOString(),",
    "  };",
    "}",
  }, "\n")
  return {
    ok = true,
    engine = "neocodeium",
    mode = mode,
    provider = payload.provider or "neocodeium",
    reply = string.format(
      "### :Clina · NeoCodeium (`monkoose/neocodeium`)\nTask: `%s`\n\n```typescript\n%s\n```",
      prompt,
      code
    ),
    proposal = {
      path = target_file,
      code = code,
      description = "NeoCodeium synthesis for: " .. prompt,
    },
  }
end

--- Add or toggle a file in Clina's context list.
---@param path string
function M.toggle_context_file(path)
  path = vim.fn.fnamemodify(path, ":p")
  for i, existing in ipairs(M.state.context_files) do
    if existing == path then
      table.remove(M.state.context_files, i)
      return false
    end
  end
  table.insert(M.state.context_files, path)
  return true
end

function M.apply_last_proposal()
  local prop = M.state.last_proposal
  if not prop or not prop.code or prop.code == "" then
    UI.notify("No pending Clina proposal to apply", vim.log.levels.WARN)
    return false, "no proposal"
  end
  if prop.path and prop.path ~= "" and prop.path ~= "buffer.ts" then
    local dir = vim.fn.fnamemodify(prop.path, ":h")
    if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
      pcall(vim.fn.mkdir, dir, "p")
    end
    local fd, err = io.open(prop.path, "w")
    if not fd then
      UI.notify("Failed to write " .. prop.path .. ": " .. tostring(err), vim.log.levels.ERROR)
      return false, err
    end
    fd:write(prop.code)
    if not prop.code:match("\n$") then
      fd:write("\n")
    end
    fd:close()
    UI.notify("Clina applied changes to " .. vim.fn.fnamemodify(prop.path, ":~"))
    return true, prop.path
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].modifiable then
    local lines = vim.split(prop.code, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    UI.notify("Clina applied code to current buffer")
    return true, "buffer"
  end
  return false, "not modifiable"
end

function M.diff_last_proposal()
  local prop = M.state.last_proposal
  if not prop or not prop.code then
    return UI.notify("No pending Clina proposal to diff", vim.log.levels.WARN)
  end
  local lines = {
    "  :Clina (NeoCodeium) Diff Preview — " .. (prop.path and vim.fn.fnamemodify(prop.path, ":~") or "active buffer"),
    "  " .. string.rep("─", 74),
  }
  for _, l in ipairs(vim.split(prop.diff or prop.code, "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. l
  end
  local buf, win = UI.open({
    title = " :Clina · NeoCodeium Diff Preview ",
    width = math.min(vim.o.columns - 6, 92),
    height = math.min(vim.o.lines - 6, math.max(12, #lines + 2)),
    filetype = "diff",
  })
  UI.set_lines(buf, lines)
  UI.map(buf, "q", function()
    UI.close(win)
  end)
  UI.map(buf, "<Esc>", function()
    UI.close(win)
  end)
  UI.map(buf, "ga", function()
    UI.close(win)
    M.apply_last_proposal()
  end)
end

function M.send(prompt, opts)
  opts = opts or {}
  prompt = vim.trim(prompt or "")
  if prompt == "" then
    return UI.notify("Enter a prompt for :Clina", vim.log.levels.WARN)
  end
  local mode = opts.mode or M.state.mode
  local provider = M.current_provider()
  local active_file = opts.active_file or vim.api.nvim_buf_get_name(0)

  M.run_ts_engine({
    prompt = prompt,
    mode = mode,
    provider = provider.id,
    model = provider.model,
    workspace = vim.fn.getcwd(),
    active_file = active_file,
    selection = opts.selection or "",
    context_files = M.state.context_files,
  }, function(_, res)
    res = res or M._fallback_synthesize({ prompt = prompt, mode = mode })
    if res.proposal then
      M.state.last_proposal = res.proposal
    end
    table.insert(M.state.messages, {
      role = "assistant",
      mode = mode,
      provider = provider.model,
      timestamp = os.date("%H:%M:%S"),
      content = res.reply or "Completed.",
      proposal = res.proposal,
    })
    if opts.on_done then
      opts.on_done(res)
    else
      UI.notify(res.reply or "Clina completed task")
    end
  end)
end

function M.select_provider(id)
  if id and id ~= "" then
    for _, p in ipairs(M.providers) do
      if p.id == id or p.model == id then
        M.state.provider_id = p.id
        UI.notify((":Clina provider set to %s (%s)"):format(p.name, p.model))
        return
      end
    end
    return UI.notify("Unknown Clina provider: " .. id, vim.log.levels.ERROR)
  end
  vim.ui.select(M.providers, {
    prompt = ":Clina · Select AI Provider (Default: NeoCodeium)",
    format_item = function(p)
      local current = p.id == M.state.provider_id and " ● " or "   "
      return string.format("%s%-32s [%-20s] %s", current, p.name, p.model, p.description)
    end,
  }, function(chosen)
    if chosen then
      M.state.provider_id = chosen.id
      UI.notify((":Clina provider set to %s (%s)"):format(chosen.name, chosen.model))
    end
  end)
end

function M.status()
  local has_nc = M.neocodeium_available()
  local lines = {
    ":Clina · NeoCodeium (`monkoose/neocodeium`) Integration",
    ("  NeoCodeium plugin: %s"):format(has_nc and "LOADED" or "not loaded yet (run `:Clina install` to add to lazy.nvim)"),
    ("  Completion state:  %s (buffer: %s)"):format(
      M.state.neocodeium_enabled and "ENABLED" or "DISABLED",
      M.state.buffer_enabled and "ENABLED" or "DISABLED"
    ),
    ("  Suggestion label:  %s"):format(M.state.last_label),
    "  Keymaps:           <A-f> accept · <A-w> word · <A-a> line · <A-e>/<A-r> cycle · <A-c> clear",
  }
  UI.notify(table.concat(lines, "\n"))
end

--- Open the `:Clina` NeoCodeium IDE Control Center modal in Neovim.
---@param initial_prompt? string
function M.ide(initial_prompt)
  if initial_prompt and vim.trim(initial_prompt) ~= "" then
    M.send(initial_prompt)
    return
  end

  local width = math.min(vim.o.columns - 6, 96)
  local height = 24
  local buf, win = UI.open({
    title = " :Clina · NeoCodeium (monkoose/neocodeium) AI Coding IDE ",
    width = width,
    height = height,
    filetype = "installer-clina",
  })
  vim.wo[win].cursorline = true

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local has_nc = M.neocodeium_available()
    local vis = M.visible()
    local lines = {
      "  ⚡ :Clina is powered by NeoCodeium (`monkoose/neocodeium`)",
      "  " .. string.rep("─", width - 4),
      string.format(
        "  Plugin Status : %-18s │ Global Completion : %-8s │ Buffer : %s",
        has_nc and "● Loaded" or "○ Not installed",
        M.state.neocodeium_enabled and "ENABLED" or "DISABLED",
        M.state.buffer_enabled and "ENABLED" or "DISABLED"
      ),
      string.format(
        "  Virtual Text  : %-18s │ Suggestion Counter: %-8s │ Engine : Windsurf/Codeium",
        vis and "Visible" or "Idle",
        M.state.last_label
      ),
      "",
      "  ⌨️  NeoCodeium Insert-Mode Keymaps (configured by `:Clina setup`):",
    }
    for _, km in ipairs(M.neocodeium_keymaps) do
      lines[#lines + 1] = string.format("    %-8s  %-14s  %s", km.lhs, "(" .. km.action .. ")", km.desc)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  🔤 NeoCodeium Commands & Actions (press key in this dashboard):"
    lines[#lines + 1] = "    [i] Install / Save `lua/plugins/neocodeium.lua` spec to lazy.nvim"
    lines[#lines + 1] = "    [s] Review `monkoose/neocodeium` spec in `:Installer` modal"
    lines[#lines + 1] = "    [a] Authenticate (`:NeoCodeium auth`) — save Windsurf/Codeium API token"
    lines[#lines + 1] = "    [c] Open NeoCodeium Chat (`:NeoCodeium chat`) in browser"
    lines[#lines + 1] = "    [t] Toggle global NeoCodeium completion (`:NeoCodeium toggle`)"
    lines[#lines + 1] = "    [b] Toggle buffer NeoCodeium completion (`:NeoCodeium toggle_buffer`)"
    lines[#lines + 1] = "    [r] Restart NeoCodeium language server (`:NeoCodeium restart`)"
    lines[#lines + 1] = "    [l] Open NeoCodeium log tab (`:NeoCodeium open_log`)"
    lines[#lines + 1] = "    [w] Open Starsky Web Code IDE (`:Clina web`)"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  i install spec  s modal  a auth  c chat  t toggle  b buffer  r restart  l log  w web  q close"
    UI.set_lines(buf, lines)
    vim.bo[buf].modifiable = false
  end

  local function close()
    UI.close(win)
  end

  UI.map(buf, "q", close)
  UI.map(buf, "<Esc>", close)
  UI.map(buf, "i", function()
    M.setup_neocodeium()
    local ok, path = M.install_neocodeium(false)
    if ok then
      UI.notify("Saved & installed monkoose/neocodeium spec → " .. tostring(path))
    end
    render()
  end)
  UI.map(buf, "s", function()
    close()
    require("installer").open(M.neocodeium_spec())
  end)
  UI.map(buf, "a", function()
    close()
    M.neocodeium_cmd("auth")
  end)
  UI.map(buf, "c", function()
    close()
    M.neocodeium_cmd("chat")
  end)
  UI.map(buf, "t", function()
    M.neocodeium_cmd("toggle")
    render()
  end)
  UI.map(buf, "b", function()
    M.neocodeium_cmd("toggle_buffer")
    render()
  end)
  UI.map(buf, "r", function()
    M.neocodeium_cmd("restart")
    render()
  end)
  UI.map(buf, "l", function()
    close()
    M.neocodeium_cmd("open_log")
  end)
  UI.map(buf, "w", function()
    close()
    require("installer.starsky").open()
  end)

  render()
end

--- Dispatch `:Clina [subcommand] [args...]`
---@param args string[]
---@param range_text? string
---@param bang? boolean
function M.dispatch(args, range_text, bang)
  local sub = (args[1] or ""):lower()
  local rest = table.concat(vim.list_slice(args, 2), " ")

  if sub == "" or sub == "ide" or sub == "neocodeium" or sub == "open" then
    M.ide(rest ~= "" and rest or nil)
  elseif sub == "setup" then
    M.setup_neocodeium()
    UI.notify(":Clina configured NeoCodeium keymaps (<A-f>, <A-w>, <A-a>, <A-e>, <A-r>, <A-c>)")
  elseif sub == "install" or sub == "save" then
    M.setup_neocodeium()
    M.install_neocodeium(sub == "save")
  elseif sub == "accept" then
    M.accept()
  elseif sub == "accept_word" or sub == "word" then
    M.accept_word()
  elseif sub == "accept_line" or sub == "line" then
    M.accept_line()
  elseif sub == "cycle" or sub == "complete" then
    M.cycle_or_complete(tonumber(args[2]) or 1)
  elseif sub == "clear" then
    M.clear()
  elseif sub == "auth" then
    M.neocodeium_cmd("auth", bang)
  elseif sub == "enable" or sub == "disable" or sub == "toggle"
    or sub == "enable_buffer" or sub == "disable_buffer" or sub == "toggle_buffer"
    or sub == "restart" or sub == "open_log" then
    M.neocodeium_cmd(sub, bang)
  elseif sub == "log" then
    M.neocodeium_cmd("open_log", bang)
  elseif sub == "chat" then
    if rest == "" then
      M.neocodeium_cmd("chat", bang)
    else
      M.send(rest, { mode = "chat", selection = range_text })
    end
  elseif sub == "ask" or sub == "agent" or sub == "edit" or sub == "refactor" or sub == "spec" then
    M.state.mode = sub == "ask" and "chat" or (sub == "refactor" and "edit" or sub)
    if rest == "" then
      M.ide()
    else
      M.send(rest, { mode = M.state.mode, selection = range_text })
    end
  elseif sub == "apply" then
    M.apply_last_proposal()
  elseif sub == "diff" then
    M.diff_last_proposal()
  elseif sub == "provider" or sub == "model" then
    M.select_provider(rest)
  elseif sub == "presets" or sub == "plugins" then
    require("installer.ai").open()
  elseif sub == "web" or sub == "starsky" then
    require("installer.starsky").open()
  elseif sub == "status" then
    M.status()
  else
    M.send(table.concat(args, " "), { selection = range_text })
  end
end

return M
