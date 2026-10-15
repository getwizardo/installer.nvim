-- kaeru.nvim · :Kikru — remote control.
--
-- Two transports, one protocol:
--
--   * a local unix socket (`$XDG_RUNTIME_DIR/nvim-kaeru-kikru.sock`) for
--     headless/daemon mode — `:Kikru ipc play`, exactly like cliamp's
--     `cliamp ipc <command>` remote control;
--   * TCP for the **2-Neovim** setup: one Neovim instance is the server and
--     owns the audio output, any number of other instances connect as clients,
--     receive state snapshots and forward their commands.
--
-- Messages are newline delimited JSON (`kaeru.json`), every message is
-- versioned, the server answers with an `ack`, and peers exchange heartbeats
-- so a dead client is dropped instead of silently diverging.
local Json = require("kaeru.json")

local M = {}

local uv = vim.uv or vim.loop

M.protocol = 2
M.heartbeat = 5 -- seconds

---@class MusicDevice
---@field id string
---@field name string
---@field role "server"|"client"
---@field addr string
---@field pid number
---@field connected_at string
---@field last_seen number
---@field active boolean

--- Filled in by `kaeru.kikru` (avoids a require cycle).
---@type {dispatch: fun(action: string, args: table|nil): table, snapshot: fun(): table, ui: fun()|nil}
M.handlers = {}

---@param handlers table
function M.set_handlers(handlers)
  M.handlers = handlers
end

local function now()
  return os.time()
end

local function iso_time()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---@param value string
---@return string
local function short_hash(value)
  local hash = 5381
  for i = 1, #value do
    hash = (hash * 33 + value:byte(i)) % 4294967296
  end
  return ("%08x"):format(hash)
end

-- Sessions ------------------------------------------------------------------------

M.session = nil
M.role = "none" -- "none" | "server" | "client" | "daemon"

---@type MusicDevice[]
M.devices = {}

---@type table<string, {sock: any, addr: string, device: MusicDevice|nil, buffer: string, last_seen: number}>
M.peers = {}

M.server = nil
M.client = nil
M.ipc_server = nil
M._broadcast_rev = 0
M._broadcast_pending = false

---@return string
function M.device_id()
  local id = ("nvim-%s"):format(tostring(uv and uv.os_getpid and uv.os_getpid() or math.random(1000, 9999)))
  return id
end

---@param id? string
---@return MusicDevice
function M.local_device(id)
  return {
    id = id or M.device_id(),
    name = ("Neovim #%s (%s)"):format(tostring(uv and uv.os_getpid and uv.os_getpid() or "?"), M.role == "client" and "client" or "server"),
    role = M.role == "client" and "client" or "server",
    addr = "127.0.0.1",
    pid = uv and uv.os_getpid and uv.os_getpid() or 0,
    connected_at = iso_time(),
    last_seen = now(),
    active = M.role ~= "client",
  }
end

