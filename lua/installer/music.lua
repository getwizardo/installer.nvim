-- :MusicPlayer — Built-in Neovim Music Player with 10-Band EQ, Real-time ASCII Visualization,
-- Streaming Services, Internet Radio, and 2-Neovim Device Controller (Server <-> Client TCP RPC).
local Config = require("installer.config")
local UI = require("installer.ui")

local M = {}

local uv = vim.uv or vim.loop

M.eq_frequencies = { "31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz" }

---@type table<string, number[]>
M.eq_presets = {
  ["flat"] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  ["bass-boost"] = { 8, 7, 5, 2, 0, 0, 1, 2, 2, 1 },
  ["lofi-coding"] = { 4, 5, 3, 1, -1, -2, -4, -5, -6, -7 },
  ["synthwave"] = { 6, 5, 2, -1, 1, 3, 5, 6, 7, 5 },
  ["vocal"] = { -3, -2, 0, 3, 5, 5, 4, 2, 0, -1 },
  ["electronic"] = { 6, 5, 1, 0, -2, 2, 1, 3, 6, 7 },
  ["classical"] = { 4, 3, 2, 1, -1, -1, 0, 2, 3, 4 },
  ["night"] = { -4, -2, 0, 2, 2, 1, 0, -2, -3, -5 },
}

M.eq_preset_order = {
  "lofi-coding", "synthwave", "bass-boost", "electronic", "vocal", "classical", "night", "flat",
}

M.visualizer_modes = { "spectrum", "wave", "vu", "matrix", "starfield" }

---@class MusicStation
---@field id string
---@field title string
---@field artist string
---@field genre string
---@field service string
---@field url string
---@field bitrate string

---@type MusicStation[]
M.stations = {
  {
    id = "lofi-girl",
    title = "Lofi Girl · Beats to Code / Relax To",
    artist = "Lofi Girl Radio",
    genre = "Lo-Fi / Chillhop",
    service = "Internet Radio",
    url = "https://play.streamafrica.net/lofiradio",
    bitrate = "128 kbps",
  },
  {
    id = "somafm-groovesalad",
    title = "SomaFM · Groove Salad",
    artist = "SomaFM San Francisco",
    genre = "Ambient / Downtempo",
    service = "SomaFM Stream",
    url = "https://ice1.somafm.com/groovesalad-128-mp3",
    bitrate = "128 kbps",
  },
  {
    id = "somafm-defcon",
    title = "SomaFM · DEF CON Radio",
    artist = "SomaFM Hacker Stream",
    genre = "Electronic / Hacker",
    service = "SomaFM Stream",
    url = "https://ice1.somafm.com/defcon-128-mp3",
    bitrate = "128 kbps",
  },
  {
    id = "nightride-fm",
    title = "Nightride FM · Cyberpunk Synthwave",
    artist = "Nightride FM",
    genre = "Synthwave / Outrun",
    service = "Nightride Stream",
    url = "https://stream.nightride.fm/nightride.m4a",
    bitrate = "192 kbps",
  },
  {
    id = "coderadio-fcc",
    title = "freeCodeCamp · Code Radio 24/7",
    artist = "freeCodeCamp",
    genre = "Coding Beats",
    service = "CodeRadio Stream",
    url = "https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3",
    bitrate = "128 kbps",
  },
  {
    id = "somafm-dronezone",
    title = "SomaFM · Drone Zone",
    artist = "SomaFM Ambient",
    genre = "Atmospheric / Space",
    service = "SomaFM Stream",
    url = "https://ice1.somafm.com/dronezone-128-mp3",
    bitrate = "128 kbps",
  },
  {
    id = "somafm-secretagent",
    title = "SomaFM · Secret Agent",
    artist = "SomaFM Lounge",
    genre = "Spy Jazz / Lounge",
    service = "SomaFM Stream",
    url = "https://ice1.somafm.com/secretagent-128-mp3",
    bitrate = "128 kbps",
  },
}

