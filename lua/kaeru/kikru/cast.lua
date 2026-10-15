-- kaeru.nvim · Kikru: cast YouTube / YouTube Music (and friends) into Neovim.
--
-- The workflow this module implements is the one every music player has these
-- days: you are watching something in the YouTube/YouTube Music app (or in a
-- browser tab) and you want it to keep playing, but through Kikru, with the
-- 10-band EQ, the NodeLink filter chain and the spectrum analyzer on top.
--
-- Three ways in:
--
--   1. `:Kikru cast https://music.youtube.com/watch?v=…`
--      `:Kikru youtube lofi hip hop`          (YouTube search)
--      `:Kikru ytmusic daft punk discovery`   (YouTube Music search)
--      → resolved with yt-dlp, then queued/played.
--
--   2. The built-in cast server (`:Kikru cast server`): a tiny HTTP listener on
--      127.0.0.1 that accepts `GET /cast?url=…`, `POST /cast {"url": …}` plus
--      transport endpoints (`/play`, `/next`, `/volume?value=70`, …). Point a
--      browser bookmarklet, an iOS/Android shortcut, a Stream Deck or a phone
--      on the same Wi-Fi at it and the link lands in Neovim. A `kikru://` URL
--      scheme handler (`:Kikru cast scheme`) makes "Open with Kikru" work from
--      any OS dialog.
--
--   3. `:Kikru appcast` reads the *currently playing* item from any MPRIS
--      player (the YouTube Music desktop app, a Chromium/Brave/Firefox tab,
--      Spotify, VLC, …) and continues it inside Kikru, this is the "cast the
--      app you already have open" path and needs no browser extension.
--
-- Everything network-ish is optional: without yt-dlp the URLs are still
-- classified, canonicalised and handed to the backend if it can play them.
local Compat = require("kaeru.compat")
local Json = require("kaeru.json")
local Sources = require("kaeru.kikru.sources")
local Tags = require("kaeru.kikru.tags")

local M = {}

M.default_port = 8722
M.scheme = "kikru"

--- Hosts the cast feature understands, mapped to a friendly app name.
M.hosts = {
  ["youtube.com"] = "youtube",
  ["www.youtube.com"] = "youtube",
  ["m.youtube.com"] = "youtube",
  ["music.youtube.com"] = "youtube_music",
  ["youtu.be"] = "youtube",
  ["www.youtubekids.com"] = "youtube_kids",
  ["youtubekids.com"] = "youtube_kids",
}

--- Everything else we can still hand to yt-dlp / a direct stream.
M.stream_hosts = {
  ["soundcloud.com"] = "soundcloud",
  ["bandcamp.com"] = "bandcamp",
  ["mixcloud.com"] = "mixcloud",
  ["bilibili.com"] = "bilibili",
  ["twitch.tv"] = "twitch",
  ["vimeo.com"] = "vimeo",
  ["dailymotion.com"] = "dailymotion",
  ["archive.org"] = "archive",
  ["open.spotify.com"] = "spotify",
  ["music.apple.com"] = "apple_music",
  ["deezer.com"] = "deezer",
  ["music.yandex.ru"] = "yandex_music",
}

-- URL classification ---------------------------------------------------------------

---@param url string
---@return string|nil host, string|nil path, table query
local function split_url(url)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if scheme and scheme:lower() ~= "http" and scheme:lower() ~= "https" then
    -- mailto:, magnet:, spotify:, kikru:// … are not things we stream
    return nil
  end
  if not scheme then
    if url:match("^%a[%w+.-]*:[^/]") then
      return nil -- a scheme we do not handle (or a Windows drive letter)
    end
    rest = url:gsub("^//", "")
    if not rest:match("^[%w%-%.]+%.[%a][%w%-%.]*[/:?]?") then
      return nil -- not a URL at all: treat the caller's text as a search query
    end
    scheme = "https"
  end
  if not rest or rest == "" then
    return nil
  end
  local authority, path_and_query = rest:match("^([^/?#]*)(.*)$")
  local host = (authority or ""):gsub("^[^@]*@", ""):gsub(":%d+$", "")
  host = host:lower()
  if host == "" then
    return nil
  end
  local path, query_string = (path_and_query or ""):match("^([^?]*)(.*)$")
  query_string = (query_string or ""):gsub("^%?", "")
  local query = {}
  for pair in tostring(query_string or ""):gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=(.*)$")
    if key then
      query[key] = value:gsub("+", " ")
    else
      query[pair] = ""
    end
  end
  return host, path or "", query
end

M._split_url = split_url

