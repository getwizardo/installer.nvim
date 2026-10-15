-- kaeru.nvim · :Kikru — playback backends.
--
-- mpv is the primary engine because its JSON IPC gives us *real* state:
-- position, duration, ICY metadata, audio parameters and a live `af` chain
-- (that is how the 10-band EQ and the NodeLink style filters are applied).
-- ffplay, VLC, MPD and MPRIS/playerctl are supported as fallbacks — the
-- capability flags below tell the UI what each engine can actually do, so the
-- player never claims to do something it cannot.
local Filters = require("kaeru.kikru.filters")
local Json = require("kaeru.json")

local M = {}

local uv = vim.uv or vim.loop

---@class MusicEngineStatus
---@field engine string
---@field playing boolean
---@field paused boolean
---@field position number
---@field duration number
---@field volume number
---@field muted boolean
---@field title string
---@field url string
---@field speed number
---@field live boolean
---@field icestream boolean

M.socket_path = nil
M.pipe = nil
M.job = nil
M.engine = "none"
M.status = {
  engine = "none",
  playing = false,
  paused = false,
  position = 0,
  duration = 0,
  volume = 80,
  muted = false,
  title = "",
  url = "",
  speed = 1,
  live = false,
  icestream = false,
}

M._listeners = {}
M._buffer = ""
M._pending_commands = {}
M._request_id = 0
M._requests = {}
M._started_at = 0

--- Register a listener for backend events:
--- `file-loaded`, `end-file`, `position`, `duration`, `error`, `idle`, `exit`, `metadata`.
---@param cb fun(event: string, data: any)
---@return fun()  unsubscribe
function M.on_event(cb)
  table.insert(M._listeners, cb)
  return function()
    for i, listener in ipairs(M._listeners) do
      if listener == cb then
        table.remove(M._listeners, i)
        break
      end
    end
  end
end

---@param event string
---@param data? any
function M.emit(event, data)
  for _, cb in ipairs(vim.deepcopy(M._listeners)) do
    local ok, err = pcall(cb, event, data)
    if not ok then
      vim.schedule(function()
        vim.notify(":Kikru backend listener error: " .. tostring(err), vim.log.levels.DEBUG)
      end)
    end
  end
end

-- Engine discovery ---------------------------------------------------------------

---@class MusicEngineInfo
---@field id string
---@field name string
---@field bin string
---@field capabilities table<string, boolean>

---@return MusicEngineInfo[]
function M.available_engines()
  local engines = {}
  if vim.fn.executable("mpv") == 1 then
    engines[#engines + 1] = {
      id = "mpv",
      name = "mpv (JSON IPC — full EQ & filters)",
      bin = "mpv",
      capabilities = { eq = true, filters = true, seek = true, volume = true, metadata = true, position = true, speed = true },
    }
  end
  if vim.fn.executable("ffplay") == 1 then
    engines[#engines + 1] = {
      id = "ffplay",
      name = "ffplay (ffmpeg filters)",
      bin = "ffplay",
      capabilities = { eq = true, filters = true, seek = true, volume = true, metadata = false, position = false, speed = false },
    }
  end
  if vim.fn.executable("cvlc") == 1 then
    engines[#engines + 1] = {
      id = "vlc",
      name = "VLC (equalizer presets only)",
      bin = "cvlc",
      capabilities = { eq = true, filters = false, seek = false, volume = true, metadata = false, position = false, speed = true },
    }
  end
  if vim.fn.executable("mpc") == 1 then
    engines[#engines + 1] = {
      id = "mpd",
      name = "MPD via mpc (external daemon)",
      bin = "mpc",
      capabilities = { eq = false, filters = false, seek = true, volume = true, metadata = true, position = true, speed = false },
    }
  end
  if vim.fn.executable("playerctl") == 1 then
    engines[#engines + 1] = {
      id = "mpris",
      name = "MPRIS via playerctl (Spotify / browser)",
      bin = "playerctl",
      capabilities = { eq = false, filters = false, seek = true, volume = true, metadata = true, position = true, speed = false },
    }
  end
  return engines
