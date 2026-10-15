-- kaeru.nvim · :Karu — Google Cast, powered by the TypeScript implementation
-- in `karu/` (see `karu/README.md`).
--
-- Two directions:
--   * **receiver** — `:Karu receive` makes this machine show up in the Cast
--     list of the YouTube / YouTube Music apps (mDNS `_googlecast._tcp`,
--     CASTV2 over TLS on port 8009). Every LOAD is bridged into Kikru through
--     the cast server (`:Kikru cast server`), so the phone streams into Neovim.
--   * **sender** — `:Karu discover` / `:Karu cast <url> [device]` controls real
--     Chromecast / Google TV / Nest devices: launch the Default Media
--     Receiver, LOAD a stream, transport, volume.
--
-- This module is the Lua side of that bridge: it locates the CLI, runs it with
-- `jobstart`, parses the JSON it prints and keeps the device list + receiver
-- state for completion.
local Compat = require("kaeru.compat")
local Json = require("kaeru.json")

local M = {}

M.default_name = "Karu · Neovim"
M.default_port = 8009
M.min_node = { 22, 6 }

-- ---------------------------------------------------------------------------
-- locating the CLI
-- ---------------------------------------------------------------------------

--- Plugin root directory (…/lua/kaeru/karu.lua → …)
---@return string|nil
function M.root()
  local source = debug.getinfo(1, "S").source or ""
  local path = source:gsub("^@", "")
  local dir = path:match("^(.*)[/\\]lua[/\\]kaeru[/\\]karu%.lua$")
  return dir
end

---@param path string
---@return boolean
local function executable_file(path)
  if not path or path == "" then
    return false
  end
  if vim.fn and vim.fn.executable then
    if vim.fn.executable(path) == 1 then
      return true
    end
  end
  local uv = vim.uv or vim.loop
  if uv and uv.fs_stat and uv.fs_access then
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file" and uv.fs_access(path, "X") then
      return true
    end
  end
  return false
end

--- The command that starts Karu, or nil + a reason.
---@return string[]|nil cmd, string|nil reason
function M.cli()
  local path = M.config().path
  if path and path ~= "" then
    if executable_file(path) then
      return { path }
    end
    return nil, "karu.path points at “" .. path .. "”, which is not executable"
  end
  local root = M.root()
  if root then
    local local_cli = root .. "/karu/bin/karu"
    if executable_file(local_cli) then
      return { local_cli }
    end
  end
  if vim.fn and vim.fn.executable and vim.fn.executable("karu") == 1 then
    return { "karu" }
  end
  return nil, "karu is not installed (expected karu/bin/karu inside the plugin, or `karu` in $PATH)"
end

local Config_options

--- Effective `karu` configuration with defaults applied.
---@return table
function M.config()
  local config = require("kaeru.config")
  Config_options = config.options -- luacheck: ignore
  local settings = config.options.karu or {}
  return {
    enabled = settings.enabled ~= false,
    path = settings.path,
    node = settings.node,
    name = settings.device_name or M.default_name,
    port = settings.port or M.default_port,
    mdns = settings.mdns ~= false,
    bridge = settings.bridge,
    token = settings.token,
    fallback = settings.fallback or "none",
    autostart = settings.autostart == true,
    notify = settings.notify ~= false,
    timeout = settings.timeout or 2500,
    devices = settings.devices or {},
    kikru_url = settings.kikru_url,
  }
end

