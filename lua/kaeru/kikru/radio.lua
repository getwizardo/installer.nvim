-- kaeru.nvim · :Kikru — internet radio.
--
-- Two layers, like cliamp (https://cliamp.stream/docs/radios):
--   1. a curated, offline-curated station list with per-station fallback URLs
--      (SomaFM, Lofi Girl, Nightride FM, CodeRadio, Radio Paradise, …);
--   2. the Radio Browser directory (`/json/stations/search`) for 30 000+ live
--      stations, searched on demand and cached for the session.
local Sources = require("kaeru.kikru.sources")
local Tags = require("kaeru.kikru.tags")
local Compat = require("kaeru.compat")

local M = {}

---@class MusicStation
---@field id string
---@field title string
---@field artist string
---@field genre string
---@field service string
---@field url string
---@field urls? string[]   fallbacks tried in order
---@field bitrate string
---@field country? string
---@field tags? string[]
---@field source? string

-- Curated stations ---------------------------------------------------------------

---@type MusicStation[]
M.stations = {
  {
    id = "lofi-girl",
    title = "Lofi Girl · Beats to Code / Relax To",
    artist = "Lofi Girl Radio",
    genre = "Lo-Fi / Chillhop",
    service = "Lofi Girl",
    url = "https://play.streamafrica.net/lofiradio",
    urls = { "https://streams.ilovemusic.de/iloveradio17.mp3", "https://usa9.fastcast4u.com/proxy/jamz?mp=/1" },
    bitrate = "128 kbps",
    country = "INT",
    tags = { "lofi", "chillhop", "coding" },
  },
  {
    id = "somafm-groovesalad",
    title = "SomaFM · Groove Salad",
    artist = "SomaFM San Francisco",
    genre = "Ambient / Downtempo",
    service = "SomaFM",
    url = "https://ice1.somafm.com/groovesalad-128-mp3",
    urls = { "https://ice2.somafm.com/groovesalad-128-mp3", "https://ice4.somafm.com/groovesalad-128-mp3" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "ambient", "downtempo", "coding" },
  },
  {
    id = "somafm-defcon",
    title = "SomaFM · DEF CON Radio",
    artist = "SomaFM Hacker Stream",
    genre = "Electronic / Hacker",
    service = "SomaFM",
    url = "https://ice1.somafm.com/defcon-128-mp3",
    urls = { "https://ice2.somafm.com/defcon-128-mp3" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "electronic", "hacker", "coding" },
  },
  {
    id = "somafm-dronezone",
    title = "SomaFM · Drone Zone",
    artist = "SomaFM Ambient",
    genre = "Atmospheric / Space",
    service = "SomaFM",
    url = "https://ice1.somafm.com/dronezone-128-mp3",
    urls = { "https://ice2.somafm.com/dronezone-128-mp3" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "ambient", "space", "focus" },
  },
  {
    id = "somafm-secretagent",
    title = "SomaFM · Secret Agent",
    artist = "SomaFM Lounge",
    genre = "Spy Jazz / Lounge",
    service = "SomaFM",
    url = "https://ice1.somafm.com/secretagent-128-mp3",
    urls = { "https://ice2.somafm.com/secretagent-128-mp3" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "jazz", "lounge" },
  },
  {
    id = "somafm-lush",
    title = "SomaFM · Lush",
    artist = "SomaFM",
    genre = "Vocal / Dream Pop",
    service = "SomaFM",
    url = "https://ice1.somafm.com/lush-128-mp3",
    bitrate = "128 kbps",
    country = "US",
    tags = { "vocal", "dream pop" },
  },
  {
    id = "somafm-spacestation",
    title = "SomaFM · Space Station Soma",
    artist = "SomaFM",
    genre = "Mid-Tempo Space Kikru",
    service = "SomaFM",
    url = "https://ice1.somafm.com/spacestation-128-mp3",
    bitrate = "128 kbps",
    country = "US",
    tags = { "space", "electronic" },
  },
  {
    id = "somafm-u80s",
    title = "SomaFM · Underground 80s",
    artist = "SomaFM",
    genre = "Synthpop / New Wave",
    service = "SomaFM",
    url = "https://ice1.somafm.com/u80s-128-mp3",
    bitrate = "128 kbps",
    country = "US",
    tags = { "80s", "synth" },
  },
  {
    id = "nightride-fm",
    title = "Nightride FM · Cyberpunk Synthwave",
    artist = "Nightride FM",
    genre = "Synthwave / Outrun",
    service = "Nightride FM",
    url = "https://stream.nightride.fm/nightride.m4a",
    urls = { "https://stream.nightride.fm/nightride.mp3", "https://stream.nightride.fm/chillsynth.m4a" },
    bitrate = "192 kbps",
    country = "INT",
    tags = { "synthwave", "outrun", "coding" },
  },
  {
    id = "nightride-chillsynth",
    title = "Nightride FM · Chillsynth",
    artist = "Nightride FM",
    genre = "Chill Synth",
    service = "Nightride FM",
    url = "https://stream.nightride.fm/chillsynth.m4a",
    bitrate = "192 kbps",
    country = "INT",
    tags = { "synthwave", "chill" },
  },
  {
    id = "coderadio-fcc",
    title = "freeCodeCamp · Code Radio 24/7",
    artist = "freeCodeCamp",
    genre = "Coding Beats",
    service = "CodeRadio",
    url = "https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3",
    urls = { "https://coderadio-admin.freecodecamp.org/radio/8010/radio.mp3" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "coding", "beats" },
  },
  {
    id = "radioparadise-main",
    title = "Radio Paradise · Main Mix",
    artist = "Radio Paradise",
    genre = "Eclectic Rock / World",
    service = "Radio Paradise",
    url = "https://stream.radioparadise.com/aac-320",
    urls = { "https://stream.radioparadise.com/mp3-192", "https://stream.radioparadise.com/rock-320" },
    bitrate = "320 kbps",
    country = "US",
    tags = { "eclectic", "rock" },
  },
  {
    id = "radioparadise-mellow",
    title = "Radio Paradise · Mellow Mix",
    artist = "Radio Paradise",
    genre = "Mellow / Downtempo",
    service = "Radio Paradise",
    url = "https://stream.radioparadise.com/mellow-320",
    urls = { "https://stream.radioparadise.com/mellow-192" },
    bitrate = "320 kbps",
    country = "US",
    tags = { "mellow", "chill" },
  },
  {
    id = "jazz24",
    title = "Jazz24 · 24/7 Jazz",
    artist = "KNKX / Jazz24",
    genre = "Jazz",
    service = "Jazz24",
    url = "https://live.wostreaming.net/direct/ppm-jazz24aac-ibc1",
    urls = { "https://live.wostreaming.net/direct/ppm-jazz24mp3-ibc1" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "jazz", "focus" },
  },
  {
    id = "kexp",
    title = "KEXP 90.3 FM · Seattle",
    artist = "KEXP",
    genre = "Indie / Alternative",
    service = "KEXP",
    url = "https://kexp-mp3-128.streamguys1.com/kexp128.mp3",
    urls = { "https://kexp.streamguys1.com/kexp160.aac" },
    bitrate = "128 kbps",
    country = "US",
    tags = { "indie", "alternative" },
  },
  {
    id = "classicfm",
    title = "Classic FM · Relaxing Classics",
    artist = "Global",
    genre = "Classical",
    service = "Classic FM",
    url = "https://media-ice.musicradio.com/ClassicFMMP3",
    bitrate = "128 kbps",
    country = "UK",
    tags = { "classical", "focus" },
  },
  {
    id = "drone-ambient",
    title = "Ambient Sleeping Pill",
    artist = "SomaFM / Ambient",
    genre = "Deep Ambient",
    service = "SomaFM",
    url = "https://ice1.somafm.com/deepspaceone-128-mp3",
    bitrate = "128 kbps",
    country = "US",
    tags = { "ambient", "sleep" },
  },
}

--- SomaFM channels constructible from a channel id
--- (`:Kikru radio somafm:groovesalad`).
M.somafm_channels = {
  "groovesalad", "dronezone", "defcon", "secretagent", "lush", "spacestation", "u80s", "deepspaceone",
  "indiepop", "beatblender", "bootliquor", "cliqhop", "digitalis", "fluid", "folkforward", "gsclassic",
  "illstreet", "leftcoast77", "missioncontrol", "poptron", "reggae", "seventies", "sf1033", "sonicuniverse",
  "suburbsofgoa", "thetrip", "thistle", "tiki", "totallyradio", "7soul", "brfm", "christmas",
}

--- Find a station by index, id, name or tag ("1", "lofi", "groove salad",
--- "soma:groovesalad"). Used by `:Kikru play <station>` and the cast server.
---@param query string|integer
---@return KikruStation|nil
function M.find(query)
  if query == nil then
    return nil
  end
  local key = tostring(query):lower()
  local index = tonumber(key)
  if index and M.stations[index] then
    return M.stations[index]
  end
  if key:sub(1, 5) == "soma:" then
    return M.somafm(key:sub(6))
  end
  local best
  for _, station in ipairs(M.stations) do
    local id = tostring(station.id or ""):lower()
    local name = tostring(station.title or station.name or ""):lower()
    local tags = table.concat(station.tags or {}, " "):lower()
    if id == key or name == key then
      return station
    end
    if not best and (id:find(key, 1, true) or name:find(key, 1, true) or tags:find(key, 1, true)) then
      best = station
    end
  end
  return best or M.somafm(key)
end


---@param id string
---@return MusicStation|nil
function M.by_id(id)
  for _, station in ipairs(M.stations) do
    if station.id == id then
      return station
    end
  end
  return nil
end

--- Build a SomaFM station descriptor from a channel name.
---@param channel string
---@return MusicStation
function M.somafm(channel)
  channel = (channel or "groovesalad"):lower():gsub("[^%w]", "")
  if channel == "" then
    channel = "groovesalad"
  end
  local known = M.by_id("somafm-" .. channel)
  if known then
    return known
  end
  local pretty = channel:gsub("^%l", string.upper)
  return {
    id = "somafm-" .. channel,
    title = ("SomaFM · %s"):format(pretty),
    artist = "SomaFM",
    genre = "SomaFM channel",
    service = "SomaFM",
    url = ("https://ice1.somafm.com/%s-128-mp3"):format(channel),
    urls = { ("https://ice2.somafm.com/%s-128-mp3"):format(channel) },
    bitrate = "128 kbps",
    country = "US",
    tags = { "somafm", channel },
  }
end

--- Turn a station into a playable track table.
---@param station MusicStation
---@return MusicTagTrack
function M.to_track(station)
  return Tags.normalize({
    path = station.url,
    url = station.url,
    stream_url = station.url,
    fallbacks = station.urls,
    title = station.title,
    artist = station.artist or station.service or "Internet Radio",
    album = station.service,
    genre = station.genre,
    duration = 0,
    format = "stream",
    source = "radio",
    station_id = station.id,
    bitrate = tonumber((station.bitrate or ""):match("(%d+)")) or 0,
    country = station.country,
  })
end

--- Offline search across the curated stations (used when there is no network).
---@param query string
---@return MusicStation[]
function M.search_local(query)
  query = Compat.trim(tostring(query or "")):lower()
  local out = {}
  for _, station in ipairs(M.stations) do
    local haystack = table.concat({
      station.id,
      station.title,
      station.artist or "",
      station.genre or "",
      station.service or "",
      table.concat(station.tags or {}, " "),
    }, " "):lower()
    if query == "" or haystack:find(query, 1, true) then
      out[#out + 1] = station
    end
  end
  return out
end

--- Genre/category buckets for the station picker.
---@return table<string, MusicStation[]>
function M.by_genre()
  local out = {}
  for _, station in ipairs(M.stations) do
    local key = (station.genre or "Other"):match("^([^/]+)") or "Other"
    key = Compat.trim(key)
    out[key] = out[key] or {}
    table.insert(out[key], station)
  end
  return out
end

--- Search the Radio Browser directory, falling back to the curated list.
---@param query string
---@param opts? {limit?: integer}
---@param cb fun(err: string|nil, stations: MusicStation[])
function M.search(query, opts, cb)
  opts = opts or {}
  local query_lower = tostring(query or ""):lower()
  if query_lower:match("^somafm:") or query_lower:match("^soma:") then
    local channel = query_lower:gsub("^soma[mf]*:", "")
    return cb(nil, { M.somafm(channel) })
  end
  if not Sources.have("curl") then
    local local_hits = M.search_local(query)
    if #local_hits > 0 then
      return cb(nil, local_hits)
    end
    return cb("curl is required to search the Radio Browser directory", {})
  end

  Sources.radio_search(query, { limit = opts.limit or 25 }, function(err, stations)
    -- Radio Browser returns bitrate/urls in a slightly different shape; normalise.
    for _, station in ipairs(stations or {}) do
      station.source = "radio"
      station.service = station.service or "Radio Browser"
    end
    if #(stations or {}) == 0 then
      local cached = M._cache and M._cache[query_lower]
      if cached then
        return cb(err, cached)
      end
      local local_hits = M.search_local(query)
      if #local_hits > 0 then
        return cb(nil, local_hits)
      end
    end
    if #(stations or {}) > 0 then
      M._cache = M._cache or {}
      M._cache[query_lower] = stations
    end
    cb(err, stations or {})
  end)
end

--- Pick the stream URL that should be tried first for a station.
---@param station MusicStation
---@return string
function M.primary_url(station)
  return station.url or (station.urls and station.urls[1]) or ""
end

--- All URLs for a station (primary first, then fallbacks, deduplicated).
---@param station MusicStation
---@return string[]
function M.urls(station)
  local out, seen = {}, {}
  local function push(url)
    if url and url ~= "" and not seen[url] then
      seen[url] = true
      out[#out + 1] = url
    end
  end
  push(station.url)
  for _, url in ipairs(station.urls or {}) do
    push(url)
  end
  return out
end

--- Stations as tracks (for the playlist UI).
---@param stations? MusicStation[]
---@return MusicTagTrack[]
function M.tracks(stations)
  local out = {}
  for _, station in ipairs(stations or M.stations) do
    out[#out + 1] = M.to_track(station)
  end
  return out
end

return M