end

--- Preferred engine (config `music.engine` wins when it is installed).
---@return string|nil id, MusicEngineInfo|nil
function M.pick_engine()
  local Config = require("kaeru.config")
  local wanted = (Config.options.music and Config.options.music.engine) or "auto"
  local engines = M.available_engines()
  if wanted ~= "auto" and wanted ~= "" then
    for _, engine in ipairs(engines) do
      if engine.id == wanted then
        return engine.id, engine
      end
    end
  end
  for _, engine in ipairs(engines) do
    if engine.id == "mpv" then
      return engine.id, engine
    end
  end
  return engines[1] and engines[1].id or nil, engines[1]
end

---@param engine string
---@return MusicEngineInfo|nil
function M.capabilities(engine)
  for _, info in ipairs(M.available_engines()) do
    if info.id == engine then
      return info
    end
  end
  return nil
end

---@param capability string
---@param engine? string
---@return boolean
function M.can(capability, engine)
  local info = M.capabilities(engine or M.engine)
  return info ~= nil and info.capabilities[capability] == true
end

-- mpv JSON IPC -------------------------------------------------------------------

---@return string
function M.mpv_socket_path()
  if M.socket_path then
    return M.socket_path
  end
  local dir = vim.fn.stdpath("cache") .. "/kaeru"
  pcall(vim.fn.mkdir, dir, "p")
  M.socket_path = ("%s/music-%d.sock"):format(dir, uv and uv.os_getpid and uv.os_getpid() or math.random(100000))
  return M.socket_path
end

