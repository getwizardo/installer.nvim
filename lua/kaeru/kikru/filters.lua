-- kaeru.nvim · :Kikru — audio filter graph (10-band EQ + lavalink/NodeLink
-- style effects) rendered down to whatever the active backend understands.
--
-- The filter vocabulary follows the LavaLink / NodeLink "filters" object
-- (https://github.com/PerformanC/NodeLink — equalizer, timescale, tremolo,
-- vibrato, rotation, distortion, channelMix, lowPass, karaoke, compressor,
-- reverb, echo, chorus, phaser) so that the same preset names work in the
-- Neovim UI, the 2-Neovim remote and the Starsky web client.
--
-- Rendering targets:
--   * mpv        -> `af` chain (biquad `equalizer` + `lavfi` passthrough)
--   * ffplay     -> `-af` chain (ffmpeg filter syntax)
--   * vlc/cvlc   -> `--audio-filter=equalizer` + `--equalizer-preset=`
local M = {}

--- Center frequencies of the 10-band graphic EQ (LavaLink/NodeLink/cliamp order).
---@type number[]
M.frequencies = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 }

--- Human readable labels for the EQ UI.
---@type string[]
M.frequency_labels = { "31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz" }

--- Q (bandwidth) per band — wide at the low end, narrower higher up so the
--- bands do not smear into each other.
---@type number[]
M.q = { 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6 }

M.min_gain = -12
M.max_gain = 12

local function zero_bands()
  return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end

M.flat = zero_bands()

--- 10-band presets. The first block are the coding-focused ones (:Kikru
--- defaults, cliamp-inspired); the second block mirrors LavaLink/NodeLink's
--- built-in equalizer presets so the same names work everywhere.
---@type table<string, number[]>
M.presets = {
  ["flat"] = zero_bands(),
  ["lofi-coding"] = { 4, 5, 3, 1, -1, -2, -4, -5, -6, -7 },
  ["synthwave"] = { 6, 5, 2, -1, 1, 3, 5, 6, 7, 5 },
  ["bass-boost"] = { 8, 7, 5, 2, 0, 0, 1, 2, 2, 1 },
  ["treble-boost"] = { -2, -1, 0, 0, 0, 2, 4, 6, 7, 8 },
  ["vocal"] = { -3, -2, 0, 3, 5, 5, 4, 2, 0, -1 },
  ["electronic"] = { 6, 5, 1, 0, -2, 2, 1, 3, 6, 7 },
  ["classical"] = { 4, 3, 2, 1, -1, -1, 0, 2, 3, 4 },
  ["night"] = { -4, -2, 0, 2, 2, 1, 0, -2, -3, -5 },
  ["focus"] = { 3, 4, 4, 2, 0, -1, -2, -3, -4, -5 },
  ["podcast"] = { -6, -4, -1, 3, 4, 4, 3, 1, -1, -3 },
  -- LavaLink / NodeLink names
  ["boost"] = { -2, -1, 0, 2, 5, 5, 3, 1, 0, 0 },
  ["metal"] = { 5, 4, 2, 0, -2, 0, 3, 5, 6, 5 },
  ["piano"] = { 3, 2, 1, 0, 1, 2, 3, 4, 4, 3 },
  ["pop"] = { -1, -1, 0, 2, 4, 4, 3, 1, 0, -1 },
  ["rock"] = { 5, 4, 3, 1, -1, -1, 1, 3, 5, 5 },
  ["jazz"] = { 4, 3, 2, 2, -1, -1, 0, 1, 3, 4 },
  ["hiphop"] = { 6, 5, 3, 1, 0, -1, 1, 2, 3, 3 },
  ["party"] = { 5, 4, 2, 0, 1, 3, 4, 5, 5, 4 },
  ["soft"] = { 2, 1, 0, -1, -2, -2, -1, 0, 1, 2 },
  ["treblebass"] = { 6, 5, 4, 1, -2, -2, 0, 3, 6, 7 },
  ["bass_and_treble"] = { 7, 6, 4, 2, 0, 0, 2, 4, 6, 7 },
  ["fullbass"] = { 9, 8, 6, 3, 1, -1, -2, -3, -4, -5 },
  ["fulltreble"] = { -6, -5, -4, -2, 0, 2, 5, 7, 9, 9 },
  ["fullbasstreble"] = { 6, 5, 3, 1, 0, 1, 3, 5, 6, 6 },
  ["loudness"] = { 6, 4, 1, 0, -1, 0, 1, 2, 5, 6 },
  ["movies"] = { 4, 3, 1, 0, -1, 0, 2, 4, 5, 4 },
  ["rich"] = { 4, 3, 2, 1, 0, 1, 2, 3, 4, 4 },
  ["speech"] = { -6, -4, -2, 1, 3, 4, 4, 3, 2, 0 },
  ["headphone"] = { 4, 3, 2, 1, 0, 1, 3, 4, 5, 5 },
  ["live"] = { -3, -1, 1, 3, 4, 4, 3, 1, -1, -3 },
  ["vocalboost"] = { -4, -3, -1, 2, 5, 6, 5, 3, 1, 0 },
}