---@return MusicDevice[]
function M.device_list()
  local out = {}
  if #M.devices > 0 then
    for _, device in ipairs(M.devices) do
      out[#out + 1] = device
    end
  end
  return out
end

-- Message helpers ------------------------------------------------------------------

---@param message table
---@return string
local function encode(message)
  message.protocol = M.protocol
  message.ts = now()
  if message.type ~= "hello" and message.type ~= "welcome" then
    message.session = M.session
  end
  local ok, text = pcall(Json.encode, message)
  if not ok then
    return '{"type":"error","message":"encode failed"}\n'
  end
  return text .. "\n"
end

---@param sock any
---@param message table
---@return boolean ok
local function send(sock, message)
  if not sock then
    return false
  end
  local ok = pcall(function()
    sock:write(encode(message))
  end)
  if not ok and sock == M.client then
    M.client = nil
    M.role = "none"
  end
  return ok
end

--- Process one incoming message from a peer.
---@param message table
---@param sock any
---@param peer_id? string
---@return table|nil response
function M.handle_message(message, sock, peer_id)
  local mtype = message.type
  if mtype == "hello" then
    return {
      type = "paired",
      device = M.local_device(),
      server = {
        id = M.device_id(),
        name = "Neovim :Kikru Server",
        protocol = M.protocol,
      },
      state = M.handlers.snapshot and M.handlers.snapshot() or nil,
      devices = M.device_list(),
    }
  elseif mtype == "welcome" then
    -- client side: server introduced itself
    if message.state and M.handlers.apply_state then
      M.handlers.apply_state(message.state)
    end
    return { type = "hello", device = M.local_device(M.device_id()), protocol = M.protocol }
  elseif mtype == "paired" then
    if message.state and M.handlers.apply_state then
      M.handlers.apply_state(message.state)
    end
    if message.devices then
      M.devices = message.devices
    end
    return nil
  elseif mtype == "state" then
    if M.handlers.apply_state and message.state then
      M.handlers.apply_state(message.state, message.rev)
    end
    return nil
  elseif mtype == "command" then
    local result = { ok = true }
    if M.handlers.dispatch then
      local ok, res = pcall(M.handlers.dispatch, message.action, message.args or {}, { remote = true, peer = peer_id })
      result.ok = ok and (res == nil or res.ok ~= false)
      result.result = res
      result.error = not ok and tostring(res) or nil
    end
    result.type = "ack"
    result.id = message.id
    result.rev = M._broadcast_rev
    if M.role == "server" then
      M.schedule_broadcast()
    end
    return result
  elseif mtype == "ack" then
    if M.handlers.on_ack then
      M.handlers.on_ack(message)
    end
    return nil
  elseif mtype == "ping" then
    return { type = "pong", rev = M._broadcast_rev }
  elseif mtype == "pong" then
    local peer = peer_id and M.peers[peer_id]
    if peer then
      peer.last_seen = now()
    end
    return nil
  elseif mtype == "handoff" then
    if M.handlers.handoff then
      M.handlers.handoff(message.device_id, { remote = true })
    end
    if M.role == "server" then
      M.schedule_broadcast()
    end
    return { type = "ack", id = message.id, ok = true, rev = M._broadcast_rev }
  elseif mtype == "bye" then
    return nil
  elseif mtype == "error" then
    if M.handlers.on_error then
      M.handlers.on_error(message.message or "remote error")
    end
    return nil
  end
  return { type = "error", message = "unknown message type: " .. tostring(mtype) }
end

---@param chunk string
---@param buffer string
---@param handler fun(line: string)
---@return string leftover
function M.consume_lines(chunk, buffer, handler)
  buffer = (buffer or "") .. chunk
  while true do
    local newline = buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = buffer:sub(1, newline - 1)
    buffer = buffer:sub(newline + 1)
    if line ~= "" then
      handler(line)
    end
  end
  return buffer
end

--- Decode every complete line in `chunk` (JSON), returning the leftover buffer
--- and the decoded messages. Errors are reported through the callback instead
--- of aborting the stream.
---@param chunk string
---@param buffer? string
---@param on_error? fun(message: string)
---@return {buffer: string, messages: table[], errors: string[]}
function M.consume(chunk, buffer, on_error)
  local messages, errors = {}, {}
  local leftover = M.consume_lines(chunk, buffer or "", function(line)
    local message, err = Json.decode(line)
    if message == nil then
      err = err or "invalid JSON"
      errors[#errors + 1] = err
      if on_error then
        on_error(err)
      end
    else
      messages[#messages + 1] = message
    end
  end)
  return { buffer = leftover, messages = messages, errors = errors }
end

-- 2-Neovim TCP controller -----------------------------------------------------------

--- Broadcast the current state to every connected client (throttled to one
--- broadcast per event-loop tick so a volume sweep does not flood the socket).
function M.schedule_broadcast()
  if M.role ~= "server" then
    return
  end
  if M._broadcast_pending then
    return
  end
  M._broadcast_pending = true
  vim.schedule(function()
    M._broadcast_pending = false
    M.broadcast()
  end)
end

---@param force? boolean
function M.broadcast(force)
  if M.role ~= "server" then
    return
  end
  M._broadcast_rev = M._broadcast_rev + 1
  local message = {
    type = "state",
    rev = M._broadcast_rev,
    state = M.handlers.snapshot and M.handlers.snapshot() or {},
    devices = M.device_list(),
  }
  local _ = force
  for id, peer in pairs(M.peers) do
    if not send(peer.sock, message) then
      M.peers[id] = nil
    end
  end
end

--- Start the TCP server Neovim instance.
---@param opts? {port?: integer, host?: string, token?: string}
---@return boolean ok, string msg
function M.start_server(opts)
  opts = opts or {}
  local port = tonumber(opts.port) or 41999
  local host = opts.host or "127.0.0.1"
  if not uv or not uv.new_tcp then
    M.role = "server"
    return true, ("Started :Kikru server on %s:%d (libuv missing, state-only mode)"):format(host, port)
  end
  M.disconnect()
  local server = uv.new_tcp()
  local ok_bind, bind_err = server:bind(host, port)
  if not ok_bind then
    return false, ("could not bind %s:%d — %s"):format(host, port, tostring(bind_err))
  end
  M.server = server
  M.role = "server"
  M.session = short_hash(("%s:%d:%d"):format(host, port, now()))
  M.devices = { M.local_device() }
  M.devices[1].addr = ("%s:%d"):format(host, port)

  server:listen(32, function(err)
    if err then
      return
    end
    local sock = uv.new_tcp()
    server:accept(sock)
    local peer = sock:getpeername() or {}
    local addr = ("%s:%s"):format(peer.ip or "?", tostring(peer.port or 0))
    local id = short_hash(addr .. tostring(now()))
    local record = { sock = sock, addr = addr, device = nil, buffer = "", last_seen = now() }
    M.peers[id] = record
    send(sock, {
      type = "welcome",
      server = { id = M.device_id(), name = "Neovim :Kikru Server", protocol = M.protocol },
      session = M.session,
      requires_token = opts.token ~= nil and opts.token ~= "",
      state = M.handlers.snapshot and M.handlers.snapshot() or {},
      devices = M.device_list(),
    })
    sock:read_start(function(read_err, chunk)
      if read_err or not chunk then
        pcall(function()
          sock:close()
        end)
        M.peers[id] = nil
        return
      end
      record.buffer = M.consume_lines(chunk, record.buffer, function(line)
        vim.schedule(function()
          local message, decode_err = Json.decode_line(line)
          if not message then
            send(sock, { type = "error", message = "invalid JSON: " .. tostring(decode_err) })
            return
          end
          if opts.token ~= nil and opts.token ~= "" and message.token ~= opts.token and message.type ~= "hello" then
            send(sock, { type = "error", message = "invalid token" })
            return
          end
          if message.type == "hello" then
            local device = message.device or {}
            record.device = {
              id = device.id or id,
              name = device.name or ("Neovim client %s"):format(addr),
              role = "client",
              addr = addr,
              pid = device.pid or 0,
              connected_at = iso_time(),
              last_seen = now(),
              active = false,
            }
            M.devices[#M.devices + 1] = record.device
          end
          record.last_seen = now()
          local response = M.handle_message(message, sock, id)
          if response then
            send(sock, response)
          else
            send(sock, { type = "ack", id = message.id, ok = true, rev = M._broadcast_rev })
          end
        end)
      end)
    end)
  end)

  M.start_heartbeat()
  return true, ("Started 2-Neovim :Kikru server on %s:%d"):format(host, port)
end

--- Connect this Neovim instance as a client.
---@param opts? {host?: string, port?: integer, token?: string, name?: string}
---@return boolean ok, string msg
function M.connect_client(opts)
  opts = opts or {}
  local host = opts.host or "127.0.0.1"
  local port = tonumber(opts.port) or 41999
  if not uv or not uv.new_tcp then
    M.role = "client"
    return true, ("Connected as client to %s:%d (libuv missing, state-only mode)"):format(host, port)
  end
  M.disconnect()
  local sock = uv.new_tcp()
  M.client = sock
  M.role = "client"
  M.devices = { M.local_device() }
  local record = { sock = sock, addr = ("%s:%d"):format(host, port), buffer = "", last_seen = now() }
  M.peers.server = record

  local connected = false
  sock:connect(host, port, function(err)
    vim.schedule(function()
      if err then
        M.client = nil
        M.role = "none"
        M.emit_error(("could not connect to %s:%d — %s"):format(host, port, tostring(err)))
        return
      end
      connected = true
      send(sock, { type = "hello", device = M.local_device(M.device_id()), token = opts.token })
      if M.handlers.on_connect then
        M.handlers.on_connect(host, port)
      end
    end)
  end)

  sock:read_start(function(read_err, chunk)
    if read_err or not chunk then
      vim.schedule(function()
        if connected then
          M.emit_error("disconnected from the :Kikru server")
        end
        M.client = nil
        M.role = "none"
      end)
      pcall(function()
        sock:close()
      end)
      return
    end
    record.buffer = M.consume_lines(chunk, record.buffer, function(line)
      vim.schedule(function()
        local message = Json.decode_line(line)
        if not message then
          return
        end
        record.last_seen = now()
        local response = M.handle_message(message, sock, "server")
        if response then
          send(sock, response)
        end
      end)
    end)
  end)

  M.start_heartbeat()
  return true, ("Connecting to :Kikru server at %s:%d…"):format(host, port)
end

--- Send a command from a client to the server (used by every local action while
--- connected as client).
---@param action string
---@param args? table
---@return boolean sent
function M.send_command(action, args)
  if not M.client then
    return false
  end
  M._command_id = (M._command_id or 0) + 1
  return send(M.client, {
    type = "command",
    id = M._command_id,
    action = action,
    args = args or {},
    device_id = M.device_id(),
  })
end

--- Ask the server to route audio output to `device_id`.
---@param device_id string
---@return boolean sent
function M.handoff(device_id)
  if M.role == "server" then
    if M.handlers.handoff then
      M.handlers.handoff(device_id)
    end
    M.schedule_broadcast()
    return true
  end
  if not M.client then
    return false
  end
  return send(M.client, { type = "handoff", device_id = device_id })
end

---@param message string
function M.emit_error(message)
  local UI = require("kaeru.ui")
  UI.notify(message, vim.log.levels.ERROR)
end

--- Heartbeats: the server pings every `M.heartbeat` seconds and drops peers
--- that did not answer within two intervals.
function M.start_heartbeat()
  if not (uv and uv.new_timer) then
    return
  end
  M.stop_heartbeat()
  local timer = uv.new_timer()
  M._heartbeat = timer
  timer:start(M.heartbeat * 1000, M.heartbeat * 1000, function()
    vim.schedule(function()
      if M.role == "server" then
        local deadline = now() - M.heartbeat * 2
        for id, peer in pairs(M.peers) do
          if peer.last_seen < deadline then
            pcall(function()
              peer.sock:close()
            end)
            M.peers[id] = nil
            for index, device in ipairs(M.devices) do
              if device.addr == peer.addr then
                table.remove(M.devices, index)
                break
              end
            end
          else
            send(peer.sock, { type = "ping" })
          end
        end
      elseif M.client then
        send(M.client, { type = "ping" })
      end
    end)
  end)
end

function M.stop_heartbeat()
  if M._heartbeat then
    pcall(function()
      M._heartbeat:stop()
      M._heartbeat:close()
    end)
    M._heartbeat = nil
  end
end

--- Tear down server/client/IPC state.
function M.disconnect()
  for _, peer in pairs(M.peers) do
    pcall(function()
      peer.sock:close()
    end)
  end
  M.peers = {}
  if M.client then
    pcall(function()
      M.client:close()
    end)
    M.client = nil
  end
  if M.server then
    pcall(function()
      M.server:close()
    end)
    M.server = nil
  end
  M.stop_heartbeat()
  M.devices = {}
  M.role = "none"
  M.session = nil
end

-- Local IPC / daemon mode -----------------------------------------------------------

---@return string
function M.ipc_path()
  local Config = require("kaeru.config")
  local configured = Config.options.music and Config.options.music.ipc_socket
  if configured and configured ~= "" then
    return vim.fn.expand(configured)
  end
  local runtime = vim.env.XDG_RUNTIME_DIR
  local base = (runtime and runtime ~= "") and runtime or (vim.fn.stdpath("cache") .. "/kaeru")
  return base .. "/nvim-kaeru-kikru.sock"
end

--- Start the local IPC socket (idempotent).
---@param path? string
---@return boolean ok, string msg
function M.start_ipc(path)
  path = path or M.ipc_path()
  if M.ipc_server then
    return true, "IPC already listening on " .. path
  end
  if not uv or not uv.new_pipe then
    return false, "libuv is required for the :Kikru IPC socket"
  end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  pcall(function()
    vim.fn.delete(path)
  end)
  local pipe = uv.new_pipe(false)
  local ok, err = pcall(function()
    pipe:bind(path)
  end)
  if not ok then
    return false, "could not bind " .. path .. ": " .. tostring(err)
  end
  M.ipc_server = pipe
  M.ipc_path_value = path
  pipe:listen(16, function(listen_err)
    if listen_err then
      return
    end
    local client = uv.new_pipe(false)
    pipe:accept(client)
    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        pcall(function()
          client:close()
        end)
        return
      end
      buffer = M.consume_lines(chunk, buffer, function(line)
        vim.schedule(function()
          local response = M.handle_ipc_line(line)
          if response then
            pcall(function()
              client:write(Json.encode(response) .. "\n")
            end)
          end
        end)
      end)
    end)
  end)
  M.role = M.role == "client" and "client" or "daemon"
  return true, "IPC socket listening on " .. path
end

--- Handle a single IPC request line (also used by the tests directly).
---@param line string
---@return table response
function M.handle_ipc_line(line)
  local message, err = Json.decode_line(line)
  if not message then
    return { ok = false, error = err or "invalid request" }
  end
  if message.type == "status" or message.command == "status" then
    return { ok = true, state = M.handlers.snapshot and M.handlers.snapshot() or {} }
  end
  local action = message.action or message.command
  if not action then
    return { ok = false, error = "missing action" }
  end
  if not M.handlers.dispatch then
    return { ok = false, error = "no command handler registered" }
  end
  local ok, result = pcall(M.handlers.dispatch, action, message.args or message, { remote = true, ipc = true })
  return {
    ok = ok and (result == nil or result.ok ~= false),
    action = action,
    result = result,
    error = not ok and tostring(result) or nil,
    state = M.handlers.snapshot and M.handlers.snapshot() or nil,
  }
end

--- Send a command to a running IPC server (`:Kikru ipc <cmd> [args]`).
---@param action string
---@param args? table
---@param opts? {path?: string, timeout?: number}
---@param cb? fun(ok: boolean, response: table|nil, err: string|nil)
---@return boolean
function M.ipc_send(action, args, opts, cb)
  opts = opts or {}
  path = opts.path or M.ipc_path()
  if not (uv and uv.new_pipe) then
    if cb then
      cb(false, nil, "libuv is required")
    end
    return false
  end
  local pipe = uv.new_pipe(false)
  local payload = Json.encode({ action = action, args = args or {}, protocol = M.protocol }) .. "\n"
  local buffer = ""
  local done = false
  local function finish(ok, response, err)
    if done then
      return
    end
    done = true
    pcall(function()
      pipe:close()
    end)
    if cb then
      cb(ok, response, err)
    end
  end
  local timeout = (opts.timeout or 10) * 1000
  if uv.new_timer then
    local timer = uv.new_timer()
    timer:start(timeout, 0, function()
      timer:stop()
      timer:close()
      vim.schedule(function()
        finish(false, nil, "timed out waiting for the :Kikru daemon")
      end)
    end)
  end
  pipe:connect(path, function(err)
    if err then
      return vim.schedule(function()
        finish(false, nil, ("no :Kikru daemon at %s (%s)"):format(path, tostring(err)))
      end)
    end
    pcall(function()
      pipe:write(payload)
    end)
    pipe:read_start(function(read_err, chunk)
      if read_err or not chunk then
        return vim.schedule(function()
          finish(false, nil, "daemon closed the connection")
        end)
      end
      buffer = buffer .. chunk
      local newline = buffer:find("\n", 1, true)
      if newline then
        local line = buffer:sub(1, newline - 1)
        vim.schedule(function()
          local response = Json.decode(line)
          finish(response ~= nil, response, response == nil and "invalid response" or nil)
        end)
      end
    end)
  end)
  return true
end

--- Stop the IPC server.
function M.stop_ipc()
  if M.ipc_server then
    pcall(function()
      M.ipc_server:close()
    end)
    M.ipc_server = nil
  end
  if M.ipc_path_value then
    pcall(vim.fn.delete, M.ipc_path_value)
  end
end

--- One-line status line for the daemon/IPC state (used by the UI footer).
---@return string
function M.transport_label()
  if M.role == "server" then
    return ("SERVER %s · %d peer(s)"):format(M.session or "?", math.max(0, #M.devices - 1))
  elseif M.role == "client" then
    return "CLIENT → " .. (M.peers.server and M.peers.server.addr or "server")
  elseif M.ipc_server then
    return "DAEMON · " .. M.ipc_path_value
  end
  return "STANDALONE"
end

return M
