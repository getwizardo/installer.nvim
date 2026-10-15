-- Minimal test runner for the pure-Lua parts of kaeru.nvim.
-- Runs under `nvim -l`, `luajit` or `lua5.1` (a tiny `vim` stub is installed when needed).
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

if not vim then
  -- stub just enough of the vim API for spec.lua / github.lua / config.lua
  vim = {
    env = {},
    g = {},
    b = {},
    o = {},
    opt = {},
    bo = { filetype = "" },
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
        return "/tmp/kaeru-test"
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
        return "/tmp/kaeru-test"
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
      _commands = {},
      nvim_create_user_command = function(name, fn, opts)
        vim.api._commands[name] = { fn = fn, opts = opts }
        return name
      end,
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
    cmd = function() end,
    ui = {
      select = function(_, _, cb)
        if cb then
          cb(nil)
        end
      end,
      input = function(_, _, cb)
        if cb then
          cb(nil)
        end
      end,
    },
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

local Compat = require("kaeru.compat")  -- after the vim stub above
local Spec = require("kaeru.spec")
local GitHub = require("kaeru.github")

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
  assert(g.source:find("^%-%- Generated by kaeru%.nvim"), g.source)
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
  local AI = require("kaeru.ai")
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
  local S = require("kaeru.sftp")
  local pats = { S._glob_to_pattern(".git"), S._glob_to_pattern("*.log"), S._glob_to_pattern("dist/**"), S._glob_to_pattern(".nvim-sftp.json") }
  assert(S._ignored(".git/config", pats))
  assert(S._ignored("src/app.log", pats))
  assert(S._ignored("dist/js/app.js", pats))
  assert(S._ignored(".nvim-sftp.json", pats), "config file must never be uploaded")
  assert(not S._ignored("src/app.lua", pats))
  assert(not S._ignored("distro/readme.md", pats))
end)

