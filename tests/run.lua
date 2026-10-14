-- Minimal test runner for the pure-Lua parts of installer.nvim.
-- Runs under `nvim -l`, `luajit` or `lua5.1` (a tiny `vim` stub is installed when needed).
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

if not vim then
  -- stub just enough of the vim API for spec.lua / github.lua / config.lua
  vim = {
    env = {},
    fn = { executable = function()
      return 0
    end },
    log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } },
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

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
  os.exit(1)
end