--- The order `e`/`:Kikru eq` cycles through (coding first).
---@type string[]
M.preset_order = {
  "lofi-coding", "synthwave", "focus", "bass-boost", "electronic", "vocal", "classical", "night", "flat",
}

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

M.clamp = clamp

---@param name string
---@return number[]|nil  a copy of the preset bands
function M.preset_bands(name)
  local bands = M.presets[name]
  if not bands then
    return nil
  end
  local out = {}
  for i = 1, #M.frequencies do
    out[i] = bands[i] or 0
  end
  return out
end

--- Apply the EQ to the bands table it belongs to (mirrors classic Winamp EQ).
---@param bands number[]
---@param index integer
---@param delta number
---@return number[]
function M.adjust_band(bands, index, delta)
  if index < 1 or index > #M.frequencies then
    return bands
  end
  bands[index] = clamp((bands[index] or 0) + delta, M.min_gain, M.max_gain)
  return bands
end

--- All 10 bands at 0? (used to pick the "flat"/"custom" label)
---@param bands number[]
---@return boolean
function M.is_flat(bands)
  for i = 1, #M.frequencies do
    if math.abs(bands[i] or 0) > 0.01 then
      return false
    end
  end
  return true
end

--- Name of the preset matching `bands` exactly, if any.
---@param bands number[]
---@return string|nil
function M.preset_for(bands)
  for name, preset in pairs(M.presets) do
    local same = true
    for i = 1, #M.frequencies do
      if math.abs((bands[i] or 0) - (preset[i] or 0)) > 0.01 then
        same = false
        break
      end
    end
    if same then
      return name
    end
  end
  return M.is_flat(bands) and "flat" or nil
end

-- LavaLink/NodeLink effect definitions ----------------------------------------

---@class MusicFilterSpec
---@field timescale? {speed?: number, pitch?: number, rate?: number}
---@field tremolo? {frequency?: number, depth?: number}
---@field vibrato? {frequency?: number, depth?: number}
---@field rotation? {rotationHz?: number}
---@field distortion? {sinOffset?: number, sinScale?: number, cosOffset?: number, cosScale?: number, tanOffset?: number, tanScale?: number, offset?: number, scale?: number}
---@field channelMix? {leftToLeft?: number, leftToRight?: number, rightToLeft?: number, rightToRight?: number}
---@field lowPass? {smoothing?: number}
---@field karaoke? {level?: number, monoLevel?: number, filterBand?: number, filterWidth?: number}
---@field compressor? {threshold?: number, ratio?: number, attack?: number, release?: number, makeup?: number, knee?: number}
---@field reverb? {delays?: number[], decays?: number[], wet?: number, dry?: number, depth?: number}
---@field echo? {delay?: number, decay?: number}
---@field chorus? {rate?: number, depth?: number, phase?: number, feedback?: number}
---@field phaser? {rate?: number, depth?: number, phase?: number, feedback?: number}
---@field volume? number

