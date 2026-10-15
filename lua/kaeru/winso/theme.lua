-- Winso reading themes: a page color, a status-bar color and whether ASCII pictures
-- use a light-background ramp. Applying a theme sets the KaeruWinso* highlight groups.

local M = {}

M.themes = {
  night = { label = "night", fg = "#d6d1c4", bg = "#1c1f24", bar_fg = "#1c1f24", bar_bg = "#c9a66b", invert = false },
  paper = { label = "paper", fg = "#2b2b2b", bg = "#f5f0e1", bar_fg = "#f5f0e1", bar_bg = "#7a5c2e", invert = true },
  sepia = { label = "sepia", fg = "#3d2f1f", bg = "#eadbb8", bar_fg = "#eadbb8", bar_bg = "#5b4120", invert = true },
}

M.order = { "night", "paper", "sepia" }
M.default = "night"

--- A theme by name; unknown names fall back to the default theme.
---@param name? string
---@return table
function M.get(name)
  return M.themes[name] or M.themes[M.default]
end

--- Set the highlight groups for a theme and point the reader window at them.
---@param name? string
---@param win? integer  window to style; omit to only define the groups
---@return table theme
function M.apply(name, win)
  local theme = M.get(name)
  vim.api.nvim_set_hl(0, "KaeruWinsoNormal", { fg = theme.fg, bg = theme.bg })
  vim.api.nvim_set_hl(0, "KaeruWinsoBar", { fg = theme.bar_fg, bg = theme.bar_bg, bold = true })
  vim.api.nvim_set_hl(0, "KaeruWinsoDim", { fg = theme.fg, bg = theme.bg, italic = true })
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winhighlight = "Normal:KaeruWinsoNormal,NormalNC:KaeruWinsoNormal,EndOfBuffer:KaeruWinsoNormal"
  end
  return theme
end

return M