---@param command string
---@param args? table
---@param cb? fun(response: table|nil)
---@return boolean queued
function M.mpv_command(command, args, cb)
  local payload = { command = { command } }
  for _, arg in ipairs(args or {}) do
    payload.command[#payload.command + 1] = arg
  end
  if cb then
    M._request_id = M._request_id + 1
    payload.request_id = M._request_id
    M._requests[M._request_id] = cb
  end
  local line = Json.encode(payload) .. "\n"
  if not M.pipe then
    M._pending_commands[#M._pending_commands + 1] = line
    return false
  end
  local ok = pcall(function()
    M.pipe:write(line)
  end)
  return ok
end

---@param name string
---@param value any
---@param cb? fun(response: table|nil)
function M.set_property(name, value, cb)
  return M.mpv_command("set_property", { name, value }, cb)
end

---@param name string
---@param cb fun(value: any, response: table|nil)
function M.get_property(name, cb)
  M.mpv_command("get_property", { name }, function(response)
    cb(response and response.data, response)
  end)
end

---@param names string[]
---@param cb fun(values: table<string, any>)
function M.get_properties(names, cb)
  local remaining = #names
  local values = {}
  if remaining == 0 then
    return cb(values)
  end
  for _, name in ipairs(names) do
    M.get_property(name, function(value)
      values[name] = value
      remaining = remaining - 1
      if remaining == 0 then
        cb(values)
      end
    end)
  end
end

---@param line string
local function handle_mpv_message(line)
  local message = Json.decode(line)
  if type(message) ~= "table" then
    return
  end
  if message.request_id and M._requests[message.request_id] then
    local cb = M._requests[message.request_id]
    M._requests[message.request_id] = nil
    cb(message)
    return
  end
  local event = message.event
  if not event then
    return
  end
  if event == "property-change" then
    local name = message.name
    local value = message.data
    if name == "time-pos" and type(value) == "number" then
      M.status.position = value
      M.emit("position", value)
    elseif name == "duration" and type(value) == "number" then
      M.status.duration = value
      M.emit("duration", value)
    elseif name == "pause" then
      M.status.paused = value == true
      M.emit("pause", M.status.paused)
    elseif name == "volume" and type(value) == "number" then
      M.status.volume = value
      M.emit("volume", value)
    elseif name == "mute" then
      M.status.muted = value == true
    elseif name == "speed" and type(value) == "number" then
      M.status.speed = value
    elseif name == "idle-active" then
      M.status.playing = value ~= true
      M.status.idle = value == true
    elseif name == "media-title" then
      M.status.title = tostring(value or "")
      M.emit("metadata", { title = M.status.title })
    elseif name == "metadata" and type(value) == "table" then
      M.emit("metadata", value)
    elseif name == "eof-reached" and value == true then
      M.emit("eof", true)
    end
  elseif event == "start-file" then
    M.status.playing = true
    M.status.paused = false
    M.status.live = false
    M.status.icestream = false
  elseif event == "file-loaded" then
    M.status.playing = true
    M.status.paused = false
    M.emit("file-loaded", { url = M.status.url })
    M.get_properties({ "duration", "audio-params", "metadata", "media-title", "path" }, function(values)
      M.status.duration = type(values.duration) == "number" and values.duration or M.status.duration
      if type(values["audio-params"]) == "table" then
        M.status.samplerate = values["audio-params"]["samplerate"]
        M.status.channels = values["audio-params"]["channel-count"]
        M.status.format = values["audio-params"]["format"]
      end
      M.status.title = values["media-title"] or M.status.title
      M.emit("metadata", vim.tbl_extend("force", values.metadata or {}, {
        title = M.status.title,
        duration = M.status.duration,
      }))
    end)
  elseif event == "end-file" then
    M.status.playing = false
    M.emit("end-file", { reason = message.reason or "eof" })
  elseif event == "idle" then
    M.status.playing = false
    M.emit("idle", true)
  elseif event == "shutdown" then
    M.emit("exit", true)
  elseif event == "log-message" or event == "audio-reconfig" then
    M.emit(event, message)
  end
end

--- Connect to the mpv IPC socket, replaying queued commands once ready.
---@param cb? fun(ok: boolean, err?: string)
function M.connect_mpv(cb)
  if not uv or not uv.new_pipe then
    return cb and cb(false, "libuv is unavailable")
  end
  local path = M.mpv_socket_path()
  local attempts = 0
  local function attempt()
    attempts = attempts + 1
    local pipe = uv.new_pipe(false)
    pipe:connect(path, function(err)
      if err then
        pcall(function()
          pipe:close()
        end)
        if attempts < 40 then
          return vim.defer_fn(attempt, 50)
        end
        return cb and cb(false, "could not connect to mpv IPC at " .. path)
      end
      M.pipe = pipe
      for _, line in ipairs(M._pending_commands) do
        pcall(function()
          pipe:write(line)
        end)
      end
      M._pending_commands = {}
      pipe:read_start(function(read_err, data)
        if read_err or not data then
          M.pipe = nil
          M.emit("exit", true)
          return
        end
        M._buffer = M._buffer .. data
        while true do
          local newline = M._buffer:find("\n", 1, true)
          if not newline then
            break
          end
          local line = M._buffer:sub(1, newline - 1)
          M._buffer = M._buffer:sub(newline + 1)
          vim.schedule(function()
            handle_mpv_message(line)
          end)
        end
      end)
      -- Observe everything the UI needs.
      for _, property in ipairs({ "time-pos", "duration", "pause", "volume", "mute", "speed", "idle-active", "media-title", "metadata", "eof-reached" }) do
        M.mpv_command("observe_property", { 1, property })
      end
      if cb then
        cb(true)
      end
    end)
  end
  attempt()
end

-- Engine lifecycle ----------------------------------------------------------------

--- Extra CLI arguments per engine (mixing config + filter chain + stream tweaks).
---@param engine string
---@param state table
---@return string[]
function M.engine_args(engine, state)
  local Config = require("kaeru.config")
  local music = (Config.options.music) or {}
  local built = Filters.build(engine, state or { bands = state and state.bands or Filters.flat, filters = state and state.filters, preamp = state and state.preamp })

  if engine == "mpv" then
    local args = {
      "--no-video",
      "--no-terminal",
      "--force-window=no",
      "--idle=yes",
      "--really-quiet",
      "--no-input-default-bindings",
      "--input-ipc-server=" .. M.mpv_socket_path(),
      "--volume=" .. tostring(math.floor((state and state.volume) or 80)),
      -- streaming friendliness (cliamp-style: never stall on a network stream)
      "--cache=yes",
      "--cache-secs=15",
      "--demuxer-max-bytes=64MiB",
      "--demuxer-readahead-secs=30",
      "--gapless-audio=weak",
      "--audio-display=no",
      "--ytdl=yes",
      "--ytdl-format=bestaudio/best",
      "--term-status-msg=",
      "--msg-level=all=error",
    }
    if built.af and built.af ~= "" then
      args[#args + 1] = "--af=" .. built.af
    end
    vim.list_extend(args, built.args)
    if music.audio_device and music.audio_device ~= "" then
      args[#args + 1] = "--audio-device=" .. music.audio_device
    end
    if music.audio_exclusive then
      args[#args + 1] = "--audio-exclusive=yes"
    end
    if music.replaygain then
      args[#args + 1] = "--replaygain=" .. music.replaygain
    end
    vim.list_extend(args, music.mpv_args or {})
    return args
  elseif engine == "ffplay" then
    local args = {
      "-nodisp",
      "-autoexit",
      "-loglevel",
      "quiet",
      "-hide_banner",
      "-volume",
      tostring(math.floor((state and state.volume) or 80)),
      "-infbuf",
      "-window_title",
      ":Kikru",
    }
    if built.af and built.af ~= "" then
      args[#args + 1] = "-af"
      args[#args + 1] = built.af
    end
    vim.list_extend(args, music.ffplay_args or {})
    return args
  elseif engine == "vlc" then
    local args = { "--no-video", "--intf", "dummy", "--quiet" }
    args[#args + 1] = ("--volume=%d"):format(math.floor(((state and state.volume) or 80) * 256 / 100))
    vim.list_extend(args, built.args)
    vim.list_extend(args, music.vlc_args or {})
    return args
  end
  return {}
end

--- Start (or restart) the audio engine.
---@param state {volume?: number, bands?: number[], filters?: table, preamp?: number}
---@param cb? fun(ok: boolean, err?: string)
---@return boolean ok, string? err
function M.start(state, cb)
  state = state or {}
  local engine = M.pick_engine()
  if not engine then
    local err = "no audio backend found — install mpv (recommended), ffplay or VLC"
    if cb then
      cb(false, err)
    end
    return false, err
  end
  M.stop()
  M.engine = engine
  M.status.engine = engine

  if engine == "mpv" then
    local args = { "mpv" }
    vim.list_extend(args, M.engine_args("mpv", state))
    M.job = vim.fn.jobstart(args, {
      on_exit = function()
        M.job = nil
        M.status.playing = false
        M.emit("exit", true)
      end,
    })
    if M.job <= 0 then
      M.job = nil
      local err = "failed to start mpv"
      if cb then
        cb(false, err)
      end
      return false, err
    end
    M.status.volume = state.volume or M.status.volume
    M.connect_mpv(function(ok, err)
      if cb then
        cb(ok, err)
      end
    end)
    return true
  end

  -- Engines without IPC start per track (see `M.load`).
  M.status.volume = state.volume or M.status.volume
  if cb then
    vim.schedule(function()
      cb(true)
    end)
  end
  return true
end

--- Stop the engine and close the IPC pipe.
function M.stop()
  if M.pipe then
    pcall(function()
      M.pipe:close()
    end)
    M.pipe = nil
  end
  if M.job and vim.fn.jobstop then
    pcall(vim.fn.jobstop, M.job)
  end
  M.job = nil
  M._buffer = ""
  M._pending_commands = {}
  M._requests = {}
  M.status.playing = false
  M.status.paused = false
  M.status.position = 0
end

---@return boolean
function M.running()
  return M.job ~= nil and M.job > 0
end

-- Playback -----------------------------------------------------------------------

---@param args string[]
---@param cb? fun(res: KaeruProcResult)
local function run_async(args, cb)
  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, code)
      if cb then
        cb({ code = code })
      end
    end,
  })
  if job <= 0 then
    return nil
  end
  return job
end

--- Load and play a track/URL.
---@param track MusicTagTrack
---@param opts? {autoplay?: boolean, engine?: string}
---@param cb? fun(ok: boolean, err?: string)
---@return boolean ok, string? err
function M.load(track, opts, cb)
  opts = opts or {}
  local url = track.stream_url or track.url or track.path
  if not url or url == "" then
    local err = "track has no playable URL"
    if cb then
      cb(false, err)
    end
    return false, err
  end
  M.status.url = url
  M.status.title = require("kaeru.kikru.tags").label(track)
  M.status.duration = track.duration or 0
  M.status.position = 0
  M.status.live = track.format == "stream" or M.status.duration == 0

  local engine = opts.engine or M.pick_engine()
  if not engine then
    local err = "no audio backend found — install mpv, ffplay or VLC (see :Kikru engine)"
    M.emit("error", { message = err })
    if cb then
      cb(false, err)
    end
    return false, err
  end
  if engine == "none" or not M.running() then
    local ok, err = M.start({
      volume = M.status.volume,
      bands = opts.bands,
      filters = opts.filters,
      preamp = opts.preamp,
    })
    if not ok then
      if cb then
        cb(false, err)
      end
      return false, err
    end
    engine = M.engine
  end

  if engine == "mpv" then
    M.set_property("pause", true)
    M.mpv_command("loadfile", { url, "replace" }, function(response)
      if response and response.error and response.error ~= "success" then
        if cb then
          cb(false, tostring(response.error))
        end
        return
      end
      if opts.autoplay ~= false then
        M.set_property("pause", false)
        M.mpv_command("play")
      end
      if cb then
        cb(true)
      end
    end)
    return true
  elseif engine == "ffplay" then
    local args = { "ffplay" }
    vim.list_extend(args, M.engine_args("ffplay", { volume = M.status.volume, bands = opts.bands, filters = opts.filters }))
    args[#args + 1] = url
    M.job = run_async(args)
    M.status.playing = M.job ~= nil
    if cb then
      cb(M.job ~= nil, M.job == nil and "failed to start ffplay" or nil)
    end
    return M.job ~= nil
  elseif engine == "vlc" then
    local args = { "cvlc" }
    vim.list_extend(args, M.engine_args("vlc", { volume = M.status.volume, bands = opts.bands }))
    args[#args + 1] = url
    M.job = run_async(args)
    M.status.playing = M.job ~= nil
    if cb then
      cb(M.job ~= nil, M.job == nil and "failed to start VLC" or nil)
    end
    return M.job ~= nil
  elseif engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "clear" }, {}, function() end)
    Sources.capture({ "mpc", "add", url }, {}, function()
      Sources.capture({ "mpc", "play" }, {}, function(err)
        if cb then
          cb(err == nil, err)
        end
      end)
    end)
    return true
  elseif engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "play" }, {}, function(err)
      if err then
        Sources.capture({ "playerctl", "open", url }, {}, function(open_err)
          if cb then
            cb(open_err == nil, open_err)
          end
        end)
      elseif cb then
        cb(true)
      end
    end)
    return true
  end

  local err = "engine " .. tostring(engine) .. " cannot play " .. url
  if cb then
    cb(false, err)
  end
  return false, err
end

---@param autoplay? boolean
function M.play(autoplay)
  if M.engine == "mpv" then
    M.set_property("pause", not (autoplay ~= false))
    if autoplay ~= false then
      M.mpv_command("play")
    end
  else
    M.resume()
  end
end

function M.pause()
  if M.engine == "mpv" then
    M.set_property("pause", true)
  else
    M.mpris_command(M.engine == "mpd" and { "mpc", "pause" } or { "playerctl", "pause" })
  end
  M.status.paused = true
end

---@return boolean playing
function M.toggle()
  if M.engine == "mpv" then
    M.get_property("pause", function(paused)
      M.set_property("pause", not paused)
      M.status.paused = not paused
    end)
    return not M.status.paused
  end
  if M.engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "toggle" }, {}, function() end)
  elseif M.engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "play-pause" }, {}, function() end)
  end
  M.status.paused = not M.status.paused
  return not M.status.paused