--- Effect presets in the LavaLink/NodeLink vocabulary.
---@type table<string, MusicFilterSpec>
M.effect_presets = {
  ["nightcore"] = { timescale = { speed = 1.3, pitch = 1.3, rate = 1 } },
  ["vaporwave"] = { timescale = { speed = 0.85, pitch = 0.85, rate = 1 } },
  ["daycore"] = { timescale = { speed = 0.9, pitch = 0.9, rate = 1 } },
  ["bassboost"] = { equalizer_bands = nil, lowPass = { smoothing = 20.0 } },
  ["8d"] = { rotation = { rotationHz = 0.2 } },
  ["karaoke"] = { karaoke = { level = 1.0, monoLevel = 1.0, filterBand = 220.0, filterWidth = 100.0 } },
  ["tremolo"] = { tremolo = { frequency = 4.0, depth = 0.75 } },
  ["vibrato"] = { vibrato = { frequency = 4.0, depth = 0.75 } },
  ["compressor"] = { compressor = { threshold = -20, ratio = 6, attack = 5, release = 80, makeup = 4, knee = 30 } },
  ["echo"] = { echo = { delay = 0.9, decay = 0.4 } },
  ["reverb"] = { reverb = { delays = { 0.03, 0.05 }, decays = { 0.5, 0.4 }, wet = 0.4, dry = 0.8 } },
  ["chorus"] = { chorus = { rate = 1.5, depth = 0.4, phase = 0.2, feedback = 0.2 } },
  ["phaser"] = { phaser = { rate = 0.5, depth = 0.6, phase = 0.3, feedback = 0.3 } },
  ["lowpass"] = { lowPass = { smoothing = 60.0 } },
  ["soft"] = { lowPass = { smoothing = 35.0 }, volume = 0.82 },
  ["treble"] = { equalizer_bands = M.presets["treble-boost"] },
  ["earrape"] = { volume = 2.0, distortion = { sinScale = 2.0, cosScale = 2.0 } },
}

---@param spec table
---@return MusicFilterSpec
function M.normalize_spec(spec)
  spec = spec or {}
  local out = {}
  local maps = {
    "timescale", "tremolo", "vibrato", "rotation", "distortion",
    "channelMix", "lowPass", "karaoke", "compressor", "reverb", "echo", "chorus", "phaser",
  }
  for _, key in ipairs(maps) do
    if type(spec[key]) == "table" then
      local copy = {}
      for k, v in pairs(spec[key]) do
        if type(v) == "number" or type(v) == "table" then
          copy[k] = v
        end
      end
      out[key] = copy
    end
  end
  if type(spec.volume) == "number" then
    out.volume = clamp(spec.volume, 0, 5)
  end
  if type(spec.equalizer) == "table" and #spec.equalizer == 10 then
    out.equalizer = spec.equalizer
  end
  return out
end

--- Merge `spec` into `base` (NodeLink semantics: `null` clears a filter).
---@param base MusicFilterSpec
---@param spec MusicFilterSpec
---@return MusicFilterSpec
function M.merge(base, spec)
  local out = vim.deepcopy(base or {})
  for k, v in pairs(spec or {}) do
    if v == vim.NIL or v == nil then
      out[k] = nil
    else
      out[k] = v
    end
  end
  return out
end

-- Per-backend chain builders --------------------------------------------------

---@param value number
---@param precision? integer
---@return string
local function num(value, precision)
  precision = precision or 4
  return (("%." .. precision .. "f"):format(value)):gsub("%.?0+$", "")
end