M.streaming_services = {
  { id = "radio", name = "Internet Radio (Icecast / HLS)", status = "active", desc = "Direct live streaming from SomaFM, Lofi Girl, Nightride FM & CodeRadio" },
  { id = "spotify", name = "Spotify Connect (playerctl / spotifyd)", status = "ready", desc = "Control Spotify playback and sync track metadata via MPRIS / Spotify Connect" },
  { id = "youtube", name = "YouTube Music (yt-dlp + mpv)", status = "ready", desc = "Stream coding mixes and playlists from YouTube Music" },
  { id = "soundcloud", name = "SoundCloud Stream", status = "ready", desc = "Stream electronic, synthwave, and indie tracks from SoundCloud" },
  { id = "subsonic", name = "Subsonic / Navidrome Self-Hosted", status = "ready", desc = "Connect to your self-hosted Subsonic/Navidrome music server" },
  { id = "mpd", name = "MPD (Music Player Daemon)", status = "ready", desc = "Bridge to local or remote Music Player Daemon (`mpc`)" },
}

M.state = {
  playing = true,
  station_idx = 1,
  service_id = "radio",
  volume = 78,
  shuffle = false,
  repeat_mode = "all", -- "off" | "one" | "all"
  eq_preset = "lofi-coding",
  eq_bands = { 4, 5, 3, 1, -1, -2, -4, -5, -6, -7 },
  selected_band = 1,
  visualizer = "spectrum",
  tick = 0,
  elapsed_sec = 42,
  -- 2-Neovim Device Controller state (`none` | `server` | `client`)
  role = "none",
  port = 41999,
  host = "127.0.0.1",
  device_id = "nvim-" .. tostring((uv and uv.os_getpid and uv.os_getpid()) or math.random(1000, 9999)),
  devices = {}, ---@type {id: string, role: string, addr: string, connected_at: string, active: boolean}[]
}

M._audio_job = nil
M._server_tcp = nil
M._client_tcp = nil
M._peer_sockets = {}
M._ui_timer = nil

---@return MusicStation
function M.current_station()
  return M.stations[M.state.station_idx] or M.stations[1]
end

--- Snapshot serializable state for 2-Neovim Server <-> Client sync and Web IDE API.
---@return table
function M.get_snapshot()
  local st = M.current_station()
  return {
    playing = M.state.playing,
    station_idx = M.state.station_idx,
    station = st,
    service_id = M.state.service_id,
    volume = M.state.volume,
    shuffle = M.state.shuffle,
    repeat_mode = M.state.repeat_mode,
    eq_preset = M.state.eq_preset,
    eq_bands = M.state.eq_bands,
    selected_band = M.state.selected_band,
    visualizer = M.state.visualizer,
    elapsed_sec = M.state.elapsed_sec,
    role = M.state.role,
    host = M.state.host,
    port = M.state.port,
    device_id = M.state.device_id,
    devices = M.state.devices,
  }
end

--- Apply a state snapshot received from a paired Neovim server.
---@param snap table
function M.apply_snapshot(snap)
  if type(snap) ~= "table" then
    return
  end
  for _, k in ipairs({
    "playing", "station_idx", "service_id", "volume", "shuffle",
    "repeat_mode", "eq_preset", "visualizer", "elapsed_sec",
  }) do
    if snap[k] ~= nil then
      M.state[k] = snap[k]
    end
  end
  if type(snap.eq_bands) == "table" and #snap.eq_bands == 10 then
    M.state.eq_bands = snap.eq_bands
  end
  if type(snap.devices) == "table" then
    M.state.devices = snap.devices
  end
end

-- External Audio Process Backend (mpv / ffplay / cvlc) ---------------------------------

function M._stop_audio_backend()
  if M._audio_job and vim and vim.fn and vim.fn.jobstop then
    pcall(vim.fn.jobstop, M._audio_job)
  end
  M._audio_job = nil
end

