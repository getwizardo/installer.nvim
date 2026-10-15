-- kaeru.nvim · :Kikru — a Winamp-style terminal player for Neovim.
--
--   :Kikru                     open the player (Winamp-style float)
--   :Kikru play <path|url|q>   resolve any source and start playing
--   :Kikru radio <query>       browse/search 30k+ Radio Browser stations
--   :Kikru eq synthwave        ​10-band EQ presets & per-band gains
--   :Kikru filter nightcore    NodeLink/LavaLink effect filters
--   :Kikru server 41999        Neovim #1: own the audio output
--   :Kikru connect :41999      Neovim #2: mirror state & forward commands
--
-- Design notes
--   * Engine first: mpv's JSON IPC provides real position/duration/metadata and
--     a live `af` chain, which is how the 10-band EQ and the NodeLink style
--     filters are applied for real (no fake UI state).
--   * Sources follow the NodeLink/LavaLink model (`ytsearch:`, `scsearch:`,
--     `spsearch:`, `dzsearch:`, `amsearch:`, plain URLs, local paths, PLS/M3U,
--     RSS podcasts, Subsonic/Navidrome, Radio Browser, MPD, MPRIS).
--   * Everything is resilient: no engine, no network and no curl each degrade
--     to a clearly labelled reduced mode instead of an error.
local Config = require("kaeru.config")
local UI = require("kaeru.ui")
local Tags = require("kaeru.kikru.tags")
local Filters = require("kaeru.kikru.filters")
local Playlist = require("kaeru.kikru.playlist")
local Sources = require("kaeru.kikru.sources")
local Radio = require("kaeru.kikru.radio")
local Backend = require("kaeru.kikru.backend")
local Visualizer = require("kaeru.kikru.visualizer")
local Cast = require("kaeru.kikru.cast")
local Daemon = require("kaeru.kikru.daemon")
local Lyrics = require("kaeru.kikru.lyrics")
local Compat = require("kaeru.compat")

local M = {}

local uv = vim.uv or vim.loop

--- Schedule `fn` (falls back to running it immediately in plain Lua).
---@param fn fun()
---@param ms integer
local function defer(fn, ms)
  if vim.defer_fn then
    return vim.defer_fn(fn, ms)
  end
  return fn()
end

-- Legacy/compat surface ------------------------------------------------------------

M.eq_frequencies = Filters.frequency_labels
M.eq_presets = Filters.presets
M.eq_preset_order = Filters.preset_order
M.visualizer_modes = Visualizer.modes
M.stations = Radio.stations
M.streaming_services = {
  { id = "radio", name = "Internet Radio (SomaFM · Radio Browser)", status = "active", desc = "Icecast/HLS streams, 30k+ stations via the Radio Browser directory" },
  { id = "spotify", name = "Spotify (librespot / playerctl MPRIS)", status = "ready", desc = "Controls a running Spotify Connect session over MPRIS" },
  { id = "youtube", name = "YouTube & YouTube Kikru (yt-dlp)", status = "ready", desc = "Search and stream with yt-dlp; `ytmsearch:` also works" },
  { id = "soundcloud", name = "SoundCloud (yt-dlp)", status = "ready", desc = "Streams sets and tracks via `scsearch:`" },
  { id = "subsonic", name = "Subsonic / Navidrome", status = "ready", desc = "Self-hosted streaming with the Subsonic REST API" },
  { id = "mpd", name = "MPD (mpc)", status = "ready", desc = "Local or remote Kikru Player Daemon" },
  { id = "rss", name = "Podcasts (RSS/Atom)", status = "ready", desc = "Enclosure URLs are turned into a queue" },
}

--- Every streaming source the player can talk to, as plain ids (1.x API).
M.streaming_service_ids = { "spotify", "youtube", "youtube_music", "soundcloud", "bandcamp", "mixcloud", "bilibili", "apple", "deezer", "tidal", "radio", "subsonic", "mpd", "rss" }
M.streaming_services_pending = { "apple", "deezer", "tidal" }

-- State ------------------------------------------------------------------------------

---@class MusicPlayerState
M.state = {
  playing = false,
  paused = true,
  muted = false,
  volume = 78,
  shuffle = false,
  repeat_mode = "all",
  eq_preset = "lofi-coding",
  eq_bands = Filters.preset_bands("lofi-coding"),
  preamp = 0,
  selected_band = 1,
  filters = {},
  visualizer = "spectrum",
  theme = "winamp",
  service_id = "radio",
  station_idx = 1,
  tick = 0,
  elapsed_sec = 0,
  index = 0,
  role = "none",
  host = "127.0.0.1",
  port = 41999,
  device_id = nil,
  devices = {},
  active_device = nil,
  engine = "auto",
  rev = 0,
}

M.playlist = Playlist.new({}, "queue")
M._initialized = false
M._lyrics = nil
M._lyrics_key = nil
M._radio_results = {}
M._radio_query = ""
M._search_results = {}
M._search_query = ""
M._search_source = "auto"
M._started_at = uv and uv.hrtime and uv.hrtime() / 1e9 or os.clock()
M._backend_unsubscribe = nil
M._state_path = nil
M._save_pending = false

---@return string
function M.state_path()
  if M._state_path then
    return M._state_path
  end
  local base = vim.fn.stdpath("state")
  if not base or base == "" then
    base = vim.fn.stdpath("data")
  end
  M._state_path = base .. "/kaeru/kikru.json"
  return M._state_path
end

---@return table
function M.kikru_config()
  return (Config.options and Config.options.music) or {}
end

---@return number
function M.clock()
  if vim.uv and vim.uv.hrtime then
    return vim.uv.hrtime() / 1e9
  end
  return os.clock()
end

--- Stable per-track seed so the same song always "looks" the same.
---@return number
function M.track_seed()
  local track = M.current_track()
  local key = track and (track.path or track.title or "") or "silence"
  local hash = 0
  for i = 1, #key do
    hash = (hash * 31 + key:byte(i)) % 1000003
  end
  return hash
end

-- Initialisation ----------------------------------------------------------------------

--- Prepare state/queue/backend wiring exactly once.
function M.setup()
  if M._initialized then
    return M
  end
  M._initialized = true
  local music = M.kikru_config()

  M.state.volume = tonumber(music.volume) or M.state.volume
  M.state.visualizer = music.visualizer or M.state.visualizer
  M.state.theme = music.theme or M.state.theme
  M.state.repeat_mode = music.repeat_mode or M.state.repeat_mode
  M.state.engine = music.engine or "auto"
  M.state.device_id = ("nvim-%s"):format(tostring(uv and uv.os_getpid and uv.os_getpid() or math.random(1000, 9999)))

  local preset = music.eq_preset or M.state.eq_preset
  local bands = Filters.preset_bands(preset)
  if bands then
    M.state.eq_preset = preset
    M.state.eq_bands = bands
  end

  M.restore_state()
  M._backend_unsubscribe = Backend.on_event(function(event, data)
    M.on_backend_event(event, data)
  end)

  Daemon.set_handlers({
    snapshot = M.get_snapshot,
    dispatch = function(action, args, origin)
      M.action(action, args, origin)
      return { ok = true }
    end,
    apply_state = M.apply_snapshot,
    handoff = function(device_id)
      M.set_active_device(device_id)
    end,
    on_connect = function(host, port)
      M.state.host, M.state.port = host, port
      M.state.role = "client"
      UI.notify((":Kikru connected to the Neovim server at %s:%d"):format(host, port))
    end,
    on_error = function(message)
      UI.notify(message, vim.log.levels.WARN)
    end,
  })

  if music.daemon_on_start then
    M.start_ipc()
  end
  return M