end

function M.resume()
  if M.engine == "mpv" then
    M.set_property("pause", false)
  elseif M.engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "play" }, {}, function() end)
  elseif M.engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "play" }, {}, function() end)
  end
  M.status.paused = false
  M.status.playing = true
end

function M.stop_playback()
  if M.engine == "mpv" then
    M.mpv_command("stop")
    M.set_property("pause", true)
  elseif M.engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "stop" }, {}, function() end)
  elseif M.engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "stop" }, {}, function() end)
  else
    M.stop()
  end
  M.status.playing = false
  M.status.paused = true
end

---@param volume number 0..100
function M.set_volume(volume)
  volume = math.max(0, math.min(130, volume))
  M.status.volume = volume
  if M.engine == "mpv" then
    M.set_property("volume", volume)
  elseif M.engine == "vlc" then
    M.restart_for_volume(volume)
  elseif M.engine == "ffplay" then
    M.restart_for_volume(volume)
  elseif M.engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "volume", tostring(math.floor(volume)) }, {}, function() end)
  elseif M.engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "volume", ("%.2f"):format(volume / 100) }, {}, function() end)
  end
end

--- ffplay/VLC take the volume on the command line, so a volume change means a
--- short restart at the current position (documented in the UI).
---@param volume number
function M.restart_for_volume(volume)
  if not M._last_track then
    return
  end
  local position = M.status.position
  local track = vim.deepcopy(M._last_track)
  M.load(track, { autoplay = true, bands = M._bands, filters = M._filters, preamp = M._preamp })
  if position > 1 then
    vim.defer_fn(function()
      M.seek(position)
    end, 350)
  end
  M.status.volume = volume
