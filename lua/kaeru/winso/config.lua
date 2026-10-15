-- Winso defaults: formats, text column widths and the picture view size.

local M = {}

M.formats = { "epub", "fb2", "fb2.zip", "mobi", "azw", "azw3", "pdf", "docx", "html", "htm", "md", "markdown", "txt" }

M.defaults = {
  width = nil,        -- text column; nil = automatic
  max_width = 80,     -- desktop cap for the text column
  termux_width = 60,  -- phones: a column that fits the screen
  picture_cols = 72,  -- ASCII picture width (capped by the window)
}

return M
