-- Colored ASCII pictures for Winso. A grid of RGB cells becomes lines of characters, and
-- each character is drawn in its cell's color. Brightness picks the character from a ramp.
--
-- Colors are snapped to the xterm 6x6x6 cube (indices 16..231), so the number of
-- highlight groups stays small and the view looks the same in 256-color terminals.
-- Pure Lua apart from `define_groups`, which is the only editor call.

local M = {}

-- dark to bright; a space is an empty cell and gets no color
M.ramp = " .:-=+*#%@"

local LEVELS = { 0, 95, 135, 175, 215, 255 }

--- Cube index for an RGB color (each channel 0..255).
---@return integer
function M.cube_index(r, g, b)
  local function level(v)
    return math.floor(v / 255 * 5 + 0.5)
  end
  return 16 + 36 * level(r) + 6 * level(g) + level(b)
end

--- Hex color of a cube index.
---@param index integer
---@return string
function M.hex(index)
  local n = index - 16
  local r = LEVELS[math.floor(n / 36) + 1]
  local g = LEVELS[math.floor(n / 6) % 6 + 1]
  local b = LEVELS[n % 6 + 1]
  return ("#%02x%02x%02x"):format(r, g, b)
end

--- Perceived brightness, 0..255 (Rec. 709 weights).
---@return number
function M.luminance(r, g, b)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

--- Character for a brightness. `invert` swaps the ramp for light backgrounds.
---@param lum number
---@param invert boolean
---@return string
function M.char_for(lum, invert)
  local n = #M.ramp
  local index = math.floor(lum / 256 * n) + 1
  index = math.max(1, math.min(n, index))
  if invert then
    index = n + 1 - index
  end
  return M.ramp:sub(index, index)
end

--- Name of the highlight group for a cube index.
---@param index integer
---@return string
function M.group_name(index)
  return "KaeruWinsoPx" .. index
end

--- Lines and color runs for a grid.
---
--- `grid` is { width = cols, height = rows, pixels = { r, g, b, r, g, b, ... } } with the
--- pixels row by row. Returns { lines = {...}, runs = {{row, start, finish, cube}, ...} },
--- where `row` is 1-based, and `start`/`finish` are 0-based byte columns (finish exclusive).
---@param grid table
---@param opts? {invert?: boolean}
---@return table|nil result, string|nil err
function M.render(grid, opts)
  opts = opts or {}
  local width, height, pixels = grid.width, grid.height, grid.pixels
  if type(width) ~= "number" or type(height) ~= "number" or width < 1 or height < 1 then
    return nil, "picture grid has no size"
  end
  if type(pixels) ~= "table" or #pixels ~= width * height * 3 then
    return nil, "picture grid is incomplete"
  end
  local lines, runs = {}, {}
  for row = 0, height - 1 do
    local chars = {}
    local run_cube, run_start = nil, 0
    for col = 0, width - 1 do
      local at = (row * width + col) * 3
      local r, g, b = pixels[at + 1], pixels[at + 2], pixels[at + 3]
      local ch = M.char_for(M.luminance(r, g, b), opts.invert == true)
      chars[#chars + 1] = ch
      local cube = ch ~= " " and M.cube_index(r, g, b) or nil
      if cube ~= run_cube then
        if run_cube then
          runs[#runs + 1] = { row = row + 1, start = run_start, finish = col, cube = run_cube }
        end
        run_cube, run_start = cube, col
      end
    end
    if run_cube then
      runs[#runs + 1] = { row = row + 1, start = run_start, finish = width, cube = run_cube }
    end
    lines[#lines + 1] = table.concat(chars)
  end
  return { lines = lines, runs = runs }, nil
end

--- Define a highlight group (foreground only) for each cube index used by a picture.
---@param cubes table<integer, boolean>  set of cube indices
function M.define_groups(cubes)
  for index in pairs(cubes) do
    vim.api.nvim_set_hl(0, M.group_name(index), { fg = M.hex(index), ctermfg = index })
  end
end

return M