end

---@param seconds number
function M.seek(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if M.engine == "mpv" then
    M.mpv_command("seek", { seconds, "absolute" })
  elseif M.engine == "mpd" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "mpc", "seek", tostring(math.floor(seconds)) }, {}, function() end)
  elseif M.engine == "mpris" then
    local Sources = require("kaeru.kikru.sources")
    Sources.capture({ "playerctl", "position", ("%.3f"):format(seconds) }, {}, function() end)
  end
  M.status.position = seconds
  M.emit("position", seconds)
end

---@param delta number
function M.seek_relative(delta)
  M.seek(math.max(0, M.status.position + delta))
end

---@param speed number
function M.set_speed(speed)
  speed = math.max(0.25, math.min(4, tonumber(speed) or 1))
  M.status.speed = speed
  if M.engine == "mpv" then
    M.set_property("speed", speed)
  end
end

---@param muted boolean
function M.set_mute(muted)
  M.status.muted = muted
  if M.engine == "mpv" then
    M.set_property("mute", muted)
  end
end

-- Filter / EQ plumbing --------------------------------------------------------------

--- Apply EQ bands + filters to the running engine.
---@param state {bands?: number[], filters?: table, preamp?: number, volume?: number}
function M.sync_filters(state)
  state = state or {}
  M._bands = state.bands
  M._filters = state.filters
  M._preamp = state.preamp
  if M.engine ~= "mpv" then
    if (M.engine == "ffplay" or M.engine == "vlc") and M._last_track then
      -- These engines bake filters into the command line: reload the track.
      M.load(M._last_track, { autoplay = true, bands = state.bands, filters = state.filters, preamp = state.preamp })
    end
    return
  end
  local built = Filters.build("mpv", state)
  M.mpv_command("af", { "set", built.af or "" })
  for name, value in pairs(built.properties) do
    if value ~= nil then
      M.set_property(name, value)
    end
  end
  for _, arg in ipairs(built.args) do
    local name, value = arg:match("^%-%-([%w%-]+)=(.*)$")
    if name == "speed" then
      M.set_property("speed", tonumber(value) or 1)
    elseif name == "audio-pitch-correction" then
      M.set_property("audio-pitch-correction", value == "yes")
    end
  end
