if vim.g.loaded_installer_nvim then
  return
end
vim.g.loaded_installer_nvim = true

if vim.fn.has("nvim-0.8") ~= 1 then
  vim.notify("installer.nvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

local subcommands = { "modal", "browse", "search", "add", "dir", "ai", "login", "logout", "whoami", "sftp" }
local sftp_actions = { "upload", "upload-project", "sync", "download", "download-project", "init", "status", "select" }

vim.api.nvim_create_user_command("Installer", function(cmd)
  local installer = require("installer")
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
    local actions = {
      upload = sftp.upload_current,
      ["upload-project"] = sftp.upload_project,
      sync = sftp.sync,
      download = sftp.download_current,
      ["download-project"] = sftp.download_all,
      init = sftp.init,
      status = sftp.status,
      select = sftp.choose,
    }
    if actions[action] then
      actions[action]()
    else
      vim.notify("Unknown sftp action: " .. action .. "\nUse: " .. table.concat(sftp_actions, ", "), vim.log.levels.ERROR, { title = "installer.nvim" })
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
