if vim.g.loaded_installer_nvim then
  return
end
vim.g.loaded_installer_nvim = true

if vim.fn.has("nvim-0.8") ~= 1 then
  vim.notify("installer.nvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

local subcommands = { "modal", "browse", "search", "add", "dir", "ai", "login", "logout", "whoami", "sftp", "cache", "config" }
local sftp_actions = {
  "upload", "upload-project", "sync", "download", "download-project", "init", "status", "select", "browse", "diff", "test",
  "shell", "ssh", "run", "exec", "ls", "mkdir", "rmdir", "rm", "rename", "chmod", "chown", "chgrp", "ln", "symlink", "df", "pwd", "version",
}
local cache_actions = { "pack", "restore", "list", "remove", "clean", "dir" }
local config_actions = { "edit", "project", "reload", "show", "dump" }

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
  elseif sub == "dir" then
    vim.notify("Spec files are written to " .. installer.plugins_dir(), vim.log.levels.INFO, { title = "installer.nvim" })
  elseif sub == "ai" then
    local ai = require("installer.ai")
    if args[2] then
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
    local action = args[2] or "upload"
    local rest = vim.list_slice(args, 3)
    local raw = table.concat(rest, " ")
    local actions = {
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
  elseif sub:find("/", 1, true) or sub:find("://", 1, true) then
    -- `:Installer folke/noice.nvim` opens the modal prefilled
    installer.open({ repo = sub })
  else
    vim.notify("Unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "installer.nvim" })
  end
end, {
  nargs = "*",
  bang = true,
  desc = "installer.nvim: add plugins to lazy.nvim",
  complete = function(arglead, cmdline)
    local words = vim.split(cmdline, "%s+")
    local function filter(list)
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, list)
    end
    if #words <= 2 then
      return filter(subcommands)
    elseif words[2] == "sftp" and #words == 3 then
      return filter(sftp_actions)
    elseif words[2] == "cache" and #words == 3 then
      return filter(cache_actions)
    elseif words[2] == "cache" and #words == 4 then
      local names = vim.tbl_keys(require("installer.cache").index())
      local ok, LazyConfig = pcall(require, "lazy.core.config")
      if ok and LazyConfig.plugins then
        for name in pairs(LazyConfig.plugins) do
          names[#names + 1] = name
        end
      end
      table.sort(names)
      return filter(names)
    elseif words[2] == "config" and #words == 3 then
      return filter(config_actions)
    elseif words[2] == "login" and #words == 3 then
      return filter({ "gh", "token", "device" })
    elseif words[2] == "ai" and #words == 3 then
      return filter(vim.tbl_map(function(p)
        return p.repo
      end, require("installer.ai").presets))
    end
    return {}
  end,
})
