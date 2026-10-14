if vim.g.loaded_installer_nvim then
  return
end
vim.g.loaded_installer_nvim = true

if vim.fn.has("nvim-0.8") ~= 1 then
  vim.notify("installer.nvim requires Neovim >= 0.8", vim.log.levels.ERROR)
  return
end

local subcommands = { "modal", "browse", "search", "add", "dir" }

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
    if #words <= 2 then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, subcommands)
    end
    return {}
  end,
})
