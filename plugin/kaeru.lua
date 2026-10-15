if vim.g.loaded_kaeru_nvim then
  return
end
vim.g.loaded_kaeru_nvim = true

-- ASCII welcome screen on startup (see `welcome` in setup()).
require("kaeru.welcome").attach()

if vim.fn.has("nvim-0.8") ~= 1 then
  vim.notify("kaeru.nvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

local Complete = require("kaeru.complete")
local Compat = require("kaeru.compat")
local mason_actions = Complete.words(Complete.mason_actions)
local mason_scaffolds = Complete.mason_scaffolds
local sftp_actions = Complete.words(Complete.sftp_actions)
local cache_actions = Complete.words(Complete.cache_actions)
local config_actions = Complete.words(Complete.config_actions)
local starsky_actions = Complete.words(Complete.starsky_actions)

--- Completion callback shared by every user command: rich items (word + menu +
--- info) when the editor can show them, plain words otherwise.
---@param cmdline string
---@param cursorpos integer
---@return table
local function complete(cmdline, cursorpos)
  local items = Complete.complete_items(cmdline, cursorpos)
  local Config = require("kaeru.config")
  if (Config.options.complete or {}).items == "word" then
    return Complete.words(items)
  end
  return items
end

vim.api.nvim_create_user_command("Kaeru", function(cmd)
  local kaeru = require("kaeru")
  kaeru.ensure_setup()
  local args = cmd.fargs
  local sub = args[1]

  if sub == nil or sub == "modal" then
    kaeru.open(args[2] and { repo = args[2] } or nil)
  elseif sub == "browse" then
    kaeru.browse({ query = table.concat(args, " ", 2) })
  elseif sub == "search" then
    kaeru.search(table.concat(args, " ", 2))
  elseif sub == "add" then
    if not args[2] then
      vim.notify(":Kaeru add requires owner/repo", vim.log.levels.ERROR, { title = "kaeru.nvim" })
      return
    end
    kaeru.add({ repo = args[2] }, { force = cmd.bang })
  elseif sub == "save" then
    if not args[2] then
      vim.notify(":Kaeru save requires owner/repo", vim.log.levels.ERROR, { title = "kaeru.nvim" })
      return
    end
    kaeru.save({ repo = args[2] }, { force = cmd.bang })
  elseif sub == "pick" then
    local source = args[2]
    require("kaeru.integrations.telescope").open(source)
  elseif sub == "integrations" then
    vim.notify(require("kaeru.integrations").report_text(), vim.log.levels.INFO, { title = "kaeru.nvim" })
  elseif sub == "complete" then
    local partial = table.concat(Compat.list_slice(args, 2), " ")
    local complete = require("kaeru.complete")
    local items = complete.everything(partial)
    if #items == 0 then
      vim.notify("Nothing matches " .. tostring(partial), vim.log.levels.WARN, { title = "kaeru.nvim" })
      return
    end
    require("kaeru.integrations").pick(items, {
      title = ":Kaeru complete " .. partial,
      on_choice = function(item)
        if not item then
          return
        end
        vim.schedule(function()
          vim.cmd(item.word)
        end)
      end,
    })
  elseif sub == "music" or sub == "kikru" or sub == "player" then
    require("kaeru.kikru").dispatch(Compat.list_slice(args, 2))
    return
  elseif sub == "karu" or sub == "googlecast" then
    require("kaeru.karu").dispatch(Compat.list_slice(args, 2), { bang = cmd.bang })
  elseif sub == "cast" then
    require("kaeru.kikru").dispatch(vim.list_extend({ "cast" }, Compat.list_slice(args, 2)))
  elseif sub == "boot" then
    require("kaeru.boot").play()
  elseif sub == "parse" or sub == "readme" then
    local target = table.concat(args, " ", 2)
    require("kaeru.parser").command(target, {
      bang = cmd.bang,
      range = cmd.range and cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil,
    })
  elseif sub == "dir" then
    vim.notify("Spec files are written to " .. kaeru.plugins_dir(), vim.log.levels.INFO, { title = "kaeru.nvim" })
  elseif sub == "ai" then
    local ai = require("kaeru.ai")
    if args[2] then
      local preset = ai.get(args[2])
      if not preset then
        return vim.notify("Unknown AI preset: " .. args[2], vim.log.levels.ERROR, { title = "kaeru.nvim" })
      end
      if not ai.enabled() then
        return ai.pick() -- shows the "disabled" notice
      end
      if cmd.bang then
        ai.install_preset(preset)
      else
        ai.open_preset(preset)
      end
    else
      ai.pick()
    end
  elseif sub == "login" then
    require("kaeru.account").login(args[2])
  elseif sub == "logout" then
    require("kaeru.account").logout()
  elseif sub == "whoami" then
    require("kaeru.account").whoami()
  elseif sub == "sftp" then
    local sftp = require("kaeru.sftp")
    local action = args[2] or "ui"
    local rest = Compat.list_slice(args, 3)
    local raw = table.concat(rest, " ")
    local actions = {
      ui = function()
        sftp.ui(rest[1])
      end,
      upload = function()
        if rest[1] then
          sftp.upload_path(rest[1])
        else
          sftp.upload_current()
        end
      end,
      ["upload-project"] = sftp.upload_project,
      sync = sftp.sync,
      download = sftp.download_current,
      ["download-project"] = sftp.download_all,
      init = sftp.init,
      status = sftp.status,
      select = sftp.choose,
      browse = function()
        sftp.browse(rest[1])
      end,
      diff = sftp.diff,
      test = sftp.test,
      shell = function()
        sftp.shell("sftp")
      end,
      ssh = function()
        sftp.shell("ssh")
      end,
      run = function()
        sftp.run(raw)
      end,
      exec = function()
        sftp.exec(raw)
      end,
    }
    if actions[action] then
      actions[action]()
    elseif sftp.commands[action] then
      sftp.command(action, rest)
    else
      vim.notify("Unknown sftp action: " .. action .. "\nUse: " .. table.concat(sftp_actions, ", "), vim.log.levels.ERROR, { title = "kaeru.nvim" })
    end
  elseif sub == "cache" then
    local cache = require("kaeru.cache")
    local action = args[2] or "list"
    local name = args[3]
    local function notify(ok, msg)
      vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "kaeru.nvim" })
    end
    if action == "list" then
      cache.list()
    elseif action == "dir" then
      notify(true, "Cache directory: " .. cache.dir())
    elseif action == "clean" then
      cache.clean()
    elseif action == "pack" then
      if not name or name == "all" then
        cache.pack_all()
      else
        cache.pack(name, notify, { force = cmd.bang })
      end
    elseif action == "restore" then
      if not name then
        return notify(false, "Usage: :Kaeru cache restore <plugin>")
      end
      cache.restore(name, notify, { force = cmd.bang })
    elseif action == "remove" then
      if not name then
        return notify(false, "Usage: :Kaeru cache remove <plugin>")
      end
      cache.remove(name)
    else
      notify(false, "Unknown cache action: " .. action .. "\nUse: " .. table.concat(cache_actions, ", "))
    end
  elseif sub == "mason" then
    local mason = require("kaeru.mason")
    local function notify(ok, msg)
      vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "kaeru.nvim" })
    end
    local action = args[2] or "pick"
    local rest = Compat.list_slice(args, 3)
    if action == "registry" then
      local url = "https://mason-registry.dev/registry/list"
      if vim.ui and vim.ui.open then
        vim.ui.open(url)
      end
      return notify(true, "Opened " .. url .. " (601 Mason packages built-in)")
    end
    if action ~= "scaffold" and action ~= "pick" and action ~= "list" and action ~= "ft" and not mason.available() then
      return notify(false, "mason.nvim is not installed. Run `:Kaeru mason scaffold lsp` to add it to your lazy.nvim specs.")
    end
    local category_map = { lsp = "LSP", dap = "DAP", linter = "Linter", formatter = "Formatter", compiler = "Compiler", runtime = "Runtime" }
    if action == "pick" then
      mason.pick({ query = table.concat(rest, " ") })
    elseif category_map[action] then
      mason.pick({ category = category_map[action], query = table.concat(rest, " ") })
    elseif action == "install" then
      if #rest == 0 then
        return notify(false, "Usage: :Kaeru mason install <package> [<package>...]")
      end
      mason.install_many(rest, notify)
    elseif action == "uninstall" then
      if #rest == 0 then
        return notify(false, "Usage: :Kaeru mason uninstall <package>")
      end
      for _, name in ipairs(rest) do
        mason.uninstall(name, notify)
      end
    elseif action == "update" then
      if #rest == 0 then
        return notify(false, "Usage: :Kaeru mason update <package>")
      end
      for _, name in ipairs(rest) do
        mason.update(name)
      end
    elseif action == "upgrade" then
      mason.upgrade()
    elseif action == "ensure" then
      mason.ensure()
    elseif action == "export" then
      mason.export()
    elseif action == "list" then
      mason.list()
    elseif action == "ft" then
      mason.for_filetype()
    elseif action == "ui" then
      vim.cmd("Mason")
    elseif action == "scaffold" then
      local kind = rest[1] or "lsp"
      if not Compat.tbl_contains(mason_scaffolds, kind) then
        return notify(false, "Usage: :Kaeru mason scaffold " .. table.concat(mason_scaffolds, "|"))
      end
      mason.scaffold(kind)
    elseif not mason.resolve(action) then
      notify(false, "Unknown mason action: " .. action .. "\nUse: " .. table.concat(mason_actions, ", "))
    else
      -- `:Kaeru mason <package>` is a shortcut for install.
      mason.install_many({ action, unpack(rest) }, notify)
    end
  elseif sub == "config" then
    local Config = require("kaeru.config")
    local action = args[2] or "edit"
    if action == "edit" then
      Config.edit()
    elseif action == "project" then
      Config.edit(vim.fn.getcwd() .. "/" .. Config.options.config.project)
    elseif action == "reload" then
      kaeru.reload()
    elseif action == "show" or action == "dump" then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(Config.dump(), "\n", { plain = true }))
      vim.bo[buf].filetype = "yaml"
      vim.bo[buf].bufhidden = "wipe"
      vim.api.nvim_buf_set_name(buf, "kaeru://config")
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, buf)
    else
      vim.notify("Unknown config action: " .. action .. "\nUse: " .. table.concat(config_actions, ", "), vim.log.levels.ERROR, { title = "kaeru.nvim" })
    end
  elseif sub == "cve" then
    require("kaeru.cve").command({ unpack(args, 2) })
  elseif sub == "starsky" or sub == "web" then
    local starsky = require("kaeru.starsky")
    local action = args[2] or "start"
    if action == "start" then
      starsky.start({ open = not cmd.bang })
    elseif action == "stop" then
      starsky.stop()
    elseif action == "open" then
      starsky.open_browser()
    elseif action == "status" then
      starsky.status()
    elseif action == "build" then
      starsky.build()
    elseif action == "info" then
      starsky.info()
    else
      vim.notify("Unknown starsky action: " .. action .. "\nUse: " .. table.concat(starsky_actions, ", "), vim.log.levels.ERROR, { title = "kaeru.nvim" })
    end
  elseif sub:find("/", 1, true) or sub:find("://", 1, true) then
    -- `:Kaeru folke/noice.nvim` opens the modal prefilled
    kaeru.open({ repo = sub })
  else
    vim.notify("Unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "kaeru.nvim" })
  end
end, {
  nargs = "*",
  bang = true,
  range = true,
  desc = "kaeru.nvim: add plugins to lazy.nvim",
  complete = function(_, cmdline, cursorpos)
    return complete(cmdline, cursorpos)
  end,
})