end

---@param track MusicTagTrack
function M.remember_track(track)
  M._last_track = track
end

---@return MusicEngineStatus
function M.snapshot()
  return {
    engine = M.engine,
    playing = M.status.playing and not M.status.paused,
    paused = M.status.paused,
    position = M.status.position,
    duration = M.status.duration,
    volume = M.status.volume,
    muted = M.status.muted,
    title = M.status.title,
    url = M.status.url,
    speed = M.status.speed,
    live = M.status.live,
    icestream = M.status.icestream,
    samplerate = M.status.samplerate,
    channels = M.status.channels,
    format = M.status.format,
    running = M.running(),
  }
end

-- MPRIS / playerctl ----------------------------------------------------------------

---@param args string[]
function M.mpris_command(args)
  local Sources = require("kaeru.kikru.sources")
  Sources.capture(args, {}, function() end)
end

--- Read the MPRIS now-playing of any running player (Spotify, browsers, …).
---@param cb fun(err: string|nil, info: table|nil)
function M.mpris_nowplaying(cb)
  if vim.fn.executable("playerctl") ~= 1 then
    return cb("playerctl is not installed", nil)
  end
  local format = "{{status}}|{{artist}}|{{title}}|{{album}}|{{mpris:length}}|{{position}}|{{playerName}}"
  local Sources = require("kaeru.kikru.sources")
  Sources.capture({ "playerctl", "metadata", "--format", format }, {}, function(err, stdout)
    if err then
      return cb(err, nil)
    end
    local line = stdout:match("^([^\r\n]+)")
    if not line then
      return cb("no MPRIS player", nil)
    end
    local status, artist, title, album, length_us, position_us, player = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    cb(nil, {
      player = player,
      playing = status == "Playing",
      paused = status == "Paused",
      artist = artist,
      title = title,
      album = album,
      duration = (tonumber(length_us) or 0) / 1000000,
      position = (tonumber(position_us) or 0) / 1000000,
    })
  end)
end

--- List controllable MPRIS players.
---@param cb fun(players: string[])
function M.mpris_players(cb)
  if vim.fn.executable("playerctl") ~= 1 then
    return cb({})
  end
  local Sources = require("kaeru.kikru.sources")
  Sources.capture({ "playerctl", "-l" }, {}, function(_, stdout)
    local players = {}
    for line in (stdout or ""):gmatch("[^\r\n]+") do
      players[#players + 1] = line
    end
    cb(players)
  end)
end

--- MPD status via mpc (`--format` keeps the parsing stable).
---@param cb fun(err: string|nil, info: table|nil)
function M.mpd_status(cb)
  if vim.fn.executable("mpc") ~= 1 then
    return cb("mpc is not installed", nil)
  end
  local Sources = require("kaeru.kikru.sources")
  Sources.capture({ "mpc", "--format", "%file%|%title%|%artist%|%album%|%time%" }, {}, function(err, stdout)
    if err then
      return cb(err, nil)
    end
    local file, title, artist, album, time = (stdout or ""):match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)")
    cb(nil, {
      file = file,
      title = title,
      artist = artist,
      album = album,
      position = tonumber(time and time:match("^(%d+)")) or 0,
    })
  end)
end

return M