--- `node --version` parsed as numbers.
---@return integer[]|nil
function M.node_version()
  if not (vim.fn and vim.fn.executable and vim.fn.executable("node") == 1) then
    return nil
  end
  local out = vim.fn.system({ "node", "--version" })
  if type(out) ~= "string" then
    return nil
  end
  local major, minor = out:match("v(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor) }
end

--- Node new enough for type-stripping (22.6+), or a compiled `dist/` build.
---@return boolean ok, string|nil reason
function M.available()
  local cmd, reason = M.cli()
  if not cmd then
    return false, reason
  end
  local cfg = M.config()
  if cfg.node and executable_file(cfg.node) then
    return true
  end
  local version = M.node_version()
  if not version then
    return false, "node is not installed — Karu needs Node ≥ 22.6 (or a compiled karu/dist)"
  end
  local needed = M.min_node
  if version[1] < needed[1] or (version[1] == needed[1] and version[2] < needed[2]) then
    local root = M.root()
    local dist = root and (root .. "/karu/dist/src/cli.js")
    if dist and executable_file(dist) then
      return true
    end
    return false, ("node %d.%d is too old — Karu needs ≥ %d.%d (or run `npm run build` in karu/)"):format(version[1], version[2], needed[1], needed[2])
  end
  return true
end

--- One-line status for statuslines / `:Kaeru integrations`.
---@return string
function M.summary()
  local available, reason = M.available()
  local receiver = M.receiver_running() and "receiving" or "idle"
  local count = #M.devices()
  if not available then
    return "karu: unavailable (" .. (reason or "?") .. ")"
  end
  return ("karu: %s · %d device(s)"):format(receiver, count)
end

-- ---------------------------------------------------------------------------
-- running the CLI
-- ---------------------------------------------------------------------------

---@param message string
---@param level? integer
local function notify(message, level)
  if not M.config().notify then
    return
  end
  local ui = require("kaeru.ui")
  if ui and ui.notify then
    ui.notify(message, level)
  elseif vim.notify then
    vim.notify(message, level)
  end
end
M.notify = notify

--- Run the Karu CLI, streaming JSON objects to `on_event`.
---@param args string[]
---@param opts? { on_event?: fun(payload: table|string), on_exit?: fun(code: integer), cwd?: string }
---@return integer|nil job
function M.run(args, opts, on_event, on_exit)
  opts = opts or {}
  local cmd, reason = M.cli()
  if not cmd then
    if opts.on_exit then
      opts.on_exit(127)
    end
    return nil, reason
  end
  if not (vim.fn and vim.fn.jobstart) then
    return nil, "jobstart is unavailable in this environment"
  end

  local argv = { cmd[1] }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end

  local buffers = { out = "", err = "" }
  local function consume(stream, data)
    local text = (buffers[stream] or "") .. (type(data) == "table" and table.concat(data, "\n") or tostring(data or ""))
    while true do
      local line, rest = text:match("^([^\n]*)\n(.*)$")
      if not line then
        break
      end
      text = rest
      if line ~= "" then
        local ok, payload = pcall(Json.decode, line)
        if ok and type(payload) == "table" then
          if opts.on_event then
            opts.on_event(payload)
          end
        elseif opts.on_event and line:sub(1, 1) ~= "#" then
          opts.on_event(line)
        end
      end
    end
    buffers[stream] = text
  end

  local job = vim.fn.jobstart(argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    cwd = opts.cwd,
    on_stdout = function(_, data)
      consume("out", data)
    end,
    on_stderr = function(_, data)
      consume("err", data)
    end,
    on_exit = function(_, code)
      if opts.on_exit then
        opts.on_exit(code)
      end
    end,
  })
  if job <= 0 then
    return nil, "could not start " .. argv[1]
  end
  return job
end

--- Run the CLI and collect the first JSON object it prints.
---@param args string[]
---@param cb fun(err: string|nil, payload: table|nil)
function M.request(args, cb)
  local available, reason = M.available()
  if not available then
    return cb(reason or "karu is unavailable", nil)
  end
  local done = false
  local job
  job = M.run(vim.list_extend({ "--json" }, args), {}, function(payload)
    if done or type(payload) ~= "table" then
      return
    end
    done = true
    if job and vim.fn.jobstop then
      pcall(vim.fn.jobstop, job)
    end
    if payload.ok == false then
      return cb(payload.error or "karu failed", payload)
    end
    cb(nil, payload)
  end, function(code)
    if not done then
      done = true
      cb("karu exited with code " .. tostring(code), nil)
    end
  end)
  return job