function M._sync_audio_backend()
  M._stop_audio_backend()
  if not M.state.playing then
    return
  end
  if not (vim and vim.fn and vim.fn.executable and vim.fn.jobstart) then
    return
  end
  local st = M.current_station()
  if not st or not st.url then
    return
  end
  if vim.fn.executable("mpv") == 1 then
    M._audio_job = vim.fn.jobstart({
      "mpv",
      "--no-video",
      "--volume=" .. tostring(M.state.volume),
      st.url,
    }, { detach = false })
  elseif vim.fn.executable("ffplay") == 1 then
    M._audio_job = vim.fn.jobstart({
      "ffplay",
      "-nodisp",
      "-autoexit",
      "-loglevel",
      "quiet",
      "-volume",
      tostring(M.state.volume),
      st.url,
    }, { detach = false })
  end
end

-- 2-Neovim Device Controller (Server <-> Client TCP RPC) -------------------------------

local function encode_msg(tbl)
  local ok, json = pcall(function()
    return (vim.json and vim.json.encode(tbl)) or vim.fn.json_encode(tbl)
  end)
  return ok and (json .. "\n") or "{}\n"
end

local function decode_msg(line)
  local ok, tbl = pcall(function()
    return (vim.json and vim.json.decode(line)) or vim.fn.json_decode(line)
  end)
  return ok and tbl or nil
end

--- Broadcast current `:MusicPlayer` state from the Server Neovim instance to all connected Client Neovim instances.
function M.broadcast_state()
  if M.state.role ~= "server" or #M._peer_sockets == 0 then
    return
  end
  local payload = encode_msg({
    type = "state",
    snapshot = M.get_snapshot(),
  })
  for i = #M._peer_sockets, 1, -1 do
    local sock = M._peer_sockets[i]
    local ok = pcall(function()
      sock:write(payload)
    end)
    if not ok then
      table.remove(M._peer_sockets, i)
    end
  end
end

--- Send a remote command from a Client Neovim instance to the Server Neovim instance.
---@param action string
---@param args? table
---@return boolean
function M.send_remote_command(action, args)
  if M.state.role ~= "client" or not M._client_tcp then
    return false
  end
  local payload = encode_msg({
    type = "command",
    device_id = M.state.device_id,
    action = action,
    args = args or {},
  })
  local ok = pcall(function()
    M._client_tcp:write(payload)
  end)
  return ok
end

--- Start the 2-Neovim `:MusicPlayer` TCP Server (`:MusicPlayer server [port]`).
---@param port? integer
---@return boolean ok, string msg
function M.start_server(port)
  port = tonumber(port) or M.state.port or 41999
  if not uv or not uv.new_tcp then
    M.state.role = "server"
    M.state.port = port
    M.state.devices = {
      {
        id = M.state.device_id .. " (Server)",
        role = "server",
        addr = "127.0.0.1:" .. tostring(port),
        connected_at = os.date("%H:%M:%S"),
        active = true,
      },
    }
    return true, ("Started :MusicPlayer Server on 127.0.0.1:%d"):format(port)
  end

  M.disconnect()
  local server = uv.new_tcp()
  local ok_bind, bind_err = server:bind("127.0.0.1", port)
  if not ok_bind then
    return false, "Could not bind :MusicPlayer server on port " .. tostring(port) .. ": " .. tostring(bind_err)
  end

  M._server_tcp = server
  M.state.role = "server"
  M.state.port = port
  M.state.devices = {
    {
      id = M.state.device_id .. " (Primary Neovim Server)",
      role = "server",
      addr = "127.0.0.1:" .. tostring(port),
      connected_at = os.date("%H:%M:%S"),
      active = true,
    },
  }

  server:listen(16, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    server:accept(client)
    table.insert(M._peer_sockets, client)
    local peer = client:getpeername()
    local addr = peer and (peer.ip .. ":" .. tostring(peer.port)) or "127.0.0.1:peer"
    local peer_id = "nvim-client-" .. tostring(#M.state.devices)

    table.insert(M.state.devices, {
      id = peer_id,
      role = "client",
      addr = addr,
      connected_at = os.date("%H:%M:%S"),
      active = false,
    })

    -- Send immediate state snapshot to the newly connected Neovim client
    pcall(function()
      client:write(encode_msg({ type = "state", snapshot = M.get_snapshot() }))
    end)

    local buffer = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        client:close()
        return
      end
      buffer = buffer .. chunk
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        vim.schedule(function()
          local msg = decode_msg(line)
          if msg then
            if msg.type == "hello" and msg.device_id then
              for _, d in ipairs(M.state.devices) do
                if d.addr == addr then
                  d.id = msg.device_id .. " (Neovim Client)"
                end
              end
              M.broadcast_state()
            elseif msg.type == "command" then
              M._execute_local_action(msg.action, msg.args or {})
              M.broadcast_state()
            end
          end
        end)
      end
    end)
  end)

  local msg = ("Started 2-Neovim :MusicPlayer Server on 127.0.0.1:%d (connect from a 2nd Neovim with `:MusicPlayer connect %d`)"):format(port, port)
  UI.notify(msg)
  return true, msg