--- Classify any URL: what app it came from, what kind of item it is and which
--- id/list/query it carries. Pure function → easy to test and to reuse.
---@param url string
---@return {app: string, kind: string, url: string, id?: string, list?: string, time?: number, host?: string, streamable: boolean, source: string}
function M.classify(url)
  local raw = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local host, path, query = split_url(raw)
  local result = {
    app = "unknown",
    kind = "unknown",
    url = raw,
    host = host,
    streamable = false,
    source = "auto",
  }
  if not host then
    if raw:match("^%a[%w+.-]*:") and not raw:match("^%s") then
      -- `mailto:`, `magnet:`, `ftp:` and similar are schemes we cannot cast.
      result.kind = "unknown"
      result.app = "unsupported"
      return result
    end
    -- Not a URL: a search string. `:Kikru cast lofi hip hop` should just work.
    if raw ~= "" then
      result.kind = "query"
      result.app = "search"
      result.query = raw
      result.streamable = true
      result.source = "youtube"
    end
    return result
  end

  local app = M.hosts[host] or M.stream_hosts[host]
  if not app then
    -- Unknown host: might be an icecast stream, a Subsonic server, a raw file…
    if host:find("radio%-browser") or path:match("%.m3u8?$") or path:match("%.pls$") then
      result.app = "radio"
      result.kind = "stream"
      result.streamable = true
      result.source = "radio"
    elseif path:match("%.mp3$") or path:match("%.flac$") or path:match("%.ogg$") or path:match("%.m4a$") or path:match("%.opus$") or path:match("%.wav$") then
      result.app = "file"
      result.kind = "stream"
      result.streamable = true
    elseif path == "" or path == "/" or host:find("ice") or host:find("stream") or host:find("radio") or host:find("somafm") then
      -- Icecast/SHOUTcast style endpoints (ice1.somafm.com, streams.example.org:8000/…)
      result.app = "radio"
      result.kind = "icecast"
      result.streamable = true
      result.source = "radio"
    else
      result.app = "generic"
      result.kind = "page"
      result.streamable = Sources and true or false
    end
    return result
  end

  result.app = app
  result.source = app == "youtube" and "youtube" or (app == "youtube_music" and "youtube_music" or app)
  result.streamable = true
  -- non-YouTube providers (SoundCloud, Bandcamp, …) are still castable: yt-dlp
  -- has an extractor for each of them.
  if M.stream_hosts[host] then
    local segments = {}
    for segment in path:gmatch("[^/]+") do
      segments[#segments + 1] = segment
    end
    local known = {
      track = true,
      album = true,
      playlist = true,
      set = true,
      sets = true,
      artist = true,
      video = true,
      watch = true,
      song = true,
      chapter = true,
    }
    local kind = "page"
    if host:find("soundcloud", 1, true) then
      if path:find("/sets/", 1, true) then
        kind = "set"
      elseif #segments >= 2 then
        kind = "track"
      end
    elseif app == "spotify" then
      kind = known[segments[1] or ""] and segments[1] or "page"
    elseif segments[1] and known[segments[1]] then
      kind = segments[1]
    elseif #segments >= 2 then
      kind = "track"
    end
    result.kind = kind
    result.id = segments[#segments]
    result.source = app
    return result
  end

  -- youtu.be/<id>, /shorts/<id>, /live/<id>, /embed/<id>, /watch?v=<id>
  local video_id = path:match("^/(shorts)/([%w_%-]+)") and path:match("^/shorts/([%w_%-]+)")
    or path:match("^/live/([%w_%-]+)")
    or path:match("^/embed/([%w_%-]+)")
    or path:match("^/v/([%w_%-]+)")
  if not video_id and host == "youtu.be" then
    video_id = path:match("^/([%w_%-]+)")
  end
  if not video_id then
    video_id = query.v
  end

  local list = query.list
  local time = tonumber(query.t) or tonumber(query.start)
  if time and time > 100000 then
    -- YouTube's `t=1h2m3s` / `t=90s` forms
    time = nil
  end
  if not time and query.t then
    local hours, minutes, seconds = query.t:match("^(%d+)h(%d+)m(%d+)s$")
    if hours then
      time = tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
    else
      local minutes2, seconds2 = query.t:match("^(%d+)m(%d+)s$")
      if minutes2 then
        time = tonumber(minutes2) * 60 + tonumber(seconds2)
      else
        seconds2 = query.t:match("^(%d+)s$")
        time = seconds2 and tonumber(seconds2) or nil
      end
    end
  end

  result.id = video_id
  result.list = list
  result.time = time

  local playlist_path = path:match("^/(playlist)$")
  local channel = path:match("^/channel/([%w_%-]+)") or path:match("^/c/([%w_%-]+)") or path:match("^/@([%w_%.-]+)")
  local browse = path:match("^/browse/([%w_%-]+)")

  if playlist_path or (list and not video_id) then
    if list and list:match("^RD") then
      result.kind = "radio"
    else
      result.kind = "playlist"
    end
  elseif video_id then
    if query.list and query.list:match("^RD") then
      result.kind = "video_radio"
    else
      result.kind = "video"
    end
    if path:match("^/shorts/") then
      result.kind = result.kind == "video" and "short" or result.kind
    elseif path:match("^/live/") then
      result.kind = "live"
    end
  elseif channel then
    result.kind = "channel"
    result.channel = channel
  elseif browse then
    result.kind = "browse"
    result.browse = browse
  elseif app == "spotify" then
    result.kind = path:match("^/(playlist|album|artist|track)") or "page"
    result.spotify_kind = result.kind
    result.id = path:match("^/[%a]+/([%w]+)") or nil
  else
    result.kind = "page"
  end

  return result
end

--- Canonical URL for a classified item (drops tracking parameters, keeps the
--- timestamp so a casted song resumes at the point you shared it).
---@param info table
---@param opts? {keep_time?: boolean}
---@return string
function M.canonical(info, opts)
  opts = opts or {}
  if info.kind == "query" then
    return "ytsearch1:" .. (info.query or "")
  end
  local base
  if info.app == "youtube_music" and info.id then
    base = "https://music.youtube.com/watch?v=" .. info.id
  elseif info.id then
    base = "https://www.youtube.com/watch?v=" .. info.id
  elseif info.list then
    base = "https://www.youtube.com/playlist?list=" .. info.list
  else
    return info.url
  end
  if info.list and info.kind == "playlist" and not base:find("list=" .. info.list, 1, true) then
    base = base .. (base:find("?", 1, true) and "&" or "?") .. "list=" .. info.list
  end
  if opts.keep_time ~= false and info.time and info.time > 0 then
    base = base .. "&t=" .. tostring(math.floor(info.time))
  end
  return base
end

---@param url string
---@return boolean
function M.is_cast_url(url)
  local info = M.classify(url)
  if info.kind == "unknown" then
    return false
  end
  if info.kind == "page" then
    return info.app ~= "unknown" and info.app ~= "generic"
  end
  return true
end

--- Human readable one-liner for the UI/status line.
---@param info table
---@return string
function M.describe(info)
  local labels = {
    video = "YouTube video",
    short = "YouTube Short",
    live = "YouTube live stream",
    playlist = "YouTube playlist",
    radio = "YouTube Music radio",
    video_radio = "YouTube video + radio",
    channel = "YouTube channel",
    browse = "YouTube Music browse page",
    query = "search",
    playlist_track = "playlist track",
  }
  if info.kind == "video" and info.app == "youtube_music" then
    labels.video = "YouTube Music track"
  end
  local label = labels[info.kind] or (info.app ~= "unknown" and info.app or "link")
  if info.id then
    label = label .. " " .. info.id
  elseif info.list then
    label = label .. " " .. info.list
  end
  if info.time and info.time > 0 then
    label = label .. (" @%s"):format(Tags.format_time(info.time))
  end
  return label
end

-- yt-dlp plumbing -------------------------------------------------------------------

---@return boolean
function M.ytdlp()
  return Sources.ytdlp_available()
end

--- URLs / search terms handed to yt-dlp.
---@param info table
---@param opts? {limit?: integer}
---@return string
function M.query_for(info, opts)
  opts = opts or {}
  local limit = opts.limit or (info.kind == "query" and 10 or 1)
  if info.kind == "query" then
    local prefix = info.source == "youtube_music" and "ytmsearch" or "ytsearch"
    return ("%s%d:%s"):format(prefix, limit, info.query)
  end
  if info.kind == "playlist" or info.kind == "channel" or info.kind == "browse" or info.kind == "radio" then
    -- playlists: resolve every entry (flat), the player then owns the queue
    return M.canonical(info, { keep_time = false })
  end
  return M.canonical(info, { keep_time = false })
end

--- YouTube Music "radio"/mix and channel page support: yt-dlp understands the
--- normal watch/playlist URLs, so for the exotic ones we fall back to a
--- search-based query instead of failing.
---@param info table
---@return string|nil
function M.fallback_query(info)
  if info.kind == "browse" and info.browse then
    return "ytmsearch20:" .. info.browse
  end
  if info.kind == "channel" and info.channel then
    return "ytsearch20:" .. info.channel
  end
  return nil
end

-- Cast server (HTTP) ------------------------------------------------------------------

M.state = {
  server = nil,
  port = nil,
  running = false,
  last = nil, ---@type table|nil  last casted item
  log = {}, ---@type string[]
  token = nil,
}

---@param message string
local function log(message)
  M.state.log[#M.state.log + 1] = ("%s %s"):format(os.date("%H:%M:%S"), message)
  while #M.state.log > 50 do
    table.remove(M.state.log, 1)
  end
end
M.log = log

---@return string
function M.port()
  local Config = require("kaeru.config")
  local conf = (Config.options.kikru or Config.options.music or {}).cast or {}
  return tonumber(conf.port) or M.default_port
end

---@return string|nil
function M.token()
  local Config = require("kaeru.config")
  local conf = (Config.options.kikru or Config.options.music or {}).cast or {}
  local token = conf.token
  if type(token) == "string" and token ~= "" then
    return token
  end
  return nil
end

--- Decode `?a=1&b=two` (also used for `POST` bodies with a form content type).
---@param query string
---@return table<string, string>
function M.parse_query(query)
  local out = {}
  for pair in tostring(query or ""):gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=(.*)$")
    if key then
      key = key:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
      value = value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
      out[key] = value
    else
      out[pair] = ""
    end
  end
  return out
end

--- The whole HTTP surface as a *pure* function: (method, path, body) →
--- (status, content-type, payload). Keeping it pure means the routing table is
--- unit-testable and the socket code below stays trivial.
---@param method string
---@param path string
---@param body? string
---@return integer status, string content_type, string payload
function M.handle_request(method, path, body)
  method = (method or "GET"):upper()
  local route, query = tostring(path or "/"):match("^([^?]*)%??(.*)$")
  local params = M.parse_query(query)
  if body and body ~= "" and (not query or query == "") then
    local ok, decoded = pcall(Json.decode, body)
    if ok and type(decoded) == "table" then
      for key, value in pairs(decoded) do
        if params[key] == nil then
          params[key] = tostring(value)
        end
      end
    else
      for key, value in pairs(M.parse_query(body)) do
        params[key] = params[key] or value
      end
    end
  end

  local function json(payload, status)
    return status or 200, "application/json", Json.encode(payload) or "{}"
  end

  if M.token() and (params.token or "") ~= M.token() then
    return json({ ok = false, error = "missing or invalid token" }, 401)
  end

  local route_key = route:gsub("/+$", "")
  if route_key == "" then
    route_key = "/"
  end

  if method == "OPTIONS" then
    return 204, "text/plain", ""
  end

  if route_key == "/" then
    return 200, "text/html; charset=utf-8", M.page()
  end

  if route_key == "/status" then
    local Kikru = require("kaeru.kikru")
    return json({ ok = true, state = Kikru.get_snapshot(), cast = M.state.last, port = M.state.port })
  end

  if route_key == "/cast" then
    local url = params.url or params.q or params.query
    if not url or url == "" then
      return json({ ok = false, error = "?url= is required" }, 400)
    end
    local mode = params.mode or "play"
    local info = M.classify(url)
    if not M.is_cast_url(url) then
      return json({ ok = false, error = "unsupported link: " .. tostring(url), kind = info.kind }, 415)
    end
    M.state.last = { url = info.url, kind = info.kind, app = info.app, at = os.time(), canonical = M.canonical(info) }
    log(("cast %s (%s)"):format(info.url, info.kind))
    M.cast_async(info, { mode = mode, source = params.source, limit = tonumber(params.limit) })
    return json({ ok = true, queued = mode, item = M.state.last })
  end

  local transports = { play = "play", pause = "pause", toggle = "toggle", next = "next", prev = "prev", stop = "stop" }
  if transports[route_key:sub(2)] then
    local Kikru = require("kaeru.kikru")
    local action = transports[route_key:sub(2)]
    Kikru.action(action)
    return json({ ok = true, action = action })
  end

  if route_key == "/volume" then
    local Kikru = require("kaeru.kikru")
    local value = tonumber(params.value or params.volume)
    if value then
      Kikru.action("volume", { volume = value })
    elseif params.delta then
      Kikru.action("volume", { delta = tonumber(params.delta) })
    end
    return json({ ok = true, volume = Kikru.state.volume })
  end

  if route_key == "/eq" then
    local Kikru = require("kaeru.kikru")
    if params.preset then
      Kikru.action("eq_preset", { preset = params.preset })
    end
    return json({ ok = true, preset = Kikru.state.eq_preset, bands = Kikru.state.eq_bands })
  end

  if route_key == "/queue" then
    local Kikru = require("kaeru.kikru")
    local items = {}
    for index, track in ipairs(Kikru.playlist.items) do
      items[#items + 1] = { index = index, label = Tags.label(track), url = track.url or track.path }
    end
    return json({ ok = true, items = items, summary = require("kaeru.kikru.playlist").summary(Kikru.playlist) })
  end

  if route_key == "/youtube" or route_key == "/ytm" then
    local q = params.q or params.url
    if not q or q == "" then
      return json({ ok = false, error = "?q= is required" }, 400)
    end
    local source = route_key == "/ytm" and "youtube_music" or "youtube"
    local info = M.classify(q)
    if info.kind == "unknown" then
      info.kind = "query"
      info.query = q
      info.app = "search"
    end
    info.source = source
    M.state.last = { url = q, kind = info.kind, app = info.app, at = os.time() }
    M.cast_async(info, { mode = params.mode or "play", source = source, limit = tonumber(params.limit) })
    return json({ ok = true, query = q, source = source })
  end

  if route_key == "/open" then
    Compat.defer_fn(function()
      pcall(function()
        require("kaeru.kikru").ui()
      end)
    end, 10)
    return json({ ok = true, opened = true })
  end

  if route_key == "/appcast" then
    M.from_app({ mode = params.mode or "play" })
    return json({ ok = true, appcast = true })
  end

  return json({ ok = false, error = "not found: " .. route_key }, 404)
end

--- The bookmarklet/phone friendly page served at `/`.
---@return string
function M.page()
  return [[<!doctype html>
<html><head><meta charset="utf-8"><title>Kikru cast</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: dark }
  body { margin:0; font:15px/1.5 ui-monospace,Menlo,monospace; background:#0b0f0e; color:#d7ffe9; padding:2rem }
  h1 { font-size:1.2rem; color:#00ff9f; margin:0 0 .4rem }
  form { display:flex; gap:.5rem; margin:1rem 0 }
  input { flex:1; padding:.7rem .9rem; border-radius:.5rem; border:1px solid #1f3b33; background:#081412; color:inherit }
  button { padding:.7rem 1rem; border-radius:.5rem; border:0; background:#00ff9f; color:#04120d; font-weight:700 }
  .row { display:flex; gap:.5rem; flex-wrap:wrap; margin:.6rem 0 }
  .row button { background:#12261f; color:#9fe8c6; font-weight:400 }
  pre { background:#081412; padding:1rem; border-radius:.5rem; overflow:auto; max-height:40vh }
  a { color:#5ce1b0 }
  small { color:#5f7a70 }
</style></head><body>
<h1>▸ Kikru cast</h1>
<small>Paste a YouTube / YouTube Music / SoundCloud link, it plays in Neovim (mpv + 10&nbsp;band EQ + FFT analyzer).</small>
<form onsubmit="cast(event)">
  <input id="url" placeholder="https://music.youtube.com/watch?v=…" autofocus>
  <button>Cast</button>
</form>
<div class="row">
  <button onclick="send('toggle')">⏯ toggle</button>
  <button onclick="send('next')">⏭ next</button>
  <button onclick="send('prev')">⏮ prev</button>
  <button onclick="send('stop')">⏹ stop</button>
  <button onclick="send('open')">▣ show player</button>
  <button onclick="send('appcast')">⇢ cast current app</button>
</div>
<div class="row">
  <input id="q" placeholder="search YouTube Music…" style="flex:1">
  <button onclick="search('ytm')">yt music</button>
  <button onclick="search('youtube')">youtube</button>
</div>
<pre id="out">ready</pre>
<script>
const out = document.getElementById('out');
const show = (d) => out.textContent = JSON.stringify(d, null, 2);
const get = (p, q) => fetch(p + (q ? '?' + new URLSearchParams(q) : '')).then(r => r.json()).then(show).catch(e => show({error: String(e)}));
const cast = (e) => { e.preventDefault(); get('/cast', { url: document.getElementById('url').value }); };
const send = (p) => get('/' + p);
const search = (s) => get('/' + (s === 'ytm' ? 'ytm' : 'youtube'), { q: document.getElementById('q').value });
get('/status');
setInterval(() => get('/status'), 4000);
</script>
</body></html>
]]
end

local STATUS_TEXT = {
  [200] = "OK",
  [204] = "No Content",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [415] = "Unsupported Media Type",
  [500] = "Internal Server Error",
}

--- Write one HTTP/1.1 response and close the socket soon after.
---@param client table  uv_tcp_t
---@param cleanup fun()
---@param status integer
---@param content_type string
---@param payload string
local function respond(client, cleanup, status, content_type, payload)
  local response = table.concat({
    ("HTTP/1.1 %d %s"):format(status, STATUS_TEXT[status] or "OK"),
    "Content-Type: " .. content_type,
    "Content-Length: " .. tostring(#payload),
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Headers: content-type",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Connection: close",
    "",
    payload,
  }, "\r\n")
  pcall(function()
    client:write(response)
  end)
  Compat.defer_fn(cleanup, 30)
end

--- Serve one connected socket: read the request head, dispatch, answer.
---@param client table  uv_tcp_t
local function serve_client(client)
  local buffer = ""
  local function cleanup()
    pcall(function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
  client:read_start(function(err, chunk)
    if err or not chunk then
      return cleanup()
    end
    buffer = buffer .. chunk
    local head_end = buffer:find("\r\n\r\n", 1, true)
    if not head_end then
      if #buffer > 65536 then
        cleanup()
      end
      return
    end
    local head = buffer:sub(1, head_end - 1)
    local body = buffer:sub(head_end + 4)
    local method, path = head:match("^(%u+)%s+(%S+)")
    local content_length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
    if #body < content_length then
      return -- wait for the rest of the body
    end
    -- Routes touch the editor (notifications, playback), which is not allowed inside a
    -- libuv callback. Run them on the main loop and always answer, even on error.
    vim.schedule(function()
      local ok, status, content_type, payload = pcall(M.handle_request, method or "GET", path or "/", body)
      if not ok then
        status, content_type, payload = 500, "application/json", vim.json.encode({ ok = false, error = tostring(status) })
      end
      respond(client, cleanup, status, content_type, payload or "")
    end)
  end)
end

--- Start the cast server (`:Kikru cast server [port]`).
---@param port? integer
---@return boolean ok, string message
function M.start_server(port)
  local uv = Compat.uv()
  if not uv or not uv.new_tcp then
    return false, "the cast server needs Neovim's luv bindings (not available)"
  end
  if M.state.running then
    return true, ("cast server already listening on http://127.0.0.1:%d"):format(M.state.port)
  end
  port = tonumber(port) or M.port()
  local server = uv.new_tcp()
  local ok, err = pcall(function()
    server:bind("127.0.0.1", port)
    server:listen(64, function(accept_err)
      if accept_err then
        log("accept error: " .. tostring(accept_err))
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      serve_client(client)
    end)
  end)
  if not ok then
    pcall(function()
      server:close()
    end)
    return false, ("cannot bind 127.0.0.1:%d (%s)"):format(port, tostring(err))
  end
  M.state.server = server
  M.state.port = port
  M.state.running = true
  log(("listening on http://127.0.0.1:%d"):format(port))
  return true, ("cast server listening on http://127.0.0.1:%d"):format(port)
end

---@return boolean
function M.stop_server()
  if not M.state.running or not M.state.server then
    return false
  end
  pcall(function()
    M.state.server:close()
  end)
  M.state.server = nil
  M.state.running = false
  log("stopped")
  return true
end

---@return boolean
function M.server_running()
  return M.state.running == true
end

---@return string
function M.url()
  return ("http://127.0.0.1:%d"):format(M.state.port or M.port())
end

-- kikru:// URL scheme handler ----------------------------------------------------------

---@return string
local function bin_dir()
  local home = vim.fn.expand and vim.fn.expand("~") or os.getenv("HOME") or "/tmp"
  return home .. "/.local/bin"
end

---@return string
local function desktop_dir()
  local home = vim.fn.expand and vim.fn.expand("~") or os.getenv("HOME") or "/tmp"
  return home .. "/.local/share/applications"
end

---@return string
function M.handler_script()
  local port = M.state.port or M.port()
  return table.concat({
    "#!/bin/sh",
    "# kaeru.nvim · Kikru cast handler, forwards a kikru:// URL to the cast server.",
    '# usage: kaeru-cast "kikru://cast?url=https://music.youtube.com/watch?v=…"',
    'url="$1"',
    'case "$url" in',
    '  kikru://*|kaeru://*) target=$(printf %s "$url" | sed -e "s#^kikru://##" -e "s#^kaeru://##") ;;',
    '  *) target="cast?url=$url" ;;',
    "esac",
    'base="http://127.0.0.1:${KIKRU_CAST_PORT:-' .. tostring(port) .. '}"',
    'case "$target" in',
    '  cast?*|cast/*) path="/cast?${target#cast?}" ;;',
    '  *) path="/cast?url=$(printf %s "$target" | sed -e "s#^cast/##")" ;;',
    "esac",
    'if command -v curl >/dev/null 2>&1; then',
    '  curl -fsS --max-time 5 "$base$path" >/dev/null 2>&1 && exit 0',
    "fi",
    'if command -v wget >/dev/null 2>&1; then',
    '  wget -q -O /dev/null "$base$path" && exit 0',
    "fi",
    'printf "kikru: cast server is not reachable at %s\\n" "$base" >&2',
    "exit 1",
    "",
  }, "\n")
end

---@return string
function M.desktop_entry()
  return table.concat({
    "[Desktop Entry]",
    "Type=Application",
    "Name=Kikru cast",
    "Comment=Play this link in Neovim with kaeru.nvim's Kikru player",
    "Exec=" .. bin_dir() .. "/kaeru-cast %u",
    "Terminal=false",
    "NoDisplay=true",
    "MimeType=x-scheme-handler/kikru;x-scheme-handler/kaeru;",
    "Categories=AudioVideo;Audio;Player;",
    "",
  }, "\n")
end

--- Install the `kikru://` handler (script + .desktop + mimetype registration).
---@return boolean ok, string message
function M.install_scheme()
  local script = bin_dir() .. "/kaeru-cast"
  local desktop = desktop_dir() .. "/kaeru-cast.desktop"
  local ok1 = pcall(vim.fn.writefile, vim.split(M.handler_script(), "\n"), script)
  if not ok1 then
    return false, "cannot write " .. script
  end
  pcall(vim.fn.system, { "chmod", "+x", script })
  local ok2 = pcall(vim.fn.writefile, vim.split(M.desktop_entry(), "\n"), desktop)
  if not ok2 then
    return false, "cannot write " .. desktop
  end
  if vim.fn.executable and vim.fn.executable("xdg-mime") == 1 then
    pcall(vim.fn.system, { "xdg-mime", "default", "kaeru-cast.desktop", "x-scheme-handler/kikru" })
    pcall(vim.fn.system, { "update-desktop-database", desktop_dir() })
  end
  return true, ("kikru:// handler installed (%s, %s)"):format(script, desktop)
end

---@return boolean ok, string message
function M.uninstall_scheme()
  local script = bin_dir() .. "/kaeru-cast"
  local desktop = desktop_dir() .. "/kaeru-cast.desktop"
  pcall(vim.fn.delete, script)
  pcall(vim.fn.delete, desktop)
  return true, "kikru:// handler removed"
end

-- MPRIS "cast the app I already have open" --------------------------------------------

--- Names we consider YouTube-ish when scanning the MPRIS bus.
M.app_patterns = {
  { pattern = "youtube music", source = "youtube_music" },
  { pattern = "youtube", source = "youtube" },
  { pattern = "ytm", source = "youtube_music" },
  { pattern = "spotify", source = "spotify" },
  { pattern = "soundcloud", source = "soundcloud" },
  { pattern = "vlc", source = "vlc" },
  { pattern = "mpv", source = "mpv" },
  { pattern = "brave", source = "browser" },
  { pattern = "chrom", source = "browser" },
  { pattern = "firefox", source = "browser" },
}

---@param name string
---@return string|nil
function M.source_for_player(name)
  name = tostring(name or ""):lower()
  for _, entry in ipairs(M.app_patterns) do
    if name:find(entry.pattern, 1, true) then
      return entry.source
    end
  end
  return nil
end

--- Read the URL/title currently playing on an MPRIS player.
---@param player string|nil
---@param cb fun(err: string|nil, info: table|nil)
function M.from_app_async(player, cb)
  local Backend = require("kaeru.kikru.backend")
  local function pick(players)
    if not players or #players == 0 then
      return cb("no MPRIS players found (install playerctl)", nil)
    end
    local chosen = player
    if not chosen then
      for _, name in ipairs(players) do
        if M.source_for_player(name) then
          chosen = name
          break
        end
      end
      chosen = chosen or players[1]
    end
    if not Backend.mpris_nowplaying then
      return cb("MPRIS is not available in this build", nil)
    end
    Backend.mpris_nowplaying(function(err, now)
      if err or not now then
        return cb(err or "nothing is playing on " .. chosen, nil)
      end
      now.player = chosen
      now.source = M.source_for_player(chosen) or "mpris"
      cb(nil, now)
    end, chosen)
  end
  if Backend.mpris_players then
    Backend.mpris_players(function(err, players)
      if err then
        return cb(err, nil)
      end
      pick(players)
    end)
  else
    pick({ player or "playerctl" })
  end
end

--- Cast whatever the MPRIS app is playing right now.
---@param opts? {mode?: string, player?: string, cb?: fun(ok: boolean, message: string)}
function M.from_app(opts)
  opts = opts or {}
  M.from_app_async(opts.player, function(err, now)
    if err or not now then
      local message = ":Kikru · " .. tostring(err or "nothing playing")
      if opts.cb then
        return opts.cb(false, message)
      end
      return require("kaeru.ui").notify(message, vim.log.levels.WARN)
    end
    local url = now.url or now.title
    local info = M.classify(url)
    if info.kind == "unknown" and now.title then
      info = M.classify(now.title) -- some players only expose the title
      if info.kind == "unknown" then
        info.kind = "query"
        info.query = now.title
        info.source = "youtube_music"
      end
    end
    info.app = info.app ~= "unknown" and info.app or now.source or "mpris"
    if info.time == nil and now.position and now.position > 0 then
      info.time = math.floor(now.position)
    end
    M.cast_async(info, { mode = opts.mode or "play", cb = opts.cb, origin = "appcast" })
  end)
end

-- Casting -----------------------------------------------------------------------------

--- Resolve and hand a classified item to the player.
---@param info table
---@param opts? {mode?: string, source?: string, limit?: integer, cb?: fun(ok: boolean, message: string), origin?: string}
function M.cast_async(info, opts)
  opts = opts or {}
  local Kikru = require("kaeru.kikru")
  local mode = opts.mode or "play"
  local function done(ok, message)
    log(message)
    if opts.cb then
      return opts.cb(ok, message)
    end
    return require("kaeru.ui").notify(":Kikru · " .. message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end

  if not M.ytdlp() then
    -- No yt-dlp: only direct audio URLs can be played.
    if info.app == "radio" or info.app == "file" or (info.url or ""):match("%.mp3") then
      return M.play_tracks({ Tags.normalize({ url = info.url, title = info.url, format = "stream" }) }, mode, done)
    end
    return done(false, "yt-dlp is required to cast YouTube links (install yt-dlp or set kikru.ytdlp)")
  end

  local query = M.query_for(info, { limit = opts.limit })
  local fallback = M.fallback_query(info)
  local source = opts.source or info.source or "auto"

  local function run(q)
    Sources.resolve(q, {
      limit = opts.limit or (info.kind == "query" and 10 or 50),
      source = source,
      flat = info.kind == "playlist" or info.kind == "channel" or info.kind == "browse" or info.kind == "radio",
      no_playlist = info.kind == "video" or info.kind == "short" or info.kind == "live",
    }, function(err, result)
      if (err or not result) and fallback then
        return run(fallback)
      end
      if err or not result then
        return done(false, ("cannot resolve %s (%s)"):format(M.describe(info), tostring(err)))
      end
      local tracks = result.tracks or {}
      if #tracks == 0 then
        return done(false, "nothing found for " .. tostring(info.query or info.url))
      end
      if info.time and info.time > 0 and tracks[1] then
        tracks[1].start_at = info.time
      end
      for _, track in ipairs(tracks) do
        track.cast_from = info.app
        track.cast_kind = info.kind
      end
      return M.play_tracks(tracks, mode, done, info)
    end)
  end

  run(query)
end

---@param tracks table[]
---@param mode string
---@param done fun(ok: boolean, message: string)
---@param info? table
function M.play_tracks(tracks, mode, done, info)
  local Kikru = require("kaeru.kikru")
  local label = info and M.describe(info) or Tags.label(tracks[1])
  if mode == "queue" then
    Kikru.enqueue(tracks, { play = false })
    return done(true, ("queued %d track(s) from %s"):format(#tracks, label))
  elseif mode == "next" then
    local playlist = require("kaeru.kikru.playlist")
    playlist.insert_after_current(Kikru.playlist, tracks)
    return done(true, ("queued %d track(s) after the current one"):format(#tracks))
  end
  if #tracks > 1 then
    Kikru.playlist = require("kaeru.kikru.playlist").new(tracks, "cast")
    Kikru.state.index = 1
    Kikru.play(tracks[1], { autoplay = true })
    return done(true, ("casting %d track(s): %s"):format(#tracks, label))
  end
  Kikru.enqueue(tracks, { play = true, replace = false })
  return done(true, ("casting %s"):format(label))
end

--- `:Kikru cast <url|query>`: the friendly entry point.
---@param url_or_query string
---@param opts? {mode?: string, cb?: fun(ok: boolean, message: string)}
---@return boolean started
function M.cast(url_or_query, opts)
  opts = opts or {}
  if not url_or_query or url_or_query == "" then
    return false
  end
  local info = M.classify(url_or_query)
  if not M.is_cast_url(url_or_query) then
    info.kind = "query"
    info.query = url_or_query
    info.app = "search"
    info.source = opts.source or "youtube_music"
  end
  M.cast_async(info, opts)
  return true
end

--- YouTube search → play (`:Kikru youtube <query>`).
---@param query string
---@param opts? {mode?: string, cb?: fun(ok: boolean, message: string)}
function M.youtube(query, opts)
  opts = opts or {}
  local info = M.classify(query)
  if info.kind ~= "query" then
    info.app = "youtube"
    info.source = "youtube"
  else
    info.source = "youtube"
  end
  return M.cast_async(info, opts)
end

--- YouTube Music search → play (`:Kikru ytmusic <query>`).
---@param query string
---@param opts? {mode?: string, cb?: fun(ok: boolean, message: string)}
function M.youtube_music(query, opts)
  opts = opts or {}
  local info = M.classify(query)
  if info.kind ~= "query" then
    info.app = "youtube_music"
    info.source = "youtube_music"
  else
    info.source = "youtube_music"
    info.app = "youtube_music"
  end
  return M.cast_async(info, opts)
end

--- Everything cast-related, for `:Kikru cast status` and the web client.
---@return table
function M.info()
  return {
    running = M.state.running,
    port = M.state.port or M.port(),
    url = M.url(),
    scheme = M.scheme,
    ytdlp = M.ytdlp(),
    last = M.state.last,
    log = vim.deepcopy(M.state.log or {}),
    endpoints = {
      "GET /            cast page (paste a link)",
      "GET /cast?url=…&mode=play|queue|next",
      "POST /cast       {\"url\": \"…\", \"mode\": \"play\"}",
      "GET /ytm?q=…     YouTube Music search",
      "GET /youtube?q=… YouTube search",
      "GET /appcast     cast whatever MPRIS is playing",
      "GET /status      player state (JSON)",
      "GET /queue       current queue",
      "GET /play|pause|toggle|next|prev|stop",
      "GET /volume?value=70   /eq?preset=synthwave",
      "GET /open        focus the player window",
    },
  }
end

return M