end

-- ---------------------------------------------------------------------------
-- discovery
-- ---------------------------------------------------------------------------

M._devices = {}
M._devices_at = 0

--- Cached device list (for completion and the statusline).
---@return table[]
function M.devices()
  return M._devices or {}
end

---@param device table
---@return string
function M.device_label(device)
  if type(device) ~= "table" then
    return tostring(device)
  end
  local host = device.address or device.host
  local name = device.name or host or "device"
  if host and device.port then
    return ("%s (%s:%d)"):format(name, host, device.port)
  end
  if host then
    return ("%s (%s)"):format(name, host)
  end
  return name
end

---@param opts? { timeout?: integer, address?: string|string[], force?: boolean }
---@param cb fun(err: string|nil, devices: table[]|nil)
function M.discover(opts, cb)
  opts = opts or {}
  local cfg = M.config()
  if not opts.force and #M.devices() > 0 and (os.time() - M._devices_at) < 30 then
    return cb(nil, M.devices())
  end
  local args = { "discover", "--timeout", tostring(opts.timeout or cfg.timeout) }
  local addresses = {}
  if type(opts.address) == "string" then
    addresses[#addresses + 1] = opts.address
  elseif type(opts.address) == "table" then
    vim.list_extend(addresses, opts.address)
  end
  vim.list_extend(addresses, cfg.devices)
  for _, entry in ipairs(addresses) do
    args[#args + 1] = "--address"
    args[#args + 1] = entry
  end

  local function finish(err, payload)
    if err then
      return cb(err, nil)
    end
    M._devices = payload.devices or {}
    M._devices_at = os.time()
    cb(nil, M._devices)
  end

  local done = false
  local job
  job = M.run(args, {}, function(payload)
    if done or type(payload) ~= "table" or payload.count == nil then
      return
    end
    done = true
    if job and vim.fn.jobstop then
      pcall(vim.fn.jobstop, job)
    end
    finish(payload.ok == false and (payload.error or "discovery failed") or nil, payload)
  end, function(code)
    if not done then
      done = true
      finish("karu discover exited with code " .. tostring(code), nil)
    end
  end)
  return job
end

---@param device? string
---@return string[]
local function device_args(device)
  if device == nil or device == "" then
    return {}
  end
  return { "--device", tostring(device) }
end

-- ---------------------------------------------------------------------------
-- sender commands
-- ---------------------------------------------------------------------------

--- Cast a URL (or a search query that yt-dlp resolves) to a device.
---@param target string
---@param opts? { device?: string, autoplay?: boolean, title?: string, cb?: fun(err, payload) }
function M.cast(target, opts, cb)
  opts = opts or {}
  cb = cb or opts.cb
  local args = { "cast", target }
  vim.list_extend(args, device_args(opts.device))
  if opts.autoplay == false then
    args[#args + 1] = "--autoplay"
    args[#args + 1] = "false"
  end
  if opts.title then
    args[#args + 1] = "--title"
    args[#args + 1] = tostring(opts.title)
  end
  local payload_cb = cb or function(err, payload)
    notify(err and ("Karu: " .. err) or ("Karu cast started: " .. ((payload and payload.device and payload.device.name) or "device")), err and vim.log.levels.ERROR or vim.log.levels.INFO)
  end
  return M.request(args, payload_cb)
end

--- transport control: play · pause · toggle · stop · quit · status
---@param action string
---@param device? string
---@param cb? fun(err, payload)
function M.control(action, device, cb)
  return M.request(vim.list_extend({ "control", action }, device_args(device)), cb or function(err, payload)
    notify(err and ("Karu: " .. err) or ("Karu " .. action .. (payload and payload.device and (" → " .. payload.device.name) or "")), err and vim.log.levels.ERROR or vim.log.levels.INFO)
  end)
end

---@param seconds number
---@param device? string
---@param cb? fun(err, payload)
function M.seek(seconds, device, cb)
  return M.request(vim.list_extend({ "seek", tostring(seconds) }, device_args(device)), cb)
end

---@param value string|number  `0-100`, `+5`, `-5`, `mute`, `unmute`
---@param device? string
---@param cb? fun(err, payload)
function M.volume(value, device, cb)
  return M.request(vim.list_extend({ "volume", tostring(value) }, device_args(device)), cb)
end

---@param device? string
---@param cb? fun(err, payload)
function M.status(device, cb)
  return M.request(vim.list_extend({ "status" }, device_args(device)), cb)
end

---@param host string
---@param cb? fun(err, payload)
function M.probe(host, cb)
  return M.request({ "probe", host }, cb or function(err, payload)
    notify(err and ("Karu: " .. err) or ("Karu: " .. host .. " answered"), err and vim.log.levels.ERROR or vim.log.levels.INFO)
  end)
end

--- Protocol + environment report.
---@param cb? fun(err, payload)
function M.info(cb)
  return M.request({ "info" }, cb)
end

-- ---------------------------------------------------------------------------
-- receiver
-- ---------------------------------------------------------------------------

M._receiver = { job = nil, info = nil }

---@return boolean
function M.receiver_running()
  return M._receiver.job ~= nil
end

---@return table|nil
function M.receiver_info()
  return M._receiver.info
end

--- Start the Cast receiver (advertises this machine and bridges to Kikru).
---@param opts? { name?: string, port?: integer, mdns?: boolean, address?: string, bridge?: string, token?: string, fallback?: string, on_ready?: fun(info: table) }
---@return integer|nil job, string|nil err
function M.receive(opts, on_ready)
  opts = opts or {}
  local cfg = M.config()
  if M.receiver_running() then
    if on_ready then
      on_ready(M._receiver.info)
    end
    return M._receiver.job, nil
  end
  local args = {
    "receive",
    "--name", opts.name or cfg.name,
    "--port", tostring(opts.port or cfg.port),
    "--bridge", opts.bridge or cfg.bridge or cfg.kikru_url or "http://127.0.0.1:8722",
    "--fallback", opts.fallback or cfg.fallback,
  }
  if opts.mdns == false or (opts.mdns == nil and cfg.mdns == false) then
    args[#args + 1] = "--no-mdns"
  end
  if opts.address then
    args[#args + 1] = "--address"
    args[#args + 1] = opts.address
  end
  local token = opts.token or cfg.token
  if token and token ~= "" then
    args[#args + 1] = "--token"
    args[#args + 1] = token
  end

  local job = M.run(args, {}, function(payload)
    if type(payload) ~= "table" then
      return
    end
    if payload.event == "ready" then
      M._receiver.info = payload
      notify(
        ("Karu is a Cast device now: “%s” on %s:%d — cast from the YouTube Music app"):format(payload.name, payload.address, payload.port),
        vim.log.levels.INFO
      )
      if on_ready then
        on_ready(payload)
      end
    elseif payload.event == "cast" then
      notify("Karu: cast received · " .. tostring(payload.url or ""), vim.log.levels.INFO)
    elseif payload.event == "stopped" then
      M._receiver = { job = nil, info = nil }
    end
  end, function(code)
    if M._receiver.job == job then
      M._receiver = { job = nil, info = nil }
    end
    if code ~= 0 and code ~= 143 then
      notify("Karu receiver exited with code " .. tostring(code), vim.log.levels.WARN)
    end
  end)
  if job then
    M._receiver.job = job
  end
  return job, job and nil or "could not start the Karu receiver"
end

--- Stop the receiver if it is running.
---@return boolean stopped
function M.stop_receiver()
  local job = M._receiver.job
  if not job then
    return false
  end
  if vim.fn and vim.fn.jobstop then
    pcall(vim.fn.jobstop, job)
  end
  M._receiver = { job = nil, info = nil }
  return true
end

--- A `kikru://`-style deep link that opens the cast page; used by the UI.
---@return string
function M.cast_url()
  local info = M._receiver.info
  if not info then
    return "http://127.0.0.1:8722"
  end
  return ("http://%s:%d"):format(info.address or "127.0.0.1", info.port or M.default_port)
end

--- Everything a UI needs, in one place.
---@return table
function M.snapshot()
  local available, reason = M.available()
  return {
    available = available,
    reason = reason,
    running = M.receiver_running(),
    info = M._receiver.info,
    devices = M.devices(),
    node = M.node_version(),
    cli = M.cli() or "",
    summary = M.summary(),
    subcommands = M.subcommands(),
    config = M.config(),
    url = M.cast_url(),
  }
end


-- ---------------------------------------------------------------------------
-- :Karu
-- ---------------------------------------------------------------------------

local HELP = {
  "Karu — Google Cast (karu/, TypeScript)",
  "",
  "  :Karu                        status of the first device",
  "  :Karu discover [host:port]   list Cast devices on the network",
  "  :Karu cast <url|query> [dev] cast to a device (yt-dlp resolves searches)",
  "  :Karu play|pause|toggle|quit|next|prev [dev]",
  "  :Karu stop [dev]             stop playback on the device",
  "  :Karu control <action> [dev] raw CLI action (play, pause, status, …)",
  "  :Karu seek <seconds> [dev]",
  "  :Karu volume <0-100|+N|-N|mute|unmute> [dev]",
  "  :Karu probe <host[:port]>    reachability test",
  "  :Karu receive [--name N] [--port P] [--no-mdns] [--fallback mpv]",
  "  :Karu off                    stop the receiver",
  "  :Karu bridge                 receiver + Kikru bridge status",
  "  :Karu info | version         protocol/environment report",
  "  :Karu json                   machine-readable snapshot of the bridge",
  "",
  "Cast from the YouTube / YouTube Music app: run `:Karu receive` once and pick",
  "“" .. M.default_name .. "” in the app's Cast list; playback lands in Kikru.",
}

---@param message string
---@param level? integer
local function report(message, level)
  notify(message, level)
end

--- Make sure something can receive the casts we bridge to.
---@param opts table
local function ensure_bridge(opts)
  local bridge = opts.bridge or M.config().bridge
  if bridge and not bridge:match("^https?://127%.0%.0%.1") and not bridge:match("^https?://localhost") then
    return
  end
  local ok, cast = pcall(require, "kaeru.kikru.cast")
  if not ok or not cast or not cast.start_server then
    return
  end
  local running = cast.server_running and cast.server_running()
  if running then
    return
  end
  local started = cast.start_server(cast.port and cast.port() or nil)
  if started then
    notify(("Karu: started the Kikru cast bridge on http://127.0.0.1:%d"):format(cast.port and cast.port() or 8722), vim.log.levels.INFO)
  end
end

---@param text string
---@return table
--- Receiver flags → the `karu receive` option table.
---@param args string[]
---@return table
function M.parse_receive_flags(words)
  local opts = {}
  local index = 1
  while index <= #words do
    local word = words[index]
    if word == "--name" then
      opts.name = words[index + 1]
      index = index + 2
    elseif word == "--port" then
      opts.port = tonumber(words[index + 1])
      index = index + 2
    elseif word == "--bridge" then
      opts.bridge = words[index + 1]
      index = index + 2
    elseif word == "--token" then
      opts.token = words[index + 1]
      index = index + 2
    elseif word == "--fallback" then
      opts.fallback = words[index + 1]
      index = index + 2
    elseif word == "--no-mdns" or word == "--no-mdns=true" then
      opts.mdns = false
      index = index + 1
    elseif word == "--address" then
      opts.address = words[index + 1]
      index = index + 2
    else
      index = index + 1
    end
  end
  return opts
end

--- Open a picker over the discovered devices and show what it is doing.
---@param cb fun(device: table|nil)
function M.pick_device(cb)
  M.discover({ force = true }, function(err, devices)
    if err or not devices or #devices == 0 then
      return report("Karu: " .. (err or "no Cast devices found"), vim.log.levels.WARN)
    end
    local labels = {}
    for _, device in ipairs(devices) do
      labels[#labels + 1] = M.device_label(device)
    end
    require("kaeru.integrations").pick(labels, {
      title = "Cast devices",
      on_choice = function(choice, index)
        local picked = devices[index] or devices[choice]
        if picked then
          cb(picked)
        end
      end,
    })
  end)
end

--- A one-line playback summary for `:Karu status`.
---@param payload table|nil
---@param device? string
---@return string
local function status_text(payload, device)
  if type(payload) ~= "table" then
    return "Karu: no status"
  end
  local media = payload.media or payload.status or {}
  local state = media.playerState or payload.playerState or "IDLE"
  local title = (media.media and media.media.metadata and media.media.metadata.title) or payload.title
  local position = tonumber(media.currentTime or payload.currentTime or 0) or 0
  local parts = { ("Karu%s · %s"):format(device and (" " .. device) or "", state) }
  if title and title ~= "" then
    parts[#parts + 1] = title
  end
  if position > 0 then
    parts[#parts + 1] = ("%.1fs"):format(position)
  end
  if payload.device then
    parts[#parts + 1] = payload.device.name or payload.device.host or ""
  end
  return table.concat(parts, " · ")
end

---@param args string[]
---@param opts? { bang?: boolean }
function M.dispatch(args, opts)
  opts = opts or {}
  local sub = args[1]

  if sub == nil or sub == "status" then
    local device = args[2]
    M.status(device, function(err, payload)
      if err then
        return report("Karu: " .. err, vim.log.levels.WARN)
      end
      report(status_text(payload, device), vim.log.levels.INFO)
    end)
  elseif sub == "control" then
    local action = args[2] or "status"
    M.control(action, args[3])
  elseif sub == "discover" or sub == "devices" or sub == "ls" then
    local address = args[2] and not args[2]:match("^%-") and args[2] or nil
    M.discover({ force = true, address = address }, function(err, devices)
      if err then
        return report("Karu: " .. err, vim.log.levels.ERROR)
      end
      if #devices == 0 then
        return report("Karu: no Cast devices found (add one with karu.devices in kaeru.yaml)", vim.log.levels.WARN)
      end
      if opts.bang then
        return M.pick_device(function() end)
      end
      local lines = { "Cast devices:" }
      for index, device in ipairs(devices) do
        lines[#lines + 1] = ("  %d. %s"):format(index, M.device_label(device))
      end
      lines[#lines + 1] = "Use `:Karu cast <url> <device>` or `:Karu status <device>`"
      report(table.concat(lines, "\n"), vim.log.levels.INFO)
    end)
  elseif sub == "cast" then
    local target = args[2]
    if not target then
      return report("Karu: cast needs a URL or a search query", vim.log.levels.ERROR)
    end
    M.cast(target, { device = args[3] })
  elseif sub == "play" or sub == "pause" or sub == "toggle" or sub == "quit" or sub == "next" or sub == "prev" then
    M.control(sub, args[2])
  elseif sub == "stop" then
    local device = args[2]
    if device == nil and not M.devices()[1] then
      return report("Karu: nothing to stop", vim.log.levels.WARN)
    end
    M.control("stop", device)
  elseif sub == "seek" then
    local seconds = tonumber(args[2])
    if not seconds then
      return report("Karu: seek needs a number of seconds", vim.log.levels.ERROR)
    end
    M.seek(seconds, args[3], function(err)
      if err then
        report("Karu: " .. err, vim.log.levels.ERROR)
      end
    end)
  elseif sub == "volume" then
    local value = args[2] or "toggle"
    if value == "up" then
      value = "+10"
    elseif value == "down" then
      value = "-10"
    end
    M.volume(value, args[3], function(err, payload)
      if err then
        return report("Karu: " .. err, vim.log.levels.ERROR)
      end
      local volume = payload and payload.volume or {}
      report(("Karu: volume %d%%%s"):format(math.floor(((volume.level or 0) * 100) + 0.5), volume.muted and " (muted)" or ""), vim.log.levels.INFO)
    end)
  elseif sub == "probe" then
    if not args[2] then
      return report("Karu: probe needs host[:port]", vim.log.levels.ERROR)
    end
    M.probe(args[2])
  elseif sub == "receive" or sub == "start" or sub == "on" then
    if sub ~= "receive" and args[2] == "stop" then
      return M.stop_receiver() and report("Karu: receiver stopped", vim.log.levels.INFO)
      or report("Karu: the receiver is not running", vim.log.levels.WARN)
    end
    local receive_opts = M.parse_receive_flags(Compat.list_slice(args, 2))
    ensure_bridge(receive_opts)
    local job, err = M.receive(receive_opts)
    if err then
      return report("Karu: " .. err, vim.log.levels.ERROR)
    end
    local _ = job
  elseif sub == "off" or sub == "unreceive" or sub == "shutdown" or sub == "stop-receiver" then
    if M.stop_receiver() then
      report("Karu: receiver stopped", vim.log.levels.INFO)
    else
      report("Karu: the receiver is not running", vim.log.levels.WARN)
    end
  elseif sub == "bridge" then
    local ok, cast = pcall(require, "kaeru.kikru.cast")
    local bridge = M.config().bridge or M.config().kikru_url or "http://127.0.0.1:8722"
    local kikru_state = ok and cast and cast.server_running and cast.server_running() and "running" or "stopped"
    local info = M.receiver_info()
    report(
      ("Karu bridge → %s (Kikru cast server: %s)\nReceiver: %s"):format(
        bridge,
        kikru_state,
        info and ("“" .. info.name .. "” on " .. info.address .. ":" .. info.port .. " (id " .. tostring(info.deviceId) .. ")") or "stopped"
      ),
      vim.log.levels.INFO
    )
  elseif sub == "info" then
    M.info(function(err, payload)
      if err then
        return report("Karu: " .. err, vim.log.levels.ERROR)
      end
      report(
        ("Karu %s · node %s · %s:%d · id %s\nnamespaces: %s\ncert: %s"):format(
          payload.version,
          payload.node,
          payload.address,
          payload.port,
          payload.deviceId,
          table.concat(payload.namespaces or {}, ", "),
          payload.certDir
        ),
        vim.log.levels.INFO
      )
    end)
  elseif sub == "version" then
    M.info(function(err, payload)
      if err then
        return report("Karu: " .. err, vim.log.levels.ERROR)
      end
      report(("karu %s (node %s)"):format(payload.version, payload.node), vim.log.levels.INFO)
    end)
  elseif sub == "json" then
    report(require("kaeru.json").encode(M.snapshot()), vim.log.levels.INFO)
  elseif sub == "help" or sub == "?" or sub == "--help" then
    report(table.concat(HELP, "\n"), vim.log.levels.INFO)
  elseif sub:match("^https?://") or sub:match("^(ytsearch|ytmsearch|scsearch)") or sub:match("%S+%.%S+") then
    -- `:Karu <url|query> [device]` casts straight away
    M.cast(sub, { device = args[2] })
  else
    report("Karu: unknown subcommand “" .. tostring(sub) .. "” — try `:Karu help`", vim.log.levels.ERROR)
  end
end

--- A `:Karu help` text for docs/pickers.
---@return string[]
function M.help()
  return HELP
end

--- Command completion for `:Karu`.
---@return string[]
function M.subcommands()
  return {
    "discover", "devices", "cast", "play", "pause", "toggle", "stop", "quit",
    "next", "prev", "control", "seek", "volume", "status", "receive", "start",
    "stop-receiver", "probe", "info", "bridge", "json", "version", "help",
  }
end

local _ = Compat
return M
