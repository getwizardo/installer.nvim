-- kaeru.nvim · :Kikru — source resolution.
--
-- The source model follows NodeLink / LavaLink (https://github.com/PerformanC/NodeLink):
-- a query is first matched against the source registry (`ytsearch:`, `scsearch:`,
-- `spsearch:`, `dzsearch:`, `amsearch:`, `ytmsearch:`, … plus plain URLs and
-- local paths) and afterwards handed to the resolver of that source. External
-- work (yt-dlp, curl, mpv, mpc) runs in child processes so the UI never blocks.
local Process = require("kaeru.process")
local Tags = require("kaeru.kikru.tags")
local Playlist = require("kaeru.kikru.playlist")
local Compat = require("kaeru.compat")

local M = {}

local uv = vim.uv or vim.loop

M.user_agent = "kaeru.nvim/kikru (+https://github.com/getwizardo/installer.nvim)"

-- Source registry ---------------------------------------------------------------

---@class MusicSource
---@field id string
---@field name string
---@field prefix string        LavaLink style search prefix ("" = no search)
---@field patterns string[]    Lua patterns matched against an URL
---@field requires string[]    binaries used to resolve this source
---@field kind string          "local" | "stream" | "ytdlp" | "api" | "rss" | "player"

---@type table<string, MusicSource>
M.sources = {
  local_file = {
    id = "local_file",
    name = "Local files & folders",
    prefix = "",
    patterns = { "^/", "^~", "^%./", "^%../", "^%a:[/\\]" },
    requires = {},
    kind = "local",
  },
  http = {
    id = "http",
    name = "HTTP(S) stream / playlist",
    prefix = "http",
    patterns = { "^https?://" },
    requires = {},
    kind = "stream",
  },
  youtube = {
    id = "youtube",
    name = "YouTube",
    prefix = "ytsearch",
    patterns = { "youtube%.com", "youtu%.be", "^ytsearch:", "^ytdl:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  youtube_music = {
    id = "youtube_music",
    name = "YouTube Kikru",
    prefix = "ytmsearch",
    patterns = { "music%.youtube%.com", "^ytmsearch:", "^ytm:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  soundcloud = {
    id = "soundcloud",
    name = "SoundCloud",
    prefix = "scsearch",
    patterns = { "soundcloud%.com", "^scsearch:", "^sc:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  bandcamp = {
    id = "bandcamp",
    name = "Bandcamp",
    prefix = "bcsearch",
    patterns = { "bandcamp%.com", "^bcsearch:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  mixcloud = {
    id = "mixcloud",
    name = "Mixcloud",
    prefix = "mcsearch",
    patterns = { "mixcloud%.com", "^mcsearch:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  bilibili = {
    id = "bilibili",
    name = "Bilibili",
    prefix = "bsearch",
    patterns = { "bilibili%.com", "b23%.tv", "^bsearch:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  twitch = {
    id = "twitch",
    name = "Twitch",
    prefix = "twsearch",
    patterns = { "twitch%.tv", "^twsearch:" },
    requires = { "yt-dlp", "streamlink" },
    kind = "ytdlp",
  },
  spotify = {
    id = "spotify",
    name = "Spotify",
    prefix = "spsearch",
    patterns = { "open%.spotify%.com", "spotify:", "^spsearch:" },
    requires = { "yt-dlp" },
    kind = "api",
  },
  deezer = {
    id = "deezer",
    name = "Deezer",
    prefix = "dzsearch",
    patterns = { "deezer%.com", "^dzsearch:" },
    requires = { "yt-dlp" },
    kind = "api",
  },
  apple_music = {
    id = "apple_music",
    name = "Apple Kikru",
    prefix = "amsearch",
    patterns = { "music%.apple%.com", "^amsearch:" },
    requires = { "yt-dlp" },
    kind = "api",
  },
  yandex_music = {
    id = "yandex_music",
    name = "Yandex Kikru",
    prefix = "ymsearch",
    patterns = { "music%.yandex", "^ymsearch:" },
    requires = { "yt-dlp" },
    kind = "api",
  },
  nico = {
    id = "nico",
    name = "NicoNico",
    prefix = "ncsearch",
    patterns = { "nicovideo%.jp", "^ncsearch:" },
    requires = { "yt-dlp" },
    kind = "ytdlp",
  },
  radio = {
    id = "radio",
    name = "Radio Browser (30k+ stations)",
    prefix = "radio:",
    patterns = { "^radio:", "^radiosearch:" },
    requires = { "curl" },
    kind = "api",
  },
  somafm = {
    id = "somafm",
    name = "SomaFM",
    prefix = "somafm:",
    patterns = { "somafm%.com", "^somafm:", "^soma:" },
    requires = {},
    kind = "stream",
  },
  subsonic = {
    id = "subsonic",
    name = "Subsonic / Navidrome",
    prefix = "subsonic:",
    patterns = { "^subsonic:", "^navidrome:" },
    requires = { "curl" },
    kind = "api",
  },
  mpd = {
    id = "mpd",
    name = "MPD (mpc)",
    prefix = "mpd:",
    patterns = { "^mpd:" },
    requires = { "mpc" },
    kind = "player",
  },
  rss = {
    id = "rss",
    name = "Podcast / RSS feed",
    prefix = "rss:",
    patterns = { "^rss:", "%.rss$", "/feed", "/podcast" },
    requires = {},
    kind = "rss",
  },
}

--- Order used when a bare query (no prefix, no URL) needs a source.
M.search_order = { "youtube_music", "youtube", "soundcloud", "bandcamp" }

---@return string[]
function M.source_ids()
  local ids = {}
  for id in pairs(M.sources) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

---@param id string
---@return MusicSource|nil
function M.source(id)
  return M.sources[id]
end

--- Is this string a URL?
---@param s string
---@return boolean
function M.is_url(s)
  return type(s) == "string" and s:match("^%a[%w+.-]*://") ~= nil
end

---@param s string
---@return boolean
function M.is_local(s)
  if type(s) ~= "string" then
    return false
  end
  if M.is_url(s) then
    return false
  end
  if s:match("^%a+:$") then
    return false
  end
  return true
end

--- Split a LavaLink style `prefix:rest` query.
---@param query string
---@return string|nil source_id, string rest
function M.parse_prefix(query)
  query = tostring(query or "")
  local prefix, rest = query:match("^([%w_]+):%s*(.*)$")
  if prefix and rest and rest ~= "" then
    local wanted = prefix:lower()
    for id, source in pairs(M.sources) do
      if source.prefix == wanted then
        return id, rest
      end
    end
    -- also allow the source id itself (`youtube:daft punk`)
    local direct = M.sources[wanted]
    if direct then
      return wanted, rest
    end
  end
  return nil, query
end

--- Detect the source of a query/path without doing any I/O.
---@param query string
---@return string source_id, string query  (query without the prefix)
function M.detect(query)
  query = Compat.trim(tostring(query or ""))
  local prefixed, rest = M.parse_prefix(query)
  if prefixed then
    return prefixed, rest
  end
  if M.is_url(query) then
    local lower = query:lower()
    if lower:match("%.pls") or lower:match("%.m3u[8]?$") or lower:match("%.xspf") then
      return "http", query
    end
    if lower:match("%.rss$") or lower:match("/feed/?$") or lower:match("/podcast") then
      return "rss", query
    end
    for id, source in pairs(M.sources) do
      if source.kind ~= "local" then
        for _, pattern in ipairs(source.patterns) do
          if lower:match(pattern) then
            return id, query
          end
        end
      end
    end
    local configured = M.subsonic_options()
    if configured.url and configured.url ~= "" and query:sub(1, #configured.url) == configured.url then
      return "subsonic", query
    end
    return "http", query
  end
  return "local_file", query
end

--- The source that a bare search string should use (first available resolver).
---@return string source_id
function M.default_search_source()
  for _, id in ipairs(M.search_order) do
    local source = M.sources[id]
    if source then
      local ready = true
      for _, bin in ipairs(source.requires) do
        if vim.fn.executable(bin) ~= 1 then
          ready = false
          break
        end
      end
      if ready then
        return id
      end
    end
  end
  return "youtube_music"
end

-- Subprocess + HTTP helpers ------------------------------------------------------

---@param bin string
---@return boolean
function M.have(bin)
  return vim.fn.executable(bin) == 1
end

--- First executable from a list.
---@param bins string[]
---@return string|nil
function M.first_executable(bins)
  for _, bin in ipairs(bins) do
    if M.have(bin) then
      return bin
    end
  end
  return nil
end

--- Run a command and capture stdout (async, callback style).
---@param args string[]
---@param opts? {timeout?: number, cwd?: string}
---@param cb fun(err: string|nil, stdout: string, res: KaeruProcResult|nil)
function M.capture(args, opts, cb)
  opts = opts or {}
  if type(args) == "string" then
    args = { args }
  end
  if vim.fn.executable(args[1]) ~= 1 then
    return cb(args[1] .. " is not installed", "", nil)
  end
  Process.run(args, { cwd = opts.cwd }, function(res)
    if res.code ~= 0 then
      local err = (res.stderr ~= "" and res.stderr) or (res.stdout ~= "" and res.stdout) or ("exit code " .. tostring(res.code))
      return cb(Compat.trim(err:gsub("%s+$", "")), res.stdout or "", res)
    end
    cb(nil, res.stdout or "", res)
  end)
end

--- Synchronous variant used for tiny, fast lookups (local files, prefix parse).
---@param args string[]
---@param opts? {cwd?: string}
---@return integer code, string stdout, string stderr
function M.capture_sync(args, opts)
  if vim.fn.executable(args[1]) ~= 1 then
    return 127, "", args[1] .. " is not executable"
  end
  if vim.system then
    local ok, res = pcall(vim.system, args, { text = true, cwd = opts and opts.cwd }, nil)
    if ok and res then
      local result = res:wait()
      return result.code or 0, result.stdout or "", result.stderr or ""
    end
  end
  local out = vim.fn.systemlist(args)
  return vim.v.shell_error or 0, table.concat(out, "\n"), ""
end

--- Fetch a URL with curl (async).
---@param url string
---@param opts? {headers?: string[], timeout?: number, max_bytes?: integer, method?: string, data?: string}
---@param cb fun(err: string|nil, body: string, headers: string)
function M.http_get(url, opts, cb)
  opts = opts or {}
  if not M.have("curl") then
    return cb("curl is not installed (needed for HTTP sources)", "", "")
  end
  local args = {
    "curl",
    "-sSL",
    "--max-time",
    tostring(opts.timeout or 20),
    "--retry",
    "1",
    "-A",
    M.user_agent,
    "-D",
    "-",
  }
  if opts.max_bytes then
    args[#args + 1] = "--max-filesize"
    args[#args + 1] = tostring(opts.max_bytes)
  end
  for _, header in ipairs(opts.headers or {}) do
    args[#args + 1] = "-H"
    args[#args + 1] = header
  end
  if opts.method then
    args[#args + 1] = "-X"
    args[#args + 1] = opts.method
  end
  if opts.data then
    args[#args + 1] = "--data"
    args[#args + 1] = opts.data
  end
  args[#args + 1] = url
  Process.run(args, {}, function(res)
    if res.code ~= 0 then
      local err = res.stderr ~= "" and Compat.trim(res.stderr) or ("curl exit code " .. tostring(res.code))
      return cb(err, "", "")
    end
    local body = res.stdout or ""
    local headers = ""
    local split = body:find("\r\n\r\n")
    if split then
      headers = body:sub(1, split - 1)
      body = body:sub(split + 4)
    end
    cb(nil, body, headers)
  end)
end

--- Fetch + decode a JSON API (async).
---@param url string
---@param opts? {headers?: string[], timeout?: number}
---@param cb fun(err: string|nil, data: any)
function M.http_json(url, opts, cb)
  M.http_get(url, opts, function(err, body)
    if err then
      return cb(err, nil)
    end
    local data, derr = require("kaeru.json").decode(body)
    if data == nil then
      return cb("invalid JSON from " .. url .. (derr and (": " .. derr) or ""), nil)
    end
    cb(nil, data)
  end)
end

---@param value string
---@return string
function M.url_encode(value)
  return (
    tostring(value):gsub("([^%w%-%._~])", function(c)
      return ("%%%02X"):format(c:byte())
    end)
  )
end

-- yt-dlp ------------------------------------------------------------------------

---@return boolean
function M.ytdlp_available()
  return M.have("yt-dlp") or M.have("youtube-dl")
end

---@return string
function M.ytdlp_bin()
  return M.have("yt-dlp") and "yt-dlp" or "youtube-dl"
end

---@return string[]
function M.ytdlp_format_args()
  local Config = require("kaeru.config")
  local music = (Config.options and Config.options.music) or {}
  local args = {}
  if music.ytdlp_cookies and music.ytdlp_cookies ~= "" then
    args[#args + 1] = "--cookies"
    args[#args + 1] = vim.fn.expand(music.ytdlp_cookies)
  end
  if music.ytdlp_extra_args then
    vim.list_extend(args, music.ytdlp_extra_args)
  end
  return args
end

--- Resolve a query/URL into a playable direct URL with metadata (async).
---@param query string
---@param opts? {source?: string, limit?: integer, audio_only?: boolean}
---@param cb fun(err: string|nil, result: table|nil)
function M.resolve_ytdlp(query, opts, cb)
  opts = opts or {}
  local source = opts.source or "youtube_music"
  if not M.ytdlp_available() then
    return cb("yt-dlp is required for " .. source .. " (install it or use a direct stream)", nil)
  end
  local bin = M.ytdlp_bin()
  local is_search = not M.is_url(query)
  local target = query
  if is_search then
    local prefix = source == "soundcloud" and "scsearch" or (source == "youtube" and "ytsearch" or "ytmsearch")
    target = ("%s%d:%s"):format(prefix, opts.limit or 1, query)
  end
  local args = { bin, "--no-warnings", "--ignore-config", "--dump-single-json" }
  -- A playlist URL (or an explicit `flat`/`playlist` request) must be expanded,
  -- everything else stays a single video — that is what casting a link means.
  local expand = opts.playlist == true or opts.flat == true or (opts.no_playlist ~= true and M.is_url(target) and target:lower():find("list=", 1, true) ~= nil)
  if expand then
    args[#args + 1] = "--yes-playlist"
    args[#args + 1] = "--flat-playlist"
  else
    args[#args + 1] = "--no-playlist"
  end
  if opts.limit and opts.limit > 1 and not expand then
    vim.list_extend(args, { "--flat-playlist" })
  end
  vim.list_extend(args, M.ytdlp_format_args())
  args[#args + 1] = target
  M.capture(args, { timeout = 45 }, function(err, stdout)
    if err then
      return cb(err, nil)
    end
    local json = require("kaeru.json")
    if opts.limit and opts.limit > 1 then
      local tracks = {}
      for line in stdout:gmatch("[^\r\n]+") do
        local item = json.decode(line)
        if item then
          if item.entries then
            for _, entry in ipairs(item.entries) do
              tracks[#tracks + 1] = M.track_from_ytdlp(entry, source)
            end
          else
            tracks[#tracks + 1] = M.track_from_ytdlp(item, source)
          end
        end
      end
      return cb(nil, { kind = "search", source = source, query = query, tracks = tracks })
    end
    local data = json.decode(stdout)
    if not data then
      return cb("could not parse yt-dlp output", nil)
    end
    data.title = data.title or query
    return cb(nil, { kind = "track", source = source, query = query, tracks = { M.track_from_ytdlp(data, source) } })
  end)
end

--- Resolve to a *direct* stream URL only (used right before playback).
---@param url string
---@param cb fun(err: string|nil, url: string|nil)
function M.ytdlp_stream_url(url, cb)
  if not M.ytdlp_available() then
    -- mpv can also use its own yt-dlp hook; let it try the original URL.
    return cb(nil, url)
  end
  local args = { M.ytdlp_bin(), "--no-warnings", "--no-playlist", "--ignore-config", "-f", "bestaudio/best", "-g" }
  if url:match("youtu%.?be") or url:match("list=") then
    args[#args + 1] = "--no-playlist"
  end
  vim.list_extend(args, M.ytdlp_format_args())
  args[#args + 1] = url
  M.capture(args, { timeout = 45 }, function(err, stdout)
    if err then
      return cb(nil, url)
    end
    local first = stdout:match("^([^\r\n]+)")
    cb(nil, first or url)
  end)
end

---@param data table
---@param source string
---@return MusicTagTrack
function M.track_from_ytdlp(data, source)
  local track = {
    path = data.webpage_url or data.url or data.original_url or "",
    url = data.webpage_url or data.url or "",
    stream_url = data.url,
    title = data.track or data.title or "unknown",
    artist = data.artist or data.uploader or data.channel or data.creator or "",
    album = data.album or "",
    duration = tonumber(data.duration) or 0,
    format = source or "ytdlp",
    source = source or "ytdlp",
    bitrate = (data.abr and math.floor(tonumber(data.abr) or 0)) or 0,
    samplerate = tonumber(data.asr) or 0,
    thumbnail = data.thumbnail,
    id = data.id,
  }
  if track.artist == "" then
    -- "Artist - Title" in the uploader field is common on YouTube
    local artist, title = track.title:match("^(.-)%s+[-–—]%s+(.+)$")
    if artist and #artist <= 40 then
      track.artist = artist
      track.title = title
    end
  end
  return Tags.normalize(track)
end

-- Streams, playlists and RSS -----------------------------------------------------

--- Expand a `.pls` / `.m3u` URL into tracks (async).
---@param url string
---@param cb fun(err: string|nil, tracks: MusicTagTrack[])
function M.expand_remote_playlist(url, cb)
  M.http_get(url, { max_bytes = 2 * 1024 * 1024 }, function(err, body)
    if err then
      return cb(err, {})
    end
    local tracks = Playlist.parse_m3u(body)
    if #tracks == 0 then
      -- XSPF: pull every <location> element
      for location in body:gmatch("<location>([^<]+)</location>") do
        tracks[#tracks + 1] = Tags.normalize({ path = location, url = location, format = "stream", title = Tags.basename(location) })
      end
    end
    cb(nil, tracks)
  end)
end

--- Parse a podcast RSS/Atom feed into episode tracks (pure, testable).
---@param xml string
---@param feed_url? string
---@return MusicTagTrack[]
function M.parse_rss(xml, feed_url)
  local tracks = {}
  local channel_title = xml:match("<title[^>]*>(.-)</title>") or ""
  channel_title = channel_title:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("&amp;", "&")
  for item in xml:gmatch("<item[^>]*>(.-)</item>") do
    local title = item:match("<title[^>]*>(.-)</title>")
    if title then
      title = title:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'")
    end
    local enclosure = item:match('<enclosure[^>]-url="([^"]+)"')
      or item:match('<media:content[^>]-url="([^"]+)"')
      or item:match("<link>(.-)</link>")
    local duration_text = item:match("<itunes:duration>([^<]+)</itunes:duration>")
    local duration = 0
    if duration_text then
      duration_text = Compat.trim(duration_text)
      if duration_text:match("^%d+:%d+:%d+$") then
        local h, m, s = duration_text:match("^(%d+):(%d+):(%d+)$")
        duration = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
      elseif duration_text:match("^%d+:%d+$") then
        local m, s = duration_text:match("^(%d+):(%d+)$")
        duration = tonumber(m) * 60 + tonumber(s)
      else
        duration = tonumber(duration_text) or 0
      end
    end
    if enclosure then
      tracks[#tracks + 1] = Tags.normalize({
        path = enclosure,
        url = enclosure,
        title = title or Tags.basename(enclosure),
        artist = channel_title,
        album = channel_title,
        duration = duration,
        format = "podcast",
        source = "rss",
        feed = feed_url,
      })
    end
  end
  return tracks
end

--- Fetch a feed and return its episodes (async).
---@param url string
---@param cb fun(err: string|nil, tracks: MusicTagTrack[])
function M.resolve_rss(url, cb)
  M.http_get(url, { max_bytes = 8 * 1024 * 1024 }, function(err, body)
    if err then
      return cb(err, {})
    end
    cb(nil, M.parse_rss(body, url))
  end)
end

-- Subsonic / Navidrome -----------------------------------------------------------

---@return {url: string, user: string, password: string, client: string}
function M.subsonic_options()
  local Config = require("kaeru.config")
  local cfg = (Config.options and Config.options.music and Config.options.music.subsonic) or {}
  return {
    url = (cfg.url or ""):gsub("/$", ""),
    user = cfg.user or "",
    password = cfg.password or "",
    client = cfg.client or "kaeru.nvim",
  }
end

--- Build a Subsonic REST URL (`/rest/<method>.view?...`). Token auth is used
--- when the password already looks like an MD5 hash, plaintext otherwise.
---@param method string  e.g. "search3", "stream", "getPlaylists"
---@param params? table<string, string|number>
---@return string|nil url, string|nil err
function M.subsonic_url(method, params)
  local cfg = M.subsonic_options()
  if cfg.url == "" then
    return nil, "music.subsonic.url is not configured (see kaeru.yaml)"
  end
  if cfg.user == "" then
    return nil, "music.subsonic.user is not configured"
  end
  local query = {
    "u=" .. M.url_encode(cfg.user),
    "v=1.16.1",
    "c=" .. M.url_encode(cfg.client),
    "f=json",
  }
  if cfg.password:match("^%x+%.%x+$") then
    local token, salt = cfg.password:match("^(%x+)%.(%x+)$")
    query[#query + 1] = "t=" .. token
    query[#query + 1] = "s=" .. salt
  elseif cfg.password ~= "" then
    query[#query + 1] = "p=" .. M.url_encode(cfg.password)
  end
  for k, v in pairs(params or {}) do
    query[#query + 1] = ("%s=%s"):format(k, M.url_encode(tostring(v)))
  end
  return ("%s/rest/%s.view?%s"):format(cfg.url, method, table.concat(query, "&")), nil
end

--- Convert a Subsonic `child` object into a track.
---@param cfg table
---@param child table
---@return MusicTagTrack
function M.subsonic_track(cfg, child)
  local url = M.subsonic_url("stream", { id = child.id })
  return Tags.normalize({
    path = url or child.id,
    url = url,
    stream_url = url,
    title = child.title or child.name or "unknown",
    artist = child.artist or child.albumArtist or "",
    album = child.album or "",
    genre = child.genre or "",
    duration = tonumber(child.duration) or 0,
    track = child.track and tostring(child.track) or "",
    format = "subsonic",
    source = "subsonic",
    bitrate = tonumber(child.bitRate) or 0,
    id = child.id,
  })
end

--- Search a Subsonic/Navidrome server (async).
---@param query string
---@param cb fun(err: string|nil, tracks: MusicTagTrack[])
function M.subsonic_search(query, cb)
  local cfg = M.subsonic_options()
  local url, err = M.subsonic_url("search3", {
    query = query,
    songCount = 50,
    albumCount = 5,
    artistCount = 5,
  })
  if not url then
    return cb(err, {})
  end
  M.http_json(url, {}, function(herr, data)
    if herr then
      return cb(herr, {})
    end
    local tracks = {}
    local result = data and data["subsonic-response"] and data["subsonic-response"].searchResult3
    for _, child in ipairs((result and result.song) or {}) do
      tracks[#tracks + 1] = M.subsonic_track(cfg, child)
    end
    cb(nil, tracks)
  end)
end

-- Radio (Radio Browser) ----------------------------------------------------------

M.radio_mirrors = {
  "https://de1.api.radio-browser.info",
  "https://nl1.api.radio-browser.info",
  "https://at1.api.radio-browser.info",
}

--- Search 30k+ stations from the Radio Browser directory (async, mirror failover).
---@param query string
---@param opts? {limit?: integer, on_mirror?: fun(url: string)}
---@param cb fun(err: string|nil, stations: table[])
function M.radio_search(query, opts, cb)
  opts = opts or {}
  local limit = opts.limit or 25
  local attempts = {}
  for _, mirror in ipairs(M.radio_mirrors) do
    attempts[#attempts + 1] = mirror
  end
  local function try(index, last_err)
    local mirror = attempts[index]
    if not mirror then
      return cb(last_err or "no Radio Browser mirror reachable", {})
    end
    if opts.on_mirror then
      opts.on_mirror(mirror)
    end
    local url
    if query == "" or query == "*" then
      url = ("%s/json/stations/topvote/%d"):format(mirror, limit)
    else
      url = ("%s/json/stations/search?name=%s&limit=%d&hidebroken=true&order=votes&reverse=true"):format(
        mirror,
        M.url_encode(query),
        limit
      )
    end
    M.http_json(url, { headers = { "Accept: application/json" }, timeout = 12 }, function(err, data)
      if err or type(data) ~= "table" then
        return try(index + 1, err)
      end
      local stations = {}
      for _, station in ipairs(data) do
        stations[#stations + 1] = {
          id = station.stationuuid or station.id,
          title = station.name or "unknown station",
          artist = station.country or "",
          genre = station.tags or station.codec or "",
          service = "Radio Browser",
          url = station.url_resolved or station.url,
          homepage = station.homepage,
          bitrate = (station.bitrate and station.bitrate ~= 0) and (tostring(station.bitrate) .. " kbps") or "stream",
          codec = station.codec,
          country = station.country,
          votes = station.votes,
          source = "radio",
        }
      end
      cb(nil, stations)
    end)
  end
  try(1, nil)
end

-- Local + dispatch ---------------------------------------------------------------

--- Immediate (synchronous) resolution for things that need no network:
--- local files/directories and playlist files.
---@param query string
---@return {kind: string, tracks: MusicTagTrack[], source: string}|nil, string|nil err
function M.resolve_local(query)
  local path = vim.fn.expand(query)
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  local is_dir = stat and stat.type == "directory" or vim.fn.isdirectory(path) == 1
  local readable = stat ~= nil or vim.fn.filereadable(path) == 1

  if is_dir then
    local tracks = Playlist.scan_tracks(path)
    if #tracks == 0 then
      return nil, "no audio files found in " .. path
    end
    return { kind = "playlist", tracks = tracks, source = "local_file", query = query }
  end

  if readable then
    if Tags.is_playlist(path) then
      local playlist, err = Playlist.load(path, { resolve = Tags.read })
      if not playlist then
        return nil, err
      end
      return { kind = "playlist", tracks = playlist.items, source = "local_file", query = query, name = playlist.name }
    end
    if Tags.is_audio(path) then
      return { kind = "track", tracks = { Tags.read(path) }, source = "local_file", query = query }
    end
    return nil, "unsupported file type: " .. vim.fn.fnamemodify(path, ":t")
  end

  return nil, nil -- not a local path: the caller should search
end

--- Resolve any query asynchronously. `cb(err, result)` with
--- `result = { kind, source, tracks, name? }`.
---@param query string
---@param opts? {source?: string, limit?: integer, search?: boolean}
---@param cb fun(err: string|nil, result: table|nil)
function M.resolve(query, opts, cb)
  opts = opts or {}
  query = Compat.trim(tostring(query or ""))
  if query == "" then
    return cb("nothing to play", nil)
  end

  local source_id, rest = M.detect(query)
  local source = M.sources[source_id] or M.sources.local_file
  rest = rest ~= "" and rest or query

  if source.kind == "local" then
    local immediate, err = M.resolve_local(rest)
    if immediate then
      return cb(nil, immediate)
    end
    if err then
      return cb(err, nil)
    end
    -- Not a path: search instead.
    return M.search(rest, opts, cb)
  end

  if source.kind == "stream" then
    local lower = rest:lower()
    if lower:match("%.pls") or (lower:match("%.m3u") and not lower:match("%.m3u8")) then
      return M.expand_remote_playlist(rest, function(err, tracks)
        if err then
          return cb(err, nil)
        end
        if #tracks == 0 then
          return cb("no stations found in " .. rest, nil)
        end
        cb(nil, { kind = "playlist", source = source_id, query = query, tracks = tracks })
      end)
    end
    local title = Tags.basename(rest)
    return cb(nil, {
      kind = "track",
      source = source_id,
      query = query,
      tracks = { Tags.normalize({ path = rest, url = rest, stream_url = rest, title = title, format = "stream", source = source_id }) },
    })
  end

  if source.kind == "rss" then
    return M.resolve_rss(rest, function(err, tracks)
      if err then
        return cb(err, nil)
      end
      if #tracks == 0 then
        return cb("no episodes found in " .. rest, nil)
      end
      cb(nil, { kind = "playlist", source = "rss", query = query, tracks = tracks, name = Tags.basename(rest) })
    end)
  end

  if source.kind == "api" and source_id == "subsonic" then
    return M.subsonic_search(rest, function(err, tracks)
      if err then
        return cb(err, nil)
      end
      if #tracks == 0 then
        return cb("no tracks found on the Subsonic server for " .. rest, nil)
      end
      cb(nil, { kind = "search", source = "subsonic", query = query, tracks = tracks })
    end)
  end

  if source.kind == "api" and source_id == "radio" then
    local radio = require("kaeru.kikru.radio")
    return radio.search(rest, { limit = opts.limit or 25 }, function(err, stations)
      if err then
        return cb(err, nil)
      end
      local tracks = {}
      for _, station in ipairs(stations) do
        tracks[#tracks + 1] = radio.to_track(station)
      end
      cb(nil, { kind = "search", source = "radio", query = query, tracks = tracks })
    end)
  end

  if source.kind == "player" and source_id == "mpd" then
    return cb(nil, { kind = "player", source = "mpd", query = rest, tracks = {} })
  end

  -- spotify / deezer / apple music: try a native resolver first, fall back to
  -- a yt-dlp search of the very same query (documented behaviour).
  if source_id == "spotify" or source_id == "deezer" or source_id == "apple_music" or source_id == "yandex_music" then
    local search = rest:gsub("^[%w]+:", "")
    if not M.is_url(search) then
      search = query
    end
    return M.resolve_ytdlp(search, { source = "youtube_music", limit = opts.limit or 1 }, function(err, result)
      if err then
        return cb(err, nil)
      end
      for _, track in ipairs(result.tracks or {}) do
        track.original_source = source_id
        track.source = source_id
      end
      cb(nil, result)
    end)
  end

  -- ytdlp sources
  local ytdlp_opts = {
    source = source_id,
    limit = opts.limit or 1,
    flat = opts.flat,
    playlist = opts.playlist,
    no_playlist = opts.no_playlist or opts.flat ~= true,
  }
  if M.is_url(rest) and not opts.search then
    -- A URL is a *request for that exact thing*: a playlist link expands, a
    -- watch link does not — unless the caller asked for a queue.
    ytdlp_opts.no_playlist = opts.playlist ~= true
    if opts.playlist then
      ytdlp_opts.limit = opts.limit or 50
    else
      ytdlp_opts.limit = 1
    end
    if opts.flat then
      ytdlp_opts.limit = opts.limit or 50
    end
    return M.resolve_ytdlp(rest, ytdlp_opts, cb)
  end
  return M.resolve_ytdlp(rest, ytdlp_opts, cb)
end

--- Search (not resolve) a query and return several candidate tracks.
---@param query string
---@param opts? {limit?: integer, source?: string}
---@param cb fun(err: string|nil, result: table|nil)
function M.search(query, opts, cb)
  opts = opts or {}
  local source_id = opts.source or M.default_search_source()
  local limit = opts.limit or 20
  if source_id == "radio" then
    return M.resolve("radio:" .. query, { limit = limit }, cb)
  end
  if source_id == "subsonic" then
    return M.subsonic_search(query, function(err, tracks)
      if err then
        return cb(err, nil)
      end
      cb(nil, { kind = "search", source = "subsonic", query = query, tracks = tracks })
    end)
  end
  return M.resolve_ytdlp(query, { source = source_id, limit = limit, no_playlist = true }, cb)
end

--- Synchronous "what would play" preview for the UI / completion.
---@param query string
---@return string source_id, string description
function M.preview(query)
  local source_id, rest = M.detect(query)
  local source = M.sources[source_id]
  local ready = {}
  for _, bin in ipairs(source.requires) do
    ready[#ready + 1] = bin .. (M.have(bin) and " ✓" or " ✗")
  end
  local desc = ("[%s] %s"):format(source.name, rest)
  if #ready > 0 then
    desc = desc .. "  (" .. table.concat(ready, ", ") .. ")"
  end
  return source_id, desc
end

--- All sources that are actually usable in this environment (for pickers).
---@return MusicSource[]
function M.available_sources()
  local out = {}
  for _, id in ipairs(M.source_ids()) do
    local source = M.sources[id]
    local ready = true
    for _, bin in ipairs(source.requires) do
      if not M.have(bin) then
        ready = false
        break
      end
    end
    if ready then
      out[#out + 1] = source
    end
  end
  return out
end

return M
