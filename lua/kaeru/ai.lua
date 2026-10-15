-- AI coding presets: curated lazy.nvim specs for the most used AI plugins.
-- Disabled by default (`ai.enabled = false`), see `:help kaeru-ai`.
--
-- Every preset mirrors the install snippet from the plugin's README at the time
-- of writing; the modal lets you review/edit it before anything is written.
local Config = require("kaeru.config")
local UI = require("kaeru.ui")

local M = {}

---@class KaeruAiPreset
---@field repo string
---@field title string
---@field category "completion"|"chat"|"agent"|"tools"
---@field needs string      what you need (account / API key / CLI)
---@field desc string
---@field form KaeruForm values passed to the modal

---@type KaeruAiPreset[]
M.presets = {
  -- completion --------------------------------------------------------------
  {
    repo = "monkoose/neocodeium",
    title = "neocodeium (:Clina default)",
    category = "completion",
    needs = "free Windsurf/Codeium account (:NeoCodeium auth)",
    desc = "Flicker-free pure-Lua AI completion & chat for Neovim with dot-repeat and word/line accept (used by :Clina).",
    form = {
      repo = "monkoose/neocodeium",
      event = "VeryLazy",
      cmd = "NeoCodeium",
      config = [[function()
  local neocodeium = require("neocodeium")
  neocodeium.setup({ manual = false })
  vim.keymap.set("i", "<A-f>", function() neocodeium.accept() end, { desc = "NeoCodeium Accept" })
  vim.keymap.set("i", "<A-w>", function() neocodeium.accept_word() end, { desc = "NeoCodeium Accept Word" })
  vim.keymap.set("i", "<A-a>", function() neocodeium.accept_line() end, { desc = "NeoCodeium Accept Line" })
  vim.keymap.set("i", "<A-e>", function() neocodeium.cycle_or_complete() end, { desc = "NeoCodeium Next/Complete" })
  vim.keymap.set("i", "<A-r>", function() neocodeium.cycle_or_complete(-1) end, { desc = "NeoCodeium Prev" })
  vim.keymap.set("i", "<A-c>", function() neocodeium.clear() end, { desc = "NeoCodeium Clear" })
end]],
    },
  },
  {
    repo = "zbirenbaum/copilot.lua",
    title = "copilot.lua",
    category = "completion",
    needs = "GitHub Copilot subscription",
    desc = "Lua rewrite of copilot.vim: ghost-text suggestions, panel, NES. Neovim ≥ 0.11.",
    form = {
      repo = "zbirenbaum/copilot.lua",
      cmd = "Copilot",
      event = "InsertEnter",
      opts = [[{ suggestion = { enabled = true, auto_trigger = true }, panel = { enabled = false } }]],
    },
  },
  {
    repo = "github/copilot.vim",
    title = "copilot.vim",
    category = "completion",
    needs = "GitHub Copilot subscription + Node.js",
    desc = "The official GitHub Copilot plugin (Vimscript). Run :Copilot setup after install.",
    form = { repo = "github/copilot.vim", event = "InsertEnter", cmd = "Copilot" },
  },
  {
    repo = "supermaven-inc/supermaven-nvim",
    title = "supermaven-nvim",
    category = "completion",
    needs = "free Supermaven account",
    desc = "Very fast inline completions with a generous free tier.",
    form = { repo = "supermaven-inc/supermaven-nvim", event = "InsertEnter", opts = "{}" },
  },
  {
    repo = "Exafunction/windsurf.nvim",
    title = "windsurf.nvim (Codeium)",
    category = "completion",
    needs = "free Codeium/Windsurf account",
    desc = "Native Codeium completions, nvim-cmp source and virtual text. Run :Codeium Auth.",
    form = {
      repo = "Exafunction/windsurf.nvim",
      event = "InsertEnter",
      cmd = "Codeium",
      dependencies = "nvim-lua/plenary.nvim, hrsh7th/nvim-cmp",
      config = 'function()\n  require("codeium").setup({})\nend',
    },
  },
  {
    repo = "milanglacier/minuet-ai.nvim",
    title = "minuet-ai.nvim",
    category = "completion",
    needs = "API key: OpenAI / Claude / Gemini / Codestral / DeepSeek, or Ollama",
    desc = "LLM completions from any provider (incl. local Ollama) via nvim-cmp, blink or virtual text.",
    form = {
      repo = "milanglacier/minuet-ai.nvim",
      event = "InsertEnter",
      opts = [[{ provider = "openai_fim_compatible", virtualtext = { auto_trigger_ft = { "*" } } }]],
    },
  },
  -- chat / inline ------------------------------------------------------------
  {
    repo = "olimorris/codecompanion.nvim",
    title = "codecompanion.nvim",
    category = "chat",
    needs = "API key or Copilot (Anthropic, OpenAI, Gemini, Copilot, Ollama, ...)",
    desc = "Chat buffers, inline edits and agent/tool workflows. Works with Copilot out of the box.",
    form = {
      repo = "olimorris/codecompanion.nvim",
      cmd = "CodeCompanion, CodeCompanionChat, CodeCompanionActions",
      dependencies = "nvim-lua/plenary.nvim, nvim-treesitter/nvim-treesitter",
      opts = "{}",
    },
  },
  {
    repo = "avante-corp/avante.nvim",
    title = "avante.nvim",
    category = "chat",
    needs = "API key (Claude, OpenAI, Gemini, Copilot, ...)",
    desc = "Cursor-like sidebar with diff apply. Needs `make` (or cargo). Set your provider in opts.",
    form = {
      repo = "avante-corp/avante.nvim",
      event = "VeryLazy",
      version = "false",
      build = "make",
      dependencies = "nvim-lua/plenary.nvim, MunifTanjim/nui.nvim, MeanderingProgrammer/render-markdown.nvim",
      opts = [[{ provider = "claude", instructions_file = "avante.md" }]],
    },
  },
  {
    repo = "CopilotC-Nvim/CopilotChat.nvim",
    title = "CopilotChat.nvim",
    category = "chat",
    needs = "GitHub Copilot subscription",
    desc = "Chat with Copilot models (GPT, Claude, ...) about your buffers and selections.",
    form = {
      repo = "CopilotC-Nvim/CopilotChat.nvim",
      cmd = "CopilotChat, CopilotChatToggle, CopilotChatExplain",
      dependencies = "nvim-lua/plenary.nvim",
      build = "make tiktoken",
      opts = "{}",
    },
  },
  {
    repo = "Robitx/gp.nvim",
    title = "gp.nvim",
    category = "chat",
    needs = "API key (OpenAI, Anthropic, Gemini, Ollama, ...)",
    desc = "ChatGPT-style sessions, rewrite/append/prepend commands, whisper support.",
    form = { repo = "Robitx/gp.nvim", cmd = "GpChatNew, GpChatToggle, GpRewrite", opts = "{}" },
  },
  {
    repo = "frankroeder/parrot.nvim",
    title = "parrot.nvim",
    category = "chat",
    needs = "API key (OpenAI, Anthropic, Gemini, Ollama, ...)",
    desc = "Lightweight chat/notes with persistent conversations and provider switching.",
    form = { repo = "frankroeder/parrot.nvim", cmd = "PrtChatNew, PrtChatToggle", opts = "{}" },
  },
  {
    repo = "David-Kunz/gen.nvim",
    title = "gen.nvim",
    category = "chat",
    needs = "Ollama (local models)",
    desc = "Minimal prompt-based text generation with local Ollama models.",
    form = { repo = "David-Kunz/gen.nvim", cmd = "Gen", opts = [[{ model = "llama3.1" }]] },
  },
  -- agents -------------------------------------------------------------------
  {
    repo = "folke/sidekick.nvim",
    title = "sidekick.nvim",
    category = "agent",
    needs = "Copilot (NES) and/or a CLI agent (Claude Code, Codex, OpenCode, ...)",
    desc = "Next Edit Suggestions + an integrated terminal for CLI coding agents.",
    form = {
      repo = "folke/sidekick.nvim",
      event = "VeryLazy",
      opts = "{}",
      keys = [[{
  { "<leader>aa", function() require("sidekick.cli").toggle() end, desc = "Sidekick Toggle CLI" },
  { "<leader>as", function() require("sidekick.cli").select() end, desc = "Sidekick Select CLI" },
}]],
    },
  },
  {
    repo = "coder/claudecode.nvim",
    title = "claudecode.nvim",
    category = "agent",
    needs = "Claude Code CLI",
    desc = "Claude Code IDE integration (same protocol as the VS Code extension).",
    form = {
      repo = "coder/claudecode.nvim",
      cmd = "ClaudeCode, ClaudeCodeFocus, ClaudeCodeSend, ClaudeCodeAdd",
      dependencies = "folke/snacks.nvim",
      config = "true",
      keys = [[{
  { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
  { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
}]],
    },
  },
  {
    repo = "nickjvandyke/opencode.nvim",
    title = "opencode.nvim",
    category = "agent",
    needs = "OpenCode CLI",
    desc = "Neovim front-end for the OpenCode agent: ask, send ranges, review diffs.",
    form = {
      repo = "nickjvandyke/opencode.nvim",
      event = "VeryLazy",
      config = [[function()
  vim.g.opencode_opts = {}
  vim.keymap.set({ "n", "x" }, "<C-a>", function() require("opencode").ask("@this: ") end, { desc = "Ask OpenCode" })
  vim.keymap.set({ "n", "x" }, "<C-x>", function() require("opencode").select() end, { desc = "Select OpenCode" })
end]],
    },
  },
  {
    repo = "greggh/claude-code.nvim",
    title = "claude-code.nvim",
    category = "agent",
    needs = "Claude Code CLI",
    desc = "Toggleable Claude Code terminal with file-change reload.",
    form = {
      repo = "greggh/claude-code.nvim",
      cmd = "ClaudeCode",
      dependencies = "nvim-lua/plenary.nvim",
      opts = "{}",
    },
  },
  {
    repo = "GeorgesAlkhouri/nvim-aider",
    title = "nvim-aider",
    category = "agent",
    needs = "aider CLI",
    desc = "Aider terminal integration with buffer/file context commands.",
    form = {
      repo = "GeorgesAlkhouri/nvim-aider",
      cmd = "Aider",
      dependencies = "folke/snacks.nvim",
      config = "true",
    },
  },
  -- tools --------------------------------------------------------------------
  {
    repo = "ravitemer/mcphub.nvim",
    title = "mcphub.nvim",
    category = "tools",
    needs = "Node.js (installs mcp-hub)",
    desc = "MCP client: expose MCP servers to avante / codecompanion / CopilotChat.",
    form = {
      repo = "ravitemer/mcphub.nvim",
      cmd = "MCPHub",
      dependencies = "nvim-lua/plenary.nvim",
      build = "npm install -g mcp-hub@latest",
      config = 'function()\n  require("mcphub").setup()\nend',
    },
  },
  {
    repo = "zbirenbaum/copilot-cmp",
    title = "copilot-cmp",
    category = "tools",
    needs = "copilot.lua + nvim-cmp",
    desc = "Shows Copilot suggestions inside the nvim-cmp menu.",
    form = {
      repo = "zbirenbaum/copilot-cmp",
      dependencies = "zbirenbaum/copilot.lua",
      event = "InsertEnter",
      config = "true",
    },
  },
  {
    repo = "fang2hou/blink-copilot",
    title = "blink-copilot",
    category = "tools",
    needs = "copilot.lua + blink.cmp",
    desc = "Copilot source for blink.cmp (add `copilot` to your blink sources).",
    form = { repo = "fang2hou/blink-copilot", dependencies = "zbirenbaum/copilot.lua", lazy = "true" },
  },
}

local CATEGORY_LABEL = {
  completion = "Inline completion",
  chat = "Chat & inline edits",
  agent = "Coding agents",
  tools = "Add-ons",
}
local CATEGORY_ORDER = { "completion", "chat", "agent", "tools" }

---@return boolean
function M.enabled()
  return Config.options.ai.enabled == true
end

---@return KaeruAiPreset[]
function M.list()
  local excluded = {}
  for _, repo in ipairs(Config.options.ai.exclude or {}) do
    excluded[repo:lower()] = true
  end
  local out = {}
  for _, p in ipairs(M.presets) do
    if not excluded[p.repo:lower()] then
      out[#out + 1] = p
    end
  end
  return out
end

---@param repo string
---@return KaeruAiPreset|nil
function M.get(repo)
  for _, p in ipairs(M.presets) do
    if p.repo:lower() == repo:lower() or p.title:lower() == repo:lower() then
      return p
    end
  end
end

--- Open the modal prefilled with a preset.
---@param preset KaeruAiPreset
function M.open_preset(preset)
  require("kaeru").open(vim.deepcopy(preset.form))
end

--- Install a preset directly (bypasses the modal).
---@param preset KaeruAiPreset
function M.install_preset(preset)
  require("kaeru").add(vim.deepcopy(preset.form))
end

local function disabled_notice()
  UI.notify(
    "AI coding presets are disabled.\nEnable them with:\n  require(\"kaeru\").setup({ ai = { enabled = true } })",
    vim.log.levels.WARN
  )
end

--- Floating picker (`:Kaeru ai`).
function M.pick()
  if not M.enabled() then
    return disabled_notice()
  end
  local presets = M.list()
  local lazy_mod = require("kaeru.lazy")

  -- rows: either a header or a preset
  ---@type {header?: string, preset?: KaeruAiPreset}[]
  local rows = {}
  for _, cat in ipairs(CATEGORY_ORDER) do
    local group = vim.tbl_filter(function(p)
      return p.category == cat
    end, presets)
    if #group > 0 then
      rows[#rows + 1] = { header = CATEGORY_LABEL[cat] }
      for _, p in ipairs(group) do
        rows[#rows + 1] = { preset = p }
      end
    end
  end

  local width = math.min(vim.o.columns - 4, 100)
  local buf, win = UI.open({
    title = "kaeru.nvim · AI coding plugins",
    width = width,
    height = math.min(#rows + 3, vim.o.lines - 6),
    filetype = "kaeru-ai",
  })
  vim.wo[win].cursorline = true

  local lines = {}
  for i, row in ipairs(rows) do
    if row.header then
      lines[i] = "  " .. row.header
    else
      local p = row.preset
      local installed = lazy_mod.find_plugin(p.repo:match("/(.+)$")) and "●" or " "
      local line = string.format("  %s %-26s %s", installed, p.title, p.desc)
      local max = width - vim.fn.strdisplaywidth(p.needs) - 4
      if vim.fn.strdisplaywidth(line) > max then
        line = vim.fn.strcharpart(line, 0, math.max(10, max - 1)) .. "…"
      end
      lines[i] = line
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  <CR> review in modal   i install now   C :Clina IDE   K details   o open on GitHub   q close"
  UI.set_lines(buf, lines)
  vim.bo[buf].modifiable = false

  for i, row in ipairs(rows) do
    if row.header then
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 0, { end_col = #lines[i], hl_group = "Title" })
    else
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 2, { end_col = 5, hl_group = "DiagnosticOk", strict = false })
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 6, { end_col = 6 + #row.preset.title, hl_group = "Identifier", strict = false })
      vim.api.nvim_buf_set_extmark(buf, UI.ns, i - 1, 0, {
        virt_text = { { row.preset.needs .. "  ", "Comment" } },
        virt_text_pos = "right_align",
      })
    end
  end
  vim.api.nvim_buf_set_extmark(buf, UI.ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "Comment" })

  local function current()
    local row = rows[vim.api.nvim_win_get_cursor(win)[1]]
    return row and row.preset or nil
  end
  local function close()
    UI.close(win)
  end
  UI.map(buf, "q", close)
  UI.map(buf, "<Esc>", close)
  UI.map(buf, "C", function()
    close()
    require("kaeru.clina").ide()
  end)
  UI.map(buf, "<CR>", function()
    local p = current()
    if p then
      close()
      M.open_preset(p)
    end
  end)
  UI.map(buf, "i", function()
    local p = current()
    if p then
      close()
      M.install_preset(p)
    end
  end)
  UI.map(buf, "o", function()
    local p = current()
    if p and vim.ui.open then
      vim.ui.open("https://github.com/" .. p.repo)
    end
  end)
  UI.map(buf, "K", function()
    local p = current()
    if p then
      local src = require("kaeru").preview(p.form)
      UI.notify(("%s — %s\nNeeds: %s\n\n%s"):format(p.title, p.desc, p.needs, src or ""))
    end
  end)
  -- skip headers when moving
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cur = vim.api.nvim_win_get_cursor(win)[1]
      local row = rows[cur]
      if not row or row.header then
        local target = cur
        while rows[target] and rows[target].header do
          target = target + 1
        end
        if not rows[target] then
          target = cur - 1
          while rows[target] and rows[target].header do
            target = target - 1
          end
        end
        if rows[target] then
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        end
      end
    end,
  })
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
end

function M.ide(prompt)
  return require("kaeru.clina").ide(prompt)
end

return M