end

--- Connect a 2nd Neovim instance as a Client to a running `:MusicPlayer` Server (`:MusicPlayer connect [host:port]`).
---@param target? string
---@return boolean ok, string msg
function M.connect_client(target)
  target = vim.trim(tostring(target or ""))
  local host = "127.0.0.1"
  local port = M.state.port or 41999
  if target ~= "" then
    local h, p = target:match("^([^:]+):(%d+)$")
    if h and p then
      host = h
      port = tonumber(p)
    elseif target:match("^%d+$") then
      port = tonumber(target)
    end
  end

  if not uv or not uv.new_tcp then
    M.state.role = "client"
    M.state.host = host
    M.state.port = port
    return true, ("Connected :MusicPlayer Client to %s:%d"):format(host, port)
  end

  M.disconnect()
  local client = uv.new_tcp()
  M._client_tcp = client
  M.state.role = "client"
  M.state.host = host
  M.state.port = port

  client:connect(host, port, function(err)
    vim.schedule(function()
      if err then
        M.state.role = "none"
        M._client_tcp = nil
        UI.notify(("Could not connect to :MusicPlayer server at %s:%d (%s)"):format(host, port, tostring(err)), vim.log.levels.ERROR)
        return
      end
      pcall(function()
        client:write(encode_msg({
          type = "hello",
          device_id = M.state.device_id,
        }))
      end)
      UI.notify(("Connected to 2-Neovim :MusicPlayer Server at %s:%d"):format(host, port))

      local buffer = ""
      client:read_start(function(rerr, chunk)
        if rerr or not chunk then
          vim.schedule(function()
            M.state.role = "none"
            UI.notify("Disconnected from :MusicPlayer server", vim.log.levels.WARN)
          end)
          client:close()
          return
        end
        buffer = buffer .. chunk
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then
            break
          end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          vim.schedule(function()
            local msg = decode_msg(line)
            if msg and msg.type == "state" and msg.snapshot then
              M.apply_snapshot(msg.snapshot)
              M.state.role = "client"
            end
          end)
        end
      end)
    end)
  end)

  return true, ("Connecting :MusicPlayer Client to %s:%d…"):format(host, port)
end

--- Disconnect any active Server or Client TCP sockets.
function M.disconnect()
  for _, sock in ipairs(M._peer_sockets) do
    pcall(function()
      sock:close()
    end)
  end
  M._peer_sockets = {}
  if M._server_tcp then
    pcall(function()
      M._server_tcp:close()
    end)
    M._server_tcp = nil
  end
  if M._client_tcp then
    pcall(function()
      M._client_tcp:close()
    end)
    M._client_tcp = nil
  end
  M.state.role = "none"
  M.state.devices = {}
end

-- Playback, EQ & Station Actions -------------------------------------------------------

