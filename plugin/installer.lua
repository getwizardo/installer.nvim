if vim.g.loaded_installer_nvim then
  return
end
vim.g.loaded_installer_nvim = true

if vim.fn.has("nvim-0.8") ~= 1 then
  vim.notify("installer.nvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

local Complete = require("installer.complete")
local mason_actions = Complete.mason_actions
local mason_scaffolds = Complete.mason_scaffolds
local sftp_actions = Complete.sftp_actions
local cache_actions = Complete.cache_actions
local config_actions = Complete.config_actions
local starsky_actions = Complete.starsky_actions

vim.api.nvim_create_user_command("Installer", function(cmd)
  local installer = require("installer")
  installer.ensure_setup()
  local args = cmd.fargs
  local sub = args[1]

  if sub == nil or sub == "modal" then
    installer.open(args[2] and { repo = args[2] } or nil)
  elseif sub == "browse" then
    installer.browse({ query = table.concat(args, " ", 2) })
  elseif sub == "search" then
    installer.search(table.concat(args, " ", 2))
  elseif sub == "add" then
    if not args[2] then
      vim.notify(":Installer add requires owner/repo", vim.log.levels.ERROR, { title = "installer.nvim" })
      return
    end
    installer.add({ repo = args[2] }, { force = cmd.bang })
  elseif sub == "save" then
    if not args[2] then
      vim.notify(":Installer save requires owner/repo", vim.log.levels.ERROR, { title = "installer.nvim" })
      return
    end
    installer.save({ repo = args[2] }, { force = cmd.bang })
  elseif sub == "clina" then
    require("installer.clina").dispatch(vim.list_slice(args, 2), nil, cmd.bang)
  elseif sub == "music" then
    require("installer.music").dispatch(vim.list_slice(args, 2))
  elseif sub == "boot" then
    require("installer.boot").play()
  elseif sub == "parse" or sub == "readme" then
    local target = table.concat(args, " ", 2)
    require("installer.parser").command(target, {
      bang = cmd.bang,
      range = cmd.range and cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil,
    })
  elseif sub == "dir" then
    vim.notify("Spec files are written to " .. installer.plugins_dir(), vim.log.levels.INFO, { title = "installer.nvim" })
  elseif sub == "ai" then
    local ai = require("installer.ai")
    if args[2] == "ide" or args[2] == "clina" then
      return require("installer.clina").dispatch(vim.list_slice(args, 3))
    elseif args[2] then
      local preset = ai.get(args[2])
      if not preset then
        return vim.notify("Unknown AI preset: " .. args[2], vim.log.levels.ERROR, { title = "installer.nvim" })
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
    require("installer.account").login(args[2])
  elseif sub == "logout" then
    require("installer.account").logout()
  elseif sub == "whoami" then
    require("installer.account").whoami()
  elseif sub == "sftp" then
    local sftp = require("installer.sftp")
    local action = args[2] or "ui"
    local rest = vim.list_slice(args, 3)
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
      vim.notify("Unknown sftp action: " .. action .. "\nUse: " .. table.concat(sftp_actions, ", "), vim.log.levels.ERROR, { title = "installer.nvim" })
    end
  elseif sub == "cache" then
    local cache = require("installer.cache")
    local action = args[2] or "list"
    local name = args[3]
    local function notify(ok, msg)
      vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "installer.nvim" })
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
        return notify(false, "Usage: :Installer cache restore <plugin>")
      end
      cache.restore(name, notify, { force = cmd.bang })
    elseif action == "remove" then
      if not name then
        return notify(false, "Usage: :Installer cache remove <plugin>")
      end
      cache.remove(name)
    else
      notify(false, "Unknown cache action: " .. action .. "\nUse: " .. table.concat(cache_actions, ", "))
    end
  elseif sub == "mason" then
    local mason = require("installer.mason")
    local function notify(ok, msg)
      vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "installer.nvim" })
    end
    local action = args[2] or "pick"
    local rest = vim.list_slice(args, 3)
    if action == "registry" then
      local url = "https://mason-registry.dev/registry/list"
      if vim.ui and vim.ui.open then
        vim.ui.open(url)
      end
      return notify(true, "Opened " .. url .. " (601 Mason packages built-in)")
    end
    if action ~= "scaffold" and action ~= "pick" and action ~= "list" and action ~= "ft" and not mason.available() then
      return notify(false, "mason.nvim is not installed. Run `:Installer mason scaffold lsp` to add it to your lazy.nvim specs.")
    end
    local category_map = { lsp = "LSP", dap = "DAP", linter = "Linter", formatter = "Formatter", compiler = "Compiler", runtime = "Runtime" }
    if action == "pick" then
      mason.pick({ query = table.concat(rest, " ") })
    elseif category_map[action] then
      mason.pick({ category = category_map[action], query = table.concat(rest, " ") })
    elseif action == "install" then
      if #rest == 0 then
        return notify(false, "Usage: :Installer mason install <package> [<package>...]")
      end
      mason.install_many(rest, notify)
    elseif action == "uninstall" then
      if #rest == 0 then
        return notify(false, "Usage: :Installer mason uninstall <package>")
      end
      for _, name in ipairs(rest) do
        mason.uninstall(name, notify)
      end
    elseif action == "update" then
      if #rest == 0 then
        return notify(false, "Usage: :Installer mason update <package>")
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
      if not vim.tbl_contains(mason_scaffolds, kind) then
        return notify(false, "Usage: :Installer mason scaffold " .. table.concat(mason_scaffolds, "|"))
      end
      mason.scaffold(kind)
    elseif not mason.resolve(action) then
      notify(false, "Unknown mason action: " .. action .. "\nUse: " .. table.concat(mason_actions, ", "))
    else
      -- `:Installer mason <package>` is a shortcut for install.
      mason.install_many({ action, unpack(rest) }, notify)
    end
  elseif sub == "config" then
    local Config = require("installer.config")
    local action = args[2] or "edit"
    if action == "edit" then
      Config.edit()
    elseif action == "project" then
      Config.edit(vim.fn.getcwd() .. "/" .. Config.options.config.project)
    elseif action == "reload" then
      installer.reload()
    elseif action == "show" or action == "dump" then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(Config.dump(), "\n", { plain = true }))
      vim.bo[buf].filetype = "yaml"
      vim.bo[buf].bufhidden = "wipe"
      vim.api.nvim_buf_set_name(buf, "installer://config")
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, buf)
    else
      vim.notify("Unknown config action: " .. action .. "\nUse: " .. table.concat(config_actions, ", "), vim.log.levels.ERROR, { title = "installer.nvim" })
    end
  elseif sub == "starsky" or sub == "web" then
    local starsky = require("installer.starsky")
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
    else
      vim.notify("Unknown starsky action: " .. action .. "\nUse: " .. table.concat(starsky_actions, ", "), vim.log.levels.ERROR, { title = "installer.nvim" })
    end
  elseif sub:find("/", 1, true) or sub:find("://", 1, true) then
    -- `:Installer folke/noice.nvim` opens the modal prefilled
    installer.open({ repo = sub })
  else
    vim.notify("Unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "installer.nvim" })
  end
end, {
  nargs = "*",
  bang = true,
  range = true,
  desc = "installer.nvim: add plugins to lazy.nvim",
  complete = function(arglead, cmdline, cursorpos)
    return Complete.cmdline(arglead, cmdline, cursorpos)
  end,
})

vim.api.nvim_create_user_command("Clina", function(cmd)
  local installer = require("installer")
  installer.ensure_setup()
  local range_text = nil
  if cmd.range and cmd.range > 0 then
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, 0, cmd.line1 - 1, cmd.line2, false)
    if ok and lines then
      range_text = table.concat(lines, "\n")
    end
  end
  require("installer.clina").dispatch(cmd.fargs, range_text, cmd.bang)
end, {
  nargs = "*",
  bang = true,
  range = true,
  desc = ":Clina — NeoCodeium AI Coding IDE integration for Neovim",
  complete = function(arglead, cmdline, cursorpos)
    return Complete.clina_cmdline(arglead, cmdline, cursorpos)
  end,
})

vim.api.nvim_create_user_command("MusicPlayer", function(cmd)
  local installer = require("installer")
  installer.ensure_setup()
  require("installer.music").dispatch(cmd.fargs)
end, {
  nargs = "*",
  bang = true,
  desc = ":MusicPlayer — Built-in Music Player with 10-band EQ, Visualizer, Radio & 2-Neovim Device Controller",
  complete = function(arglead, cmdline, cursorpos)
    return Complete.music_cmdline(arglead, cmdline, cursorpos)
  end,
})