--- mpv `equalizer` biquad chain for the 10 bands (+ optional preamp).
---@param bands number[]
---@param preamp? number
---@return string
function M.mpv_equalizer(bands, preamp)
  local parts = {}
  for i, freq in ipairs(M.frequencies) do
    local gain = bands[i] or 0
    if math.abs(gain) >= 0.05 then
      parts[#parts + 1] = ("equalizer=f=%s:t=q:w=%s:g=%s"):format(num(freq, 0), num(M.q[i], 2), num(gain, 2))
    end
  end
  if (preamp or 0) ~= 0 then
    parts[#parts + 1] = ("volume=volume=%s dB"):format(num(preamp, 2))
  end
  return table.concat(parts, ",")
end

--- ffmpeg/ffplay `-af` chain for the 10 bands (different option names!).
---@param bands number[]
---@param preamp? number
---@return string
function M.ffmpeg_equalizer(bands, preamp)
  local parts = {}
  for i, freq in ipairs(M.frequencies) do
    local gain = bands[i] or 0
    if math.abs(gain) >= 0.05 then
      parts[#parts + 1] = ("equalizer=f=%s:width_type=q:width=%s:g=%s"):format(num(freq, 0), num(M.q[i], 2), num(gain, 2))
    end
  end
  if (preamp or 0) ~= 0 then
    parts[#parts + 1] = ("volume=%sdB"):format(num(preamp, 2))
  end
  return table.concat(parts, ",")
end

--- mpv filter-chain fragments for the effect part of the spec.
--- Filters that only exist in ffmpeg land are emitted as `lavfi=[...]`
--- (mpv protects commas inside the brackets, so the chain stays valid).
---@param spec MusicFilterSpec
---@return string[]
function M.mpv_effects(spec)
  local out = {}
  local ts = spec.timescale
  if ts and (ts.speed or ts.pitch or ts.rate) then
    -- Pitch shifting without changing tempo is done by the backend through
    -- `--audio-pitch-correction=no`; here we only add the tempo scaler.
    out[#out + 1] = "scaletempo2"
  end
  if spec.tremolo then
    out[#out + 1] = ("tremolo=f=%s:d=%s"):format(num(spec.tremolo.frequency or 4, 3), num(spec.tremolo.depth or 0.5, 3))
  end
  if spec.vibrato then
    out[#out + 1] = ("vibrato=f=%s:d=%s"):format(num(spec.vibrato.frequency or 4, 3), num(spec.vibrato.depth or 0.5, 3))
  end
  if spec.rotation then
    -- NodeLink rotation == rotating stereo field == ffmpeg apulsator.
    out[#out + 1] = ("lavfi=[apulsator=hz=%s]"):format(num(spec.rotation.rotationHz or 0.2, 3))
  end
  if spec.distortion then
    local d = spec.distortion
    out[#out + 1] = ("lavfi=[aeval=val(0)*%s+sin(%s*val(0)*%s)]"):format(
      num(d.scale or 1, 3),
      num(d.sinScale or 0.5, 3),
      num(d.sinOffset or 0, 3)
    )
  end
  if spec.channelMix then
    local cm = spec.channelMix
    local ll = cm.leftToLeft or 1
    local lr = cm.leftToRight or 0
    local rl = cm.rightToLeft or 0
    local rr = cm.rightToRight or 1
    out[#out + 1] = ("lavfi=[pan=stereo|FL=%s*FL+%s*FR|FR=%s*FL+%s*FR]"):format(
      num(ll, 3),
      num(rl, 3),
      num(lr, 3),
      num(rr, 3)
    )
  end
  if spec.lowPass then
    local smoothing = clamp(spec.lowPass.smoothing or 20, 1, 100)
    -- NodeLink: smoothing 1..100 -> cutoff 500Hz..20kHz
    local cutoff = 500 + (smoothing - 1) / 99 * 19500
    out[#out + 1] = ("lowpass=f=%s"):format(num(cutoff, 0))
  end
  if spec.karaoke then
    local k = spec.karaoke
    out[#out + 1] = ("lavfi=[stereotools=mlev=%s:slev=%s]"):format(
      num(clamp((k.level or 1) * 0.5, 0, 1), 3),
      num(clamp(1 - (k.monoLevel or 1) * 0.3, 0, 1), 3)
    )
    out[#out + 1] = ("highpass=f=%s"):format(num(200, 0))
  end
  if spec.compressor then
    local c = spec.compressor
    out[#out + 1] = ("acompressor=threshold=%s:ratio=%s:attack=%s:release=%s:makeup=%s"):format(
      num(10 ^ ((c.threshold or -20) / 20), 4),
      num(c.ratio or 4, 2),
      num((c.attack or 20) / 1000, 4),
      num((c.release or 250) / 1000, 3),
      num(10 ^ ((c.makeup or 0) / 20), 4)
    )
  end
  if spec.echo then
    local e = spec.echo
    local delay = clamp(e.delay or 0.9, 0, 5)
    local decay = clamp(e.decay or 0.4, 0, 1)
    out[#out + 1] = ("aecho=0.8:0.9:%d:%s"):format(math.floor(delay * 1000), num(decay, 3))
  end
  if spec.reverb then
    local r = spec.reverb
    local delays = r.delays or { 0.03, 0.05 }
    local decays = r.decays or { 0.5, 0.4 }
    local args = {}
    for i = 1, math.max(#delays, #decays) do
      args[#args + 1] = ("%d"):format(math.floor((delays[i] or 0.03) * 1000))
      args[#args + 1] = num(decays[i] or 0.4, 2)
    end
    out[#out + 1] = ("aecho=%s"):format(table.concat(args, ":"))
  end
  if spec.chorus then
    local c = spec.chorus
    out[#out + 1] = ("chorus=0.6:0.9:%d:0.4:0.25:%s"):format(
      math.floor(clamp(0.05 / math.max(0.1, c.rate or 1.5), 0.001, 100) * 1000),
      num(clamp(c.depth or 0.4, 0, 1), 2)
    )
  end
  if spec.phaser then
    -- No native phaser in mpv; approximate with a slow comb via aecho.
    local p = spec.phaser
    out[#out + 1] = ("aecho=0.8:0.8:%d:%s"):format(math.floor(clamp(1 / math.max(0.05, p.rate or 0.5) * 3, 1, 900)), num(clamp(p.depth or 0.5, 0, 1) * 0.6, 2))
  end
  return out
end

--- ffmpeg/ffplay filter-chain for the effect part of the spec.
---@param spec MusicFilterSpec
---@return string[]
function M.ffmpeg_effects(spec)
  local out = {}
  if spec.timescale then
    local ts = spec.timescale
    local speed = ts.speed or 1
    local pitch = ts.pitch or speed
    local rate = ts.rate or speed
    if math.abs(speed - 1) > 0.001 then
      out[#out + 1] = ("atempo=%s"):format(num(clamp(speed, 0.5, 2.0), 3))
    end
    if math.abs(pitch - 1) > 0.001 then
      out[#out + 1] = ("rubberband=pitch=%s"):format(num(pitch, 3))
    end
    if math.abs(rate - 1) > 0.001 and math.abs(rate - speed) > 0.001 then
      out[#out + 1] = ("atempo=%s"):format(num(clamp(rate, 0.5, 2.0), 3))
    end
  end
  if spec.tremolo then
    out[#out + 1] = ("tremolo=f=%s:d=%s"):format(num(spec.tremolo.frequency or 4, 3), num(spec.tremolo.depth or 0.5, 3))
  end
  if spec.vibrato then
    out[#out + 1] = ("vibrato=f=%s:d=%s"):format(num(spec.vibrato.frequency or 4, 3), num(spec.vibrato.depth or 0.5, 3))
  end
  if spec.rotation then
    out[#out + 1] = ("apulsator=hz=%s"):format(num(spec.rotation.rotationHz or 0.2, 3))
  end
  if spec.channelMix then
    local cm = spec.channelMix
    out[#out + 1] = ("pan=stereo|FL=%s*FL+%s*FR|FR=%s*FL+%s*FR"):format(
      num(cm.leftToLeft or 1, 3),
      num(cm.rightToLeft or 0, 3),
      num(cm.leftToRight or 0, 3),
      num(cm.rightToRight or 1, 3)
    )
  end
  if spec.lowPass then
    local smoothing = clamp(spec.lowPass.smoothing or 20, 1, 100)
    out[#out + 1] = ("lowpass=f=%s"):format(num(500 + (smoothing - 1) / 99 * 19500, 0))
  end
  if spec.karaoke then
    out[#out + 1] = "highpass=f=200"
  end
  if spec.compressor then
    local c = spec.compressor
    out[#out + 1] = ("acompressor=threshold=%s:ratio=%s:attack=%s:release=%s:makeup=%s"):format(
      num(10 ^ ((c.threshold or -20) / 20), 4),
      num(c.ratio or 4, 2),
      num((c.attack or 20) / 1000, 4),
      num((c.release or 250) / 1000, 3),
      num(10 ^ ((c.makeup or 0) / 20), 4)
    )
  end
  if spec.echo then
    out[#out + 1] = ("aecho=0.8:0.9:%d:%s"):format(math.floor(clamp(spec.echo.delay or 0.9, 0, 5) * 1000), num(clamp(spec.echo.decay or 0.4, 0, 1), 3))
  end
  if spec.reverb then
    local r = spec.reverb
    local args = {}
    local delays = r.delays or { 0.03, 0.05 }
    local decays = r.decays or { 0.5, 0.4 }
    for i = 1, math.max(#delays, #decays) do
      args[#args + 1] = ("%d"):format(math.floor((delays[i] or 0.03) * 1000))
      args[#args + 1] = num(decays[i] or 0.4, 2)
    end
    out[#out + 1] = ("aecho=%s"):format(table.concat(args, ":"))
  end
  if spec.chorus then
    out[#out + 1] = ("chorus=0.6:0.9:%d:0.4:0.25:%s"):format(
      math.floor(clamp(0.05 / math.max(0.1, spec.chorus.rate or 1.5), 0.001, 100) * 1000),
      num(clamp(spec.chorus.depth or 0.4, 0, 1), 2)
    )
  end
  if spec.phaser then
    out[#out + 1] = ("aecho=0.8:0.8:%d:%s"):format(
      math.floor(clamp(3 / math.max(0.05, spec.phaser.rate or 0.5), 1, 900)),
      num(clamp(spec.phaser.depth or 0.5, 0, 1) * 0.6, 2)
    )
  end
  return out
end

--- VLC equalizer preset names, nearest match for the active bands.
---@param bands number[]
---@return string
function M.vlc_preset(bands)
  local candidates = {
    "flat", "classical", "club", "dance", "full bass", "full bass and treble", "full treble",
    "headphones", "large hall", "live", "party", "pop", "reggae", "rock", "ska", "soft",
    "soft rock", "techno",
  }
  local custom = {
    ["lofi-coding"] = "soft",
    ["synthwave"] = "techno",
    ["bass-boost"] = "full bass",
    ["treble-boost"] = "full treble",
    ["electronic"] = "techno",
    ["vocal"] = "pop",
    ["classical"] = "classical",
    ["podcast"] = "soft",
  }
  for name, vlc in pairs(custom) do
    local preset = M.presets[name]
    local same = preset ~= nil
    for i = 1, #M.frequencies do
      if math.abs((bands[i] or 0) - ((preset or {})[i] or -100)) > 0.01 then
        same = false
        break
      end
    end
    if same then
      return vlc
    end
  end
  local _ = candidates
  return M.is_flat(bands) and "flat" or "full bass and treble"
end

--- Build the complete backend filter description.
---@param engine string  "mpv" | "ffplay" | "vlc" | "mpc" | "other"
---@param state {bands: number[], preamp?: number, filters?: MusicFilterSpec}
---@return {af: string|nil, af_list: string[], properties: table<string, string|number>, args: string[], vlc_preset: string|nil}
function M.build(engine, state)
  state = state or {}
  local bands = state.bands or M.flat
  local spec = M.normalize_spec(state.filters)
  local preamp = state.preamp or 0
  local result = { af_list = {}, properties = {}, args = {}, vlc_preset = nil }

  if engine == "mpv" then
    local eq = M.mpv_equalizer(bands, preamp)
    local list = {}
    for _, part in ipairs({ eq }) do
      if part ~= "" then
        list[#list + 1] = part
      end
    end
    vim.list_extend(list, M.mpv_effects(spec))
    result.af_list = list
    result.af = table.concat(list, ",")
    if spec.volume then
      result.properties["volume"] = nil -- volume stays user controlled; use `volume` filter
      result.af_list[#result.af_list + 1] = ("lavfi=[volume=%s]"):format(num(spec.volume, 3))
      result.af = table.concat(result.af_list, ",")
    end
    if spec.timescale then
      local ts = spec.timescale
      local speed = ts.speed or 1
      local pitch = ts.pitch or speed
      result.properties["speed"] = num(speed, 4)
      -- mpv pitch-corrects by default; turning that off gives the classic
      -- nightcore/vaporwave pitch shift from the LavaLink filters object.
      result.args[#result.args + 1] = "--audio-pitch-correction=" .. (math.abs(pitch - 1) > 0.001 and "no" or "yes")
    end
  elseif engine == "ffplay" then
    local eq = M.ffmpeg_equalizer(bands, preamp)
    local list = {}
    if eq ~= "" then
      list[#list + 1] = eq
    end
    vim.list_extend(list, M.ffmpeg_effects(spec))
    if spec.volume then
      list[#list + 1] = ("volume=%s"):format(num(spec.volume, 3))
    end
    result.af_list = list
    result.af = table.concat(list, ",")
  elseif engine == "vlc" then
    result.vlc_preset = M.vlc_preset(bands)
    result.args[#result.args + 1] = "--audio-filter=equalizer"
    result.args[#result.args + 1] = "--equalizer-preset=" .. result.vlc_preset
    if spec.timescale then
      result.args[#result.args + 1] = ("--rate=%s"):format(num((spec.timescale.speed or 1) * 1000 / 1000, 3))
    end
  end

  if spec.volume and engine ~= "mpv" then
    result.properties["volume-scale"] = spec.volume
  end
  return result
end

--- Short human description of the active effects (for the :Kikru UI).
---@param spec MusicFilterSpec
---@return string
function M.describe(spec)
  local names = {}
  for _, key in ipairs({ "timescale", "tremolo", "vibrato", "rotation", "distortion", "channelMix", "lowPass", "karaoke", "compressor", "reverb", "echo", "chorus", "phaser" }) do
    if spec[key] then
      local detail = ""
      if key == "timescale" then
        detail = ("x%s"):format(num(spec.timescale.speed or spec.timescale.rate or 1, 2))
      elseif key == "lowPass" then
        detail = ("%s%%"):format(num(spec.lowPass.smoothing or 20, 0))
      end
      names[#names + 1] = key:lower() .. detail
    end
  end
  if spec.volume and math.abs(spec.volume - 1) > 0.001 then
    names[#names + 1] = ("vol x%s"):format(num(spec.volume, 2))
  end
  if #names == 0 then
    return "none"
  end
  return table.concat(names, " · ")
end

--- Apply a named effect preset on top of the current spec state.
---@param state {filters: MusicFilterSpec}
---@param name string
---@return MusicFilterSpec spec, string|nil err
function M.apply_effect_preset(state, name)
  local key = tostring(name or ""):lower()
  local preset = M.effect_presets[key]
  if not preset and M.presets[key] then
    return state.filters or {}, ("%s is an EQ preset, use `eq %s`"):format(name, name)
  end
  if not preset then
    return state.filters or {}, "unknown filter preset: " .. tostring(name)
  end
  local spec = vim.deepcopy(preset)
  if spec.equalizer_bands then
    state.bands = vim.deepcopy(spec.equalizer_bands)
    spec.equalizer_bands = nil
  end
  local merged = M.merge(state.filters or {}, spec)
  return merged
end

--- Clear one filter (or all of them when `name` is "all"/nil).
---@param state {filters: MusicFilterSpec}
---@param name? string
function M.clear(state, name)
  if not name or name == "" or name == "all" then
    state.filters = {}
    return
  end
  state.filters = M.merge(state.filters or {}, { [name] = vim.NIL })
end

return M