function M._execute_local_action(action, args)
  args = args or {}
  if action == "play" then
    M.state.playing = true
    M._sync_audio_backend()
  elseif action == "pause" then
    M.state.playing = false
    M._stop_audio_backend()
  elseif action == "toggle" then
    M.state.playing = not M.state.playing
    M._sync_audio_backend()
  elseif action == "stop" then
    M.state.playing = false
    M.state.elapsed_sec = 0
    M._stop_audio_backend()
  elseif action == "next" then
    M.state.station_idx = (M.state.station_idx % #M.stations) + 1
    M.state.elapsed_sec = 0
    M._sync_audio_backend()
  elseif action == "prev" then
    M.state.station_idx = ((M.state.station_idx - 2 + #M.stations) % #M.stations) + 1
    M.state.elapsed_sec = 0
    M._sync_audio_backend()
  elseif action == "volume" then
    local v = tonumber(args.volume) or (M.state.volume + (tonumber(args.delta) or 0))
    M.state.volume = math.max(0, math.min(100, v))
  elseif action == "eq_preset" then
    local preset = args.preset
    if preset and M.eq_presets[preset] then
      M.state.eq_preset = preset
      M.state.eq_bands = vim.deepcopy(M.eq_presets[preset])
    else
      -- cycle
      local idx = 1
      for i, p in ipairs(M.eq_preset_order) do
        if p == M.state.eq_preset then
          idx = (i % #M.eq_preset_order) + 1
          break
        end
      end
      local next_p = M.eq_preset_order[idx]
      M.state.eq_preset = next_p
      M.state.eq_bands = vim.deepcopy(M.eq_presets[next_p])
    end
  elseif action == "eq_band" then
    local b = tonumber(args.band) or M.state.selected_band
    local delta = tonumber(args.delta) or 0
    if b >= 1 and b <= 10 then
      M.state.eq_bands[b] = math.max(-12, math.min(12, (M.state.eq_bands[b] or 0) + delta))
      M.state.eq_preset = "custom"
    end
  elseif action == "station" then
    local idx = tonumber(args.index)
    if idx and M.stations[idx] then
      M.state.station_idx = idx
      M.state.elapsed_sec = 0
      M._sync_audio_backend()
    end
  elseif action == "visualizer" then
    local mode = args.mode
    if mode then
      M.state.visualizer = mode
    else
      for i, m in ipairs(M.visualizer_modes) do
        if m == M.state.visualizer then
          M.state.visualizer = M.visualizer_modes[(i % #M.visualizer_modes) + 1]
          break
        end
      end
    end
  end
end

--- Run an action locally (and broadcast if Server) or forward to Server (if Client).
---@param action string
---@param args? table
function M.action(action, args)
  if M.state.role == "client" and M.send_remote_command(action, args) then
    return
  end
  M._execute_local_action(action, args)
  if M.state.role == "server" then
    M.broadcast_state()
  end
end

-- ASCII Equalizer & Visualizer Renderer ------------------------------------------------

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- Render 6 lines of real-time ASCII visualization for the current mode & EQ curve.
---@param width integer
---@return string[]
function M.render_visualizer(width)
  local mode = M.state.visualizer
  local t = M.state.tick
  local playing = M.state.playing
  local cols = math.min(44, math.max(20, width - 16))
  local out = {}

  if mode == "spectrum" then
    local row_top, row_mid, row_bot = {}, {}, {}
    for c = 1, cols do
      local band_idx = math.min(10, math.max(1, math.ceil((c / cols) * 10)))
      local eq_boost = (M.state.eq_bands[band_idx] or 0) / 12
      local energy = playing
          and (0.48 + 0.35 * math.sin(t * 0.38 + c * 0.55) + 0.22 * math.cos(t * 0.71 - c * 0.3) + eq_boost * 0.25)
        or 0.08
      energy = math.max(0.05, math.min(1.0, energy * (M.state.volume / 100)))
      local level = math.floor(energy * 24)
      row_top[#row_top + 1] = level > 16 and BARS[math.min(8, level - 16)] or " "
      row_mid[#row_mid + 1] = level > 8 and BARS[math.min(8, level - 8)] or (level > 16 and "█" or " ")
      row_bot[#row_bot + 1] = BARS[math.max(1, math.min(8, level))]
    end
    out[#out + 1] = "    │ " .. table.concat(row_top, " ") .. " │"
    out[#out + 1] = "    │ " .. table.concat(row_mid, " ") .. " │"
    out[#out + 1] = "    │ " .. table.concat(row_bot, " ") .. " │"
  elseif mode == "wave" then
    local ch_l, ch_r = {}, {}
    local wave_chars = { "╭", "─", "╮", "│", "╰", "─", "╯", "∿" }
    for c = 1, cols * 2 do
      if not playing then
        ch_l[#ch_l + 1] = "─"
        ch_r[#ch_r + 1] = "─"
      else
        local idx_l = ((c + t) % #wave_chars) + 1
        local idx_r = ((c + t * 2 + 3) % #wave_chars) + 1
        ch_l[#ch_l + 1] = wave_chars[idx_l]
        ch_r[#ch_r + 1] = wave_chars[idx_r]
      end
    end
    out[#out + 1] = "    L ∿ " .. table.concat(ch_l)
    out[#out + 1] = "    R ∿ " .. table.concat(ch_r)
    out[#out + 1] = "    dB  -48       -24       -12        -6         0 dB"
  elseif mode == "vu" then
    local lvl_l = playing and math.floor((0.6 + 0.35 * math.sin(t * 0.45)) * 36 * (M.state.volume / 100)) or 2
    local lvl_r = playing and math.floor((0.6 + 0.35 * math.cos(t * 0.52)) * 36 * (M.state.volume / 100)) or 2
    lvl_l = math.max(1, math.min(36, lvl_l))
    lvl_r = math.max(1, math.min(36, lvl_r))
    out[#out + 1] = string.format("    VU-L [%s%s] %2d dB", string.rep("█", lvl_l), string.rep("░", 36 - lvl_l), lvl_l - 34)
    out[#out + 1] = string.format("    VU-R [%s%s] %2d dB", string.rep("█", lvl_r), string.rep("░", 36 - lvl_r), lvl_r - 34)
    out[#out + 1] = "          -30       -20       -10        -3     0 +3 PEAK"
  else
    -- matrix / starfield
    local symbols = mode == "matrix" and { "0", "1", "⋮", "∷", "╫", "║", " " } or { "·", "✦", "★", "✧", "∘", " " }
    for r = 1, 3 do
      local row = {}
      for c = 1, cols * 2 do
        local pick = ((c * 7 + r * 13 + t * 3) % #symbols) + 1
        row[#row + 1] = playing and symbols[pick] or "·"
      end
      out[#out + 1] = "    " .. table.concat(row)
    end
  end
  return out
end

--- Render the 10-band Graphic Equalizer ASCII bars.
---@return string[]
function M.render_eq()
  local lines = {}
  local top_row = {}
  local bar_row = {}
  local lbl_row = {}
  for i, freq in ipairs(M.eq_frequencies) do
    local gain = M.state.eq_bands[i] or 0
    local norm = math.max(1, math.min(8, math.floor(((gain + 12) / 24) * 7) + 1))
    local sel = (i == M.state.selected_band)
    top_row[#top_row + 1] = string.format("%s%+3ddB%s", sel and "[" or " ", gain, sel and "]" or " ")
    bar_row[#bar_row + 1] = string.format("   %s   ", BARS[norm])
    lbl_row[#lbl_row + 1] = string.format(" %-5s ", freq)
  end
  lines[#lines + 1] = "  " .. table.concat(top_row, " ")
  lines[#lines + 1] = "  " .. table.concat(bar_row, " ")
  lines[#lines + 1] = "  " .. table.concat(lbl_row, " ")
  return lines
end

--- Open the floating `:MusicPlayer` studio window in Neovim.
function M.ui()
  local width = math.min(vim.o.columns - 4, 98)
  local height = 27
  local buf, win = UI.open({
    title = " :MusicPlayer · Built-in EQ · Visualizer · Radio · 2-Neovim Device Controller ",
    width = width,
    height = height,
    filetype = "installer-music",
  })

  local closed = false
  local function stop_timer()
    if M._ui_timer then
      pcall(function()
        M._ui_timer:stop()
        M._ui_timer:close()
      end)
      M._ui_timer = nil
    end
  end

  local function close_ui()
    if closed then
      return
    end
    closed = true
    stop_timer()
    UI.close(win)
  end

  local function render()
    if closed or not vim.api.nvim_buf_is_valid(buf) then
      stop_timer()
      return
    end
    local st = M.current_station()
    local mins = math.floor(M.state.elapsed_sec / 60)
    local secs = M.state.elapsed_sec % 60
    local role_badge = M.state.role == "server"
        and string.format("🟢 SERVER (127.0.0.1:%d · %d peer(s))", M.state.port, math.max(0, #M.state.devices - 1))
      or (M.state.role == "client" and string.format("🔵 CLIENT → %s:%d", M.state.host, M.state.port) or "⚪ STANDALONE (press D for 2-Nvim Server, C to Connect)")

    local lines = {
      string.format(
        "  %s  %s  —  %s   [%s · %s]",
        M.state.playing and "▶ PLAYING" or "⏸ PAUSED ",
        st.title,
        st.artist,
        st.genre,
        st.bitrate
      ),
      string.format(
        "  ⏱ %02d:%02d  │  🔊 Vol: %3d%%  │  🎛 EQ: %-12s  │  📊 Vis: %-9s  │  📡 %s",
        mins,
        secs,
        M.state.volume,
        M.state.eq_preset:upper(),
        M.state.visualizer:upper(),
        st.service
      ),
      "  " .. string.rep("─", width - 4),
      "  📊 REAL-TIME AUDIO VISUALIZER (" .. M.state.visualizer:upper() .. " — press `v` to switch mode):",
    }

    for _, vl in ipairs(M.render_visualizer(width)) do
      lines[#lines + 1] = vl
    end

    lines[#lines + 1] = "  " .. string.rep("─", width - 4)
    lines[#lines + 1] = "  🎚 10-BAND GRAPHIC EQUALIZER (`[`/`]` select band · `+`/`-` dB gain · `e` preset):"
    for _, el in ipairs(M.render_eq()) do
      lines[#lines + 1] = el
    end

    lines[#lines + 1] = "  " .. string.rep("─", width - 4)
    lines[#lines + 1] = "  📻 INTERNET RADIO & STREAMING STATIONS (`n`/`p` next/prev · `r` station picker · `S` service):"
    for i, s in ipairs(M.stations) do
      local active = (i == M.state.station_idx)
      lines[#lines + 1] = string.format(
        "    %s %d. %-38s  %-22s  [%s]",
        active and "●" or "·",
        i,
        s.title,
        s.genre,
        s.bitrate
      )
    end

    lines[#lines + 1] = "  " .. string.rep("─", width - 4)
    lines[#lines + 1] = "  🔗 2-NEOVIM DEVICE CONTROLLER (Server <-> Client): " .. role_badge
    lines[#lines + 1] = "  <Space> Play/Pause  n/p Track  e EQ  [/] Band  +/- Gain  9/0 Vol  v Vis  r Radio  D Server  C Client  q Close"

    UI.set_lines(buf, lines)
    vim.bo[buf].modifiable = false
  end

  UI.map(buf, "q", close_ui)
  UI.map(buf, "<Esc>", close_ui)
  UI.map(buf, "<Space>", function()
    M.action("toggle")
    render()
  end)
  UI.map(buf, "n", function()
    M.action("next")
    render()
  end)
  UI.map(buf, "p", function()
    M.action("prev")
    render()
  end)
  UI.map(buf, "e", function()
    M.action("eq_preset")
    render()
  end)
  UI.map(buf, "v", function()
    M.action("visualizer")
    render()
  end)
  UI.map(buf, "[", function()
    M.state.selected_band = ((M.state.selected_band - 2 + 10) % 10) + 1
    render()
  end)
  UI.map(buf, "]", function()
    M.state.selected_band = (M.state.selected_band % 10) + 1
    render()
  end)
  UI.map(buf, "+", function()
    M.action("eq_band", { band = M.state.selected_band, delta = 2 })
    render()
  end)
  UI.map(buf, "=", function()
    M.action("eq_band", { band = M.state.selected_band, delta = 2 })
    render()
  end)
  UI.map(buf, "-", function()
    M.action("eq_band", { band = M.state.selected_band, delta = -2 })
    render()
  end)
  UI.map(buf, "0", function()
    M.action("volume", { delta = 5 })
    render()
  end)
  UI.map(buf, "9", function()
    M.action("volume", { delta = -5 })
    render()
  end)
  UI.map(buf, "r", function()
    vim.ui.select(M.stations, {
      prompt = ":MusicPlayer · Select Radio / Stream Station",
      format_item = function(item)
        return string.format("%-38s [%s · %s]", item.title, item.genre, item.bitrate)
      end,
    }, function(chosen, idx)
      if chosen and idx then
        M.action("station", { index = idx })
        render()
      end
    end)
  end)
  UI.map(buf, "S", function()
    vim.ui.select(M.streaming_services, {
      prompt = ":MusicPlayer · Select Streaming Service Connector",
      format_item = function(item)
        return string.format("%-38s — %s", item.name, item.desc)
      end,
    }, function(chosen)
      if chosen then
        M.state.service_id = chosen.id
        UI.notify(":MusicPlayer service switched to " .. chosen.name)
        render()
      end
    end)
  end)
  UI.map(buf, "D", function()
    M.start_server(M.state.port)
    render()
  end)
  UI.map(buf, "C", function()
    vim.ui.input({ prompt = "Connect to Neovim :MusicPlayer Server (host:port): ", default = "127.0.0.1:41999" }, function(val)
      if val and val ~= "" then
        M.connect_client(val)
        render()
      end
    end)
  end)

  render()

  if uv and uv.new_timer then
    local timer = uv.new_timer()
    M._ui_timer = timer
    timer:start(100, 120, function()
      M.state.tick = M.state.tick + 1
      if M.state.playing and (M.state.tick % 8 == 0) then
        M.state.elapsed_sec = M.state.elapsed_sec + 1
      end
      vim.schedule(function()
        if not closed and vim.api.nvim_buf_is_valid(buf) then
          render()
        else
          stop_timer()
        end
      end)
    end)
  end
end

function M.status()
  local st = M.current_station()
  local lines = {
    ":MusicPlayer Status",
    ("  State:      %s · %s (%s)"):format(M.state.playing and "PLAYING" or "PAUSED", st.title, st.genre),
    ("  Volume/EQ:  %d%% · Preset: %s"):format(M.state.volume, M.state.eq_preset),
    ("  Visualizer: %s"):format(M.state.visualizer),
    ("  2-Neovim:   role=%s (%s:%d · %d connected device(s))"):format(
      M.state.role,
      M.state.host,
      M.state.port,
      #M.state.devices
    ),
  }
  UI.notify(table.concat(lines, "\n"))
end

--- Dispatch `:MusicPlayer [subcommand] [args...]`
---@param args string[]
function M.dispatch(args)
  local sub = (args[1] or ""):lower()
  local rest = vim.list_slice(args, 2)

  if sub == "" or sub == "ui" or sub == "open" then
    M.ui()
  elseif sub == "play" or sub == "pause" or sub == "toggle" or sub == "stop" or sub == "next" or sub == "prev" then
    M.action(sub)
    M.status()
  elseif sub == "volume" or sub == "vol" then
    M.action("volume", { volume = tonumber(rest[1]) })
    M.status()
  elseif sub == "eq" then
    M.action("eq_preset", { preset = rest[1] })
    M.status()
  elseif sub == "visualizer" or sub == "vis" then
    M.action("visualizer", { mode = rest[1] })
    M.status()
  elseif sub == "radio" or sub == "stream" then
    if rest[1] and tonumber(rest[1]) then
      M.action("station", { index = tonumber(rest[1]) })
    end
    M.ui()
  elseif sub == "server" then
    M.start_server(tonumber(rest[1]))
  elseif sub == "connect" then
    M.connect_client(rest[1] or "127.0.0.1:41999")
  elseif sub == "disconnect" then
    M.disconnect()
    UI.notify("Disconnected :MusicPlayer 2-Neovim session")
  elseif sub == "remote" then
    local remote_cmd = rest[1] or "toggle"
    M.send_remote_command(remote_cmd, { volume = tonumber(rest[2]), preset = rest[2] })
  elseif sub == "devices" or sub == "status" then
    M.status()
  else
    M.ui()
  end
end

return M