end

---@return boolean
function M.ensure()
  M.setup()
  return true
end

-- Backend events ---------------------------------------------------------------------

---@param event string
---@param data any
function M.on_backend_event(event, data)
  if event == "position" then
    M.state.elapsed_sec = tonumber(data) or M.state.elapsed_sec
  elseif event == "end-file" then
    local reason = type(data) == "table" and data.reason or tostring(data)
    if reason == "eof" or reason == nil then
      M.auto_advance()
    elseif reason == "error" then
      M.playback_error("playback failed — trying the next track")
    end
  elseif event == "eof" then
    M.auto_advance()
  elseif event == "file-loaded" or event == "metadata" then
    M.state.playing = true
    M.state.paused = false
    M.bump()
  elseif event == "exit" then
    M.state.playing = false
  end
end

--- Advance the queue because a track ended.
function M.auto_advance()
  if #M.playlist.items == 0 then
    return
  end
  local track, index, stopped = Playlist.next(M.playlist, { auto = true })
  if stopped or not track then
    M.state.playing = false
    M.state.paused = true
    M.bump()
    return
  end
  M.state.index = index or M.playlist.index
  M.play(track, { autoplay = true, remember = false })
end

--- Playback failed: skip to the next entry (cliamp behaves the same way).
---@param message string
function M.playback_error(message)
  UI.notify(":Kikru · " .. message, vim.log.levels.WARN)
  if #M.playlist.items > 1 then
    M.auto_advance()
  else
    M.state.playing = false
    M.state.paused = true
    M.bump()
  end
end

-- State persistence --------------------------------------------------------------------

--- Save volume/EQ/filters/queue so a restart continues where it stopped.
function M.save_state()
  local music = M.kikru_config()
  if music.persist == false then
    return
  end
  local path = M.state_path()
  Playlist.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local data = {
    version = 1,
    volume = M.state.volume,
    muted = M.state.muted,
    eq_preset = M.state.eq_preset,
    eq_bands = M.state.eq_bands,
    preamp = M.state.preamp,
    filters = M.state.filters,
    visualizer = M.state.visualizer,
    theme = M.state.theme,
    repeat_mode = M.state.repeat_mode,
    shuffle = M.state.shuffle,
    index = M.playlist.index,
    playlist_name = M.playlist.name,
    tracks = M.playlist.items,
  }
  local ok, text = pcall(require("kaeru.json").encode, data)
  if not ok then
    return
  end
  local fd = io.open(path, "w")
  if not fd then
    return
  end
  fd:write(text)
  fd:close()
end

--- Debounced persistence (queue edits, volume sweeps, …).
function M.save_state_soon()
  if M._save_pending then
    return
  end
  M._save_pending = true
  defer(function()
    M._save_pending = false
    M.save_state()
  end, 1500)
end