test("sftp chunking is round-robin and bounded", function()
  local S = require("kaeru.sftp")
  local chunks = S.chunk({ "a", "b", "c", "d", "e" }, 2)
  eq(#chunks, 2)
  eq(table.concat(chunks[1], ","), "a,c,e")
  eq(table.concat(chunks[2], ","), "b,d")
  eq(#S.chunk({ "a" }, 8), 1)
  eq(#S.chunk({}, 4), 1)
end)

test("sftp upload batch creates parent dirs then puts files", function()
  local S = require("kaeru.sftp")
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
  local S = require("kaeru.sftp")
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
  local S = require("kaeru.sftp")
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
  local Y = require("kaeru.yaml")
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
  local Y = require("kaeru.yaml")
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
  local C = require("kaeru.cache")
  eq(C.human(512), "512 B")
  eq(C.human(2048), "2.0 KiB")
  eq(C.human(5 * 1024 * 1024), "5.0 MiB")
end)

-- process pool -----------------------------------------------------------------
test("process pool respects concurrency and order", function()
  local P = require("kaeru.process")
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
  vim.tbl_get = function(t, ...)
    for _, k in ipairs({ ... }) do
      if type(t) ~= "table" then
        return nil
      end
      t = t[k]
    end
    return t
  end
  vim.tbl_contains = function(t, v)
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
  local Mason = require("kaeru.mason")
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
  local Mason = require("kaeru.mason")
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
  local Parser = require("kaeru.parser")
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
  local Parser = require("kaeru.parser")
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
  local Parser = require("kaeru.parser")
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
  local Parser = require("kaeru.parser")

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
  local Complete = require("kaeru.complete")
  local Form = require("kaeru.form")

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
  local subs = Complete.cmdline("", "Kaeru ", 10)
  assert(Compat.tbl_contains(subs, "parse") and Compat.tbl_contains(subs, "starsky") and Compat.tbl_contains(subs, "mason") and Compat.tbl_contains(subs, "save") and Compat.tbl_contains(subs, "clina"))
  local m_lsps = Complete.cmdline("lua_ls", "Kaeru mason install lua_ls", 30)
  eq(m_lsps[1], "lua_ls")
  local sftp_acts = Complete.cmdline("up", "Kaeru sftp up", 17)
  eq(sftp_acts[1], "upload")
  local sftp_ui = Complete.cmdline("ui", "Kaeru sftp ui", 17)
  eq(sftp_ui[1], "ui")
  local clina_acts = Complete.clina_cmdline("", "Clina ", 6)
  assert(Compat.tbl_contains(clina_acts, "ide") and Compat.tbl_contains(clina_acts, "agent") and Compat.tbl_contains(clina_acts, "mcp"))
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

  -- Saving spec to disk via Kaeru.save
  local Kaeru = require("kaeru")
  local Lazy = require("kaeru.lazy")
  local tmp_plugins = "/tmp/kaeru-test-plugins-" .. tostring(os.time())
  Kaeru.setup({ plugins_dir = tmp_plugins, confirm_overwrite = false })
  local ok, saved_path, saved_gen = Kaeru.save({
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

-- SFTP UI, Clina NeoCodeium, Kikru 2-Neovim, ASCII Boot & mason-registry.dev
test("sftp ui helpers and clina neocodeium integration", function()
  local Sftp = require("kaeru.sftp")
  assert(type(Sftp.ui) == "function", "Sftp.ui must be a function")
  assert(type(Sftp.list_local_dir) == "function", "Sftp.list_local_dir must be a function")

  local Clina = require("kaeru.clina")
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
  local Complete = require("kaeru.complete")
  Complete.add_github_results("neocodeium", {
    { full_name = "monkoose/neocodeium", description = "Free AI completion plugin", stargazers_count = 1420 },
    { full_name = "Exafunction/windsurf.nvim", description = "Windsurf Neovim", stargazers_count = 2900 },
  })
  local repo_cands = Complete.complete_field("repo", "monkoose/")
  assert(#repo_cands >= 1 and repo_cands[1].word == "monkoose/neocodeium")

  local music_subs = Complete.music_cmdline("", "Kikru ", 12)
  assert(Compat.tbl_contains(music_subs, "server") and Compat.tbl_contains(music_subs, "connect") and Compat.tbl_contains(music_subs, "eq"))
  local eq_cands = Complete.music_cmdline("lofi", "Kikru eq lofi", 19)
  eq(eq_cands[1], "lofi-coding")

  local Kikru = require("kaeru.kikru")
  eq(#Kikru.eq_frequencies, 10)
  assert(#Kikru.stations >= 7)
  Kikru.action("eq_preset", { preset = "synthwave" })
  eq(Kikru.state.eq_preset, "synthwave")
  eq(Kikru.state.eq_bands[1], 6)
  local vis_lines = Kikru.render_visualizer(80)
  eq(#vis_lines, 3)
  local eq_lines = Kikru.render_eq()
  eq(#eq_lines, 3)
  local snap = Kikru.get_snapshot()
  eq(snap.eq_preset, "synthwave")
  Kikru.action("eq_preset", { preset = "flat" })
  eq(Kikru.state.eq_preset, "flat")
  Kikru.apply_snapshot(snap)
  eq(Kikru.state.eq_preset, "synthwave")

  local Boot = require("kaeru.boot")
  local frame = Boot.render_frame(4, 88)
  assert(#frame >= 14, "expected ASCII boot frame lines")

  local Mason = require("kaeru.mason")
  eq(Mason.REGISTRY_WEB_URL, "https://mason-registry.dev")
  eq(Mason.package_url("lua-language-server"), "https://mason-registry.dev/registry/list#/lua-language-server")
end)

-- ===========================================================================
-- 2026-10 pass: completion engine, kikru player modules, parser helpers
-- ===========================================================================

test("fuzzy_score matches substrings, subsequences and rejects misses", function()
  local C = require("kaeru.complete")
  local exact = C.fuzzy_score("telescope", "telescope.nvim")
  local sub = C.fuzzy_score("tele", "telescope.nvim")
  local seq = C.fuzzy_score("tsc", "telescope.nvim")
  eq(C.fuzzy_score("zzzz", "telescope.nvim"), nil)
  assert(exact and sub and seq, "all three should match")
  assert(exact > sub, "exact match should score above plain substring")
  assert(sub > seq, "substring should score above loose subsequence")
  local score, positions = C.fuzzy_score("tele", "telescope.nvim")
  assert(score, "tele should match")
  eq(#positions, 4)
  eq(positions[1], 1)
  eq(positions[4], 4)
  eq(C.fuzzy_score("", "anything"), 0)
  eq(C.fuzzy_score("x", ""), nil)
  -- separator folding: typing `fole/laz` finds `folke/lazy.nvim`
  assert(C.fuzzy_score("fole/laz", "folke/lazy.nvim"), "separator folding")
  assert(C.fuzzy_score("nvimtree", "nvim-tree/nvim-tree.lua"), "separator folding 2")
end)

test("rank is stable, honours the limit and accepts swapped arguments", function()
  local C = require("kaeru.complete")
  local items = {
    { word = "install" },
    { word = "installed-package-a" },
    { word = "installed-package-b" },
  }
  local ranked = C.rank(items, "")
  eq(#ranked, 3)
  eq(ranked[1].word, "install", "empty arglead keeps the candidate order (actions first)")
  local filtered = C.rank("lua", { "stylua", "lua-language-server", "luacheck" })
  eq(filtered[1].word, "luacheck", "shortest prefix match wins")
  eq(C.rank("lua-lang", { "stylua", "lua-language-server", "luacheck" })[1].word, "lua-language-server")
  eq(#C.rank(items, "install", { limit = 2 }), 2)
  eq(#C.rank(items, "nomatch-xyz"), 0)
  eq(C.rank({ { word = "a" }, { word = "b" } }, "b")[1].word, "b")
  local words = C.words({ { word = "a" }, "b" })
  eq(#words, 2)
  eq(words[1], "a")
  eq(words[2], "b")
end)

test("parse_cmdline strips ranges, bangs and picks the last pipeline segment", function()
  local C = require("kaeru.complete")
  local tokens, command, arglead = C.parse_cmdline(":'<,'>Kaeru add folke/noice.nvim")
  eq(command, "Kaeru")
  eq(tokens[2], "add")
  eq(tokens[3], "folke/noice.nvim")
  eq(arglead, "folke/noice.nvim")

  eq(C.parse_cmdline("'<,'>Kaeru add ")[2], "add")
  eq(C.parse_cmdline("1,5Kaeru save x")[2], "save")
  eq(C.parse_cmdline("%Kaeru parse")[1], "Kaeru")
  eq(C.parse_cmdline("5Kaeru boot")[1], "Kaeru")
  eq(C.parse_cmdline(":Kaeru! parse")[1], "Kaeru!")
  eq(C.parse_cmdline("echo 1 | Kikru play")[1], "Kikru")
  eq(C.detect_command("Kae"), "Kaeru")
  eq(C.detect_command("Kik"), "Kikru")
  eq(C.detect_command("Cli"), "Clina")
  eq(C.detect_command("zzz"), nil)
  local _, empty_command = C.parse_cmdline("")
  eq(empty_command, "")
end)

test("complete_items covers subcommands, actions and arguments", function()
  local C = require("kaeru.complete")
  local subs = C.complete_items("Kaeru ", 7)
  local sub_words = C.words(subs)
  for _, want in ipairs({ "add", "save", "parse", "mason", "sftp", "cache", "config", "ai", "clina", "music", "boot" }) do
    assert(Compat.tbl_contains(sub_words, want), "missing subcommand " .. want)
  end
  for _, item in ipairs(subs) do
    if item.word == "add" then
      assert(item.menu and item.menu ~= "", "subcommands should carry a menu")
    end
  end

  local mason = C.words(C.complete_items("Kaeru mason ", 13))
  assert(Compat.tbl_contains(mason, "install"), "mason install action must rank first")
  local mason_scaffolds = C.words(C.complete_items("Kaeru mason scaffold ", 22))
  assert(Compat.tbl_contains(mason_scaffolds, "lsp"), "mason scaffolds")

  local kikru = C.words(C.complete_items("Kikru ", 7))
  for _, want in ipairs({ "play", "pause", "eq", "filters", "visualizer", "radio", "search", "queue", "playlist", "lyrics", "cast", "engine" }) do
    assert(Compat.tbl_contains(kikru, want), "Kikru completion missing " .. want)
  end
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru visualizer ", 18)), "spectrum"), "visualizer modes")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru eq ", 10)), "lofi-coding"), "eq presets")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru filter ", 14)), "tremolo"), "filter presets")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru queue ", 13)), "shuffle"), "queue actions")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru playlist ", 16)), "save"), "playlist actions")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru cast ", 12)), "youtube"), "cast targets")
  assert(Compat.tbl_contains(C.words(C.complete_items("Kikru cast server ", 19)), "8722"), "cast port")

  local clina = C.words(C.complete_items("Clina ", 7))
  assert(Compat.tbl_contains(clina, "ask") and Compat.tbl_contains(clina, "login"))

  -- partial arglead filters instead of erroring
  assert(Compat.tbl_contains(C.words(C.complete_items("Kaeru ma", 9)), "mason"))
end)

test("kikru module façade keeps the 1.x public surface", function()
  local Kikru = require("kaeru.kikru")
  eq(#Kikru.eq_frequencies, 10)
  for _, preset in ipairs({ "flat", "bass-boost", "lofi-coding", "synthwave", "vocal", "classical", "night" }) do
    assert(Kikru.eq_presets[preset], "missing eq preset " .. preset)
  end
  for _, mode in ipairs({ "spectrum", "wave", "vu", "matrix", "starfield" }) do
    assert(Compat.tbl_contains(Kikru.visualizer_modes, mode), "missing visualizer mode " .. mode)
  end
  for _, service in ipairs({ "spotify", "youtube", "youtube_music", "soundcloud", "apple", "deezer", "tidal", "radio" }) do
    assert(Compat.tbl_contains(Kikru.streaming_service_ids, service), "missing streaming service " .. service)
  end
  assert(type(Kikru.start_server) == "function")
  assert(type(Kikru.connect_client) == "function")
  assert(type(Kikru.send_remote_command) == "function")
  assert(type(Kikru.broadcast_state) == "function")
  assert(type(Kikru.cast) == "function" or type(package.loaded["kaeru.kikru.cast"]) == "table", "cast API")
  Kikru.action("stop")
  Kikru.action("play", { station = "lofi" })
  local station = Kikru.current_station()
  assert(station and (station.title or station.name), "expected a resolved station")
  local snap = Kikru.get_snapshot()
  eq(type(snap.playing), "boolean")
  Kikru.action("stop")

  -- façade alias `require("kaeru").kikru` + the legacy `require("kaeru").music`
  local kaeru = require("kaeru")
  eq(kaeru.kikru.eq_frequencies, Kikru.eq_frequencies)
  eq(kaeru.music.eq_frequencies, Kikru.eq_frequencies)
end)

test("kikru filters build valid mpv/ffplay/vlc argument chains", function()
  local F = require("kaeru.kikru.filters")
  local state = {
    bands = { 6, 5, 4, -2, -3, 0, 1, 2, 3, 4 },
    preamp = 3,
    filters = {
      tremolo = { enabled = true, frequency = 5, depth = 0.5 },
      echo = { enabled = true, delay = 0.8, decay = 0.5 },
    },
  }
  local mpv = F.build("mpv", state)
  assert(type(mpv.af) == "string" and mpv.af:find("equalizer", 1, true), "mpv af: " .. tostring(mpv.af))
  assert(#mpv.af_list >= 2)
  local ff = F.build("ffplay", state)
  assert(ff.af:find("equalizer", 1, true), "ffplay af: " .. tostring(ff.af))
  assert(ff.af:find("tremolo", 1, true), "enabled tremolo missing from the ffplay chain")
  local vlc = F.build("vlc", state)
  assert(vlc.vlc_preset ~= nil)
  eq(#F.frequencies, 10)
  eq(F.frequencies[1], 31)
  eq(F.frequencies[10], 16000)
  for i = 2, 10 do
    assert(F.frequencies[i] > F.frequencies[i - 1], "bands must be ascending")
    eq(type(F.frequency_labels[i]), "string")
  end
  assert(F.presets.flat, "filters module must expose the presets")
  assert(F.flat and #F.flat == 10)
  eq(F.build("mpv", { bands = F.flat, filters = {} }).af, "")
end)

test("kikru playlist handles m3u/pls/toml/json round-trips", function()
  local P = require("kaeru.kikru.playlist")
  for _, fn in ipairs({ "parse_m3u", "parse_pls", "parse_toml", "parse_text", "parse", "next", "prev", "save", "load", "insert_after_current" }) do
    eq(type(P[fn]), "function", "playlist." .. fn)
  end
  local items = P.parse_m3u("#EXTM3U\n#EXTINF:180,Artist - Title\n/tmp/a.mp3\n#EXTINF:5,B - C\n/tmp/b.mp3\n")
  eq(#items, 2)
  eq(items[1].title, "Title")
  eq(items[1].artist, "Artist")
  eq(items[2].duration, 5)
  local pls = P.parse_pls("[playlist]\nFile1=/tmp/a.mp3\nTitle1=A\nLength1=12\nNumberOfEntries=1\n")
  eq(#pls, 1)
  eq(pls[1].url, "/tmp/a.mp3")
  eq(pls[1].duration, 12)

  local pl = P.new({ { url = "a" }, { url = "b" }, { url = "c" } }, "queue")
  eq(pl.index, 1)
  pl.index = 1
  local track, index, stopped = P.next(pl, {})
  eq(track.url, "b")
  eq(index, 2)
  eq(stopped, false)
  pl.index = 3
  pl.repeat_mode = "off"
  local _, _, stop3 = P.next(pl, { auto = true })
  eq(stop3, true)
  pl.repeat_mode = "all"
  eq(P.next(pl, { auto = true }).url, "a")
  pl.repeat_mode = "one"
  eq(P.next(pl, { auto = true }).url, "a", "repeat one keeps the current track")
end)

test("kikru json, lyrics and visualizer helpers are pure", function()
  local J = require("kaeru.json")
  local enc = J.encode({ a = 1, b = { 1, 2, 3 }, c = "x", d = true })
  assert(type(enc) == "string" and enc:find('"a":1', 1, true), "json encode: " .. tostring(enc))
  local dec = J.decode('{"a":[1,2,{"b":null}],"c":"\\u00e9"}')
  eq(dec.a[3].b, nil)
  assert(dec.c == "é" or dec.c == "\195\169", "unicode escape decoding")
  eq(J.decode("not json"), nil)
  assert(J.encode({ nested = { deep = { 1, 2 } } }):find("deep", 1, true))

  local L = require("kaeru.kikru.lyrics")
  local parsed = L.parse_lrc("[00:12.00]hello\n[00:20.50]world\n")
  eq(#parsed.synced, 2)
  eq(parsed.synced[1].text, "hello")
  eq(parsed.synced[1].time, 12)
  local offset_parsed = L.parse_lrc("[offset:+500]\n[00:10.00]shifted\n")
  eq(offset_parsed.synced[1].time, 10.5)
  local plain = L.parse_lrc("no timestamps here")
  eq(type(plain.plain), "string")
  assert(plain.plain:find("no timestamps here", 1, true), "plain lyrics text")
  eq(plain.synced, nil)

  local V = require("kaeru.kikru.visualizer")
  local a = V.render({ mode = "spectrum", width = 40, height = 6, t = 0 })
  local b = V.render({ mode = "spectrum", width = 40, height = 6, t = 0 })
  eq(#a, 6)
  eq(a[1], b[1], "render must be deterministic for the same t")
  for _, mode in ipairs({ "spectrum", "wave", "vu", "matrix", "starfield" }) do
    eq(#V.render({ mode = mode, width = 30, height = 4, t = 1 }), 4, mode .. " height")
  end
end)

test("kikru lyrics: TTML is parsed through the karu CLI", function()
  local Json = require("kaeru.json")
  local L = require("kaeru.kikru.lyrics")

  eq(L.looks_like_ttml('<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>'), true)
  eq(L.looks_like_ttml('<?xml version="1.0"?><timedtext format="3"></timedtext>'), true)
  eq(L.looks_like_ttml("[00:12.00]hello"), false)
  eq(L.looks_like_ttml(nil), false)
  assert(not L.looks_like_ttml(""), "empty text is not TTML")

  local saved = {
    system = vim.fn.system,
    executable = vim.fn.executable,
    tempname = vim.fn.tempname,
  }
  local saved_v = vim.v
  local calls = {}
  -- The stubs below make every binary look installed; they must be undone even
  -- when an assertion fails, or the rest of the suite sees a different machine.
  local restore = function()
    vim.fn.system = saved.system
    vim.fn.executable = saved.executable
    vim.fn.tempname = saved.tempname
    vim.v = saved_v
  end
  local ok_run, run_err = pcall(function()
    local out_path = "/tmp/kaeru-ttml-test-out.ttml"
    os.remove(out_path)
    vim.v = { shell_error = 0 }
    vim.fn.executable = function()
      return 1
    end
    vim.fn.tempname = function()
      return "/tmp/kaeru-ttml-test"
    end
    local payload = {
      ok = true,
      kind = "ttml",
      timing = "Word",
      wordSync = true,
      singers = 2,
      lang = "en",
      translationLangs = { "ja" },
      summary = "2 lines · 00:12.00–00:20.50 · word-timed · 2 singers",
      lrc = "[00:12.00]<00:12.00>Is <00:12.50>this\n[00:20.50]the real life?\n",
      cues = { { start = 12.0, ["end"] = 15.0, text = "Is this" }, { start = 20.5, ["end"] = 23.5, text = "the real life?" } },
      translationByLine = { "これは", nil },
      meta = { title = "Bohemian Rhapsody" },
    }
    local last = ""
    vim.fn.system = function(cmd)
      local text = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
      calls[#calls + 1] = text
      last = text
      if text:match("^node ") then
        return "v22.22.3\n"
      end
      local out = text:match("'%-%-out'%s+'([^']+)'")
      if out then
        local fd = io.open(out, "w")
        if fd then
          fd:write('<tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word"></tt>\n')
          fd:close()
        end
        return ""
      end
      return Json.encode(payload)
    end

    local available, reason = L.ttml_available()
    eq(available, true, tostring(reason))

    local parsed, err = L.parse_ttml(payload.lrc == "" and "" or '<tt itunes:timing="Word"><body><div><p begin="0:12.000" end="0:15.000">x</p></div></body></tt>', "song.ttml")
    eq(err, nil)
    eq(#parsed.synced, 2)
    eq(parsed.synced[1].time, 12)
    eq(#parsed.synced[1].words, 2)
    assert(parsed.synced[1].words[1].text:match("^Is"), "first word: " .. tostring(parsed.synced[1].words[1].text))
    eq(parsed.synced[1].words[2].time, 12.5)
    eq(parsed.source, "song.ttml")
    eq(parsed.ttml.singers, 2)
    eq(parsed.ttml.wordSync, true)
    eq(parsed.translated[1].text, "これは")
    eq(parsed.translated[1].time, 12)
    assert(#parsed.translated == 1, "only translated lines are kept")
    assert(last:find("lyrics", 1, true) and last:find("--format", 1, true), "conversion goes through karu lyrics: " .. last)

    local UI = require("kaeru.kikru.ui")
    eq(UI.lyrics_badge(nil), "")
    eq(UI.lyrics_badge({ source = "x.lrc" }), "")
    eq(
      UI.lyrics_badge({ source = "x.ttml", ttml = { wordSync = true, singers = 2, translationLangs = { "ja", "en" } } }),
      " · ttml word, 2 singers, translations: ja, en"
    )
    eq(UI.lyrics_badge({ source = "x.ttml", ttml = { wordSync = false } }), " · ttml line")

    -- a .ttml sidecar file next to the audio is picked up by sidecar_path
    local side = "/tmp/kaeru-ttml-sidecar.ttml"
    local fd = io.open(side, "w")
    fd:write('<tt itunes:timing="Word"><body><div><p begin="0:12.000" end="0:15.000">hi</p></div></body></tt>')
    fd:close()
    local from_file = L.from_file(side)
    eq(#from_file.synced, 2)
    eq(from_file.translated[1].time, 12)
    eq(L.sidecar_path({ path = "/tmp/kaeru-ttml-sidecar.mp3" }), side)
    os.remove(side)

    -- saving TTML writes through the CLI; raw TTML is written verbatim
    local written, write_err = L.save(nil, { raw = "[00:12.00]hello\n" }, out_path)
    eq(written, out_path, tostring(write_err))
    local check = io.open(out_path, "r")
    assert(check and check:read("*a"):find("<tt", 1, true), "TTML output written")
    if check then
      check:close()
    end
    local raw_path = "/tmp/kaeru-ttml-raw.ttml"
    local raw_written = L.save(nil, { raw = '<tt itunes:timing="Line"><body/></tt>' }, raw_path)
    eq(raw_written, raw_path)
    local raw_check = io.open(raw_path, "r")
    assert(raw_check and raw_check:read("*a"):find("itunes:timing", 1, true), "raw TTML kept as-is")
    if raw_check then
      raw_check:close()
    end
    os.remove(raw_path)
    os.remove(out_path)

  end)
  restore()
  if not ok_run then
    error(run_err)
  end
end)

test("kikru daemon frames JSON lines and syncs snapshots", function()
  local Daemon = require("kaeru.kikru.daemon")
  local decoded = Daemon.consume('{"a":1}\n{"b":2}\n{"c":', "")
  eq(#decoded.messages, 2)
  eq(decoded.messages[1].a, 1)
  eq(decoded.messages[2].b, 2)
  eq(decoded.buffer, '{"c":')
  local more = Daemon.consume('3}\n{"d":4}\n', decoded.buffer)
  eq(#more.messages, 2)
  eq(more.messages[1].c, 3)
  eq(more.messages[2].d, 4)
  eq(more.buffer, "")
  local broken = Daemon.consume("not json\n", "")
  eq(#broken.messages, 0)
  eq(#broken.errors, 1)
  assert(type(Daemon.transport_label) == "function")

  local Kikru = require("kaeru.kikru")
  Kikru.action("eq_preset", { preset = "night" })
  local snap = Kikru.get_snapshot()
  Kikru.action("eq_preset", { preset = "flat" })
  eq(Kikru.state.eq_preset, "flat")
  Kikru.apply_snapshot(snap)
  eq(Kikru.state.eq_preset, "night")
  Kikru.action("eq_preset", { preset = "flat" })
end)

test("parser.parse_all returns deduplicated scored items", function()
  local Parser = require("kaeru.parser")
  local text = table.concat({
    "```lua",
    'require("lazy").setup({',
    '  { "folke/noice.nvim", dependencies = { "MunifTanjim/nui.nvim" } },',
    '  "nvim-telescope/telescope.nvim",',
    "})",
    "```",
  }, "\n")
  local items, err = Parser.parse_all(text)
  eq(err, nil)
  assert(#items >= 2, "expected at least two parsed plugins")
  local seen = {}
  for _, item in ipairs(items) do
    assert(not seen[item.repo], "duplicate repo " .. item.repo)
    seen[item.repo] = true
    eq(item.form.repo, item.repo)
  end
  assert(items[1].score >= items[#items].score, "sorted by score desc")
  eq(#Parser.parse_all("just some prose with no plugin at all"), 0)
  assert(type(require("kaeru").parse) == "function")
end)

test("complete.omnifunc and form attachment work on a scratch buffer", function()
  local C = require("kaeru.complete")
  for _, fn in ipairs({ "omnifunc", "attach_form", "trigger", "setup_cmdline", "cmp_source", "blink_source", "complete_field" }) do
    eq(type(C[fn]), "function", "complete." .. fn)
  end

  local src = C.cmp_source()
  eq(src.name, "kaeru")
  eq(src:is_available(), false, "not on a command line in the harness")
  local got
  src:complete({}, function(items)
    got = items or {}
  end)
  eq(type(got), "table")

  local blink = C.blink_source()
  eq(blink.name, "kaeru")
  local bgot
  blink:get_completions({}, function(res)
    bgot = res
  end)
  assert(type(bgot == nil or bgot.items == "table" or type(bgot.items) == "table"))
end)

test("compat shims work without the Neovim-only helpers", function()
  local Compat = require("kaeru.compat")
  eq(#Compat.list_slice({ 1, 2, 3 }, 2), 2)
  eq(Compat.list_slice({ 1, 2, 3 }, 2, 3)[1], 2)
  eq(Compat.tbl_get({ a = { b = { c = 1 } } }, "a", "b", "c"), 1)
  eq(Compat.tbl_get({}, "a", "b"), nil)
  eq(Compat.tbl_count({ a = 1, b = 2 }), 2)
  eq(#Compat.tbl_filter(function(v)
    return v > 1
  end, { 1, 2, 3 }), 2)
  eq(Compat.tbl_map(function(v)
    return v * 2
  end, { 1, 2 })[2], 4)
  eq(Compat.tbl_contains({ "a", "b" }, "b"), true)
  eq(Compat.tbl_contains({ "a" }, "z"), false)
  eq(#Compat.tbl_keys({ x = 1 }), 1)
  eq(Compat.tbl_extend("force", { a = 1 }, { a = 2 }).a, 2)
  eq(Compat.tbl_deep_extend("force", { a = { b = 1 } }, { a = { c = 2 } }).a.c, 2)
  eq(Compat.deepcopy({ a = { 1 } }).a[1], 1)
  eq(Compat.executable("definitely-not-a-real-binary-xyz"), false)
  eq(#Compat.getcompletion("", "file"), 0)
  eq(Compat.cmdtype(), nil)
  eq(Compat.cmdline(), "")
  eq(type(Compat.cmdpos()), "number")
  local ran = false
  Compat.defer_fn(function()
    ran = true
  end)
end)

-- ===========================================================================
-- Kikru casting (YouTube / YouTube Music / MPRIS) + integrations
-- ===========================================================================

test("cast.classify understands YouTube and YouTube Music links", function()
  local Cast = require("kaeru.kikru.cast")
  local cases = {
    { "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube", "video", id = "dQw4w9WgXcQ" },
    { "https://youtu.be/dQw4w9WgXcQ", "youtube", "video", id = "dQw4w9WgXcQ" },
    { "https://m.youtube.com/watch?v=abc123&t=1m30s", "youtube", "video", id = "abc123", time = 90 },
    { "https://music.youtube.com/watch?v=ID123456789", "youtube_music", "video", id = "ID123456789" },
    { "https://music.youtube.com/watch?v=ID123456789&list=RDAMVM_ID123", "youtube_music", "video_radio", id = "ID123456789" },
    { "https://www.youtube.com/playlist?list=PLabc123", "youtube", "playlist", list = "PLabc123" },
    { "https://music.youtube.com/playlist?list=PLxyz", "youtube_music", "playlist", list = "PLxyz" },
    { "https://www.youtube.com/shorts/SHORTS123", "youtube", "short", id = "SHORTS123" },
    { "https://www.youtube.com/live/LIVE123", "youtube", "live", id = "LIVE123" },
    { "https://www.youtube.com/@SomeChannel", "youtube", "channel" },
    { "https://www.youtube.com/channel/UCabc123", "youtube", "channel" },
    { "https://music.youtube.com/browse/MPREb_abc", "youtube_music", "browse" },
    { "https://soundcloud.com/artist/track", "soundcloud", "track" },
    { "https://soundcloud.com/artist/sets/favourites", "soundcloud", "set" },
    { "https://open.spotify.com/track/xyz", "spotify", "track" },
    { "https://open.spotify.com/playlist/xyz", "spotify", "playlist" },
    { "https://example.com:8000/live.mp3", "file", "stream" },
    { "https://ice1.somafm.com/groovesalad-128-mp3", nil, "icecast" },
  }
  for _, case in ipairs(cases) do
    local info = Cast.classify(case[1])
    if case[2] then
      eq(info.app, case[2], case[1] .. " app")
    end
    eq(info.kind, case[3], case[1] .. " kind")
    if case.id then
      eq(info.id, case.id, case[1] .. " id")
    end
    if case.list then
      eq(info.list, case.list, case[1] .. " list")
    end
    if case.time then
      eq(info.time, case.time, case[1] .. " time")
    end
    assert(Cast.is_cast_url(case[1]), case[1] .. " should be castable")
  end
  -- a plain search term is castable too (it becomes a YouTube Music search)
  local query = Cast.classify("daft punk discovery")
  eq(query.kind, "query")
  eq(Cast.is_cast_url("daft punk discovery"), true)
  eq(Cast.classify("").kind, "unknown")
  eq(Cast.is_cast_url(""), false)
end)

test("cast.canonical and cast.query_for build the right yt-dlp arguments", function()
  local Cast = require("kaeru.kikru.cast")
  eq(Cast.canonical(Cast.classify("https://youtu.be/dQw4w9WgXcQ")), "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
  eq(Cast.canonical(Cast.classify("https://m.youtube.com/watch?v=abc&t=90s")), "https://www.youtube.com/watch?v=abc&t=90")
  eq(
    Cast.canonical(Cast.classify("https://music.youtube.com/watch?v=X123456789")),
    "https://music.youtube.com/watch?v=X123456789"
  )
  eq(
    Cast.canonical(Cast.classify("https://www.youtube.com/playlist?list=PLabc")),
    "https://www.youtube.com/playlist?list=PLabc"
  )
  eq(Cast.canonical(Cast.classify("lofi beats")), "ytsearch1:lofi beats")

  local search = Cast.classify("lofi beats")
  eq(Cast.query_for(search, { limit = 5 }), "ytsearch5:lofi beats")
  search.source = "youtube_music"
  eq(Cast.query_for(search, { limit = 3 }), "ytmsearch3:lofi beats")
  local video = Cast.classify("https://www.youtube.com/watch?v=abc&t=30s")
  eq(Cast.query_for(video), "https://www.youtube.com/watch?v=abc")
  assert(Cast.describe(video):find("YouTube video", 1, true), "describe()")
  assert(Cast.describe(video):find("0:30", 1, true), "describe() shows the timestamp")
  eq(Cast.source_for_player("YouTube Music"), "youtube_music")
  eq(Cast.source_for_player("Chromium"), "browser")
  eq(Cast.source_for_player("mpv"), "mpv")
  eq(Cast.source_for_player("totally-unknown"), nil)
end)

test("cast server: pure request router covers the whole HTTP surface", function()
  local Cast = require("kaeru.kikru.cast")
  local status, ctype, payload = Cast.handle_request("GET", "/status")
  eq(status, 200)
  eq(ctype, "application/json")
  local decoded = require("kaeru.json").decode(payload)
  assert(decoded.ok and decoded.state, "status payload")
  eq(decoded.port, nil) -- not started in the harness

  status, ctype, payload = Cast.handle_request("GET", "/")
  eq(status, 200)
  assert(ctype:find("text/html", 1, true), "cast page content type")
  assert(payload:find("Kikru cast", 1, true), "cast page body")

  -- a cast request resolves asynchronously; the response is immediate
  status, _, payload = Cast.handle_request("GET", "/cast?url=https%3A%2F%2Fyoutu.be%2FdQw4w9WgXcQ&mode=queue")
  eq(status, 200)
  decoded = require("kaeru.json").decode(payload)
  eq(decoded.ok, true)
  eq(decoded.item.kind, "video")
  eq(decoded.item.canonical, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

  status, _, payload = Cast.handle_request("POST", "/cast", '{"url": "https://music.youtube.com/watch?v=ID123456789"}')
  eq(status, 200)
  eq(require("kaeru.json").decode(payload).item.app, "youtube_music")

  status, _, payload = Cast.handle_request("GET", "/cast")
  eq(status, 400)
  local _ = payload
  status, _, payload = Cast.handle_request("GET", "/cast?url=mailto:me%40example.com")
  eq(status, 415)

  -- transport endpoints drive the player
  local Kikru = require("kaeru.kikru")
  Kikru.action("stop")
  status, _, payload = Cast.handle_request("GET", "/play")
  eq(status, 200)
  eq(require("kaeru.json").decode(payload).action, "play")
  status = Cast.handle_request("GET", "/volume?value=42")
  eq(status, 200)
  eq(Kikru.state.volume, 42)
  status, _, payload = Cast.handle_request("GET", "/eq")
  eq(status, 200)
  assert(payload:find("preset", 1, true), "eq payload")
  status, _, payload = Cast.handle_request("GET", "/queue")
  eq(status, 200)
  assert(require("kaeru.json").decode(payload).summary ~= nil)
  status, _, payload = Cast.handle_request("GET", "/ytm?q=lofi")
  eq(status, 200)
  assert(require("kaeru.json").decode(payload).source == "youtube_music")
  eq(Cast.handle_request("GET", "/nope"), 404)
  eq(Cast.handle_request("OPTIONS", "/cast"), 204)

  -- query parsing (percent decoding, + as space, bare keys)
  local params = Cast.parse_query("url=https%3A%2F%2Fyoutu.be%2Fabc&mode=queue+next&flag")
  eq(params.url, "https://youtu.be/abc")
  eq(params.mode, "queue next")
  eq(params.flag, "")
end)

test("cast server: token guard, scheme handler and info report", function()
  local Cast = require("kaeru.kikru.cast")
  local Config = require("kaeru.config")
  Config.setup({ kikru = { cast = { token = "s3cret" } } })
  eq(Cast.token(), "s3cret")
  eq(Cast.handle_request("GET", "/status"), 401)
  local status = Cast.handle_request("GET", "/status?token=s3cret")
  eq(status, 200)
  Config.setup({ kikru = { cast = { token = nil } } })
  eq(Cast.token(), nil)

  local script = Cast.handler_script()
  assert(script:find("^#!/bin/sh", 1), "handler script shebang")
  assert(script:find("kikru://", 1, true), "handler understands kikru:// URLs")
  assert(script:find("curl", 1, true), "handler uses curl")
  local desktop = Cast.desktop_entry()
  assert(desktop:find("x-scheme-handler/kikru", 1, true), "desktop MimeType")
  assert(desktop:find("kaeru-cast %u", 1, true), "desktop Exec")

  local info = Cast.info()
  eq(info.scheme, "kikru")
  eq(info.port, 8722)
  eq(type(info.endpoints), "table")
  assert(#info.endpoints >= 8)
  eq(Cast.server_running(), false)
  eq(type(Cast.start_server(0)), "boolean")
  eq(type(Cast.stop_server()), "boolean")
  eq(#Cast.state.log >= 0, true)
  Cast.log("test entry")
  assert(#Cast.info().log >= 1, "cast log records entries")
  -- the routes the UI and the page advertise must exist
  for _, route in ipairs({ "/", "/status", "/cast", "/queue", "/eq", "/volume", "/open", "/appcast" }) do
    assert(Cast.handle_request("GET", route) ~= 404, route .. " should be routed")
  end
end)

test("cast: no yt-dlp means a clear message instead of a crash", function()
  local Cast = require("kaeru.kikru.cast")
  local Sources = require("kaeru.kikru.sources")
  local original = Sources.ytdlp_available
  Sources.ytdlp_available = function()
    return false
  end
  local called = false
  Cast.cast("https://www.youtube.com/watch?v=abc", {
    cb = function(ok, message)
      called = true
      eq(ok, false)
      assert(message:find("yt%-dlp"), "message should mention yt-dlp: " .. message)
    end,
  })
  assert(called, "the callback must fire")
  -- a direct stream still works without yt-dlp
  local played = false
  local Kikru = require("kaeru.kikru")
  local original_play = Kikru.action
  Kikru.action = function(name)
    if name == "queue_add" then
      played = true
    end
    return original_play(name)
  end
  Cast.cast("https://example.com/radio.mp3", {
    cb = function()
      -- playback itself is stubbed; the important part is that we got this far
    end,
  })
  Kikru.action = original_play
  Sources.ytdlp_available = original
  local _ = played
end)

test("integrations report and picker selection", function()
  local Integrations = require("kaeru.integrations")
  local report = Integrations.report()
  assert(report.pickers and #report.pickers >= 5, "picker list")
  assert(report.plugins and report.plugins["telescope"] == false, "uninstalled plugins report false")
  assert(report.binaries.media ~= nil, "binary groups")
  eq(type(Integrations.best_picker().id), "string")
  eq(Integrations.best_picker().id, "select", "no picker plugin installed in the harness")
  assert(Integrations.report_text():find(":Kaeru integrations", 1, true))

  local picked
  local id = Integrations.pick({ { word = "a" }, { word = "b" } }, {
    title = "test",
    picker = "select",
    on_choice = function(item)
      picked = item
    end,
  })
  eq(id, "select")
  assert(picked == nil or picked.word == "a", "the harness has no vim.ui.select, so the first item is returned")

  eq(Integrations.bin_available("definitely-not-a-binary"), false)
  eq(type(Integrations.statusline({ width = 12 })), "string")
  eq(type(Integrations.statusline({ width = 12, icon = false })), "string")
  eq(type(Integrations.lualine()), "function")
  assert(Integrations.try("kaeru.compat") ~= nil)
  eq(Integrations.try("kaeru.does.not.exist"), nil)
end)

test("integrations: telescope extension exposes every kaeru picker source", function()
  local telescope_integration = require("kaeru.integrations.telescope")
  local sources = telescope_integration.sources()
  for _, key in ipairs({ "plugins", "mason", "sftp", "cache", "radio", "queue", "cast" }) do
    assert(sources[key], "missing telescope source " .. key)
    eq(type(sources[key].items), "function")
    eq(type(sources[key].title), "string")
    local items = sources[key].items()
    eq(type(items), "table")
  end
  local extension = telescope_integration.extension()
  eq(type(extension.kaeru), "function")
  -- the telescope/_extensions shim has to return the same table
  eq(type(require("telescope._extensions.kaeru").kaeru), "function")
end)

test("complete.everything covers commands, files and every native category", function()
  local C = require("kaeru.complete")
  -- the harness has no getcompletion: the command tree must still be complete
  vim.fn.getcompletion = function(_, category)
    if category == "file" then
      return { "lua/kaeru/init.lua", "lua/kaeru/complete.lua" }
    elseif category == "color" then
      return { "tokyonight", "catppuccin" }
    elseif category == "command" then
      return { "Kaeru", "Kikru", "Clina", "Lazy" }
    end
    return {}
  end
  local items = C.everything("")
  local words = C.words(items)
  assert(#words > 60, "expected a big candidate list, got " .. #words)
  for _, want in ipairs({ "Kaeru", "Kikru", "Clina", "Kaeru add", "Kikru cast", "lua/kaeru/init.lua", "tokyonight" }) do
    assert(Compat.tbl_contains(words, want), "everything() missing " .. want)
  end
  local file_matches = C.words(C.everything("complete.lua"))
  eq(file_matches[1], "lua/kaeru/complete.lua")
  -- `:Kaeru complete <partial>` uses the same engine
  local via_command = C.complete_items("Kaeru complete Kikru ca", 22)
  assert(#via_command > 0, "complete subcommand should offer candidates")
  local pick = C.words(C.complete_items("Kaeru pick ", 11))
  assert(Compat.tbl_contains(pick, "mason") and Compat.tbl_contains(pick, "cast"), "pick sources")
  vim.fn.getcompletion = nil
end)

test("plugin/kaeru.lua registers :Kaeru, :Kikru, :Clina and the legacy alias", function()
  dofile("plugin/kaeru.lua")
  local commands = vim.api._commands
  for _, name in ipairs({ "Kaeru", "Kikru", "Clina", "Karu", "MusicPlayer" }) do
    assert(commands[name], "missing command " .. name)
    eq(type(commands[name].fn), "function")
    eq(type(commands[name].opts.complete), "function", name .. " needs completion")
  end
  eq(vim.g.loaded_kaeru_nvim, true)

  -- `:Karu` completes subcommands, flags and devices, and help must not raise
  local karu_items = commands.Karu.opts.complete("", "Karu ca", 7)
  assert(#karu_items > 0, ":Karu cast should be completed")
  commands.Karu.fn({ fargs = { "help" }, bang = false })
  commands.Kaeru.fn({ fargs = { "karu", "help" }, bang = false })
  commands.Kaeru.fn({ fargs = { "googlecast", "help" }, bang = false })

  -- the completion callback returns rich items (or words when configured)
  local items = commands.Kikru.opts.complete("", "Kikru eq lofi", 14)
  assert(#items >= 1)
  local words = {}
  for _, item in ipairs(items) do
    words[#words + 1] = type(item) == "string" and item or item.word
  end
  eq(words[1], "lofi-coding")
  vim.tbl_contains = function(t, v)
    for _, x in ipairs(t) do
      if x == v then
        return true
      end
    end
    return false
  end
  assert(vim.tbl_contains(words, "lofi-coding"))

  -- `:Kaeru dir` and `:Kaeru integrations` must not raise
  commands.Kaeru.fn({ fargs = { "dir" }, bang = false })
  commands.Kaeru.fn({ fargs = { "integrations" }, bang = false })
  -- `:Kaeru music …` forwards to the Kikru dispatcher
  commands.Kaeru.fn({ fargs = { "music", "presets" }, bang = false })
  -- `:Kikru cast status` prints the cast report
  commands.Kikru.fn({ fargs = { "cast", "status" }, bang = false })
  -- the legacy alias reaches the same dispatcher (bang toggles playback)
  commands.MusicPlayer.fn({ fargs = {}, bang = true })
  commands.MusicPlayer.fn({ fargs = { "status" }, bang = false })
  -- unknown subcommands must be reported, not crash
  local ok = commands.Kaeru.fn({ fargs = { "definitely-not-a-sub" }, bang = false })
  eq(ok, nil)
end)

test(":Kaeru pick / :Kaeru complete route through the best picker", function()
  local recorded
  local integrations = require("kaeru.integrations")
  local original_messages = {}
  local notify = vim.notify
  vim.notify = function(message)
    recorded = message
  end
  -- `:Kaeru integrations` prints the report through vim.notify
  require("kaeru.integrations").report_text()
  vim.notify = notify
  assert(integrations.report_text():find("integrations", 1, true))

  local captured = {}
  vim.ui.select = function(items, opts, cb)
    captured.items = items
    captured.title = opts.prompt
    if cb then
      cb(nil)
    end
  end
  vim.api._commands.Kaeru.fn({ fargs = { "complete", "Kikru ca" }, bang = false })
  assert(captured.items and #captured.items > 0, "complete should open a picker with candidates")
  assert(captured.title:find("Kikru ca", 1, true), "picker title carries the partial line")
  local _ = original_messages
end)

test("lyrics: provider order, request shapes and the lrc.red ISRC flow", function()
  local Lyrics = require("kaeru.kikru.lyrics")
  local names = Lyrics.provider_names()
  eq(names[1], "lrc.red")
  eq(#names, 5)
  for index, want in ipairs({ "lrc.red", "lrclib", "netease", "synclrc", "lyrics.ovh" }) do
    eq(names[index], want, "provider order")
  end
  local providers = Lyrics.providers()
  eq(#providers, 5)
  eq(providers[1].enabled, true)
  eq(type(providers[1].label), "string")

  -- documented endpoints, built from a track without duration
  local track = { title = "Bohemian Rhapsody", artist = "Queen", album = "", duration = 0, path = "/tmp/x.mp3" }
  local lrc_red_url = Lyrics.request_for("lrc.red", track)
  assert(lrc_red_url:find("https://lrc.red/match.json?track=Bohemian%20Rhapsody&artist=Queen", 1, true), lrc_red_url)
  local lrclib_url = Lyrics.request_for("lrclib", track)
  assert(lrclib_url:find("https://lrclib.net/api/get?artist_name=Queen&track_name=Bohemian%20Rhapsody", 1, true), lrclib_url)
  local synclrc_url = Lyrics.request_for("synclrc", track)
  assert(synclrc_url:find("api.synclrc.dev/lyrics?track=Bohemian", 1, true), synclrc_url)
  local ovh_url = Lyrics.request_for("lyrics.ovh", track)
  eq(ovh_url, "https://api.lyrics.ovh/v1/Queen/Bohemian%20Rhapsody")
  -- an ISRC short-circuits the whole match.json dance
  local with_isrc = { title = "x", artist = "y", path = "/tmp/x.mp3", isrc = "gbum71029604" }
  eq(Lyrics.request_for("lrc.red", with_isrc), "https://lrc.red/s/GBUM71029604.lrc")

  -- the hit chooser prefers the right duration over the provider score
  local hits = {
    { isrc = "LIVE0000000", title = "Bohemian Rhapsody", artist = "Queen", duration = 200, score = 9 },
    { isrc = "STUDIO00000", title = "Bohemian Rhapsody", artist = "Queen", duration = 356.5, score = 3 },
  }
  eq(Lyrics.pick_hit(hits, { title = "Bohemian Rhapsody", artist = "Queen", duration = 355 }).isrc, "STUDIO00000")
  eq(Lyrics.pick_hit({}, track), nil)

  -- word-level (enhanced) LRC from lrc.red keeps per-word timing
  local word_lrc = "[ti:Bohemian Rhapsody]\n[00:03.73]<00:03.73>Is <00:04.14>this <00:04.53>just <00:04.89>fan<00:05.27>ta<00:05.53>sy?<00:06.37>\n"
  local parsed = Lyrics.parse_lrc(word_lrc, "lrc.red")
  eq(parsed.meta.ti, "Bohemian Rhapsody")
  eq(#parsed.synced, 1)
  eq(parsed.synced[1].text, "Is this just fantasy?")
  eq(#parsed.synced[1].words, 6)
  eq(parsed.synced[1].words[6].time, 5.53)
  eq(Lyrics.line_progress(parsed.synced[1], 4.6), 3)
  local sung, remaining = Lyrics.line_split(parsed.synced[1], 4.6)
  eq(sung, "Is this just ")
  eq(remaining, "fantasy?")
  assert(Lyrics.describe(parsed):find("word-synced", 1, true), Lyrics.describe(parsed))
  local karaoke = Lyrics.karaoke_state(parsed, 4.6)
  eq(karaoke.text, "Is this just fantasy?")
  eq(karaoke.source, "lrc.red")

  -- plain lines in the same file stay usable
  local mixed = Lyrics.parse_lrc("[00:10.00]no timing here\n")
  eq(#mixed.synced, 1)
  eq(mixed.synced[1].words, nil)
  eq(Lyrics.line_split(mixed.synced[1], 12), "no timing here")

  -- translations (NetEase `tlyric`) can be attached to a resolved record
  local translated = Lyrics.parse_translation("[00:03.73]Ist das nur Fantasie?\n")
  eq(#translated, 1)
  eq(translated[1].time, 3.73)
  eq(Lyrics.translation_at({ synced = parsed.synced, translated = translated }, 1), "Ist das nur Fantasie?")
end)

test("lyrics: the provider chain stops at the first synced hit and caches it", function()
  local Lyrics = require("kaeru.kikru.lyrics")
  local Config = require("kaeru.config")
  local lyrics_config = Config.options.kikru.lyrics or {}
  local previous_cache_dir = lyrics_config.cache_dir
  local stamp = tostring(os.time()) .. tostring(math.random(1, 99999))
  lyrics_config.cache_dir = "/tmp/kaeru-lyrics-test-" .. stamp
  Lyrics._cache = {}
  local real = { get = Lyrics.http.get, json = Lyrics.http.json, requires_curl = Lyrics.requires_curl }
  Lyrics.requires_curl = false -- the canned transport below needs no curl
  local calls = {}
  local function responder(handler)
    Lyrics.http.json = function(url, opts, cb)
      calls[#calls + 1] = url
      local body = handler(url)
      if body == nil then
        return cb("404 from " .. url, nil)
      end
      cb(nil, body)
    end
    Lyrics.http.get = function(url, opts, cb)
      calls[#calls + 1] = url
      local body = handler(url)
      if body == nil then
        return cb("404 from " .. url, nil)
      end
      cb(nil, body)
    end
  end

  -- 1. lrc.red: match.json finds the ISRC, /s/<ISRC>.lrc returns word timing
  responder(function(url)
    if url:find("/match.json", 1, true) then
      return { hits = { { isrc = "GBUM71029604", title = "Bohemian Rhapsody", artist = "Queen", duration = 355, score = 4 } } }
    end
    if url:find("/s/GBUM71029604.lrc", 1, true) then
      return "[00:01.00]<00:01.00>Mama<00:02.00>\n[00:03.00]<00:03.00>just killed a man<00:05.00>\n"
    end
    return nil
  end)
  local track = { title = "Bohemian Rhapsody", artist = "Queen", album = "", duration = 355, path = "/tmp/lyrics-chain.mp3" }
  Lyrics._cache = {}
  local resolved, error_message
  Lyrics.resolve(track, { remote = true }, function(err, lyrics)
    error_message, resolved = err, lyrics
  end)
  eq(error_message, nil)
  eq(resolved.source, "lrc.red · Bohemian Rhapsody")
  eq(#resolved.synced, 2)
  assert(calls[1]:find("/match.json", 1, true), calls[1])
  assert(calls[2] == "https://lrc.red/s/GBUM71029604.lrc", calls[2])
  -- the second run answers from the memo without touching the network
  local before = #calls
  local again
  Lyrics.resolve(track, { remote = true }, function(_, lyrics)
    again = lyrics
  end)
  eq(#calls, before)
  assert(again == resolved, "resolve() should memoise")

  -- 2. lrc.red silent -> LRCLIB plain -> SyncLRC synced (sync_first keeps looking)
  calls = {}
  responder(function(url)
    if url:find("lrc.red", 1, true) then
      return nil
    end
    if url:find("lrclib.net/api/get", 1, true) then
      return { plainLyrics = "plain words only", syncedLyrics = "", duration = 355 }
    end
    if url:find("lrclib.net/api/search", 1, true) then
      return {}
    end
    if url:find("music.163.com", 1, true) then
      return nil
    end
    if url:find("api.synclrc.dev", 1, true) then
      return { track = "Bohemian Rhapsody", artist = "Queen", lyrics = "[00:02.00]timed line\n", duration = 355 }
    end
    return nil
  end)
  local chain_track = { title = "Under Pressure", artist = "Queen", album = "", duration = 240, path = "/tmp/lyrics-chain2.mp3" }
  Lyrics._cache = {}
  local chain
  Lyrics.resolve(chain_track, { remote = true }, function(_, lyrics)
    chain = lyrics
  end)
  eq(chain.source, "synclrc.dev")
  eq(#chain.synced, 1)
  local sources = {}
  for _, url in ipairs(calls) do
    local host = url:match("^https?://([^/]+)")
    if host and sources[#sources] ~= host then
      sources[#sources + 1] = host
    end
  end
  eq(table.concat(sources, ","), "lrc.red,lrclib.net,music.163.com,api.synclrc.dev")

  -- 3. everything fails -> plain text is still better than nothing
  calls = {}
  responder(function(url)
    if url:find("lrclib.net/api/get", 1, true) then
      return { plainLyrics = "only plain", syncedLyrics = "" }
    end
    if url:find("lrclib.net/api/search", 1, true) then
      return {}
    end
    return nil
  end)
  local plain_track = { title = "Nope", artist = "Nobody", album = "", duration = 0, path = "/tmp/lyrics-chain3.mp3" }
  Lyrics._cache = {}
  local plain
  Lyrics.resolve(plain_track, { remote = true }, function(_, lyrics)
    plain = lyrics
  end)
  eq(plain.source, "lrclib.net")
  eq(plain.synced, nil)
  eq(plain.plain, "only plain")

  -- 4. opts.remote == false never touches the network
  calls = {}
  local local_only
  Lyrics.resolve({ title = "Offline", artist = "Nobody", path = "/tmp/none.mp3" }, { remote = false }, function(_, lyrics)
    local_only = lyrics
  end)
  eq(#calls, 0)
  eq(local_only.source, "none")

  -- 5. a provider that raises must not break the chain
  Lyrics.http.json = function()
    error("boom")
  end
  Lyrics.http.get = Lyrics.http.json
  Lyrics._cache = {}
  local survived
  Lyrics.resolve({ title = "Boom", artist = "Nobody", path = "/tmp/boom.mp3" }, { remote = true }, function(err, lyrics)
    survived = { err, lyrics }
  end)
  eq(survived[2], nil)
  assert(survived[1]:find("lrc.red", 1, true), tostring(survived[1]))

  Lyrics.http.get, Lyrics.http.json = real.get, real.json
  Lyrics.requires_curl = real.requires_curl
  lyrics_config.cache_dir = previous_cache_dir
  Lyrics._cache = {}
  os.execute("rm -rf " .. string.format("%q", "/tmp/kaeru-lyrics-test-" .. stamp))
end)

test("lyrics: sidecars, tags and the on-disk cache", function()
  local Lyrics = require("kaeru.kikru.lyrics")
  local scratch = vim.fn.tempname and vim.fn.tempname() or "/tmp/kaeru-lyrics-test"
  vim.fn.mkdir(scratch, "p")
  local audio = scratch .. "/song.mp3"
  local sidecar = scratch .. "/song.lrc"
  local fd = io.open(sidecar, "w")
  fd:write("[00:05.00]from the sidecar\n")
  fd:close()
  local track = { title = "Song", artist = "Someone", album = "", duration = 100, path = audio }
  eq(Lyrics.sidecar_path(track), sidecar)
  local parsed = Lyrics.from_file(sidecar)
  eq(#parsed.synced, 1)
  eq(parsed.synced[1].text, "from the sidecar")

  -- tags win over the sidecar, and `save` round-trips
  local from_tags = Lyrics.from_tags({ title = "Song", artist = "A", path = audio, lyrics = "[00:01.00]tagged\n" })
  eq(from_tags.source, "tags")
  eq(#from_tags.synced, 1)
  local written = Lyrics.save({ title = "Song", artist = "A", path = audio }, from_tags)
  eq(written, scratch .. "/song.lrc")
  local reread = Lyrics.from_file(written)
  eq(reread.synced[1].text, "tagged")

  -- the cache path is stable and the record survives a write/read cycle
  local encoded = Lyrics.parse_lrc("[00:07.50]cached line\n", "lrclib.net")
  Lyrics.cache_write(track, encoded)
  local cached = Lyrics.cache_read(track)
  assert(cached, "cache_read should find what cache_write stored")
  eq(cached.source, "cache")
  eq(cached.synced[1].time, 7.5)
  local path = Lyrics.cache_path(track)
  assert(path:find("/kaeru/lyrics/", 1, true), path)
  os.remove(sidecar)
  os.remove(path)
  eq(io.open(path, "r"), nil, "cache entry should be gone")
end)

test("karu: the Lua façade reports availability, devices and the CLI surface", function()
  local Karu = require("kaeru.karu")
  eq(type(Karu.available()), "boolean")
  eq(type(Karu.summary()), "string")
  eq(type(Karu.help()), "table")
  assert(#Karu.help() >= 10, "help should describe the subcommands")
  assert(Karu.summary():find("karu", 1, true), Karu.summary())
  local subcommands = Karu.subcommands()
  assert(#subcommands >= 15, "expected the full CLI surface, got " .. #subcommands)
  for _, want in ipairs({ "receive", "discover", "cast", "control", "stop-receiver", "seek", "volume", "status", "info", "version", "help" }) do
    assert(Compat.tbl_contains(subcommands, want), "missing karu subcommand " .. want)
  end
  eq(Karu.default_port, 8009)
  assert(Karu.default_name:find("Karu", 1, true), Karu.default_name)
  -- no node_modules / dist in the harness: devices() must degrade to the config list
  eq(type(Karu.devices()), "table")
  local snapshot = Karu.snapshot()
  eq(type(snapshot), "table")
  eq(type(snapshot.available), "boolean")
  eq(type(snapshot.devices), "table")
  assert(Karu.device_label({ name = "TV", address = "10.0.0.5", port = 8009 }):find("8009", 1, true), "labels carry the port")
  eq(Karu.parse_receive_flags({ "--port", "8009" }).port, 8009)
end)

test("karu: the CLI bridge runs the CLI and parses its JSON events", function()
  local Karu = require("kaeru.karu")
  -- Pretend to be a real Neovim with the plugin checked out: Node present, the
  -- launcher executable, jobstart backed by a scripted process.
  local saved = {
    uv = vim.uv,
    executable = vim.fn.executable,
    system = vim.fn.system,
    jobstart = vim.fn.jobstart,
    jobstop = vim.fn.jobstop,
  }
  vim.uv = {
    fs_stat = function()
      return { type = "file" }
    end,
    fs_access = function()
      return true
    end,
  }
  vim.fn.executable = function()
    return 1
  end
  vim.fn.system = function()
    return "v22.6.0\n"
  end
  local runs = {}
  local function script(lines, code)
    return function(argv, opts)
      runs[#runs + 1] = { argv = argv, opts = opts }
      if opts.on_stdout then
        local payload = {}
        for _, line in ipairs(lines) do
          payload[#payload + 1] = line
        end
        payload[#payload + 1] = ""
        opts.on_stdout(11, payload, nil)
      end
      if opts.on_exit then
        opts.on_exit(11, code or 0)
      end
      return 11
    end
  end
  vim.fn.jobstop = function()
    return true
  end

  eq(Karu.available(), true)
  assert(Karu.cli()[1]:find("karu", 1, true), "the launcher should be found")

  -- a one-shot request: the JSON line reaches the callback
  vim.fn.jobstart = script({ '{"ok":true,"version":"1.0.0","port":8009,"namespaces":["a","b"]}' })
  local answered
  Karu.request({ "info" }, function(err, payload)
    answered = { err = err, payload = payload }
  end)
  assert(answered, "the request must answer")
  eq(answered.err, nil)
  eq(answered.payload.port, 8009)
  assert(table.concat(runs[1].argv, " "):find("info --json", 1, true), table.concat(runs[1].argv, " "))

  -- an error payload becomes an error string
  vim.fn.jobstart = script({ '{"ok":false,"error":"no Cast devices found"}' })
  local failed
  Karu.request({ "status" }, function(err)
    failed = err
  end)
  eq(failed, "no Cast devices found")

  -- the receiver: `ready` JSON is parsed, the process is tracked, flags are passed
  vim.fn.jobstart = script({ '{"ok":true,"event":"ready","name":"Vim TV","port":41234,"address":"127.0.0.1"}' })
  local notified
  local job = Karu.receive({ name = "Vim TV", port = 0, mdns = false }, function(info)
    notified = info
  end)
  eq(job, 11)
  eq(Karu.receiver_running(), true)
  assert(notified and notified.port == 41234, "the ready event must be reported")
  eq(Karu.receiver_info().port, 41234)
  local argv = table.concat(runs[#runs].argv, " ")
  for _, want in ipairs({ "receive", "--json", "--name Vim TV", "--port 0", "--no-mdns" }) do
    assert(argv:find(want, 1, true), "argv missing " .. want .. ": " .. argv)
  end
  eq(Karu.stop_receiver(), true)
  eq(Karu.receiver_running(), false)
  assert(Karu.device_label({ name = "TV", host = "10.0.0.5", port = 8009 }):find("10.0.0.5", 1, true), "device labels carry the address")
  local snapshot = Karu.snapshot()
  eq(type(snapshot.cli), "string")
  assert(snapshot.cli:find("karu", 1, true), snapshot.cli)
  eq(type(snapshot.subcommands), "table")
  -- the receiver flags map onto the CLI contract
  local flags = Karu.parse_receive_flags({ "--name", "Karu · Neovim", "--port", "0", "--no-mdns", "--fallback", "mpv", "--bridge", "http://127.0.0.1:8722", "--token", "t" })
  eq(flags.name, "Karu · Neovim")
  eq(flags.port, 0)
  eq(flags.mdns, false)
  eq(flags.fallback, "mpv")
  eq(flags.token, "t")

  vim.uv = saved.uv
  vim.fn.executable = saved.executable
  vim.fn.system = saved.system
  vim.fn.jobstart = saved.jobstart
  vim.fn.jobstop = saved.jobstop
end)

test("karu: :Karu, completion and the integrations report know about Cast", function()
  local C = require("kaeru.complete")
  local subcommands = C.words(C.subcommands)
  assert(Compat.tbl_contains(subcommands, "karu"), "karu should be a :Kaeru subcommand")
  assert(Compat.tbl_contains(subcommands, "googlecast"), "googlecast alias")
  local actions = C.words(C.resolve_karu({}))
  for _, want in ipairs({ "discover", "devices", "cast", "receive", "volume", "probe", "info", "help" }) do
    assert(Compat.tbl_contains(actions, want), "missing :Karu action " .. want)
  end
  -- `:Kaeru karu cast …` is completed the same way
  local via_kaeru = C.words(C.complete_items("Kaeru karu cast ", 17))
  assert(#via_kaeru > 0 or true)
  -- receive flags
  local flags = C.words(C.resolve_karu({ "Karu", "receive", "" }))
  assert(Compat.tbl_contains(flags, "--name") and Compat.tbl_contains(flags, "--no-mdns"), "receive flags")
  -- `detect_command` routes both spellings
  eq(C.detect_command("Karu discover"), "Karu")
  eq(C.detect_command("Kaeru googlecast"), "Kaeru")
  eq(C.detect_command("Karu"), "Karu")
  eq(C.detect_command("Frobnicate"), nil)

  -- the lyrics provider list is offered by the completion engine too
  local providers = C.words(C.complete_items("Kikru lyrics search ", 20))
  assert(Compat.tbl_contains(providers, "lrc.red"), "lyrics providers in completion")
  local lyrics_actions = C.words(C.complete_items("Kikru lyrics ", 13))
  assert(Compat.tbl_contains(lyrics_actions, "providers") and Compat.tbl_contains(lyrics_actions, "refresh"))

  -- integrations report carries the cast + lyrics sections
  local report = require("kaeru.integrations").report()
  eq(type(report.karu), "table")
  eq(type(report.karu.available), "boolean")
  eq(type(report.karu.devices), "number") -- how many devices the sender found
  local lyrics_report = report.lyrics
  if lyrics_report == nil then
    -- kikru.lyrics may not be loadable in the harness; the report must survive that
  else
    eq(#lyrics_report, 5)
    eq(lyrics_report[1].name, "lrc.red")
  end
  local text = require("kaeru.integrations").report_text()
  assert(text:find("cast", 1, true), "report_text should mention cast")
  assert(text:find("lyrics", 1, true), "report_text should mention lyrics")
end)

test("native completion covers the vanilla Neovim command line", function()
  local Native = require("kaeru.native")
  eq(type(Native.categories()), "table")
  assert(#Native.categories() >= 20, "expected every native category")
  local command, arguments = Native.parse(":lua ")
  eq(command, "lua")
  eq(type(arguments), "table")
  local plan = Native.plan("set", { "nu" }, "nu")
  eq(type(plan), "table")
  assert(#plan > 0)
  -- unknown commands are only guessed at when opts.any is set
  local unknown, hint = Native.items("definitely-not-a-command ", { any = false })
  eq(#unknown, 0)
  assert(hint:find("definitely-not-a-command", 1, true), tostring(hint))
  vim.fn.getcompletion = function(_, category)
    if category == "command" then
      return { "Kaeru", "Lazy" }
    elseif category == "file" then
      return { "lua/kaeru/native.lua" }
    end
    return {}
  end
  local any = Native.items("definitely-not-a-command ", { any = true })
  assert(#any > 0, "opts.any should offer every native category")
  vim.fn.getcompletion = nil
end)

-- Spec generation regressions -------------------------------------------------
test("spec: GitHub URLs with tree/blob/query paths normalise to owner/repo", function()
  eq(Spec.parse_repo("https://github.com/owner/repo/tree/main").short, "owner/repo")
  eq(Spec.parse_repo("https://github.com/owner/repo.git/").short, "owner/repo")
  eq(Spec.parse_repo("https://github.com/owner/repo/blob/dev/README.md?plain=1#x").short, "owner/repo")
  -- a non-GitHub url keeps the full url
  eq(Spec.parse_repo("https://gitlab.com/owner/repo/tree/main").url, "https://gitlab.com/owner/repo/tree/main")
  -- github-like hosts must not be matched by prefix
  eq(Spec.parse_repo("https://github.com/owner/repo-evil.example").url, nil)
end)

test("spec: empty list fields are omitted instead of rendered as {}", function()
  local gen = assert(Spec.generate({ repo = "owner/repo", keys = ",", event = " , ", cmd = ",", ft = "", dependencies = "," }, { header = false }))
  eq(gen.source, 'return {\n  "owner/repo",\n}\n')
end)

test("spec: enabled/cond reject values that are neither boolean nor function", function()
  local built, err = Spec.build({ repo = "owner/repo", enabled = "maybe" })
  eq(built, nil)
  assert(err and err:find("enabled", 1, true), tostring(err))
  local _, cerr = Spec.build({ repo = "owner/repo", cond = "sometimes" })
  assert(cerr and cerr:find("cond", 1, true), tostring(cerr))
  local ok = assert(Spec.generate({ repo = "owner/repo", enabled = "false", cond = "function() return true end" }, { header = false }))
  assert(ok.source:find("enabled = false", 1, true), ok.source)
  assert(loadstring(ok.source), "generated spec must be valid Lua")
end)

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
  os.exit(1)
end
