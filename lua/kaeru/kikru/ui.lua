-- kaeru.nvim · :Kikru — the floating player window.
--
-- Layout is a terminal take on the Winamp 2.x skin cliamp revives: an LCD
-- header with a scrolling marquee, a live spectrum analyzer, the 10-band EQ,
-- the playlist and a key legend — but it also has real panes for the radio
-- browser, the search results, the NodeLink style filters, lyrics, the
-- 2-Neovim devices and the help screen.
local UI = require("kaeru.ui")
local Tags = require("kaeru.kikru.tags")
local Filters = require("kaeru.kikru.filters")
local Visualizer = require("kaeru.kikru.visualizer")

local M = {}

---@class MusicUiTheme
---@field name string
---@field accent string
---@field dim string
---@field warn string
---@field ok string

---@type table<string, MusicUiTheme>
M.themes = {
  winamp = { name = "winamp", accent = "#00ff9f", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
  nord = { name = "nord", accent = "#88c0d0", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
  dracula = { name = "dracula", accent = "#bd93f9", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
  gruvbox = { name = "gruvbox", accent = "#fabd2f", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
  catppuccin = { name = "catppuccin", accent = "#cba6f7", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
  tokyonight = { name = "tokyonight", accent = "#7aa2f7", dim = "Comment", warn = "DiagnosticWarn", ok = "String" },
}

M.theme_order = { "winamp", "tokyonight", "nord", "dracula", "gruvbox", "catppuccin" }

---@type string[]
M.views = { "main", "playlist", "radio", "search", "filters", "lyrics", "devices", "help" }

M.state = {
  buf = nil,
  win = nil,
  open = false,
  view = "main",
  selected = 1,
  scroll = 0,
  marquee = 0,
  filter = "",
  filter_mode = false,
  prompt = nil, ---@type {label: string, value: string, on_accept: fun(value: string)}|nil
  flash = nil, ---@type {text: string, until_ts: number}|nil
  theme = "winamp",
  timer = nil,
  player = nil,
  layout = {},
}

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function now()
  if vim.uv and vim.uv.hrtime then
    return vim.uv.hrtime() / 1e9
  end
  return os.clock()
end

---@param text string
---@param width integer
---@param offset integer
---@return string
function M.marquee(text, width, offset)
  text = tostring(text or "")
  if #text <= width then
    return text .. string.rep(" ", width - #text)
  end
  local padded = text .. "   ·   "
  local start = (offset % #padded) + 1
  local out = padded:sub(start) .. padded:sub(1, start - 1)
  return out:sub(1, width)
end

---@param value number
---@param width integer
---@return string
function M.progress_bar(value, width)
  value = math.max(0, math.min(1, value or 0))
  local filled = math.floor(value * width)
  return string.rep("━", filled) .. string.rep("─", width - filled)
end

---@param text string
---@param width integer
---@param align? "left"|"right"|"center"
---@return string
function M.pad(text, width, align)
  text = tostring(text or "")
  if #text > width then
    return text:sub(1, width)
  end
  local missing = width - #text
  if align == "right" then
    return string.rep(" ", missing) .. text
  elseif align == "center" then
    local left = math.floor(missing / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", missing - left)
  end
  return text .. string.rep(" ", missing)
end

---@return MusicUiTheme
function M.theme()
  return M.themes[M.state.theme] or M.themes.winamp
end

---@param name string
function M.set_theme(name)
  if M.themes[name] then
    M.state.theme = name
  else
    for i, theme in ipairs(M.theme_order) do
      if theme == M.state.theme then
        M.state.theme = M.theme_order[(i % #M.theme_order) + 1]
        break
      end
    end
  end
end

-- Rendering primitives -------------------------------------------------------------

local function hl(lines, spans, line_index, start_col, end_col, group)
  spans[#spans + 1] = { line_index, start_col, end_col, group }
  return lines
end

--- Current player state helpers (all optional so the UI never hard-fails).
local function player()
  return M.state.player
end

local function state()
  local p = player()
  return p and p.state or {}
end

local function width()
  return M.state.layout.width or 80
end

local function inner_width()
  return math.max(20, width() - 4)
end

--- Render the LCD header (title marquee + transport info).
---@return string[] lines, table spans
function M.render_header()
  local p = player()
  local st = state()
  local track = p and p.current_track() or nil
  local w = inner_width()
  local theme = M.theme()
  local lines, spans = {}, {}

  local title = track and Tags.label(track) or "no track loaded — press `/` to search, `R` for radio"
  local marquee = M.marquee("♫ " .. title, w, M.state.marquee)
  lines[#lines + 1] = "  " .. marquee
  hl(lines, spans, 0, 2, 2 + #marquee, theme.accent)

  local snapshot = p and p.backend_snapshot() or {}
  local position = snapshot.position or 0
  local duration = snapshot.duration or (track and track.duration) or 0
  local live = (duration or 0) <= 0
  local time = live and "LIVE" or (Tags.format_time(position) .. " / " .. Tags.format_time(duration))
  local transport = st.playing and "▶" or (st.paused and "⏸" or "■")
  local info = (" %s %s  ·  %3d%% vol  ·  EQ %-12s  ·  vis %-10s  ·  %s")
    :format(transport, time, math.floor(st.volume or 0), st.eq_preset or "flat", st.visualizer or "spectrum", (snapshot.engine or "no engine"))

  -- second row: progress bar + station/service/bitrate
  local bar_width = math.max(10, math.min(30, math.floor(w * 0.35)))
  local ratio = (not live and duration > 0) and math.min(1, position / duration) or (st.playing and 1 or 0)
  local second = (" %s %s"):format(M.progress_bar(ratio, bar_width), info)
  second = M.pad(second, w - 1)
  lines[#lines + 1] = second
  hl(lines, spans, 1, 1, 1 + bar_width, live and theme.dim or theme.accent)
  hl(lines, spans, 1, bar_width + 5, math.min(w, bar_width + 5 + #info), theme.ok)

  return lines, spans
end

--- Render the analyzer block.
---@return string[] lines
function M.render_analyzer()
  local p = player()
  local st = state()
  local snapshot = p and p.backend_snapshot() or {}
  local w = inner_width() - 2
  local height = 4
  local values = p and p.analyzer_frame(w) or nil
  local levels = p and p.levels() or nil
  local frame = Visualizer.render({
    mode = st.visualizer or "spectrum",
    width = w,
    height = height,
    values = values,
    eq = st.eq_bands,
    t = p and p.clock() or now(),
    seed = p and p.track_seed() or 1,
    playing = st.playing,
    volume = st.volume,
    levels = levels,
  })
  local lines = {}
  for _, line in ipairs(frame) do
    lines[#lines + 1] = "  " .. M.pad(line, w)
  end
  return lines
end

--- Render the 10-band EQ compactly (height 2).
---@return string[] lines
function M.render_eq_compact()
  local st = state()
  local bands = st.eq_bands or Filters.flat
  local labels, values, bars = {}, {}, {}
  for i, label in ipairs(Filters.frequency_labels) do
    local gain = bands[i] or 0
    local selected = i == (st.selected_band or 1)
    labels[#labels + 1] = M.pad((selected and "[" or " ") .. label .. (selected and "]" or " "), 5, "center")
    values[#values + 1] = M.pad(("%+d"):format(gain), 5, "center")
    local level = math.floor(((gain + 12) / 24) * 8) + 1
    bars[#bars + 1] = M.pad(BARS[math.max(1, math.min(8, level))], 5, "center")
  end
  return {
    "  " .. table.concat(labels),
    "  " .. table.concat(values),
    "  " .. table.concat(bars),
  }
end

--- Render the playlist pane (compact by default, full in the playlist view).
---@param rows integer
---@return string[] lines
function M.render_playlist(rows)
  local p = player()
  local playlist = p and p.playlist
  local lines = {}
  if not playlist or #playlist.items == 0 then
    lines[#lines + 1] = "  (queue is empty — `/` search · `R` radio · `:Kikru add <path|url>`)"
    return lines
  end
  local items = p.filtered_items and p.filtered_items() or playlist.items
  rows = math.max(1, rows)
  local selected = math.min(M.state.selected, #items)
  local first = math.max(1, math.min(selected - math.floor(rows / 2), math.max(1, #items - rows + 1)))
  local total_duration = Tags.format_time(select(1, require("kaeru.kikru.playlist").duration(playlist)))
  lines[#lines + 1] = ("  PLAYLIST · %d track(s) · %s · %s"):format(#playlist.items, total_duration, require("kaeru.kikru.playlist").summary(playlist))
  for index = first, math.min(#items, first + rows - 1) do
    local track = items[index]
    local is_current = playlist.index > 0 and playlist.items[playlist.index] and track.path == playlist.items[playlist.index].path
    local marker = is_current and "▶" or (index == selected and "›" or " ")
    local duration = (track.duration or 0) > 0 and Tags.format_time(track.duration) or "--:--"
    local line = ("  %s %3d. %s  %s"):format(marker, index, M.pad(Tags.label(track), inner_width() - 18), duration)
    lines[#lines + 1] = M.pad(line, inner_width() + 2)
  end
  if #items > rows then
    lines[#lines + 1] = ("  … %d more (scroll with J/K, Enter plays the selection)"):format(#items - rows)
  end
  return lines
end

--- Render the radio pane.
---@return string[] lines
function M.render_radio()
  local p = player()
  local results = p and p.radio_results() or {}
  local query = p and p.radio_query() or ""
  local lines = {
    ("  RADIO BROWSER (Radio Browser 30k+ stations) — query: %s"):format(query ~= "" and query or "(press `/` to search)"),
  }
  if #results == 0 then
    lines[#lines + 1] = "  no stations — `/` searches the directory, `S` lists curated SomaFM channels"
    for _, station in ipairs(require("kaeru.kikru.radio").stations) do
      lines[#lines + 1] = ("    · %-40s %-24s %s"):format(station.title, station.genre, station.bitrate)
    end
    return lines
  end
  local rows = math.max(1, (M.state.layout.height or 24) - 8)
  local selected = math.min(M.state.selected, #results)
  local first = math.max(1, math.min(selected - math.floor(rows / 2), math.max(1, #results - rows + 1)))
  for index = first, math.min(#results, first + rows - 1) do
    local station = results[index]
    local marker = index == selected and "›" or " "
    lines[#lines + 1] = M.pad(
      ("  %s %3d. %-42s %-22s %s"):format(marker, index, station.title or "?", station.genre or "", station.bitrate or ""),
      inner_width() + 2
    )
  end
  return lines
end

--- Render the search pane (results come from the source resolver).
---@return string[] lines
function M.render_search()
  local p = player()
  local results = p and p.search_results() or {}
  local query = p and p.search_query() or ""
  local source = p and p.search_source() or "auto"
  local lines = {
    ("  SEARCH · source: %s · query: %s"):format(source, query ~= "" and query or "(press `/`)"),
    ("  sources: %s"):format(table.concat({ "auto", "youtube_music", "youtube", "soundcloud", "bandcamp", "radio", "subsonic", "rss" }, ", ")),
  }
  if #results == 0 then
    lines[#lines + 1] = "  no results yet — type a query and press <CR>"
    return lines
  end
  local rows = math.max(1, (M.state.layout.height or 24) - 9)
  local selected = math.min(M.state.selected, #results)
  local first = math.max(1, math.min(selected - math.floor(rows / 2), math.max(1, #results - rows + 1)))
  for index = first, math.min(#results, first + rows - 1) do
    local track = results[index]
    local marker = index == selected and "›" or " "
    lines[#lines + 1] = M.pad(
      ("  %s %3d. %-44s %-20s %s"):format(
        marker,
        index,
        Tags.label(track),
        track.source or "",
        (track.duration or 0) > 0 and Tags.format_time(track.duration) or "live"
      ),
      inner_width() + 2
    )
  end
  return lines
end

--- Render the filters pane (NodeLink style effects).
---@return string[] lines
function M.render_filters()
  local p = player()
  local spec = (state().filters) or {}
  local lines = {
    ("  FILTERS (NodeLink / LavaLink vocabulary) — active: %s"):format(Filters.describe(spec)),
    "",
    "  equalizer presets:",
  }
  local names = {}
  for _, name in ipairs(Filters.preset_order) do
    names[#names + 1] = name
  end
  for index, name in ipairs(names) do
    local bands = Filters.presets[name]
    local preview = {}
    for i = 1, #Filters.frequencies do
      local gain = (bands or {})[i] or 0
      local level = math.floor(((gain + 12) / 24) * 8) + 1
      preview[#preview + 1] = BARS[math.max(1, math.min(8, level))]
    end
    lines[#lines + 1] = ("    %-16s %s  %s"):format(name, table.concat(preview), index <= #Filters.preset_order and "" or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  effect presets (press `f` to cycle, `F` to clear all):"
  local effect_names = {}
  for name in pairs(Filters.effect_presets) do
    effect_names[#effect_names + 1] = name
  end
  table.sort(effect_names)
  local row = "   "
  for index, name in ipairs(effect_names) do
    row = row .. (" %-12s"):format(name)
    if index % 5 == 0 then
      lines[#lines + 1] = row
      row = "   "
    end
  end
  if row ~= "   " then
    lines[#lines + 1] = row
  end
  local _ = p
  return lines
end

--- Render the lyrics pane.
---@return string[] lines
function M.render_lyrics()
  local p = player()
  local track = p and p.current_track()
  local lyrics = p and p.lyrics_state() or nil
  local position = p and p.backend_snapshot().position or 0
  local lines = { ("  LYRICS · %s"):format(track and Tags.label(track) or "no track") }
  local Lyrics = require("kaeru.kikru.lyrics")
  local window, current = Lyrics.window(lyrics, position, math.max(3, (M.state.layout.height or 24) - 8))
  for index, line in ipairs(window) do
    lines[#lines + 1] = M.pad(line, inner_width() + 2)
    local _ = index
  end
  lines[#lines + 1] = ("  (source: %s%s)"):format(lyrics and lyrics.source or "none", current > 0 and (" · line " .. current) or "")
  return lines
end

--- Render the devices pane (2-Neovim controller).
---@return string[] lines
function M.render_devices()
  local p = player()
  local daemon = require("kaeru.kikru.daemon")
  local lines = {
    ("  2-NEOVIM DEVICE CONTROLLER · %s"):format(daemon.transport_label()),
    ("  local device: %s"):format(p and p.device_id() or "?"),
    "",
    "  <CR> routes the audio output to the selected device (handoff)",
    "  `D` starts the server on this instance, `C` connects to a server",
    "",
  }
  local devices = daemon.device_list()
  if #devices == 0 then
    lines[#lines + 1] = "  no paired devices — `D` starts a server, `C` connects as a client"
    return lines
  end
  for index, device in ipairs(devices) do
    local marker = index == M.state.selected and "›" or " "
    lines[#lines + 1] = M.pad(
      ("  %s %-34s %-8s %-22s %s"):format(marker, device.name or device.id, device.role or "?", device.addr or "", device.active and "[ACTIVE]" or ""),
      inner_width() + 2
    )
  end
  return lines
end

--- Render the help pane (the cliamp `Ctrl+K` equivalent).
---@return string[]
function M.render_help()
  local lines = {
    "  :Kikru — key reference (press `?` to close)",
    "",
    "  TRANSPORT      space play/pause · x play · c pause · v stop · z prev · b/n next",
    "                 ←/→ seek ∓5s · H/L seek ∓30s · -/+ volume · 9/0 volume · m mute",
    "",
    "  EQUALIZER      [ / ] select band · , / . gain ∓1 dB · < / > gain ∓3 dB",
    "                 e cycle EQ preset · E filters pane · F clear filters · f effect preset",
    "",
    "  QUEUE          P playlist pane · <CR> play selection · D remove · J/K move",
    "                 s shuffle · r repeat mode · w save playlist · a add path/URL",
    "                 u add the current directory recursively · C clear queue",
    "",
    "  SOURCES        / search (youtube · soundcloud · radio · subsonic · rss)",
    "                 R radio pane · S curated SomaFM channels · y lyrics",
    "                 o open the current track on its source page · Y yank path",
    "",
    "  VIEWS          1 main · 2 playlist · 3 radio · 4 search · 5 filters · 6 lyrics",
    "                 7 devices · 8 help · <Tab>/<S-Tab> cycle · t theme",
    "",
    "  REMOTE         d devices pane · D start 2-Neovim server · C connect client",
    "                 X disconnect · i toggle IPC daemon socket",
    "",
    "  Anything is also available as a command: :Kikru <cmd> (see `:` completion)",
  }
  return lines
end

--- Assemble the whole frame.
---@return string[] lines, table spans
function M.build()
  local p = player()
  local lines, spans = {}, {}
  local h = M.state.layout.height or 24
  local header, header_spans = M.render_header()
  for _, line in ipairs(header) do
    lines[#lines + 1] = line
  end
  for _, span in ipairs(header_spans) do
    spans[#spans + 1] = span
  end
  lines[#lines + 1] = "  " .. string.rep("─", inner_width())

  local body
  local view = M.state.view
  if view == "main" then
    body = {}
    vim.list_extend(body, M.render_analyzer())
    body[#body + 1] = "  " .. string.rep("─", inner_width())
    vim.list_extend(body, M.render_eq_compact())
    body[#body + 1] = "  " .. string.rep("─", inner_width())
    local playlist_rows = math.max(3, h - #lines - #body - 6)
    vim.list_extend(body, M.render_playlist(playlist_rows))
  elseif view == "playlist" then
    body = M.render_playlist(math.max(4, h - #lines - 6))
  elseif view == "radio" then
    body = M.render_radio()
  elseif view == "search" then
    body = M.render_search()
  elseif view == "filters" then
    body = M.render_filters()
  elseif view == "lyrics" then
    body = M.render_lyrics()
  elseif view == "devices" then
    body = M.render_devices()
  else
    body = M.render_help()
  end
  vim.list_extend(lines, body)

  -- pad / trim to the window height
  local target = math.max(6, h - 3)
  while #lines < target do
    lines[#lines + 1] = ""
  end
  while #lines > target do
    table.remove(lines)
  end

  local flash = M.state.flash
  local status
  if flash and now() < flash.until_ts then
    status = "  " .. flash.text
  elseif M.state.prompt_active then
    status = "  (typing…)  Enter accepts · Esc cancels"
  elseif M.state.filter ~= "" then
    status = ("  filter: %-24s %s"):format(M.state.filter, M.state.prompt_hint or "")
  else
    status = ("  [%s]  space ⏯ · z/b track · ←/→ seek · -/+ vol · e EQ · f filters · R radio · / search · P queue · ? help · q quit"):format(M.state.view)
  end
  lines[#lines + 1] = M.pad(status:sub(1, inner_width() + 2), inner_width() + 2)

  M.state.layout.lines = lines
  M.state.layout.spans = spans
  local _ = p
  return lines, spans
end

--- Paint the buffer.
function M.render()
  if not M.state.open or not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) then
    return
  end
  local lines, spans = M.build()
  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false
  local theme = M.theme()
  vim.api.nvim_buf_clear_namespace(M.state.buf, UI.ns, 0, -1)
  for _, span in ipairs(spans or {}) do
    local line_index, start_col, end_col, group = span[1], span[2], span[3], span[4]
    if group == theme.accent and theme.accent:match("^#") then
      pcall(vim.api.nvim_buf_set_extmark, M.state.buf, UI.ns, line_index, start_col, {
        end_col = end_col,
        hl_group = "KaeruKikruAccent",
      })
    elseif group and group ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, M.state.buf, UI.ns, line_index, start_col, { end_col = end_col, hl_group = group })
    end
  end
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { 1, 0 })
end

---@param text string
---@param ms? integer
function M.flash(text, ms)
  M.state.flash = { text = text, until_ts = now() + (ms or 4000) / 1000 }
  M.render()
end

-- Key handling ---------------------------------------------------------------------

local function views_cycle(delta)
  local at = 1
  for i, view in ipairs(M.views) do
    if view == M.state.view then
      at = i
      break
    end
  end
  local next_at = ((at - 1 + delta) % #M.views) + 1
  M.state.view = M.views[next_at]
  M.state.selected = 1
  M.state.scroll = 0
  M.render()
end

---@param name string
function M.set_view(name)
  for _, view in ipairs(M.views) do
    if view == name then
      M.state.view = view
      M.state.selected = 1
      M.render()
      return
    end
  end
end

--- Ask for a line of input inside the player window.
--- Uses `vim.fn.input()` (same technique the modal form uses) so real editing,
--- registers and paste work; the analyzer simply pauses while typing.
---@param label string
---@param on_accept fun(value: string)
---@param default? string
---@param completion? string  e.g. "file" | "dir"
function M.prompt(label, on_accept, default, completion)
  M.state.prompt_active = true
  local ok, value = pcall(vim.fn.input, {
    prompt = label,
    default = default or "",
    completion = completion,
  })
  M.state.prompt_active = nil
  if not ok then
    return M.render()
  end
  if value ~= nil and value ~= "" then
    pcall(on_accept, value)
  end
  M.render()
end

---@param fn fun(item: any, index: integer)
local function with_selection(fn)
  local p = player()
  if not p then
    return
  end
  local items = p.visible_items and p.visible_items() or (p.playlist and p.playlist.items) or {}
  local item = items[M.state.selected]
  if item then
    fn(item, M.state.selected)
  end
end

---@param buf integer
local function bindings(buf)
  local p = player()
  local function act(name, args)
    if p then
      p.action(name, args)
    end
    M.render()
  end

  -- transport (Winamp classic z x c v b + space)
  UI.map(buf, "<Space>", function()
    act("toggle")
  end)
  UI.map(buf, "x", function()
    act("play")
  end)
  UI.map(buf, "c", function()
    act("pause")
  end)
  UI.map(buf, "v", function()
    act("stop")
  end)
  UI.map(buf, "z", function()
    act("prev")
  end)
  UI.map(buf, "b", function()
    act("next")
  end)
  UI.map(buf, "n", function()
    act("next")
  end)
  UI.map(buf, "p", function()
    act("prev")
  end)
  UI.map(buf, "<Left>", function()
    act("seek_relative", { delta = -5 })
  end)
  UI.map(buf, "<Right>", function()
    act("seek_relative", { delta = 5 })
  end)
  UI.map(buf, "H", function()
    act("seek_relative", { delta = -30 })
  end)
  UI.map(buf, "L", function()
    act("seek_relative", { delta = 30 })
  end)
  UI.map(buf, "-", function()
    act("volume", { delta = -5 })
  end)
  UI.map(buf, "+", function()
    act("volume", { delta = 5 })
  end)
  UI.map(buf, "=", function()
    act("volume", { delta = 5 })
  end)
  UI.map(buf, "9", function()
    act("volume", { delta = -5 })
  end)
  UI.map(buf, "0", function()
    act("volume", { delta = 5 })
  end)
  UI.map(buf, "m", function()
    act("mute")
  end)

  -- equalizer
  UI.map(buf, "[", function()
    act("eq_band_select", { delta = -1 })
  end)
  UI.map(buf, "]", function()
    act("eq_band_select", { delta = 1 })
  end)
  UI.map(buf, ",", function()
    act("eq_band", { delta = -1 })
  end)
  UI.map(buf, ".", function()
    act("eq_band", { delta = 1 })
  end)
  UI.map(buf, "<", function()
    act("eq_band", { delta = -3 })
  end)
  UI.map(buf, ">", function()
    act("eq_band", { delta = 3 })
  end)
  UI.map(buf, "e", function()
    act("eq_preset")
  end)
  UI.map(buf, "E", function()
    M.set_view("filters")
  end)
  UI.map(buf, "f", function()
    act("filter_preset")
  end)
  UI.map(buf, "F", function()
    act("filter_clear")
  end)

  -- queue
  UI.map(buf, "J", function()
    M.state.selected = M.state.selected + 1
    M.render()
  end)
  UI.map(buf, "K", function()
    M.state.selected = math.max(1, M.state.selected - 1)
    M.render()
  end)
  UI.map(buf, "<Down>", function()
    M.state.selected = M.state.selected + 1
    M.render()
  end)
  UI.map(buf, "<Up>", function()
    M.state.selected = math.max(1, M.state.selected - 1)
    M.render()
  end)
  UI.map(buf, "D", function()
    act("queue_remove", { index = M.state.selected })
  end)
  UI.map(buf, "s", function()
    act("shuffle")
  end)
  UI.map(buf, "r", function()
    act("repeat")
  end)
  UI.map(buf, "w", function()
    M.prompt("Save playlist as: ", function(value)
      act("playlist_save", { path = value })
    end)
  end)
  UI.map(buf, "a", function()
    M.prompt("Add path/URL/query: ", function(value)
      act("queue_add", { query = value })
    end)
  end)
  UI.map(buf, "u", function()
    M.prompt("Index directory: ", function(value)
      act("queue_add_dir", { path = value })
    end)
  end)
  UI.map(buf, "C", function()
    act("queue_clear")
  end)

  -- sources / views
  UI.map(buf, "1", function()
    M.set_view("main")
  end)
  UI.map(buf, "2", function()
    M.set_view("playlist")
  end)
  UI.map(buf, "3", function()
    M.set_view("radio")
  end)
  UI.map(buf, "4", function()
    M.set_view("search")
  end)
  UI.map(buf, "5", function()
    M.set_view("filters")
  end)
  UI.map(buf, "6", function()
    M.set_view("lyrics")
  end)
  UI.map(buf, "7", function()
    M.set_view("devices")
  end)
  UI.map(buf, "8", function()
    M.set_view("help")
  end)
  UI.map(buf, "<Tab>", function()
    views_cycle(1)
  end)
  UI.map(buf, "<S-Tab>", function()
    views_cycle(-1)
  end)
  UI.map(buf, "R", function()
    M.set_view("radio")
  end)
  UI.map(buf, "P", function()
    M.set_view("playlist")
  end)
  UI.map(buf, "S", function()
    act("radio_curated")
  end)
  UI.map(buf, "y", function()
    M.set_view("lyrics")
    act("lyrics_fetch")
  end)
  UI.map(buf, "t", function()
    M.set_theme(nil)
    M.render()
  end)
  UI.map(buf, "/", function()
    M.prompt(M.state.view == "radio" and "Radio search: " or (M.state.view == "search" and "Search: " or "Filter/queue filter: "), function(value)
      if M.state.view == "radio" then
        act("radio_search", { query = value })
      elseif M.state.view == "search" then
        act("search", { query = value })
      else
        M.state.filter = value
        M.state.selected = 1
        M.render()
      end
    end)
  end)
  UI.map(buf, "o", function()
    with_selection(function(item)
      local url = item.stream_url or item.url or item.path
      if not url then
        return
      end
      if vim.ui and vim.ui.open and url:match("^https?://") then
        vim.ui.open(url)
      else
        require("kaeru.ui").notify(url)
      end
    end)
  end)
  UI.map(buf, "Y", function()
    with_selection(function(item)
      local path = item.path or item.url or ""
      vim.fn.setreg('"', path)
      M.flash("yanked " .. path)
    end)
  end)

  -- remote / daemon
  UI.map(buf, "d", function()
    M.set_view("devices")
  end)
  UI.map(buf, "X", function()
    act("disconnect")
  end)
  UI.map(buf, "i", function()
    act("ipc_toggle")
  end)

  UI.map(buf, "?", function()
    M.set_view(M.state.view == "help" and "main" or "help")
  end)
  UI.map(buf, "q", function()
    M.close()
  end)
  UI.map(buf, "<Esc>", function()
    if M.state.filter ~= "" then
      M.state.filter = ""
      M.render()
    else
      M.close()
    end
  end)

  UI.map(buf, "<CR>", function()
    if M.state.prompt_active then
      return
    end
    with_selection(function(_, index)
      if M.state.view == "radio" and p then
        p.action("radio_play", { index = index })
      elseif M.state.view == "search" and p then
        p.action("search_play", { index = index })
      elseif M.state.view == "devices" then
        p.action("handoff", { index = index })
      else
        p.action("select", { index = index })
      end
      M.render()
    end)
  end)
end

-- Window lifecycle -------------------------------------------------------------------

--- Open the :Kikru window for `player`.
---@param player table
function M.open(player)
  M.state.player = player
  if M.state.open then
    M.render()
    return
  end
  M.state.open = true
  M.state.filter = ""
  M.state.selected = 1
  local Config = require("kaeru.config")
  local ui_config = Config.options.ui or {}
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1
  local width_value = math.min(112, math.max(64, math.floor(cols * 0.82)))
  local height_value = math.min(34, math.max(16, math.floor(lines * 0.86)))
  M.state.layout.width = width_value
  M.state.layout.height = height_value

  local buf, win = UI.open({
    title = " :Kikru · Winamp-style player · 10-band EQ · NodeLink filters · 2-Neovim ",
    width = width_value,
    height = height_value,
    filetype = "kaeru-music",
    zorder = 50,
  })
  M.state.buf = buf
  M.state.win = win
  local _ = ui_config

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"

  local theme = M.theme()
  if theme.accent:match("^#") then
    pcall(vim.api.nvim_set_hl, 0, "KaeruKikruAccent", { fg = theme.accent, bold = true })
  end

  bindings(buf)
  M.render()

  if not (vim.uv or vim.loop) then
    return
  end
  local uv = vim.uv or vim.loop
  if uv.new_timer then
    local timer = uv.new_timer()
    M.state.timer = timer
    timer:start(100, 100, function()
      vim.schedule(function()
        if not M.state.open then
          if M.state.timer then
            pcall(function()
              M.state.timer:stop()
              M.state.timer:close()
            end)
            M.state.timer = nil
          end
          return
        end
        M.state.marquee = M.state.marquee + 1
        M.render()
      end)
    end)
  end
end

function M.close()
  M.state.open = false
  if M.state.timer then
    pcall(function()
      M.state.timer:stop()
      M.state.timer:close()
    end)
    M.state.timer = nil
  end
  UI.close(M.state.win)
  M.state.win = nil
  M.state.buf = nil
end

---@return boolean
function M.is_open()
  return M.state.open == true
end

---@return integer|nil
function M.window()
  return M.state.win
end

---@return string
function M.current_view()
  return M.state.view
end

---@param view string
function M.set_current_view(view)
  M.set_view(view)
end

return M
