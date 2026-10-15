-- Minimal test runner for the pure-Lua parts of installer.nvim.
-- Runs under `nvim -l`, `luajit` or `lua5.1` (a tiny `vim` stub is installed when needed).
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

if not vim then
  -- stub just enough of the vim API for spec.lua / github.lua / config.lua
  vim = {
    env = {},
    fn = {
      executable = function()
        return 0
      end,
      has = function()
        return 1
      end,
      expand = function(p)
        return p
      end,
    },
    api = {
      nvim_create_namespace = function()
        return 1
      end,
    },
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    schedule = function(f)
      f()
    end,
    tbl_filter = function(f, t)
      local out = {}
      for _, v in ipairs(t) do
        if f(v) then
          out[#out + 1] = v
        end
      end
      return out
    end,
    trim = function(s)
      return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end,
    deepcopy = function(t)
      if type(t) ~= "table" then
        return t
      end
      local c = {}
      for k, v in pairs(t) do
        c[k] = vim.deepcopy(v)
      end
      return c
    end,
    list_extend = function(a, b)
      for _, v in ipairs(b) do
        a[#a + 1] = v
      end
      return a
    end,
    tbl_deep_extend = function(_, ...)
      local function merge(dst, src)
        for k, v in pairs(src) do
          if type(v) == "table" and type(dst[k]) == "table" and #v == 0 then
            merge(dst[k], v)
          else
            dst[k] = v
          end
        end
        return dst
      end
      local out = {}
      for _, t in ipairs({ ... }) do
        merge(out, t)
      end
      return out
    end,
  }
end

local Spec = require("installer.spec")
local GitHub = require("installer.github")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print("ok   " .. name)
  else
    fail = fail + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(a, b, msg)
  if a ~= b then
    error((msg or "assertion failed") .. "\n     expected: " .. tostring(b) .. "\n     got:      " .. tostring(a), 2)
  end
end

-- parse_repo ---------------------------------------------------------------
test("parse_repo short name", function()
  local r = Spec.parse_repo("folke/noice.nvim")
  eq(r.short, "folke/noice.nvim")
  eq(r.base, "noice.nvim")
end)

test("parse_repo github https url", function()
  local r = Spec.parse_repo("https://github.com/nvim-telescope/telescope.nvim.git")
  eq(r.short, "nvim-telescope/telescope.nvim")
  eq(r.base, "telescope.nvim")
  eq(Spec.parse_repo("https://github.com/folke/lazy.nvim/").short, "folke/lazy.nvim")
end)

test("parse_repo github ssh url", function()
  eq(Spec.parse_repo("git@github.com:folke/noice.nvim.git").short, "folke/noice.nvim")
end)

test("parse_repo custom git url", function()
  local r = Spec.parse_repo("https://gitlab.com/me/my-plugin.git")
  eq(r.short, nil)
  eq(r.url, "https://gitlab.com/me/my-plugin.git")
  eq(r.base, "my-plugin")
end)

test("parse_repo rejects garbage", function()
  local r, err = Spec.parse_repo("not a repo")
  eq(r, nil)
  assert(err:find("Invalid repository"), err)
  local r2, err2 = Spec.parse_repo("")
  eq(r2, nil)
  assert(err2:find("required"), err2)
end)

-- default_filename ---------------------------------------------------------
test("default_filename strips nvim affixes", function()
  eq(Spec.default_filename("noice.nvim"), "noice")
  eq(Spec.default_filename("nvim-treesitter"), "treesitter")
  eq(Spec.default_filename("telescope.nvim"), "telescope")
  eq(Spec.default_filename("vim-fugitive"), "fugitive")
  eq(Spec.default_filename("LazyVim"), "lazyvim")
  eq(Spec.default_filename("nvim"), "nvim")
end)

-- validate_table -----------------------------------------------------------
test("validate_table accepts and wraps tables", function()
  eq(Spec.validate_table('{ a = "b" }'), '{ a = "b" }')
  eq(Spec.validate_table('a = "b"'), '{ a = "b" }')
  eq(Spec.validate_table("   "), nil)
  local _, err = Spec.validate_table("{ a = }")
  assert(err and err:find("Invalid Lua table"), tostring(err))
  eq(Spec.validate_table("1, 2"), "{ 1, 2 }")
  local _, err2 = Spec.validate_table("{} .. 'x'")
  assert(err2 and err2:find("must evaluate"), "non-table should fail: " .. tostring(err2))
end)

-- generate -----------------------------------------------------------------
test("generate bare spec", function()
  local g = assert(Spec.generate({ repo = "folke/noice.nvim" }, { header = false }))
  eq(g.source, 'return {\n  "folke/noice.nvim",\n}\n')
  eq(g.name, "noice.nvim")
  eq(g.file, "noice")
end)

test("generate full spec", function()
  local g, err = Spec.generate({
    repo = "folke/noice.nvim",
    file = "ui-noice.lua",
    name = "noice",
    lazy = "false",
    priority = "1000",
    version = "*",
    branch = "main",
    event = "VeryLazy",
    cmd = "Noice, NoiceDismiss",
    ft = "",
    keys = "<leader>sn, <C-n>",
    dependencies = "MunifTanjim/nui.nvim, https://github.com/rcarriga/nvim-notify",
    build = ":TSUpdate",
    opts = '{ presets = { bottom_search = true } }',
    config = "",
    pin = "true",
  }, { header = false })
  assert(g, err)
  eq(g.file, "ui-noice")
  eq(g.name, "noice")
  local expected = table.concat({
    "return {",
    '  "folke/noice.nvim",',
    '  name = "noice",',
    "  lazy = false,",
    "  priority = 1000,",
    '  version = "*",',
    '  branch = "main",',
    "  pin = true,",
    '  event = "VeryLazy",',
    "  cmd = {",
    '    "Noice",',
    '    "NoiceDismiss",',
    "  },",
    "  keys = {",
    '    "<leader>sn",',
    '    "<C-n>",',
    "  },",
    "  dependencies = {",
    '    "MunifTanjim/nui.nvim",',
    '    "rcarriga/nvim-notify",',
    "  },",
    '  build = ":TSUpdate",',
    "  opts = { presets = { bottom_search = true } },",
    "}",
    "",
  }, "\n")
  eq(g.source, expected)
  -- the generated file must be valid Lua returning a table
  local chunk = assert(loadstring(g.source))
  local spec = chunk()
  eq(spec[1], "folke/noice.nvim")
  eq(spec.cmd[2], "NoiceDismiss")
  eq(spec.opts.presets.bottom_search, true)
end)

test("generate config function and custom url", function()
  local g = assert(Spec.generate({
    repo = "https://gitlab.com/me/cool.nvim.git",
    config = "function",
    version = "false",
  }, { header = false }))
  assert(g.source:find('url = "https://gitlab.com/me/cool.nvim.git"', 1, true), g.source)
  assert(g.source:find("version = false", 1, true), g.source)
  assert(g.source:find("config = function(_, opts)", 1, true), g.source)
  local spec = assert(loadstring(g.source))()
  eq(type(spec.config), "function")
  eq(g.name, "cool.nvim")
  eq(g.file, "cool")
end)

test("generate rejects bad input", function()
  local _, err = Spec.generate({ repo = "a/b", priority = "high" })
  assert(err:find("Priority"), err)
  _, err = Spec.generate({ repo = "a/b", opts = "{ nope" })
  assert(err:find("Invalid Lua table"), err)
  _, err = Spec.generate({ repo = "a/b", file = "../evil" })
  assert(err:find("path separators"), err)
end)

test("render header", function()
  local g = assert(Spec.generate({ repo = "a/b" }))
  assert(g.source:find("^%-%- Generated by installer%.nvim"), g.source)
end)

test("strings are escaped", function()
  local g = assert(Spec.generate({ repo = "a/b", build = 'echo "hi"' }, { header = false }))
  assert(g.source:find('build = "echo \\"hi\\""', 1, true), g.source)
  eq(assert(loadstring(g.source))().build, 'echo "hi"')
end)

-- github -------------------------------------------------------------------
test("github query building", function()
  eq(GitHub.build_query({}), "topic:neovim-plugin")
  eq(GitHub.build_query({ query = "telescope" }), "telescope topic:neovim-plugin")
  eq(GitHub.build_query({ query = "telescope", broad = true }), "telescope neovim in:name,description,topics")
  eq(GitHub.build_query({ query = "folke/noice.nvim" }), "folke/noice.nvim in:name")
end)

test("github urlencode", function()
  eq(GitHub.urlencode("telescope topic:neovim-plugin"), "telescope%20topic%3Aneovim-plugin")
  eq(GitHub.urlencode("a/b.c-d_e~f"), "a%2Fb.c-d_e~f")
end)

test("github format_stars", function()
  eq(GitHub.format_stars(999), "999")
  eq(GitHub.format_stars(27657), "27.7k")
end)

-- raw spec fields -----------------------------------------------------------
test("raw keys / dependencies / config / init / build", function()
  local g, err = Spec.generate({
    repo = "folke/sidekick.nvim",
    keys = '{\n  { "<leader>aa", function() require("sidekick.cli").toggle() end, desc = "Toggle" },\n}',
    dependencies = '{ "folke/snacks.nvim", { "nvim-lua/plenary.nvim", lazy = true } }',
    config = "function(_, opts)\n  require('sidekick').setup(opts)\nend",
    init = "function()\n  vim.g.foo = 1\nend",
    build = '{ "make", ":TSUpdate" }',
  }, { header = false })
  assert(g, err)
  local spec = assert(loadstring(g.source))()
  eq(type(spec.keys[1][2]), "function")
  eq(spec.dependencies[2][1], "nvim-lua/plenary.nvim")
  eq(type(spec.config), "function")
  eq(type(spec.init), "function")
  eq(spec.build[2], ":TSUpdate")
  -- nested lines are indented one level deeper than the key
  assert(g.source:find('\n  keys = {\n    { "<leader>aa"', 1, true), g.source)
end)

test("raw fields are validated", function()
  local _, err = Spec.generate({ repo = "a/b", config = "function() oops" })
  assert(err and err:find("config"), tostring(err))
  _, err = Spec.generate({ repo = "a/b", init = "{ 1 }" })
  assert(err and err:find("init"), tostring(err))
  _, err = Spec.generate({ repo = "a/b", keys = "{ nope" })
  assert(err and err:find("keys"), tostring(err))
end)

-- AI presets ------------------------------------------------------------------
test("every AI preset renders a valid spec", function()
  local AI = require("installer.ai")
  assert(#AI.presets >= 15, "expected presets")
  local seen = {}
  for _, p in ipairs(AI.presets) do
    assert(not seen[p.repo], "duplicate preset " .. p.repo)
    seen[p.repo] = true
    eq(p.form.repo, p.repo, p.title)
    assert(p.category and p.needs and p.desc, p.title)
    local g, err = Spec.generate(p.form, { header = false })
    assert(g, p.title .. ": " .. tostring(err))
    local spec = assert(loadstring(g.source), p.title)()
    eq(spec[1], p.repo, p.title)
  end
  assert(AI.get("avante.nvim"))
  eq(AI.get("CopilotC-Nvim/CopilotChat.nvim").form.build, "make tiktoken")
end)

-- SFTP helpers -----------------------------------------------------------------
test("sftp glob patterns and ignores", function()
  local S = require("installer.sftp")
  local pats = { S._glob_to_pattern(".git"), S._glob_to_pattern("*.log"), S._glob_to_pattern("dist/**"), S._glob_to_pattern(".nvim-sftp.json") }
  assert(S._ignored(".git/config", pats))
  assert(S._ignored("src/app.log", pats))
  assert(S._ignored("dist/js/app.js", pats))
  assert(S._ignored(".nvim-sftp.json", pats), "config file must never be uploaded")
  assert(not S._ignored("src/app.lua", pats))
  assert(not S._ignored("distro/readme.md", pats))
end)

test("sftp chunking is round-robin and bounded", function()
  local S = require("installer.sftp")
  local chunks = S.chunk({ "a", "b", "c", "d", "e" }, 2)
  eq(#chunks, 2)
  eq(table.concat(chunks[1], ","), "a,c,e")
  eq(table.concat(chunks[2], ","), "b,d")
  eq(#S.chunk({ "a" }, 8), 1)
  eq(#S.chunk({}, 4), 1)
end)

test("sftp upload batch creates parent dirs then puts files", function()
  local S = require("installer.sftp")
  local profile = { root = "/home/me/proj", remotePath = "/var/www/app/", name = "x" }
  local batch = S.upload_batch(profile, { "src/a.lua", "src/sub/b.lua", 'odd "name".txt' })
  local lines = {}
  for l in batch:gmatch("[^\n]+") do
    lines[#lines + 1] = l
  end
  eq(lines[1], '-mkdir "/var/www/app/"')
  eq(lines[2], '-mkdir "/var/www/app/src"')
  eq(lines[3], '-mkdir "/var/www/app/src/sub"')
  eq(lines[4], 'put -p "/home/me/proj/src/a.lua" "/var/www/app/src/a.lua"')
  eq(lines[5], 'put -p "/home/me/proj/src/sub/b.lua" "/var/www/app/src/sub/b.lua"')
  eq(lines[6], 'put -p "/home/me/proj/odd \\"name\\".txt" "/var/www/app/odd \\"name\\".txt"')
  eq(S.remote_path(profile, "x/y"), "/var/www/app/x/y")
end)

test("sftp base command", function()
  local S = require("installer.sftp")
  local args = assert(S.base_cmd({ host = "h", port = 2222, privateKeyPath = "/k", username = "u" }, "sftp"))
  eq(args[1], "sftp")
  eq(table.concat(args, " "), "sftp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -P 2222 -i /k")
  eq(S.target({ host = "h", username = "u" }), "u@h")
  eq(S.target({ host = "h" }), "h")
  local _, err = S.base_cmd({ host = "h", password = "pw" }, "sftp")
  assert(err and err:find("sshpass"), tostring(err))
end)

-- process pool -----------------------------------------------------------------
test("process pool respects concurrency and order", function()
  local P = require("installer.process")
  local running, max_running, order = 0, 0, {}
  local pending = {}
  local tasks = {}
  for i = 1, 6 do
    tasks[i] = function(done)
      running = running + 1
      max_running = math.max(max_running, running)
      pending[#pending + 1] = function()
        running = running - 1
        order[#order + 1] = i
        done(i * 10)
      end
    end
  end
  local results
  P.pool(tasks, 2, function(r)
    results = r
  end)
  eq(max_running, 2)
  -- finish tasks out of order
  while #pending > 0 do
    local f = table.remove(pending, 1)
    f()
  end
  eq(max_running, 2)
  eq(#results, 6)
  eq(results[3], 30)
  local empty_called = false
  P.pool({}, 4, function(r)
    empty_called = #r == 0
  end)
  assert(empty_called)
end)

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
  os.exit(1)
end
