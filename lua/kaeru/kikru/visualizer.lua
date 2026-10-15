-- kaeru.nvim · :Kikru: terminal visualizer.
--
-- Rendering is a pure function of (mode, size, analysis frame) so it can be
-- unit-tested and reused by the web client. Analysis frames come from
-- `cava` when it is installed (real FFT, exactly like cliamp's spectrum), and
-- fall back to a deterministic synthesis otherwise. The fallback is not a lie
-- about the audio: it is driven by the playback clock, the EQ curve and the
-- volume, and it is deselected automatically as soon as real data arrives.
local Filters = require("kaeru.kikru.filters")

local M = {}

local uv = vim.uv or vim.loop

M.blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
M.dots = { "⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿" }
M.smooth_blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---@type string[]
M.modes = { "spectrum", "bars", "wave", "vu", "matrix", "starfield", "oscilloscope" }

--- cava availability (real spectrum data).
---@return boolean
function M.cava_available()
  return vim.fn.executable("cava") == 1
end

--- Render a numeric frame as unicode blocks (8 steps per cell).
---@param values number[]  each 0..1
---@param max_width? integer
---@return string
function M.blocks_line(values, max_width)
  local out = {}
  for i, value in ipairs(values) do
    if max_width and i > max_width then
      break
    end
    local level = math.max(0, math.min(1, value))
    local index = math.floor(level * (#M.blocks - 1) + 0.5) + 1
    out[#out + 1] = level <= 0.001 and " " or M.blocks[index]
  end
  return table.concat(out)
end

--- Vertical bars for a frame (top aligned), `height` lines tall.
---@param values number[]
---@param height integer
---@return string[]
function M.vertical_bars(values, height)
  height = math.max(1, height)
  local lines = {}
  for row = height, 1, -1 do
    local line = {}
    for _, value in ipairs(values) do
      local level = math.max(0, math.min(1, value))
      local cell_floor = (row - 1) / height
      local cell_ceil = row / height
      if level >= cell_ceil then
        line[#line + 1] = "█"
      elseif level > cell_floor then
        local fraction = (level - cell_floor) * height
        line[#line + 1] = M.blocks[math.max(1, math.min(#M.blocks, math.floor(fraction * #M.blocks + 0.5)))]
      else
        line[#line + 1] = " "
      end
    end
    lines[#lines + 1] = table.concat(line)
  end
  return lines
end

--- Deterministic pseudo-spectrum. `seed` should be a stable number per track so
--- the same song always "looks" the same, and the frame advances with `t`.
---@param t number      seconds of playback
---@param count integer number of bands
---@param seed? number
---@param energy? number 0..1 overall energy (volume, playing state)
---@return number[]
function M.synth_frame(t, count, seed, energy)
  seed = seed or 1
  energy = energy or 1
  local out = {}
  for i = 1, count do
    local position = i / count
    -- bass heavy curve + two moving resonances + per-band hash
    local curve = 1.05 - position * 0.55
    local wobble = 0.35 * math.sin(t * (1.1 + (seed % 7) * 0.13) + i * 0.7)
      + 0.22 * math.cos(t * (0.7 + (seed % 5) * 0.19) - i * 0.31)
      + 0.18 * math.sin(t * 2.3 + i * 1.9 + (seed % 11))
    local hash = ((seed * (i * 37 + 11)) % 97) / 97
    local value = (curve * 0.42 + wobble * 0.3 + hash * 0.28) * energy
    out[i] = math.max(0.02, math.min(1, value))
  end
  return out
end

--- Apply an EQ curve to a spectrum frame (so the bars react to the settings).
---@param frame number[]
---@param bands number[]
---@return number[]
function M.apply_eq(frame, bands)
  local out = {}
  local count = #frame
  for i = 1, count do
    local band = math.min(#Filters.frequencies, math.max(1, math.ceil(i / count * #Filters.frequencies)))
    local gain = (bands or {})[band] or 0
    out[i] = math.max(0.02, math.min(1, frame[i] * (1 + gain / 24)))
  end
  return out
end

--- Oscilloscope-ish waveform from a time value.
---@param t number
---@param width integer
---@param energy? number
---@return number[]  values in -1..1
function M.wave_frame(t, width, energy)
  energy = energy or 1
  local out = {}
  for i = 1, width do
    local x = i / width
    out[i] = energy
      * (0.6 * math.sin((x * 12 + t * 3.1) * math.pi)
        + 0.3 * math.sin((x * 27 - t * 5.7) * math.pi)
        + 0.1 * math.sin((x * 61 + t * 9.3) * math.pi))
  end
  return out
end

--- Compose the analyzer block.
---@param opts {mode: string, width: integer, height: integer, values?: number[], eq?: number[], t?: number, seed?: number, playing?: boolean, volume?: number, levels?: {left: number, right: number, peakLeft?: number, peakRight?: number}}
---@return string[]
function M.render(opts)
  local mode = opts.mode or "spectrum"
  local width = math.max(10, math.floor(opts.width or 60))
  local height = math.max(1, math.floor(opts.height or 3))
  local energy = (opts.playing and (opts.volume or 80) / 100) or 0.05
  local t = opts.t or 0
  local seed = opts.seed or 1
  local values = opts.values
  if not values then
    values = M.synth_frame(t, width, seed, energy)
    values = M.apply_eq(values, opts.eq or Filters.flat)
  end

  if mode == "spectrum" or mode == "bars" then
    return M.vertical_bars(values, height)
  elseif mode == "wave" or mode == "oscilloscope" then
    local wave = M.wave_frame(t, width, energy)
    local lines = {}
    for row = 1, height do
      local line = {}
      for _, value in ipairs(wave) do
        -- map -1..1 into the row band
        local band_low = -1 + (row - 1) * (2 / height)
        local band_high = -1 + row * (2 / height)
        if value >= band_low and value < band_high then
          line[#line + 1] = "•"
        else
          line[#line + 1] = " "
        end
      end
      lines[#lines + 1] = table.concat(line)
    end
    return lines
  elseif mode == "vu" then
    local levels = opts.levels or { left = energy, right = energy * 0.94 }
    local bar_width = math.max(8, width - 14)
    local lines = {}
    local channels = { "L", "R" }
    for _, channel in ipairs(channels) do
      local level = math.max(0, math.min(1, levels[channel:lower()] or 0))
      local filled = math.floor(level * bar_width)
      local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
      local db = level > 0.001 and (20 * math.log(level) / math.log(10)) or -60
      lines[#lines + 1] = ("  %s ┤%s├ %5.1f dB"):format(channel, bar, math.max(-60, db))
      -- A taller VU pane shows a stacked scale instead of an empty box.
      for _ = 1, math.floor((height - #channels) / #channels) do
        lines[#lines + 1] = ("  %s │%s│"):format(" ", string.rep(" ", bar_width))
      end
    end
    while #lines < height do
      lines[#lines + 1] = ""
    end
    while #lines > height do
      table.remove(lines)
    end
    return lines
  elseif mode == "matrix" then
    local glyphs = { "0", "1", "⋮", "∷", "╫", "║", " " }
    local lines = {}
    for row = 1, height do
      local line = {}
      for column = 1, width do
        local pick = ((column * 7 + row * 13 + math.floor(t * 6)) % #glyphs) + 1
        line[#line + 1] = energy > 0.08 and glyphs[pick] or "·"
      end
      lines[#lines + 1] = table.concat(line)
    end
    return lines
  elseif mode == "starfield" then
    local glyphs = { "·", "✦", "★", "✧", "∘", " " }
    local lines = {}
    for row = 1, height do
      local line = {}
      for column = 1, width do
        local pick = ((column * 11 + row * 17 + math.floor(t * 9)) % #glyphs) + 1
        line[#line + 1] = energy > 0.08 and glyphs[pick] or "·"
      end
      lines[#lines + 1] = table.concat(line)
    end
    return lines
  end

  return M.vertical_bars(values, height)
end

-- cava integration ----------------------------------------------------------------

M._cava_job = nil
M._cava_frame = nil

--- Generate a cava config with `bars` bars, ascii output on stdout.
---@param bars integer
---@return string
function M.cava_config(bars)
  return table.concat({
    "[general]",
    "framerate = 60",
    "bars = " .. tostring(bars),
    "",
    "[input]",
    "method = fifo",
    "source = /tmp/kaeru-kikru-cava.fifo",
    "",
    "[output]",
    "method = raw",
    "raw_target = /dev/stdout",
    "data_format = ascii",
    "ascii_max_range = 100",
    "channels = mono",
    "",
    "[smoothing]",
    "monstercat = 1",
    "noise_reduction = 30",
    "",
  }, "\n")
end

--- Parse one cava ascii frame ("12;45;3;...;").
---@param line string
---@param max? number
---@return number[]|nil
function M.parse_cava_frame(line, max)
  if not line or line == "" then
    return nil
  end
  local out = {}
  for value in line:gmatch("(%d+)") do
    out[#out + 1] = math.max(0, math.min(1, (tonumber(value) or 0) / (max or 100)))
  end
  return #out > 0 and out or nil
end

--- Start a cava process feeding `M._cava_frame` (best effort).
---@param bars integer
---@return boolean
function M.start_cava(bars)
  if not M.cava_available() or not (uv and uv.new_pipe) then
    return false
  end
  M.stop_cava()
  local config_path = vim.fn.tempname() .. "-cava.conf"
  local fd = io.open(config_path, "w")
  if not fd then
    return false
  end
  fd:write(M.cava_config(bars))
  fd:close()
  local job = vim.fn.jobstart({ "cava", "-p", config_path }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        local frame = M.parse_cava_frame(line)
        if frame then
          M._cava_frame = frame
        end
      end
    end,
    on_exit = function()
      M._cava_job = nil
    end,
  })
  if job <= 0 then
    return false
  end
  M._cava_job = job
  return true
end

function M.stop_cava()
  if M._cava_job then
    pcall(vim.fn.jobstop, M._cava_job)
    M._cava_job = nil
  end
  M._cava_frame = nil
end

--- Latest analysis frame (real from cava, otherwise nil).
---@param width integer
---@return number[]|nil
function M.frame(width)
  local frame = M._cava_frame
  if not frame then
    return nil
  end
  if #frame == width then
    return frame
  end
  -- resample to the requested width
  local out = {}
  for i = 1, width do
    local at = math.max(1, math.floor(i / width * #frame))
    out[i] = frame[at]
  end
  return out
end

--- Peak levels for the VU meter (left/right) from a mono frame.
---@param frame number[]|nil
---@param energy number
---@return {left: number, right: number}
function M.levels_from_frame(frame, energy)
  if not frame then
    return { left = energy, right = energy * 0.94, synthetic = true }
  end
  local mid = math.max(1, math.floor(#frame / 2))
  local sum_l, sum_r = 0, 0
  for i = 1, mid do
    sum_l = sum_l + (frame[i] or 0)
  end
  for i = mid + 1, #frame do
    sum_r = sum_r + (frame[i] or 0)
  end
  return {
    left = sum_l / mid,
    right = sum_r / math.max(1, #frame - mid),
    synthetic = false,
  }
end

return M