---@return boolean restored
function M.restore_state()
  local fd = io.open(M.state_path(), "r")
  if not fd then
    return false
  end
  local text = fd:read("*a")
  fd:close()
  local data = require("kaeru.json").decode(text)
  if type(data) ~= "table" then
    return false
  end
  M.state.volume = tonumber(data.volume) or M.state.volume
  M.state.muted = data.muted == true
  M.state.eq_preset = data.eq_preset or M.state.eq_preset
  if type(data.eq_bands) == "table" and #data.eq_bands == 10 then
    M.state.eq_bands = data.eq_bands
  end
  M.state.preamp = tonumber(data.preamp) or 0
  M.state.filters = (type(data.filters) == "table") and data.filters or {}
  M.state.visualizer = data.visualizer or M.state.visualizer
  M.state.theme = data.theme or M.state.theme
  M.state.repeat_mode = data.repeat_mode or M.state.repeat_mode
  M.state.shuffle = data.shuffle == true
  if type(data.tracks) == "table" and #data.tracks > 0 then
    M.playlist = Playlist.new({}, data.playlist_name or "queue")
    for _, track in ipairs(data.tracks) do
      if type(track) == "table" then
        Playlist.add(M.playlist, Tags.normalize(track))
      end
    end
    M.playlist.index = math.min(math.max(1, tonumber(data.index) or 1), math.max(1, #M.playlist.items))
    M.playlist.shuffle = M.state.shuffle
    M.state.index = M.playlist.index
  end
  return true
end

--- Clear the persisted queue too (`:Kikru reset`).
function M.reset_state()
  pcall(vim.fn.delete, M.state_path())
  M.playlist = Playlist.new({}, "queue")
  M.state.index = 0
end

-- Snapshot / remote state ----------------------------------------------------------------

--- Everything the UI, the 2-Neovim peers and the Starsky web client need.
---@return table
function M.get_snapshot()
  local track = M.visible_track() or M.current_track()
  local backend = Backend.snapshot()
  M.state.rev = (M.state.rev or 0) + 1
  local items = {}
  for i, item in ipairs(M.playlist.items) do
    if i > 500 then
      break
    end
    items[#items + 1] = {
      path = item.path,
      url = item.url,
      title = item.title,
      artist = item.artist,
      album = item.album,
      duration = item.duration,
      source = item.source,
      format = item.format,
      station_id = item.station_id,
    }
  end
  return {
    rev = M.state.rev,
    playing = M.state.playing and not M.state.paused,
    paused = M.state.paused,
    muted = M.state.muted,
    volume = M.state.volume,
    position = backend.position,
    duration = backend.duration or (track and track.duration) or 0,
    engine = backend.engine,
    eq_preset = M.state.eq_preset,
    eq_bands = M.state.eq_bands,
    preamp = M.state.preamp,
    selected_band = M.state.selected_band,
    filters = M.state.filters,
    visualizer = M.state.visualizer,
    theme = M.state.theme,
    shuffle = M.state.shuffle,
    repeat_mode = M.state.repeat_mode,
    station_idx = M.state.station_idx,
    service_id = M.state.service_id,
    index = M.playlist.index,
    queue_size = #M.playlist.items,
    queue = items,
    track = track and {
      title = track.title,
      artist = track.artist,
      album = track.album,
      duration = track.duration,
      path = track.path,
      url = track.url or track.path,
      stream_url = track.stream_url,
      source = track.source,
      station_id = track.station_id,
      genre = track.genre,
    } or nil,
    role = Daemon.role ~= "none" and Daemon.role or M.state.role,
    host = M.state.host,
    port = M.state.port,
    session = Daemon.session,
    device_id = Daemon.device_id(),
    devices = Daemon.device_list(),
    active_device = M.state.active_device,
    capabilities = Backend.can("eq") and { eq = true, filters = Backend.can("filters"), seek = Backend.can("seek"), position = Backend.can("position") } or { eq = false },
    ts = os.time(),
  }
end

--- Apply a snapshot received from the server (client side) or the web API.
---@param snap table
---@param rev? number
function M.apply_snapshot(snap, rev)
  if type(snap) ~= "table" then
    return
  end
  if rev and M.state.rev and rev < M.state.rev then
    return -- stale update, ignore
  end
  M.state.rev = rev or snap.rev or (M.state.rev or 0) + 1
  for _, key in ipairs({ "playing", "paused", "muted", "volume", "eq_preset", "preamp", "selected_band", "visualizer", "theme", "shuffle", "repeat_mode", "station_idx", "service_id", "index", "host", "port", "active_device" }) do
    if snap[key] ~= nil then
      M.state[key] = snap[key]
    end
  end
  if type(snap.eq_bands) == "table" and #snap.eq_bands == 10 then
    M.state.eq_bands = snap.eq_bands
  end
  if type(snap.filters) == "table" then
    M.state.filters = snap.filters
  end
  if type(snap.devices) == "table" then
    M.state.devices = snap.devices
  end
  if type(snap.queue) == "table" and #snap.queue > 0 and #snap.queue ~= #M.playlist.items then
    local items = {}
    for _, item in ipairs(snap.queue) do
      items[#items + 1] = Tags.normalize(item)
    end
    M.playlist.items = items
    M.playlist.index = math.min(math.max(1, tonumber(snap.index) or 1), #items)
  end
  if snap.track then
    M.state.remote_track = snap.track
  end
  M.state.playing = snap.playing == true and snap.paused ~= true
  M.state.paused = snap.paused == true
  M.bump()
end

--- Broadcast state to peers (server) — throttled.
function M.broadcast_state()
  Daemon.schedule_broadcast()
end

---@param action string
---@param args? table
---@return boolean
function M.send_remote_command(action, args)
  return Daemon.send_command(action, args)
end

--- Notify UI + peers that something changed.
function M.bump()
  M.state.elapsed_sec = Backend.snapshot().position or M.state.elapsed_sec
  M.save_state_soon()
  if Daemon.role == "server" then
    Daemon.schedule_broadcast()
  end
  local ui = require("kaeru.kikru.ui")
  if ui.is_open() then
    ui.render()
  end
end

-- Queue helpers ---------------------------------------------------------------------------

---@return MusicTagTrack|nil
function M.current_track()
  return Playlist.current(M.playlist) or M.state.remote_track
end

--- The track the UI shows (respects the queue filter).
---@return MusicTagTrack|nil
function M.visible_track()
  local track = M.current_track()
  return track
end

---@return MusicTagTrack[]
function M.filtered_items()
  local ui = require("kaeru.kikru.ui")
  local filter = (ui.state.filter or ""):lower()
  if filter == "" then
    return M.playlist.items
  end
  local out = {}
  for _, item in ipairs(M.playlist.items) do
    local haystack = ((item.title or "") .. " " .. (item.artist or "") .. " " .. (item.album or "") .. " " .. (item.path or "")):lower()
    if haystack:find(filter, 1, true) then
      out[#out + 1] = item
    end
  end
  return out
end

--- Items the UI currently lists (queue / radio / search / devices).
---@return table[]
function M.visible_items()
  local ui = require("kaeru.kikru.ui")
  local view = ui.state.view
  if view == "radio" then
    if #M._radio_results > 0 then
      return M._radio_results
    end
    return Radio.stations
  elseif view == "search" then
    return M._search_results
  elseif view == "devices" then
    return Daemon.device_list()
  end
  return M.filtered_items()
end

---@param tracks MusicTagTrack[]|table[]
---@param opts? {play?: boolean, replace?: boolean}
function M.enqueue(tracks, opts)
  opts = opts or {}
  if opts.replace then
    Playlist.clear(M.playlist)
  end
  local first = #M.playlist.items + 1
  Playlist.extend(M.playlist, tracks)
  if opts.play ~= false then
    M.play_playlist_index(first)
  end
  M.bump()
  return #tracks
end

---@param index integer
---@param opts? {autoplay?: boolean}
function M.play_playlist_index(index, opts)
  opts = opts or {}
  local track = Playlist.set_index(M.playlist, index)
  if track then
    M.play(track, { autoplay = opts.autoplay ~= false })
  end
end

--- Resolve a station/track and start playing it.
---@param track MusicTagTrack
---@param opts? {autoplay?: boolean, remember?: boolean, fallback_index?: integer}
function M.play(track, opts)
  opts = opts or {}
  if not track then
    return
  end
  Backend.remember_track(track)
  M.state.paused = false
  M.state.playing = true
  M._lyrics = nil
  M._lyrics_key = nil

  local url = track.stream_url or track.url or track.path
  -- yt-dlp sources: resolve the direct stream URL first (keeps metadata intact).
  local needs_resolution = track.source and track.source ~= "radio"
    and track.source ~= "local_file"
    and track.source ~= "http"
    and track.source ~= "subsonic"
    and Sources.is_url(url or "")
    and not (track.stream_url and track.stream_url ~= track.url)
  if needs_resolution and (url or ""):match("^https?://") and not Sources.is_url(url or "") then
    needs_resolution = false
  end

  local function start(resolved_url)
    local playable = vim.deepcopy(track)
    if resolved_url then
      playable.stream_url = resolved_url
    end
    Backend.load(playable, {
      autoplay = opts.autoplay ~= false,
      bands = M.state.eq_bands,
      filters = M.state.filters,
      preamp = M.state.preamp,
    }, function(ok, err)
      if not ok and err then
        M.playback_error(err)
      end
    end)
    M.bump()
  end

  if needs_resolution and Sources.ytdlp_available() and not (track.stream_url and track.stream_url ~= "") then
    Sources.ytdlp_stream_url(url, function(err, direct)
      start(err and url or direct)
    end)
  else
    start(nil)
  end
end

-- Actions ---------------------------------------------------------------------------------

local eq_band_count = #Filters.frequencies

--- Handle every player action; returns `true` when the action is known.
---@param name string
---@param args? table
---@param origin? table
---@return boolean
function M.action(name, args, origin)
  M.ensure()
  args = args or {}
  local track = M.current_track()

  -- While connected as a 2-Neovim client, playback commands belong to the server.
  if Daemon.role == "client" and not (origin and origin.remote) and M.client_actions[name] then
    if Daemon.send_command(name, args) then
      M.bump()
      return true
    end
  end

  if name == "play" then
    if args.station then
      local station = Radio.find(args.station)
      if station then
        return M.play_station(station)
      end
      return M.resolve_and_play(tostring(args.station), args)
    end
    if args.query or args.path or args.url then
      return M.resolve_and_play(args.query or args.path or args.url, args)
    end
    M.state.playing = true
    M.state.paused = false
    Backend.resume()
  elseif name == "pause" then
    M.state.paused = true
    Backend.pause()
  elseif name == "toggle" then
    if M.state.playing and not M.state.paused then
      M.state.paused = true
      Backend.pause()
    else
      M.state.paused = false
      M.state.playing = true
      if track and not Backend.running() then
        M.play(track, { autoplay = true })
      else
        Backend.resume()
      end
    end
  elseif name == "stop" then
    M.state.playing = false
    M.state.paused = true
    Backend.stop_playback()
  elseif name == "next" then
    local next_track, index, stopped = Playlist.next(M.playlist, {})
    if stopped or not next_track then
      UI.notify(":Kikru · end of the queue", vim.log.levels.INFO)
    else
      M.state.index = index
      M.play(next_track, { autoplay = true })
    end
  elseif name == "prev" then
    local previous = Playlist.prev(M.playlist)
    if previous then
      M.play(previous, { autoplay = true })
    end
  elseif name == "select" or name == "play_index" then
    M.play_playlist_index(tonumber(args.index) or 1, args)
  elseif name == "seek" then
    Backend.seek(tonumber(args.seconds) or tonumber(args.value) or 0)
  elseif name == "seek_relative" then
    Backend.seek_relative(tonumber(args.delta) or 0)
  elseif name == "volume" then
    local volume = tonumber(args.volume) or (M.state.volume + (tonumber(args.delta) or 0))
    M.state.volume = math.max(0, math.min(130, volume))
    Backend.set_volume(M.state.volume)
  elseif name == "mute" then
    M.state.muted = args.value ~= nil and args.value == true or not M.state.muted
    Backend.set_mute(M.state.muted)
  elseif name == "speed" then
    Backend.set_speed(tonumber(args.value) or tonumber(args.speed) or 1)
  elseif name == "eq_preset" then
    local preset = args.preset
    if preset and Filters.presets[preset] then
      M.state.eq_preset = preset
      M.state.eq_bands = Filters.preset_bands(preset)
    else
      local at = 1
      for i, candidate in ipairs(Filters.preset_order) do
        if candidate == M.state.eq_preset then
          at = i
          break
        end
      end
      local next_preset = Filters.preset_order[(at % #Filters.preset_order) + 1]
      M.state.eq_preset = next_preset
      M.state.eq_bands = Filters.preset_bands(next_preset)
    end
    M.sync_filters()
  elseif name == "eq_band" then
    local band = tonumber(args.band) or M.state.selected_band
    if band >= 1 and band <= eq_band_count then
      Filters.adjust_band(M.state.eq_bands, band, tonumber(args.delta) or 0)
      M.state.eq_preset = Filters.preset_for(M.state.eq_bands) or "custom"
      M.sync_filters()
    end
  elseif name == "eq_band_set" then
    local band = tonumber(args.band) or M.state.selected_band
    if band >= 1 and band <= eq_band_count then
      M.state.eq_bands[band] = math.max(Filters.min_gain, math.min(Filters.max_gain, tonumber(args.gain) or 0))
      M.state.eq_preset = Filters.preset_for(M.state.eq_bands) or "custom"
      M.sync_filters()
    end
  elseif name == "eq_band_select" then
    local delta = tonumber(args.delta) or 0
    M.state.selected_band = math.max(1, math.min(eq_band_count, (M.state.selected_band or 1) + delta))
  elseif name == "preamp" then
    M.state.preamp = math.max(-12, math.min(12, (M.state.preamp or 0) + (tonumber(args.delta) or 0)))
    M.sync_filters()
  elseif name == "filter_preset" then
    if args.preset and args.preset ~= "" then
      local spec, err = Filters.apply_effect_preset(M.state, args.preset)
      if err then
        UI.notify(":Kikru · " .. err, vim.log.levels.WARN)
      end
      M.state.filters = spec
    else
      -- cycle through the effect presets
      local names = {}
      for key in pairs(Filters.effect_presets) do
        names[#names + 1] = key
      end
      table.sort(names)
      local current = Filters.describe(M.state.filters)
      local at = 0
      for i, key in ipairs(names) do
        if current:find(key, 1, true) then
          at = i
          break
        end
      end
      local next_key = names[(at % #names) + 1]
      M.state.filters = Filters.apply_effect_preset(M.state, next_key)
    end
    M.sync_filters()
  elseif name == "filter_clear" then
    Filters.clear(M.state, args.name)
    M.sync_filters()
  elseif name == "filter_set" then
    local spec = Filters.normalize_spec(args.spec or args)
    M.state.filters = Compat.tbl_deep_extend("force", M.state.filters or {}, spec)
    M.sync_filters()
  elseif name == "visualizer" then
    local mode = args.mode
    if mode and Compat.tbl_contains(Visualizer.modes, mode) then
      M.state.visualizer = mode
    else
      local at = 1
      for i, candidate in ipairs(Visualizer.modes) do
        if candidate == M.state.visualizer then
          at = i
          break
        end
      end
      M.state.visualizer = Visualizer.modes[(at % #Visualizer.modes) + 1]
    end
  elseif name == "theme" then
    require("kaeru.kikru.ui").set_theme(args.name)
    M.state.theme = require("kaeru.kikru.ui").state.theme
  elseif name == "shuffle" then
    Playlist.set_shuffle(M.playlist, args.value)
    M.state.shuffle = M.playlist.shuffle
  elseif name == "repeat" then
    local modes = { "off", "one", "all" }
    if args.mode and Compat.tbl_contains(modes, args.mode) then
      M.state.repeat_mode = args.mode
    else
      local at = 1
      for i, mode in ipairs(modes) do
        if mode == M.state.repeat_mode then
          at = i
          break
        end
      end
      M.state.repeat_mode = modes[(at % #modes) + 1]
    end
    M.playlist.repeat_mode = M.state.repeat_mode
  elseif name == "queue_add" or name == "add" then
    local query = args.query or args.path or args.url
    if not query or query == "" then
      return true
    end
    local immediate = Sources.resolve_local(query)
    if immediate then
      M.enqueue(immediate.tracks, { play = args.play == true })
    else
      Sources.resolve(query, { limit = args.limit or 1 }, function(err, result)
        if err or not result then
          UI.notify(":Kikru · " .. (err or "nothing found for " .. query), vim.log.levels.WARN)
          return
        end
        M.enqueue(result.tracks, { play = args.play ~= false })
      end)
    end
  elseif name == "queue_add_dir" or name == "index_dir" then
    if args.path and args.path ~= "" then
      local tracks = Playlist.scan_tracks(args.path, { ignore = M.kikru_config().ignore })
      if #tracks == 0 then
        UI.notify(":Kikru · no audio files in " .. args.path, vim.log.levels.WARN)
      else
        M.enqueue(tracks, { play = args.play == true })
        UI.notify((":Kikru · indexed %d track(s) from %s"):format(#tracks, args.path))
      end
    end
  elseif name == "queue_remove" then
    local index = tonumber(args.index) or M.playlist.index
    local removed = Playlist.remove(M.playlist, index)
    if removed then
      UI.notify(":Kikru · removed " .. Tags.label(removed))
    end
  elseif name == "queue_clear" then
    Playlist.clear(M.playlist)
  elseif name == "queue_move" then
    Playlist.move(M.playlist, tonumber(args.from) or 0, tonumber(args.to) or 0)
  elseif name == "playlist_save" then
    local path = args.path
    if not path or path == "" then
      path = Playlist.default_dir() .. "/queue.m3u"
    end
    local ok, message = Playlist.save(M.playlist, path, args.format)
    UI.notify(":Kikru · " .. (ok and ("saved " .. message) or message), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  elseif name == "playlist_load" then
    if not args.path or args.path == "" then
      return true
    end
    local playlist, err = Playlist.load(args.path, { resolve = Tags.read })
    if not playlist then
      UI.notify(":Kikru · " .. tostring(err), vim.log.levels.ERROR)
      return true
    end
    M.playlist = playlist
    M.state.index = playlist.index
    Playlist.set_shuffle(M.playlist, M.state.shuffle)
    M.playlist.repeat_mode = M.state.repeat_mode
    if args.play ~= false then
      M.play_playlist_index(playlist.index > 0 and playlist.index or 1)
    end
  elseif name == "radio_search" then
    M.radio_search(args.query or "")
  elseif name == "radio_curated" then
    M._radio_results = Radio.stations
    M._radio_query = "curated"
    require("kaeru.kikru.ui").set_view("radio")
  elseif name == "radio_play" then
    local station
    if args.index then
      station = M._radio_results[tonumber(args.index) or 1]
    elseif args.id then
      station = Radio.by_id(args.id)
    end
    if station then
      M.play_station(station)
    end
  elseif name == "station" then
    if args.id then
      local station = Radio.by_id(args.id)
      if station then
        M.play_station(station)
      end
    elseif args.index then
      local station = Radio.stations[tonumber(args.index) or 1]
      if station then
        M.state.station_idx = tonumber(args.index)
        M.play_station(station)
      end
    end
  elseif name == "search" then
    M.search(args.query or "", args.source)
  elseif name == "search_play" then
    local track = M._search_results[tonumber(args.index) or 1]
    if track then
      M.enqueue({ track }, { play = true, replace = args.replace == true })
    end
  elseif name == "search_source" then
    M._search_source = args.source or "auto"
  elseif name == "lyrics_fetch" then
    M.fetch_lyrics(true)
  elseif name == "engine" then
    M.state.engine = args.id or "auto"
    Config.options.music = Config.options.music or {}
    Config.options.music.engine = M.state.engine
    if Backend.running() then
      Backend.stop()
      local current = M.current_track()
      if current then
        M.play(current, { autoplay = false })
      end
    end
  elseif name == "handoff" then
    local device_id = args.device_id
    if not device_id and args.index then
      local device = Daemon.device_list()[tonumber(args.index) or 1]
      device_id = device and device.id
    end
    if device_id then
      M.set_active_device(device_id)
    end
  elseif name == "disconnect" then
    M.disconnect()
  elseif name == "ipc_toggle" then
    if Daemon.ipc_server then
      Daemon.stop_ipc()
      UI.notify(":Kikru IPC daemon stopped")
    else
      local ok, message = M.start_ipc()
      UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
  elseif name == "reset" then
    M.reset_state()
    M.playlist = Playlist.new({}, "queue")
    M.state.volume = 78
    M.state.eq_preset = "lofi-coding"
    M.state.eq_bands = Filters.preset_bands("lofi-coding")
    M.state.filters = {}
    M.sync_filters()
  else
    return false
  end
  M.bump()
  return true
end

--- Actions forwarded to the server while connected as a 2-Neovim client.
M.client_actions = {
  play = true, pause = true, toggle = true, stop = true, next = true, prev = true,
  select = true, seek = true, seek_relative = true, volume = true, mute = true, speed = true,
  eq_preset = true, eq_band = true, eq_band_set = true, filter_preset = true, filter_clear = true,
  filter_set = true, station = true, radio_play = true, queue_add = true, search_play = true,
}

--- Push EQ/filters to the engine.
function M.sync_filters()
  Backend.sync_filters({
    bands = M.state.eq_bands,
    filters = M.state.filters,
    preamp = M.state.preamp,
    volume = M.state.volume,
  })
end

---@param device_id string
function M.set_active_device(device_id)
  M.state.active_device = device_id
  for _, device in ipairs(Daemon.device_list()) do
    device.active = device.id == device_id
  end
  UI.notify(":Kikru · audio output routed to " .. tostring(device_id))
  M.bump()
end

-- Radio / search --------------------------------------------------------------------------

---@param station MusicStation
function M.play_station(station)
  if not station then
    return
  end
  local track = Radio.to_track(station)
  M.state.station = station
  for index, known in ipairs(Radio.stations) do
    if known.id == station.id then
      M.state.station_idx = index
      break
    end
  end
  Playlist.add(M.playlist, track)
  Playlist.set_index(M.playlist, #M.playlist.items)
  M.play(track, { autoplay = true })
  UI.notify(":Kikru · " .. (station.title or station.id))
end

---@param query string
function M.radio_search(query)
  M._radio_query = query or ""
  if Compat.trim(query or "") == "" then
    M._radio_results = Radio.stations
    M.bump()
    return
  end
  if not Sources.have("curl") then
    M._radio_results = Radio.search_local(query)
    M.bump()
    return
  end
  Radio.search(query, { limit = 30 }, function(err, stations)
    M._radio_results = stations or {}
    if err then
      UI.notify(":Kikru radio · " .. err, vim.log.levels.WARN)
    end
    if #M._radio_results == 0 then
      M._radio_results = Radio.search_local(query)
    end
    M.bump()
  end)
end

---@param query string
---@param source? string
function M.search(query, source)
  M._search_query = query or ""
  if source and source ~= "" then
    M._search_source = source
  end
  local chosen = M._search_source ~= "auto" and M._search_source or nil
  if chosen == "radio" then
    return M.radio_search(query)
  end
  if chosen == "subsonic" then
    Sources.subsonic_search(query, function(err, tracks)
      M._search_results = tracks or {}
      if err then
        UI.notify(":Kikru · " .. err, vim.log.levels.WARN)
      end
      M.bump()
    end)
    return
  end
  local immediate = Sources.resolve_local(query or "")
  if immediate then
    M._search_results = immediate.tracks
    M.bump()
    return
  end
  Sources.search(query or "", { limit = 25, source = chosen }, function(err, result)
    M._search_results = (result and result.tracks) or {}
    if err then
      UI.notify(":Kikru · " .. err, vim.log.levels.WARN)
    end
    M.bump()
  end)
end

--- Resolve anything and play it (`:Kikru play <what>`).
---@param query string
---@param opts? {play?: boolean, replace?: boolean}
function M.resolve_and_play(query, opts)
  opts = opts or {}
  if not query or Compat.trim(query) == "" then
    UI.notify(":Kikru · nothing to play", vim.log.levels.WARN)
    return false
  end
  local immediate = Sources.resolve_local(query)
  if immediate then
    M.enqueue(immediate.tracks, { play = true, replace = opts.replace == true })
    return true
  end
  UI.notify(":Kikru · resolving " .. query .. "…")
  Sources.resolve(query, { limit = opts.limit or 1 }, function(err, result)
    if err or not result then
      UI.notify(":Kikru · " .. (err or "no results"), vim.log.levels.ERROR)
      return
    end
    if result.kind == "player" and result.source == "mpd" then
      M.state.service_id = "mpd"
      Backend.engine = "mpd"
      Backend.load(Tags.normalize({ path = result.query, url = result.query, format = "mpd" }), { autoplay = true })
      return
    end
    M.enqueue(result.tracks, { play = true, replace = opts.replace == true })
  end)
  return true
end

-- Lyrics ---------------------------------------------------------------------------------

--- Fetch the lyrics of the current track (tags → .lrc → LRCLIB).
---@param remote? boolean
function M.fetch_lyrics(remote)
  local track = M.current_track()
  if not track then
    return nil
  end
  local key = tostring(track.path) .. "|" .. tostring(track.title)
  if M._lyrics_key == key and M._lyrics then
    return M._lyrics
  end
  M._lyrics_key = key
  Lyrics.resolve(track, { remote = remote ~= false }, function(_, lyrics)
    M._lyrics = lyrics
    M.bump()
  end)
  return M._lyrics
end

---@return MusicLyrics|nil
function M.lyrics_state()
  if not M._lyrics and M._lyrics_key == nil then
    M.fetch_lyrics(false)
  end
  return M._lyrics
end

-- Web / API helpers -----------------------------------------------------------------------

--- Live analysis frame for the web client (spectrum values 0..1).
---@param width? integer
---@return number[]
function M.analyzer_values(width)
  width = width or 60
  local real = Visualizer.frame(width)
  if real then
    return real
  end
  local frame = Visualizer.synth_frame(M.clock(), width, M.track_seed(), M.state.playing and (M.state.volume / 100) or 0.05)
  return Visualizer.apply_eq(frame, M.state.eq_bands)
end

---@param width integer
---@return number[]|nil
function M.analyzer_frame(width)
  return Visualizer.frame(width)
end

---@return {left: number, right: number}
function M.levels()
  local real = Visualizer.frame(32)
  local energy = M.state.playing and (M.state.volume / 100) or 0.05
  return Visualizer.levels_from_frame(real, energy)
end

---@return MusicEngineStatus
function M.backend_snapshot()
  return Backend.snapshot()
end

---@return string
function M.device_id()
  return Daemon.device_id()
end

---@return MusicStation
function M.current_station()
  return M.state.station or Radio.stations[M.state.station_idx] or Radio.stations[1]
end

---@return table[]
function M.radio_results()
  if #M._radio_results > 0 then
    return M._radio_results
  end
  return Radio.stations
end

---@return string
function M.radio_query()
  return M._radio_query or ""
end

---@return table[]
function M.search_results()
  return M._search_results or {}
end

---@return string
function M.search_query()
  return M._search_query or ""
end

---@return string
function M.search_source()
  return M._search_source or "auto"
end

-- Legacy render helpers (kept because the UI and the tests use them) ---------------

--- Render a 3-line analyzer ASCII block (`:Kikru` main pane, legacy API).
---@param width? integer
---@return string[]
function M.render_visualizer(width)
  width = math.max(20, (width or 60) - 16)
  return Visualizer.render({
    mode = M.state.visualizer,
    width = width,
    height = 3,
    values = M.analyzer_values(width),
    eq = M.state.eq_bands,
    t = M.clock(),
    seed = M.track_seed(),
    playing = M.state.playing,
    volume = M.state.volume,
    levels = M.levels(),
  })
end

--- Render the 3-line 10-band EQ (legacy API).
---@return string[]
function M.render_eq()
  local lines = {}
  local top, values, bars = {}, {}, {}
  for i, label in ipairs(Filters.frequency_labels) do
    local gain = M.state.eq_bands[i] or 0
    local selected = (i == M.state.selected_band)
    top[#top + 1] = ("%s%-5s%s"):format(selected and "[" or " ", label, selected and "]" or " ")
    values[#values + 1] = ("  %+3d  "):format(gain)
    local level = math.floor(((gain + 12) / 24) * 8) + 1
    bars[#bars + 1] = ("   %s   "):format(Visualizer.blocks[math.max(1, math.min(8, level))])
  end
  lines[#lines + 1] = " " .. table.concat(top)
  lines[#lines + 1] = " " .. table.concat(values)
  lines[#lines + 1] = " " .. table.concat(bars)
  return lines
end

-- Server / client -------------------------------------------------------------------------

--- Start the 2-Neovim server (`:Kikru server [port]`).
---@param port? integer
---@return boolean ok, string msg
function M.start_server(port)
  M.ensure()
  local music = M.kikru_config()
  local ok, message = Daemon.start_server({
    port = tonumber(port) or M.state.port,
    host = music.bind or "127.0.0.1",
    token = music.sync_token,
  })
  M.state.role = Daemon.role
  M.state.port = tonumber(port) or M.state.port
  if ok then
    M.state.server = true
  end
  UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  return ok, message
end

--- Connect as a client (`:Kikru connect [host:port]`).
---@param target? string
---@return boolean ok, string msg
function M.connect_client(target)
  M.ensure()
  local host, port = "127.0.0.1", M.state.port
  target = Compat.trim(tostring(target or ""))
  if target ~= "" then
    local h, p = target:match("^([^:]+):(%d+)$")
    if h then
      host, port = h, tonumber(p)
    elseif target:match("^%d+$") then
      port = tonumber(target)
    elseif target ~= "" then
      host = target
    end
  end
  local music = M.kikru_config()
  local ok, message = Daemon.connect_client({ host = host, port = port, token = music.sync_token })
  M.state.host, M.state.port = host, port
  M.state.role = Daemon.role
  UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  return ok, message
end

---@return boolean ok, string msg
function M.disconnect()
  Daemon.disconnect()
  M.state.role = "none"
  M.state.devices = {}
  UI.notify(":Kikru · disconnected")
  return true, "disconnected"
end

---@return boolean ok, string msg
function M.start_ipc(path)
  M.ensure()
  return Daemon.start_ipc(path)
end

---@return boolean ok, string msg
function M.stop_ipc()
  Daemon.stop_ipc()
  return true, "IPC stopped"
end

---@return table
function M.devices()
  return Daemon.device_list()
end

-- UI ---------------------------------------------------------------------------------------

-- Casting (YouTube / YouTube Music / MPRIS apps) ---------------------------------------

--- Cast any link/search into the player (`:Kikru cast …`).
M.cast = Cast.cast
--- YouTube search → play.
M.youtube = Cast.youtube
--- YouTube Music search → play.
M.youtube_music = Cast.youtube_music
--- Continue whatever the MPRIS app (YouTube Music desktop, a browser tab, …) is playing.
M.appcast = Cast.from_app
--- Cast server（HTTP + `kikru://` scheme）.
M.cast_server = Cast.start_server
M.cast_stop = Cast.stop_server
M.cast_scheme = Cast.install_scheme
M.cast_info = Cast.info
M.cast_module = Cast

--- Should a cast open the floating player window? (config `kikru.cast.ui`)
---@return boolean
local function opens_ui_on_cast()
  local conf = M.music_config().cast or {}
  return conf.ui ~= false
end

--- Open (or focus) the :Kikru window.
function M.ui()
  M.ensure()
  local ui = require("kaeru.kikru.ui")
  if ui.is_open() then
    ui.render()
    return
  end
  ui.open(M)
end

---@return boolean
function M.ui_open()
  return require("kaeru.kikru.ui").is_open()
end

function M.close_ui()
  require("kaeru.kikru.ui").close()
end

-- Status / dispatch -------------------------------------------------------------------------

---@param opts? {json?: boolean}
---@return string
function M.status_text(opts)
  opts = opts or {}
  if opts.json then
    return require("kaeru.json").encode(M.get_snapshot())
  end
  local snapshot = M.get_snapshot()
  local track = M.current_track()
  local lines = {
    ":Kikru status",
    ("  state       %s · engine %s · %s"):format(
      snapshot.playing and "PLAYING" or (snapshot.paused and "PAUSED" or "STOPPED"),
      snapshot.engine or "none",
      snapshot.duration > 0 and (Tags.format_time(snapshot.position) .. " / " .. Tags.format_time(snapshot.duration)) or "live stream"
    ),
    ("  track       %s"):format(track and Tags.label(track) or "(nothing loaded)"),
    ("  volume      %d%% %s"):format(math.floor(M.state.volume), M.state.muted and "(muted)" or ""),
    ("  equalizer   %s   %s"):format(M.state.eq_preset, table.concat(M.state.eq_bands, " ")),
    ("  filters     %s"):format(Filters.describe(M.state.filters)),
    ("  visualizer  %s   theme %s"):format(M.state.visualizer, M.state.theme),
    ("  queue       %s"):format(Playlist.summary(M.playlist)),
    ("  remote      %s"):format(Daemon.transport_label()),
    ("  sources     %s"):format(table.concat((function()
      local names = {}
      for _, source in ipairs(Sources.available_sources()) do
        names[#names + 1] = source.id
      end
      return names
    end)(), ", ")),
  }
  return table.concat(lines, "\n")
end

---@param opts? {json?: boolean}
function M.status(opts)
  UI.notify(M.status_text(opts))
end

--- `:Kikru [subcommand] [args…]`
---@param args string[]
---@return boolean
function M.dispatch(args)
  M.ensure()
  args = args or {}
  local sub = (args[1] or ""):lower()
  local rest = Compat.list_slice(args, 2)
  local function joined(from)
    return table.concat(Compat.list_slice(args, from or 2), " ")
  end

  if sub == "" or sub == "ui" or sub == "open" or sub == "player" then
    M.ui()
  elseif sub == "toggle" then
    if M.ui_open() and (args[2] == nil) then
      -- `:Kikru toggle` toggles playback *and* focuses the window
      M.action("toggle")
      M.ui()
    else
      M.action("toggle")
    end
  elseif sub == "play" or sub == "pause" or sub == "stop" or sub == "next" or sub == "prev" then
    if sub == "play" and #rest > 0 then
      M.resolve_and_play(joined(2))
    else
      M.action(sub)
    end
    M.status()
  elseif sub == "add" then
    M.action("queue_add", { query = joined(2), play = false })
  elseif sub == "enqueue" or sub == "queue" then
    local action = (rest[1] or "list"):lower()
    if action == "list" then
      for index, item in ipairs(M.playlist.items) do
        print(("%3d. %s"):format(index, Tags.label(item)))
      end
      M.status()
    elseif action == "clear" then
      M.action("queue_clear")
    elseif action == "save" then
      M.action("playlist_save", { path = rest[2] })
    elseif action == "load" then
      M.action("playlist_load", { path = rest[2] })
    elseif action == "remove" then
      M.action("queue_remove", { index = tonumber(rest[2]) })
    elseif action == "move" then
      M.action("queue_move", { from = tonumber(rest[2]), to = tonumber(rest[3]) })
    elseif action == "shuffle" then
      M.action("shuffle")
    elseif action == "repeat" then
      M.action("repeat", { mode = rest[2] })
    else
      M.action("queue_add", { query = joined(2), play = rest[1] == "play" })
    end
  elseif sub == "volume" or sub == "vol" then
    if rest[1] and tonumber(rest[1]) then
      M.action("volume", { volume = tonumber(rest[1]) })
    elseif rest[1] and rest[1]:match("^[+-]%d+$") then
      M.action("volume", { delta = tonumber(rest[1]) })
    end
    M.status()
  elseif sub == "mute" then
    M.action("mute", { value = true })
    M.status()
  elseif sub == "unmute" then
    M.action("mute", { value = false })
    M.status()
  elseif sub == "seek" then
    local value = rest[1] or "0"
    if value:match("^[+-]") then
      M.action("seek_relative", { delta = tonumber(value) })
    else
      M.action("seek", { seconds = tonumber(value) })
    end
    M.status()
  elseif sub == "speed" then
    M.action("speed", { value = tonumber(rest[1]) or 1 })
    M.status()
  elseif sub == "eq" or sub == "equalizer" then
    if rest[1] and Filters.presets[rest[1]:lower()] then
      M.action("eq_preset", { preset = rest[1]:lower() })
    elseif rest[1] and rest[2] and tonumber(rest[1]) then
      M.action("eq_band_set", { band = tonumber(rest[1]), gain = tonumber(rest[2]) })
    else
      M.action("eq_preset")
    end
    M.status()
  elseif sub == "band" then
    if tonumber(rest[1]) and tonumber(rest[2]) then
      M.action("eq_band_set", { band = tonumber(rest[1]), gain = tonumber(rest[2]) })
    else
      M.action("eq_band", { band = tonumber(rest[1]), delta = tonumber(rest[2]) or 1 })
    end
    M.status()
  elseif sub == "presets" then
    local names = {}
    for name in pairs(Filters.presets) do
      names[#names + 1] = name
    end
    table.sort(names)
    UI.notify(":Kikru EQ presets\n  " .. table.concat(names, ", "))
  elseif sub == "filter" or sub == "filters" then
    local action = rest[1]
    if action == "clear" or action == "none" then
      M.action("filter_clear")
    elseif action == "list" then
      local names = {}
      for name in pairs(Filters.effect_presets) do
        names[#names + 1] = name
      end
      table.sort(names)
      UI.notify(":Kikru filters: " .. table.concat(names, ", "))
      return true
    elseif action == "timescale" then
      M.action("filter_set", { spec = { timescale = { speed = tonumber(rest[2]) or 1, pitch = tonumber(rest[3]) or tonumber(rest[2]) or 1, rate = 1 } } })
    elseif action == "lowpass" then
      M.action("filter_set", { spec = { lowPass = { smoothing = tonumber(rest[2]) or 20 } } })
    elseif action == "volume" then
      M.action("filter_set", { spec = { volume = tonumber(rest[2]) or 1 } })
    elseif action then
      M.action("filter_preset", { preset = action })
    else
      M.action("filter_preset")
    end
    M.status()
  elseif sub == "visualizer" or sub == "vis" then
    M.action("visualizer", { mode = rest[1] })
    M.status()
  elseif sub == "theme" then
    M.action("theme", { name = rest[1] })
    M.status()
  elseif sub == "radio" or sub == "stream" then
    local query = joined(2)
    if query:match("^%d+$") then
      M.action("station", { index = tonumber(query) })
      M.status()
    elseif query ~= "" then
      M.radio_search(query)
      M.ui()
      require("kaeru.kikru.ui").set_view("radio")
    else
      M.action("radio_curated")
      M.ui()
      require("kaeru.kikru.ui").set_view("radio")
    end
  elseif sub == "cast" then
    local action = (rest[1] or ""):lower()
    if action == "" then
      UI.notify(":Kikru cast <youtube|yt-music url|query>\n  cast server [port] · cast stop · cast scheme · cast status · cast log")
      return true
    elseif action == "server" then
      local ok, message = Cast.start_server(tonumber(rest[2]) or nil)
      UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      return true
    elseif action == "stop" then
      Cast.stop_server()
      UI.notify(":Kikru · cast server stopped")
      return true
    elseif action == "scheme" or action == "handler" then
      local ok, message = Cast.install_scheme()
      UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      return true
    elseif action == "uninstall" then
      UI.notify(":Kikru · " .. select(2, Cast.uninstall_scheme()))
      return true
    elseif action == "status" or action == "info" then
      local info = Cast.info()
      local lines = {
        ":Kikru cast",
        ("  server      %s %s"):format(info.running and "listening" or "stopped", info.url),
        ("  scheme      %s://  (install with `:Kikru cast scheme`)"):format(info.scheme),
        ("  yt-dlp      %s"):format(info.ytdlp and "available" or "missing (install yt-dlp)"),
        ("  last cast   %s"):format(info.last and (info.last.url .. " (" .. info.last.kind .. ")") or "—"),
        "  endpoints:",
      }
      for _, endpoint in ipairs(info.endpoints) do
        lines[#lines + 1] = "    " .. endpoint
      end
      UI.notify(table.concat(lines, "\n"))
      return true
    elseif action == "log" then
      UI.notify(":Kikru cast log\n  " .. table.concat(Cast.info().log, "\n  "))
      return true
    end
    local mode = "play"
    local parts = {}
    for index = 1, #rest do
      local token = rest[index]
      if token == "--queue" or token == "-q" then
        mode = "queue"
      elseif token == "--next" then
        mode = "next"
      elseif token ~= "--play" then
        parts[#parts + 1] = token
      end
    end
    local target = table.concat(parts, " ")
    if target == "" then
      UI.notify(":Kikru cast <url|search> [--queue|--next]", vim.log.levels.WARN)
      return true
    end
    if opens_ui_on_cast() then
      M.ui()
    end
    M.cast(target, { mode = mode })
  elseif sub == "youtube" or sub == "yt" then
    local query = joined(2)
    if query == "" then
      UI.notify(":Kikru youtube <search terms>", vim.log.levels.WARN)
      return true
    end
    M.youtube(query, { mode = Compat.tbl_contains(args, "--queue") and "queue" or "play" })
  elseif sub == "ytmusic" or sub == "ytm" or sub == "youtube-music" then
    local query = joined(2)
    if query == "" then
      UI.notify(":Kikru ytmusic <search terms>", vim.log.levels.WARN)
      return true
    end
    M.youtube_music(query, { mode = Compat.tbl_contains(args, "--queue") and "queue" or "play" })
  elseif sub == "appcast" then
    M.appcast({ mode = Compat.tbl_contains(args, "--queue") and "queue" or "play" })
  elseif sub == "station" then
    M.action("station", { id = rest[1], index = tonumber(rest[1]) })
    M.status()
  elseif sub == "search" or sub == "find" then
    M.search(joined(2), rest[2])
    M.ui()
    require("kaeru.kikru.ui").set_view("search")
  elseif sub == "sources" then
    local lines = { ":Kikru sources" }
    for _, source in ipairs(Sources.available_sources()) do
      lines[#lines + 1] = ("  %-14s %-34s prefix: %s"):format(source.id, source.name, source.prefix ~= "" and source.prefix or "-")
    end
    if #lines == 1 then
      lines[#lines + 1] = "  none available — install mpv and yt-dlp"
    end
    UI.notify(table.concat(lines, "\n"))
  elseif sub == "library" or sub == "index" then
    M.action("index_dir", { path = rest[1] or "~/Kikru", play = args[#args] == "--play" })
  elseif sub == "lyrics" then
    M.fetch_lyrics(true)
    M.ui()
    require("kaeru.kikru.ui").set_view("lyrics")
  elseif sub == "playlist" or sub == "playlists" then
    local action = (rest[1] or "list"):lower()
    if action == "list" then
      local files = Playlist.available()
      if #files == 0 then
        UI.notify(":Kikru · no playlists in " .. Playlist.default_dir())
      else
        UI.notify(":Kikru playlists\n  " .. table.concat(files, "\n  "))
      end
    elseif action == "save" then
      M.action("playlist_save", { path = rest[2], format = rest[3] })
    elseif action == "load" or action == "open" then
      M.action("playlist_load", { path = rest[2], play = args[#args] ~= "--no-play" })
    elseif action == "dir" then
      UI.notify(":Kikru playlist dir: " .. Playlist.default_dir())
    else
      M.action("playlist_load", { path = action, play = true })
    end
  elseif sub == "engine" then
    if rest[1] then
      M.action("engine", { id = rest[1] })
    end
    local lines = { ":Kikru engines" }
    for _, engine in ipairs(Backend.available_engines()) do
      lines[#lines + 1] = ("  %-8s %-40s eq:%s filters:%s seek:%s"):format(
        engine.id,
        engine.name,
        engine.capabilities.eq and "yes" or "no",
        engine.capabilities.filters and "yes" or "no",
        engine.capabilities.seek and "yes" or "no"
      )
    end
    lines[#lines + 1] = ("  active: %s (config music.engine = %s)"):format(Backend.engine, M.state.engine)
    UI.notify(table.concat(lines, "\n"))
  elseif sub == "server" then
    M.start_server(tonumber(rest[1]))
    M.ui()
  elseif sub == "connect" then
    M.connect_client(rest[1])
  elseif sub == "disconnect" then
    M.disconnect()
  elseif sub == "devices" then
    local devices = Daemon.device_list()
    if #devices == 0 then
      UI.notify(":Kikru · no paired devices (" .. Daemon.transport_label() .. ")")
      return true
    end
    local lines = { ":Kikru 2-Neovim devices — " .. Daemon.transport_label() }
    for index, device in ipairs(devices) do
      lines[#lines + 1] = ("  %d. %-34s %-8s %-22s %s"):format(index, device.name or device.id, device.role or "?", device.addr or "", device.active and "[ACTIVE]" or "")
    end
    UI.notify(table.concat(lines, "\n"))
  elseif sub == "handoff" then
    M.action("handoff", { device_id = rest[1], index = tonumber(rest[1]) })
  elseif sub == "daemon" then
    local action = (rest[1] or "start"):lower()
    if action == "start" then
      local ok, message = M.start_ipc()
      UI.notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    elseif action == "stop" then
      M.stop_ipc()
      UI.notify(":Kikru IPC daemon stopped")
    else
      UI.notify(":Kikru · " .. Daemon.transport_label() .. " · socket " .. Daemon.ipc_path())
    end
  elseif sub == "ipc" then
    local action = rest[1] or "status"
    local payload = {}
    for index = 2, #rest do
      payload[#payload + 1] = rest[index]
    end
    Daemon.ipc_send(action, { volume = tonumber(payload[1]), query = table.concat(payload, " ") }, {}, function(ok, response, err)
      if not ok then
        UI.notify(":Kikru ipc · " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      UI.notify(":Kikru ipc · " .. require("kaeru.json").encode(response or {}))
    end)
  elseif sub == "remote" then
    M.action(rest[1] or "toggle", { volume = tonumber(rest[2]), preset = rest[2] })
  elseif sub == "status" or sub == "info" then
    M.status({ json = Compat.tbl_contains(args, "--json") })
  elseif sub == "reset" then
    M.action("reset")
    UI.notify(":Kikru · reset")
  elseif sub == "config" then
    Config.edit(Config.options.config.global)
  else
    UI.notify(":Kikru · unknown subcommand: " .. sub, vim.log.levels.ERROR)
    return false
  end
  return true
end

M.eq_frequencies = Filters.frequency_labels

return M