vim.api.nvim_create_user_command("Karu", function(cmd)
  local args = cmd.fargs
  local karu = require("kaeru.karu")
  karu.dispatch(args, { bang = cmd.bang })
end, {
  nargs = "*",
  bang = true,
  desc = "Google Cast: receive casts in Neovim (bridged to Kikru) and cast to real Chromecast devices",
  complete = function(arglead, cmdline, cursorpos)
    return require("kaeru.complete").complete_items(cmdline, cursorpos)
  end,
})

vim.api.nvim_create_user_command("Kikru", function(cmd)
  local kaeru = require("kaeru")
  kaeru.ensure_setup()
  local music = require("kaeru.kikru")
  if cmd.bang and #cmd.fargs == 0 then
    music.action("toggle")
    return
  end
  music.dispatch(cmd.fargs)
end, {
  nargs = "*",
  bang = true,
  desc = ":Kikru — Built-in Kikru Player with 10-band EQ, Visualizer, Radio & 2-Neovim Device Controller",
  complete = function(_, cmdline, cursorpos)
    return complete(cmdline, cursorpos)
  end,
})

--- Legacy `:MusicPlayer` alias (kaeru.nvim ≥2 calls the player `:Kikru`).
vim.api.nvim_create_user_command("MusicPlayer", function(cmd)
  local kaeru = require("kaeru")
  kaeru.ensure_setup()
  local kikru = require("kaeru.kikru")
  if cmd.bang and #cmd.fargs == 0 then
    kikru.action("toggle")
    return
  end
  kikru.dispatch(cmd.fargs)
end, {
  nargs = "*",
  bang = true,
  desc = "Kikru (alias of :Kikru, deprecated)",
  complete = function(_, cmdline, cursorpos)
    local items = Complete.complete_items(cmdline, cursorpos)
    local Config = require("kaeru.config")
    if (Config.options.complete or {}).items == "word" then
      return Complete.words(items)
    end
    return items
  end,
})

-- Live `:` autocomplete (popup while typing, <Tab> cycling) + cmp/blink adapters.
vim.schedule(function()
  pcall(function()
    require("kaeru.complete").setup_cmdline()
  end)
end)
