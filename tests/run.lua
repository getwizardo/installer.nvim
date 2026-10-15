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
      fnamemodify = function(p)
        return p
      end,
      getcwd = function()
        return "/tmp/installer-test"
      end,
      findfile = function()
        return ""
      end,
      mkdir = function(p)
        os.execute("mkdir -p " .. string.format("%q", p))
        return 1
      end,
      filereadable = function(p)
        local f = io.open(p, "r")
        if f then
          f:close()
          return 1
        end
        return 0
      end,
      isdirectory = function(p)
        local code = os.execute("test -d " .. string.format("%q", p))
        return (code == 0 or code == true) and 1 or 0
      end,
      stdpath = function()
        return "/tmp/installer-test"
      end,
    },
    tbl_keys = function(t)
      local out = {}
      for k in pairs(t) do
        out[#out + 1] = k
      end
      return out
    end,
    tbl_extend = function(_, ...)
      local out = {}
      for _, t in ipairs({ ... }) do
        for k, v in pairs(t) do
          out[k] = v
        end
      end
      return out
    end,
    api = {
      nvim_create_namespace = function()
        return 1
      end,
      nvim_create_augroup = function()
        return 1
      end,
      nvim_create_autocmd = function()
        return 1
      end,
      nvim_list_uis = function()
        return {}
      end,
    },
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
    notify = function() end,
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
  -- several keys, ssh config, proxy jump, options
  local a2 = assert(S.base_cmd({
    host = "alias",
    privateKeyPaths = { "/k1", "/k2" },
    identitiesOnly = true,
    sshConfigFile = "/cfg",
    proxyJump = "bastion",
    options = { ServerAliveInterval = 30, Compression = true },
  }, "ssh"))
  eq(
    table.concat(a2, " "),
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -F /cfg -o ProxyJump=bastion -o Compression=yes -o ServerAliveInterval=30 -i /k1 -i /k2 -o IdentitiesOnly=yes"
  )
  eq(table.concat(S.keys({ privateKeyPath = { "/a", "/b" } }), ","), "/a,/b")
  eq(#S.keys({}), 0)
  local inter = assert(S.interactive_cmd({ host = "h", remotePath = "/srv" }, "sftp"))
  assert(not table.concat(inter, " "):find("BatchMode"), "interactive must not use BatchMode")
  eq(inter[#inter], "h")
  eq(S.target({ host = "h", username = "u" }), "u@h")
  eq(S.target({ host = "h" }), "h")
  local _, err = S.base_cmd({ host = "h", password = "pw" }, "sftp")
  assert(err and err:find("sshpass"), tostring(err))
end)

test("sftp resolve + parse_ls", function()
  local S = require("installer.sftp")
  local p = { remotePath = "/var/www/app/", root = "/x" }
  eq(S.resolve(p, nil), "/var/www/app")
  eq(S.resolve(p, "src/a.lua"), "/var/www/app/src/a.lua")
  eq(S.resolve(p, "./src"), "/var/www/app/src")
  eq(S.resolve(p, "/etc/hosts"), "/etc/hosts")
  local out = table.concat({
    "drwxr-xr-x    2 user     group        4096 Oct 14 12:05 .",
    "drwxr-xr-x    5 user     group        4096 Oct 14 12:05 ..",
    "-rw-r--r--    1 user     group           6 Oct 14 12:05 a.lua",
    "drwxr-xr-x    2 user     group        4096 Oct 14 12:05 src",
    "lrwxrwxrwx    1 user     group           3 Oct 14 12:05 link -> src",
    "-rw-r--r--    1 user     group          42 Jan  3  2025 with space.txt",
  }, "\n")
  local entries = S.parse_ls(out)
  eq(#entries, 4)
  eq(entries[1].name, "src")
  eq(entries[1].type, "dir")
  eq(entries[2].name, "a.lua")
  eq(entries[2].size, 6)
  eq(entries[3].name, "link")
  eq(entries[3].target, "src")
  eq(entries[4].name, "with space.txt")
  eq(entries[4].mtime, "Jan  3  2025")
end)

-- yaml ---------------------------------------------------------------------------
test("yaml decode", function()
  local Y = require("installer.yaml")
  local doc = table.concat({
    "# comment",
    "---",
    "after_write: install   # trailing",
    "confirm: no",
    "ui: {border: rounded, width: 0.6}",
    "github:",
    "  token: ~",
    "  topic_query: 'topic:neovim-plugin'",
    "  scope: public_repo read:user",
    "  url: http://x:8080/p",
    "ai:",
    "  exclude: [github/copilot.vim, \"a/b\"]",
    "sftp:",
    "  ignore:",
    "    - .git",
    "    - \"*.log\"",
    "  profiles:",
    "    prod:",
    "      port: 2222",
    "      privateKeyPaths: [~/.ssh/a, ~/.ssh/b]",
    "      options: {ServerAliveInterval: 30, Compression: yes}",
    "  servers:",
    "    - name: staging",
    "      host: s",
    "    - name: other",
    "note: |",
    "  one",
    "  two",
    "folded: >-",
    "  a",
    "  b",
    "escaped: \"tab\\there\"",
  }, "\n")
  local v = Y.decode(doc)
  eq(v.after_write, "install")
  eq(v.confirm, false)
  eq(v.ui.border, "rounded")
  eq(v.ui.width, 0.6)
  eq(v.github.token, nil)
  eq(v.github.topic_query, "topic:neovim-plugin")
  eq(v.github.scope, "public_repo read:user")
  eq(v.github.url, "http://x:8080/p")
  eq(v.ai.exclude[2], "a/b")
  eq(v.sftp.ignore[2], "*.log")
  eq(v.sftp.profiles.prod.port, 2222)
  eq(v.sftp.profiles.prod.privateKeyPaths[2], "~/.ssh/b")
  eq(v.sftp.profiles.prod.options.Compression, true)
  eq(v.sftp.profiles.prod.options.ServerAliveInterval, 30)
  eq(v.sftp.servers[1].host, "s")
  eq(v.sftp.servers[2].name, "other")
  eq(v.note, "one\ntwo\n")
  eq(v.folded, "a b")
  eq(v.escaped, "tab\there")
  eq(next(Y.decode("")), nil)
  local _, err = Y.safe_decode("a: 1\n b: 2\n")
  assert(err, "expected an error for bad indentation")
  _, err = Y.safe_decode("\tkey: 1")
  assert(err and err:find("tabs"), tostring(err))
end)

test("yaml encode round-trip", function()
  local Y = require("installer.yaml")
  local v = {
    after_write = "install",
    ui = { border = "rounded", width = 0.6 },
    sftp = {
      concurrency = 8,
      ignore = { ".git", "*.log", "yes", "" },
      profiles = { prod = { host = "example.com", port = 2222, keys = { "~/.ssh/a" }, uploadOnSave = true, note = "a: b", multi = "x\ny" } },
      servers = { { name = "staging", host = "s", ignore = { "dist" } }, { name = "other" } },
    },
    empty = {},
    big = { 1, 2, 3, 4, 5, 6, 7, 8 },
  }
  local text = Y.encode(v)
  assert(text:find('ignore: %[%.git, "%*%.log", "yes", ""%]'), text)
  assert(text:find("\n  servers:\n    %- host: s\n      ignore: %[dist%]\n      name: staging\n"), text)
  local back = Y.decode(text)
  local function deep_eq(a, b, path)
    if type(a) ~= "table" or type(b) ~= "table" then
      eq(a, b, path)
      return
    end
    for k, x in pairs(a) do
      deep_eq(x, b[k], path .. "." .. tostring(k))
    end
    for k in pairs(b) do
      assert(a[k] ~= nil, path .. ": unexpected key " .. tostring(k))
    end
  end
  deep_eq(v, back, "root")
end)

test("cache helpers", function()
  local C = require("installer.cache")
  eq(C.human(512), "512 B")
  eq(C.human(2048), "2.0 KiB")
  eq(C.human(5 * 1024 * 1024), "5.0 MiB")
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

test("mason packages / resolve / language_for with a fake registry", function()
  vim.tbl_get = vim.tbl_get or function(t, ...)
    for _, k in ipairs({ ... }) do
      if type(t) ~= "table" then
        return nil
      end
      t = t[k]
    end
    return t
  end
  vim.tbl_contains = vim.tbl_contains or function(t, v)
    for _, x in ipairs(t) do
      if x == v then
        return true
      end
    end
    return false
  end
  vim.bo = vim.bo or { filetype = "python" }
  local specs = {
    { name = "lua-language-server", description = "Lua LSP", categories = { "LSP" }, languages = { "Lua" }, neovim = { lspconfig = "lua_ls" } },
    { name = "stylua", description = "Lua formatter", categories = { "Formatter" }, languages = { "Lua" } },
    { name = "debugpy", description = "Python debugger", categories = { "DAP" }, languages = { "Python" } },
    { name = "pyright", description = "Python LSP", categories = { "LSP" }, languages = { "Python" }, neovim = { lspconfig = "pyright" } },
  }
  local installed = { stylua = true }
  package.preload["mason-registry"] = function()
    return {
      get_all_package_specs = function()
        return specs
      end,
      is_installed = function(n)
        return installed[n] == true
      end,
      has_package = function(n)
        for _, s in ipairs(specs) do
          if s.name == n then
            return true
          end
        end
        return false
      end,
      get_package_aliases = function(n)
        return n == "lua-language-server" and { "sumneko_lua" } or {}
      end,
    }
  end
  local Mason = require("installer.mason")
  assert(Mason.available())
  eq(#Mason.packages(), 4)
  eq(Mason.packages()[1].name, "stylua") -- installed first
  eq(#Mason.packages({ category = "LSP" }), 2)
  eq(#Mason.packages({ language = "python" }), 2)
  eq(#Mason.packages({ installed = true }), 1)
  eq(Mason.packages({ query = "lua_ls" })[1].name, "lua-language-server")
  eq(#Mason.packages({ query = "lsp python" }), 1)
  eq(Mason.resolve("lua_ls"), "lua-language-server")
  eq(Mason.resolve("sumneko_lua"), "lua-language-server")
  eq(Mason.resolve("stylua"), "stylua")
  eq(Mason.resolve("nope"), nil)
  eq(Mason.language_for("sh"), "Bash")
  eq(Mason.language_for("python"), "Python")
  eq(Mason.language_for("lua"), "Lua")
  eq(Mason.language_for("nonexistent"), nil)
  eq(Mason.language_for(""), nil)
  package.preload["mason-registry"] = nil
  package.loaded["mason-registry"] = nil
end)

-- mason built-in data fallback (all 601 Mason servers) --------------------------
test("mason fallback catalog resolves all 601 servers & lspconfig names", function()
  local Mason = require("installer.mason")
  local all = Mason.packages()
  assert(#all >= 600, "expected >= 600 built-in Mason packages, got " .. #all)
  local lsps = Mason.packages({ category = "LSP" })
  assert(#lsps >= 300, "expected >= 300 LSP servers, got " .. #lsps)
  eq(Mason.resolve("lua_ls"), "lua-language-server")
  eq(Mason.resolve("ts_ls"), "typescript-language-server")
  eq(Mason.resolve("vtsls"), "vtsls")
  eq(Mason.resolve("pyright"), "pyright")
  eq(Mason.resolve("rust_analyzer"), "rust-analyzer")
  eq(Mason.resolve("clangd"), "clangd")
end)

-- README.md & multi-manager installer parser -----------------------------------
test("parser parses lazy.nvim README spec", function()
  local Parser = require("installer.parser")
  local md = [[
# noice.nvim
## Installation
### lazy.nvim
```lua
return {
  "folke/noice.nvim",
  event = "VeryLazy",
  opts = {
    presets = { bottom_search = true },
  },
  dependencies = {
    "MunifTanjim/nui.nvim",
    "rcarriga/nvim-notify",
  },
}
```
]]
  local res = Parser.parse(md)
  assert(res.primary, "expected primary spec")
  eq(res.primary_manager, "lazy")
  eq(res.primary.repo, "folke/noice.nvim")
  eq(res.primary.event, "VeryLazy")
  eq(res.primary.dependencies, "MunifTanjim/nui.nvim, rcarriga/nvim-notify")
  local g = assert(Spec.generate(res.primary, { header = false }))
  local spec = assert(loadstring(g.source))()
  eq(spec[1], "folke/noice.nvim")
  eq(spec.opts.presets.bottom_search, true)
end)

test("parser parses packer.nvim use spec", function()
  local Parser = require("installer.parser")
  local md = [[
## Installation
```lua
use {
  'nvim-telescope/telescope.nvim', tag = '0.1.8',
  requires = { {'nvim-lua/plenary.nvim'}, {'nvim-tree/nvim-web-devicons', opt = true} },
  run = 'make',
  cmd = 'Telescope',
  opt = true,
  as = 'telescope',
}
```
]]
  local res = Parser.parse(md)
  assert(res.primary)
  eq(res.primary_manager, "packer")
  eq(res.primary.repo, "nvim-telescope/telescope.nvim")
  eq(res.primary.tag, "0.1.8")
  eq(res.primary.dependencies, "nvim-lua/plenary.nvim, nvim-tree/nvim-web-devicons")
  eq(res.primary.build, "make")
  eq(res.primary.cmd, "Telescope")
  eq(res.primary.lazy, "true")
  eq(res.primary.name, "telescope")
  local g = assert(Spec.generate(res.primary, { header = false }))
  local spec = assert(loadstring(g.source))()
  eq(spec[1], "nvim-telescope/telescope.nvim")
  eq(spec.build, "make")
end)

test("parser parses vim-plug Plug spec and multi-Plug dependencies", function()
  local Parser = require("installer.parser")
  local md = [[
```vim
call plug#begin()
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim', { 'tag': '0.1.8', 'do': ':UpdateRemotePlugins', 'on': 'Telescope', 'for': ['lua', 'python'] }
call plug#end()
```
]]
  local res = Parser.parse(md)
  assert(res.primary)
  eq(res.primary_manager, "vim-plug")
  eq(res.primary.repo, "nvim-telescope/telescope.nvim")
  eq(res.primary.tag, "0.1.8")
  eq(res.primary.build, ":UpdateRemotePlugins")
  eq(res.primary.cmd, "Telescope")
  eq(res.primary.ft, "lua, python")
  eq(res.primary.dependencies, "nvim-lua/plenary.nvim")
end)

test("parser parses mini.deps, vim.pack, pckr, paq, dein, vundle, rocks, git clone & MasonInstall", function()
  local Parser = require("installer.parser")

  -- mini.deps
  local r_mini = Parser.parse([[
MiniDeps.add({
  source = 'nvim-treesitter/nvim-treesitter',
  depends = { 'nvim-lua/plenary.nvim' },
  checkout = 'main',
  hooks = { post_checkout = function() vim.cmd('TSUpdate') end },
})
]])
  eq(r_mini.primary_manager, "mini.deps")
  eq(r_mini.primary.repo, "nvim-treesitter/nvim-treesitter")
  eq(r_mini.primary.branch, "main")
  eq(r_mini.primary.build, ":TSUpdate")
  eq(r_mini.primary.dependencies, "nvim-lua/plenary.nvim")

  -- vim.pack
  local r_vpack = Parser.parse([[
vim.pack.add({
  {
    src = 'https://github.com/nvim-treesitter/nvim-treesitter',
    version = 'main',
  },
})
]])
  eq(r_vpack.primary_manager, "vim.pack")
  eq(r_vpack.primary.repo, "nvim-treesitter/nvim-treesitter")
  eq(r_vpack.primary.version, "main")

  -- pckr.nvim
  local r_pckr = Parser.parse([[
require('pckr').add{
  { 'iamcco/markdown-preview.nvim', run = 'cd app && yarn install', cond = cmd('MarkdownPreview') };
}
]])
  eq(r_pckr.primary_manager, "pckr")
  eq(r_pckr.primary.repo, "iamcco/markdown-preview.nvim")
  eq(r_pckr.primary.build, "cd app && yarn install")
  eq(r_pckr.primary.cmd, "MarkdownPreview")

  -- dein.vim
  local r_dein = Parser.parse([[call dein#add('Shougo/deoplete.nvim', { 'build': ':UpdateRemotePlugins', 'rev': 'master' })]])
  eq(r_dein.primary_manager, "dein")
  eq(r_dein.primary.repo, "Shougo/deoplete.nvim")
  eq(r_dein.primary.build, ":UpdateRemotePlugins")
  eq(r_dein.primary.branch, "master")

  -- Vundle
  local r_vundle = Parser.parse([[Plugin 'tpope/vim-surround']])
  eq(r_vundle.primary_manager, "vundle")
  eq(r_vundle.primary.repo, "tpope/vim-surround")

  -- rocks.nvim + git clone + MasonInstall + standalone setup()
  local r_combo = Parser.parse([[
```sh
git clone -b release https://github.com/neoclide/coc.nvim.git
```
```vim
:MasonInstall lua-language-server stylua
```
```lua
require("coc").setup({ suggest = { noselect = true } })
```
]])
  eq(r_combo.primary.repo, "neoclide/coc.nvim")
  eq(r_combo.primary.branch, "release")
  eq(r_combo.primary.opts, "{ suggest = { noselect = true } }")
  eq(table.concat(r_combo.mason, ","), "lua-language-server,stylua")
end)

-- Autocomplete & Form sanitization ---------------------------------------------
test("complete field & cmdline completion", function()
  local Complete = require("installer.complete")
  local Form = require("installer.form")

  -- Form.sanitize_value prevents newline crashes in nvim_buf_set_lines
  local sanitized = Form.sanitize_value("function()\n  require('x').setup({})\nend")
  assert(not sanitized:find("\n"), "sanitize_value must remove newlines")
  local g = assert(Spec.generate({ repo = "a/b", config = sanitized }, { header = false }))
  assert(loadstring(g.source))

  -- Field completion
  local evs = Complete.complete_field("event", "Very")
  eq(evs[1].word, "VeryLazy")
  local deps = Complete.complete_field("dependencies", "plenary")
  eq(deps[1].word, "nvim-lua/plenary.nvim")
  local fts = Complete.complete_field("ft", "type")
  assert(#fts >= 2 and fts[1].word:find("typescript"), "expected typescript filetype completion")

  -- CSV-aware start column
  local start_col, key, base = Complete.find_form_start("  Event         : BufReadPre, Very", 34, 5)
  eq(key, "event")
  eq(base, "Very")
  eq(start_col, 30)

  -- Command-line completion
  local subs = Complete.cmdline("", "Installer ", 10)
  assert(vim.tbl_contains(subs, "parse") and vim.tbl_contains(subs, "starsky") and vim.tbl_contains(subs, "mason") and vim.tbl_contains(subs, "save") and vim.tbl_contains(subs, "clina"))
  local m_lsps = Complete.cmdline("lua_ls", "Installer mason install lua_ls", 30)
  eq(m_lsps[1], "lua_ls")
  local sftp_acts = Complete.cmdline("up", "Installer sftp up", 17)
  eq(sftp_acts[1], "upload")
  local sftp_ui = Complete.cmdline("ui", "Installer sftp ui", 17)
  eq(sftp_ui[1], "ui")
  local clina_acts = Complete.clina_cmdline("", "Clina ", 6)
  assert(vim.tbl_contains(clina_acts, "ide") and vim.tbl_contains(clina_acts, "agent") and vim.tbl_contains(clina_acts, "mcp"))
end)

-- Spec saving & validation fixes -----------------------------------------------
test("spec validation with uninstalled require/vim.cmd and saving spec to disk", function()
  -- Quoted/comma-suffixed repo pasted from README
  local parsed_repo = assert(Spec.parse_repo("'folke/noice.nvim',"))
  eq(parsed_repo.short, "folke/noice.nvim")

  -- opts/keys referencing require('uninstalled_module') or vim.cmd.*
  local gen = assert(Spec.generate({
    repo = '"hrsh7th/nvim-cmp",',
    opts = '{ mapping = require("cmp").mapping.preset.insert({}), dir = vim.fn.stdpath("data") }',
    keys = '{ { "<leader>e", vim.cmd.Neotree, desc = "Explorer" } }',
    config = "false",
  }, { header = false }))
  assert(gen.source:find("config = false", 1, true), "expected config = false in rendered spec")
  assert(loadstring(gen.source), "generated spec must be valid Lua")

  -- Saving spec to disk via Installer.save
  local Installer = require("installer")
  local Lazy = require("installer.lazy")
  local tmp_plugins = "/tmp/installer-test-plugins-" .. tostring(os.time())
  Installer.setup({ plugins_dir = tmp_plugins, confirm_overwrite = false })
  local ok, saved_path, saved_gen = Installer.save({
    repo = "folke/snacks.nvim",
    event = "VeryLazy",
    opts = "{ notifier = { enabled = true } }",
  })
  eq(ok, true)
  eq(saved_path, tmp_plugins .. "/snacks.lua")
  eq(saved_gen.file, "snacks")
  local fd = assert(io.open(saved_path, "r"))
  local disk_content = fd:read("*a")
  fd:close()
  assert(disk_content:find('"folke/snacks.nvim"', 1, true))
  Lazy.invalidate_spec_cache("snacks")
  os.remove(saved_path)
end)

-- SFTP UI, Clina NeoCodeium, MusicPlayer 2-Neovim, ASCII Boot & mason-registry.dev
test("sftp ui helpers and clina neocodeium integration", function()
  local Sftp = require("installer.sftp")
  assert(type(Sftp.ui) == "function", "Sftp.ui must be a function")
  assert(type(Sftp.list_local_dir) == "function", "Sftp.list_local_dir must be a function")

  local Clina = require("installer.clina")
  eq(Clina.NEOCODEIUM_REPO, "monkoose/neocodeium")
  eq(Clina.providers[1].id, "neocodeium")
  local nc_spec = Clina.neocodeium_spec()
  eq(nc_spec.repo, "monkoose/neocodeium")
  eq(nc_spec.cmd, "NeoCodeium")
  local gen = assert(Spec.generate(nc_spec, { header = false }))
  assert(gen.source:find('"monkoose/neocodeium"', 1, true))
  assert(loadstring(gen.source), "NeoCodeium spec must be valid Lua")

  local syn = Clina._fallback_synthesize({ prompt = "Configure monkoose/neocodeium", mode = "agent" })
  eq(syn.ok, true)
  assert(syn.proposal and syn.proposal.code:find("monkoose/neocodeium", 1, true))
end)

test("github api dynamic plugin autocomplete, musicplayer 2-nvim & ascii boot", function()
  local Complete = require("installer.complete")
  Complete.add_github_results("neocodeium", {
    { full_name = "monkoose/neocodeium", description = "Free AI completion plugin", stargazers_count = 1420 },
    { full_name = "Exafunction/windsurf.nvim", description = "Windsurf Neovim", stargazers_count = 2900 },
  })
  local repo_cands = Complete.complete_field("repo", "monkoose/")
  assert(#repo_cands >= 1 and repo_cands[1].word == "monkoose/neocodeium")

  local music_subs = Complete.music_cmdline("", "MusicPlayer ", 12)
  assert(vim.tbl_contains(music_subs, "server") and vim.tbl_contains(music_subs, "connect") and vim.tbl_contains(music_subs, "eq"))
  local eq_cands = Complete.music_cmdline("lofi", "MusicPlayer eq lofi", 19)
  eq(eq_cands[1], "lofi-coding")

  local Music = require("installer.music")
  eq(#Music.eq_frequencies, 10)
  assert(#Music.stations >= 7)
  Music.action("eq_preset", { preset = "synthwave" })
  eq(Music.state.eq_preset, "synthwave")
  eq(Music.state.eq_bands[1], 6)
  local vis_lines = Music.render_visualizer(80)
  eq(#vis_lines, 3)
  local eq_lines = Music.render_eq()
  eq(#eq_lines, 3)
  local snap = Music.get_snapshot()
  eq(snap.eq_preset, "synthwave")
  Music.action("eq_preset", { preset = "flat" })
  eq(Music.state.eq_preset, "flat")
  Music.apply_snapshot(snap)
  eq(Music.state.eq_preset, "synthwave")

  local Boot = require("installer.boot")
  local frame = Boot.render_frame(4, 88)
  assert(#frame >= 14, "expected ASCII boot frame lines")

  local Mason = require("installer.mason")
  eq(Mason.REGISTRY_WEB_URL, "https://mason-registry.dev")
  eq(Mason.package_url("lua-language-server"), "https://mason-registry.dev/registry/list#/lua-language-server")
end)

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
  os.exit(1)
end
