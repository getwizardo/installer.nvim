-- kaeru.nvim · :Kikru — lyrics.
--
-- Local sources first, then a chain of online providers:
--
--   1. embedded tags (USLT / Vorbis `LYRICS`)
--   2. a sidecar `.lrc` / `.txt` next to the audio file
--   3. the on-disk cache (`stdpath("cache")/kaeru/lyrics`)
--   4. providers, in the order configured by `kikru.lyrics.providers`:
--
--        lrc.red    https://lrc.red/docs — 29.8M tracks, 12.5M synced.
--                   `GET /s/<ISRC>.lrc` (word-level timestamps), `GET
--                   /match.json?track=&artist=&album=&duration=` (scored hits),
--                   `GET /search.json?q=` as a free-text fallback.
--        LRCLIB     https://lrclib.net/docs — `GET /api/get` + `/api/search`.
--        NetEase    `music.163.com/api/search/get` → `/api/song/lyric`
--                   (also carries translations in `tlyric`).
--        SyncLRC    https://synclrc.dev — `api.synclrc.dev/lyrics`,
--                   karaoke / synced / plain, 30 requests per minute.
--        lyrics.ovh https://lyrics.ovh — plain text only, last resort.
--
-- lrc.red, SyncLRC and many LRCLIB rows ship *enhanced* LRC with word-level
-- `[00:01.22]<00:01.22>word` timing. `parse_lrc` keeps those in `line.words`,
-- which gives the player a real karaoke highlight; `M.window()` renders it and
-- `M.line_progress()` says how much of the line has been sung.
--
-- Everything network-facing goes through `M.http`, which the test-suite
-- replaces with canned responses, and every `vim.fn.*` access is guarded.
local Tags = require("kaeru.kikru.tags")
local Sources = require("kaeru.kikru.sources")
local Compat = require("kaeru.compat")

local M = {}

---@class MusicLyrics
---@field synced {time: number, text: string, words?: {time: number, text: string}[]}[]|nil
---@field translated {time: number, text: string}[]|nil
---@field plain string
---@field source string
---@field offset number
---@field meta table<string, string>
---@field raw? string

M.lrclib_endpoints = {
  get = "https://lrclib.net/api/get",
  search = "https://lrclib.net/api/search",
}

M.endpoints = {
  ["lrc.red"] = {
    page = "https://lrc.red/s/%s",
    lrc = "https://lrc.red/s/%s.lrc",
    match = "https://lrc.red/match.json",
    search = "https://lrc.red/search.json",
  },
  lrclib = M.lrclib_endpoints,
  netease = {
    search = "https://music.163.com/api/search/get",
    lyric = "https://music.163.com/api/song/lyric",
  },
  synclrc = { lyrics = "https://api.synclrc.dev/lyrics" },
  ["lyrics.ovh"] = { lyrics = "https://api.lyrics.ovh/v1" },
}

--- Online providers, best first. `synced` = can return timed lyrics.
M.provider_list = {
  {
    name = "lrc.red",
    label = "lrc.red — 29.8M tracks, word-level timing",
    home = "https://lrc.red",
    synced = true,
  },
  {
    name = "lrclib",
    label = "LRCLIB — free synced lyrics API",
    home = "https://lrclib.net",
    synced = true,
  },
  {
    name = "netease",
    label = "NetEase Cloud Music — synced + translations",
    home = "https://music.163.com",
    synced = true,
  },
  {
    name = "synclrc",
    label = "SyncLRC — karaoke/synced/plain API",
    home = "https://synclrc.dev",
    synced = true,
  },
  {
    name = "lyrics.ovh",
    label = "lyrics.ovh — plain text, last resort",
    home = "https://lyrics.ovh",
    synced = false,
  },
}

M.default_provider_order = { "lrc.red", "lrclib", "netease", "synclrc", "lyrics.ovh" }

-- HTTP hook (replaced in tests) ------------------------------------------------------

M.http = {
  get = Sources.http_get,
  json = Sources.http_json,
}

--- Set to false when `M.http` was replaced by a transport that needs no curl
--- (the test-suite does exactly that).
M.requires_curl = true

---@return string|nil
local function curl_missing()
  if M.requires_curl and not Sources.have("curl") then
    return "curl is required for online lyrics"
  end
  return nil
end

---@return table<string, string>
local function headers(extra)
  local out = {
    ["Accept"] = "application/json, text/plain, */*",
    ["User-Agent"] = Sources.user_agent,
  }
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  return out
end

---@param url string
---@param cb fun(err: string|nil, data: table|nil)
local function fetch_json(url, cb, extra_headers)
  M.http.json(url, { headers = headers(extra_headers), timeout = 15 }, cb)
end

---@param url string
---@param cb fun(err: string|nil, body: string|nil)
local function fetch_text(url, cb, extra_headers)
  M.http.get(url, { headers = headers(extra_headers), timeout = 15 }, cb)
end

-- ---------------------------------------------------------------------------
-- LRC parsing
-- ---------------------------------------------------------------------------

---@param stamp string
---@return number|nil
local function stamp_seconds(stamp)
  local minutes, seconds = stamp:match("^(%d+):(%d+%.?%d*)$")
  if not minutes then
    return nil
  end
  return tonumber(minutes) * 60 + (tonumber(seconds) or 0)
end

--- Split an enhanced-LRC body (`<mm:ss.xx>word…`) into timed words.
--- Lua patterns have no alternation, so this is a plain character scan.
---@param body string
---@param fallback_time number|nil
---@return {time: number, text: string}[] words, boolean enhanced
local function split_words(body, fallback_time)
  local words, buffer = {}, {}
  local pending_time = nil
  local enhanced = false
  local index, length = 1, #body

  local function flush()
    local value = table.concat(buffer)
    buffer = {}
    if value ~= "" then
      words[#words + 1] = { time = pending_time or fallback_time or 0, text = value }
    end
  end

  while index <= length do
    local char = body:sub(index, index)
    if char == "<" then
      local close = body:find(">", index + 1, true)
      local tag = close and body:sub(index + 1, close - 1) or nil
      local seconds = tag and stamp_seconds(tag) or nil
      if seconds then
        flush()
        pending_time = seconds
        enhanced = true
        index = close + 1
      else
        buffer[#buffer + 1] = char
        index = index + 1
      end
    else
      buffer[#buffer + 1] = char
      index = index + 1
    end
  end
  flush()

  return words, enhanced
end

--- Parse LRC text (plain, enhanced or with word-level `<mm:ss.xx>` tags).
---@param text string
---@param source? string
---@return MusicLyrics
function M.parse_lrc(text, source)
  local synced = {}
  local plain = {}
  local meta = {}
  local offset = 0
  text = tostring(text or ""):gsub("\r\n", "\n")

  for line in text:gmatch("[^\n]+") do
    local offset_match = line:match("^%s*%[offset:([%-+%d]+)%]")
    if offset_match then
      offset = tonumber(offset_match) or 0
    end
    -- Metadata tags: [ti:…] [ar:…] [al:…] [length:…] [by:…]
    local meta_key, meta_value = line:match("^%s*%[(%a%a%a?):([^%]]*)%]")
    if meta_key and not meta_key:match("^%d") then
      meta[meta_key:lower()] = meta_value
    end

    local stamps = {}
    for stamp in line:gmatch("%[(%d+:%d+%.?%d*)%]") do
      local seconds = stamp_seconds(stamp)
      if seconds then
        stamps[#stamps + 1] = seconds
      end
    end

    -- Everything after the leading line stamps, including any <mm:ss.xx> words.
    local body = line:gsub("^%s*%[[%d:%.%]]*%]", "")
    body = body:gsub("%[%d+:%d+%.?%d*%]", "")
    if body:match("^%s*%[%a+:[^%]]*%]%s*$") then
      body = "" -- a bare metadata tag, not a lyric line
    end

    local words, enhanced = split_words(body, stamps[1])
    if not enhanced then
      words = {} -- no `<mm:ss.xx>` tags: the body is one plain line, not words
    end
    local content
    if #words > 0 then
      local pieces = {}
      for _, word in ipairs(words) do
        pieces[#pieces + 1] = word.text
      end
      content = table.concat(pieces)
      words[1].text = words[1].text:gsub("^%s+", "")
      words[#words].text = words[#words].text:gsub("%s+$", "")
      if words[1].text == "" and #words == 1 then
        words = {}
      end
    else
      content = body:gsub("<[^>]*>", "")
    end
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then
      words = {}
    end

    if #stamps > 0 then
      if content ~= "" then
        for _, time in ipairs(stamps) do
          local entry = { time = time + offset / 1000, text = content }
          if #words > 0 then
            local shifted = {}
            for _, word in ipairs(words) do
              shifted[#shifted + 1] = { time = word.time + offset / 1000, text = word.text }
            end
            entry.words = shifted
          end
          synced[#synced + 1] = entry
        end
      end
    elseif content ~= "" then
      plain[#plain + 1] = content
    end
  end

  table.sort(synced, function(a, b)
    return a.time < b.time
  end)

  return {
    synced = #synced > 0 and synced or nil,
    plain = #plain > 0 and table.concat(plain, "\n") or "",
    source = source or "lrc",
    offset = offset,
    meta = meta,
    raw = text,
  }
end

function M.parse_translation(text)
  if not text or text == "" then
    return nil
  end
  local parsed = M.parse_lrc(text)
  if parsed.synced and #parsed.synced > 0 then
    local out = {}
    for _, line in ipairs(parsed.synced) do
      out[#out + 1] = { time = line.time, text = line.text }
    end
    return out
  end
  if parsed.plain ~= "" then
    local out = {}
    for _, line in ipairs(vim.split(parsed.plain, "\n", { plain = true })) do
      out[#out + 1] = { time = -1, text = line }
    end
    return out
  end
  return nil
end

-- Local sources ---------------------------------------------------------------------

---@param track MusicTagTrack
---@return string|nil
function M.sidecar_path(track)
  if not track or not track.path then
    return nil
  end
  if track.path:match("^%a+://") then
    return nil
  end
  local base = track.path:gsub("%.[%w]+$", "")
  for _, candidate in ipairs({ base .. ".lrc", base .. ".ttml", base .. ".lyrics", base .. ".txt", base .. ".LRC", base .. ".TTML" }) do
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

---@param path string
---@return MusicLyrics|nil
function M.from_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  if M.looks_like_ttml(text) then
    -- TTML carries word timing, duet agents and translations that LRC cannot
    -- express; the TypeScript parser normalises it and we keep the LRC path.
    local parsed, reason = M.parse_ttml(text, path)
    if parsed then
      return parsed
    end
    M.ttml_error = reason
    return nil
  end
  local parsed = M.parse_lrc(text, path)
  if parsed.synced or parsed.plain ~= "" then
    return parsed
  end
  return nil
end

--- Lyrics embedded in the file's tags.
---@param track MusicTagTrack
---@return MusicLyrics|nil
function M.from_tags(track)
  if not track then
    return nil
  end
  local text = track.lyrics
  if not text or text == "" then
    local meta = Tags.read(track.path)
    text = meta and meta.lyrics
  end
  if not text or text == "" then
    return nil
  end
  local parsed = M.parse_lrc(text, "tags")
  if not parsed.synced and parsed.plain == "" then
    parsed.plain = text
  end
  parsed.source = "tags"
  return parsed
end

-- Cache -----------------------------------------------------------------------------

---@return string|nil
function M.cache_dir()
  local config = require("kaeru.config")
  local settings = ((config.options or {}).kikru or {}).lyrics or {}
  if settings.cache == false then
    return nil
  end
  if settings.cache_dir and settings.cache_dir ~= "" then
    return vim.fn.expand(settings.cache_dir)
  end
  if not (vim.fn and vim.fn.stdpath) then
    return nil
  end
  local ok, base = pcall(vim.fn.stdpath, "cache")
  if not ok or not base or base == "" then
    return nil
  end
  return base .. "/kaeru/lyrics"
end

---@param track MusicTagTrack
---@return string|nil
function M.cache_path(track)
  local dir = M.cache_dir()
  if not dir then
    return nil
  end
  local key = tostring(track.artist or "") .. "|" .. tostring(track.title or "") .. "|" .. tostring(track.album or "")
  local hash = 5381
  for index = 1, #key do
    hash = (hash * 33 + key:byte(index)) % 2147483647
  end
  return ("%s/%08x.lrc"):format(dir, hash)
end

---@param track MusicTagTrack
---@return MusicLyrics|nil
function M.cache_read(track)
  local path = M.cache_path(track)
  if not path then
    return nil
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  local parsed = M.parse_lrc(text, "cache")
  return (parsed.synced or parsed.plain ~= "") and parsed or nil
end

---@param track MusicTagTrack
---@param lyrics MusicLyrics
---@return boolean ok
function M.cache_write(track, lyrics)
  local path = M.cache_path(track)
  if not path or not lyrics or not lyrics.raw or lyrics.raw == "" then
    return false
  end
  local dir = path:match("^(.*)/[^/]*$") or (vim.fn.fnamemodify and vim.fn.fnamemodify(path, ":h")) or nil
  if dir and vim.fn and vim.fn.mkdir then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local fd = io.open(path, "w")
  if not fd then
    return false
  end
  fd:write(lyrics.raw)
  fd:close()
  return true
end

--- Write the lyrics next to the audio file (`<track>.lrc`, or `.ttml` on request).
---@param track MusicTagTrack
---@param lyrics? MusicLyrics
---@param path? string
---@return string|nil written_path, string|nil err
function M.save(track, lyrics, path)
  lyrics = lyrics or M._last
  if not lyrics then
    return nil, "no lyrics to write"
  end
  local target = path
  if not target then
    if not track or not track.path or track.path:match("^%a+://") then
      return nil, "the track has no file to write next to"
    end
    target = track.path:gsub("%.[%w]+$", "") .. ".lrc"
  end
  local text = lyrics.raw
  if not text or text == "" then
    local lines = {}
    for _, line in ipairs(lyrics.synced or {}) do
      local minutes = math.floor(line.time / 60)
      lines[#lines + 1] = ("[%02d:%05.2f]%s"):format(minutes, line.time - minutes * 60, line.text)
    end
    if #lines == 0 then
      lines = vim.split(lyrics.plain or "", "\n", { plain = true })
    end
    text = table.concat(lines, "\n") .. "\n"
  end
  if target:match("%.[tT][tT][mM][lL]$") then
    -- TTML is not LRC: hand the lyrics to the TypeScript writer in Karu.
    local ok, err = M.save_ttml(lyrics, target)
    return ok and target or nil, err
  end
  local fd = io.open(target, "w")
  if not fd then
    return nil, "cannot write " .. target
  end
  fd:write(text)
  fd:close()
  return target
end

-- TTML (Apple Music · AMLL/QQ/NetEase · YouTube) ------------------------------------
--
-- TTML is the format Apple Music, QQ Music and NetEase serve, and it is richer
-- than LRC: per-syllable timing, duet agents, `<br/>` breaks, translation and
-- transliteration tracks. The parser lives in TypeScript (`karu/src/lyrics/
-- ttml.ts`) and is reached through `karu lyrics <file> --format json`, which
-- returns enhanced LRC plus the translation track aligned with it. Everything
-- below therefore still ends in `parse_lrc`, so the karaoke renderer, the cache
-- and the UI need no TTML knowledge at all.
--
-- Requires the Karu CLI (Node ≥ 22 or a compiled `karu`); without it TTML files
-- are skipped and `M.ttml_error` explains why — never half-parsed.

---@param text string|nil
---@return boolean
function M.looks_like_ttml(text)
  if type(text) ~= "string" then
    return false
  end
  return text:find("<%s*tt[%s>]") ~= nil or text:find("<%s*timedtext[%s>]") ~= nil
end

--- Karu CLI argv plus the module, or nil + reason.
local function karu_cli()
  local ok, Karu = pcall(require, "kaeru.karu")
  if not ok or type(Karu) ~= "table" then
    return nil, "karu is not installed"
  end
  if Karu.available then
    local available, reason = Karu.available()
    if available == false then
      return nil, reason or "karu is unavailable"
    end
  end
  local cmd = Karu.cli and Karu.cli()
  if type(cmd) ~= "table" or not cmd[1] then
    return nil, "karu is not installed (expected karu/bin/karu inside the plugin, or `karu` in $PATH)"
  end
  return cmd
end

--- Is the TTML path usable here (Karu CLI + a synchronous runner)?
---@return boolean, string|nil
function M.ttml_available()
  local cmd, reason = karu_cli()
  if not cmd then
    return false, reason
  end
  if not (vim.fn and vim.fn.system) then
    return false, "vim.fn.system is unavailable in this environment"
  end
  return true
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---@param suffix? string
---@return string
local function temp_path(suffix)
  if vim.fn and vim.fn.tempname then
    local name = vim.fn.tempname()
    if type(name) == "string" and name ~= "" then
      return name .. (suffix or "")
    end
  end
  return (os.tmpname and os.tmpname() or "/tmp/kaeru-lyrics") .. (suffix or "")
end

local function write_file(path, text)
  local fd = io.open(path, "w")
  if not fd then
    return false
  end
  fd:write(text)
  fd:close()
  return true
end

--- Run the Karu CLI and return its stdout.
---@param args string[]
---@return string|nil stdout, string|nil err
local function run_cli(args)
  local cmd, reason = karu_cli()
  if not cmd then
    return nil, reason
  end
  if not (vim.fn and vim.fn.system) then
    return nil, "vim.fn.system is unavailable in this environment"
  end
  local parts = {}
  for _, value in ipairs(cmd) do
    parts[#parts + 1] = shell_quote(value)
  end
  for _, value in ipairs(args) do
    parts[#parts + 1] = shell_quote(value)
  end
  local out = vim.fn.system(table.concat(parts, " "))
  local code = (vim and vim.v and vim.v.shell_error) or 0
  if type(out) == "table" then
    out = table.concat(out, "\n")
  end
  if code ~= 0 then
    local message = (out or ""):gsub("^%s*karu:%s*", ""):gsub("%s+$", "")
    return nil, message ~= "" and message or ("karu lyrics exited with code " .. tostring(code))
  end
  return out
end

--- Parse TTML text into the same shape `parse_lrc` returns.
---@param text string
---@param source? string
---@return MusicLyrics|nil, string|nil
function M.parse_ttml(text, source)
  if not M.looks_like_ttml(text) then
    return nil, "not a TTML document"
  end
  local path = temp_path(".ttml")
  if not write_file(path, text) then
    return nil, "cannot write a temporary file"
  end
  local out, err = run_cli({ "lyrics", path, "--format", "json" })
  os.remove(path)
  if not out then
    return nil, err or "karu lyrics failed"
  end
  local Json = require("kaeru.json")
  local ok, payload = pcall(Json.decode, out)
  if not ok or type(payload) ~= "table" then
    return nil, "karu lyrics returned unreadable JSON"
  end
  local lrc = payload.lrc
  if type(lrc) ~= "string" or lrc == "" then
    return nil, payload.error or "the TTML document has no timed lines"
  end

  local parsed = M.parse_lrc(lrc, source or "ttml")
  parsed.ttml = {
    timing = payload.timing,
    wordSync = payload.wordSync,
    singers = payload.singers,
    lang = payload.lang,
    translationLangs = payload.translationLangs,
    meta = payload.meta,
  }
  -- Translations live outside LRC: re-attach them to their line times.
  local translated, by_line = {}, payload.translationByLine or {}
  local cues = payload.cues or {}
  for index, value in ipairs(by_line) do
    local cue = cues[index]
    if type(value) == "string" and value ~= "" then
      translated[#translated + 1] = { time = (cue and cue.start) or -1, text = value }
    end
  end
  if #translated > 0 then
    parsed.translated = translated
  end
  if type(payload.summary) == "string" then
    parsed.meta = parsed.meta or {}
    parsed.meta.ttml = payload.summary
  end
  return parsed
end

--- Convert to TTML through Karu (used by `:Kikru lyrics save <file>.ttml`).
---@param lyrics MusicLyrics
---@param target string
---@return boolean ok, string|nil err
function M.save_ttml(lyrics, target)
  local available, reason = M.ttml_available()
  if not available then
    return false, reason
  end
  if rawget(lyrics, "raw") and M.looks_like_ttml(lyrics.raw or "") then
    return write_file(target, lyrics.raw) or false, "cannot write " .. target
  end
  local text = lyrics.raw
  if not text or text == "" then
    local lines = {}
    for _, line in ipairs(lyrics.synced or {}) do
      local minutes = math.floor(line.time / 60)
      lines[#lines + 1] = ("[%02d:%05.2f]%s"):format(minutes, line.time - minutes * 60, line.text)
    end
    if #lines == 0 then
      return false, "no timed lyrics to convert"
    end
    text = table.concat(lines, "\n") .. "\n"
  end
  local source = temp_path(".lrc")
  if not write_file(source, text) then
    return false, "cannot write a temporary file"
  end
  local _, err = run_cli({ "lyrics", source, "--format", "ttml", "--out", target })
  os.remove(source)
  if err then
    return false, err
  end
  local written = io.open(target, "r")
  if written then
    written:close()
    return true
  end
  return false, "karu lyrics did not write " .. target
end

-- Providers -------------------------------------------------------------------------

---@param name string
---@return table|nil
function M.provider(name)
  for _, provider in ipairs(M.provider_list) do
    if provider.name == name then
      return provider
    end
  end
  return nil
end

---@return string[]
function M.provider_names()
  local names = {}
  for _, provider in ipairs(M.provider_list) do
    names[#names + 1] = provider.name
  end
  return names
end

--- Provider list plus whether each one is usable right now.
---@return {name: string, label: string, home: string, synced: boolean, enabled: boolean}[]
function M.providers()
  local config = require("kaeru.config")
  local settings = ((config.options or {}).kikru or {}).lyrics or {}
  local order = settings.providers or M.default_provider_order
  local enabled_set = {}
  for _, name in ipairs(order) do
    enabled_set[name] = true
  end
  local out = {}
  for _, provider in ipairs(M.provider_list) do
    out[#out + 1] = {
      name = provider.name,
      label = provider.label,
      home = provider.home,
      synced = provider.synced,
      enabled = enabled_set[provider.name] == true,
    }
  end
  return out
end

--- The order providers are tried in.
---@param opts? table
---@return string[]
function M.provider_order(opts)
  opts = opts or {}
  if opts.providers then
    return opts.providers
  end
  if opts.provider then
    return { opts.provider }
  end
  local config = require("kaeru.config")
  local settings = ((config.options or {}).kikru or {}).lyrics or {}
  return settings.providers or M.default_provider_order
end

--- Which hit from a provider's result list best matches the track?
--- Duration wins when we know it, then the provider's own score, then title.
---@param hits table[]
---@param track MusicTagTrack
---@return table|nil
function M.pick_hit(hits, track)
  if not hits or #hits == 0 then
    return nil
  end
  local best, best_score = nil, -math.huge
  for _, hit in ipairs(hits) do
    local score = tonumber(hit.score) or 0
    local duration = tonumber(hit.duration) or 0
    if duration > 1000 then -- NetEase reports milliseconds
      duration = duration / 1000
    end
    if (track.duration or 0) > 1 and duration > 1 then
      local delta = math.abs(duration - track.duration)
      if delta < 3 then
        score = score + 10
      elseif delta < 10 then
        score = score + 4
      elseif delta > 60 then
        score = score - 4
      end
    end
    local hit_title = hit.title or hit.trackName or hit.name or ""
    if track.title and track.title ~= "" then
      local lowered_a = hit_title:lower()
      local lowered_b = track.title:lower()
      if lowered_a == lowered_b then
        score = score + 6
      elseif lowered_a:find(lowered_b, 1, true) or lowered_b:find(lowered_a, 1, true) then
        score = score + 2
      end
    end
    local hit_artist = hit.artist or hit.artistName or ""
    if track.artist and track.artist ~= "" and hit_artist ~= "" then
      if hit_artist:lower():find(track.artist:lower(), 1, true) then
        score = score + 3
      end
    end
    if hit.isrc and hit.isrc ~= "" then
      score = score + 1
    end
    if score > best_score then
      best, best_score = hit, score
    end
  end
  return best
end

---@param track MusicTagTrack
---@return string
function M.query_string(track)
  return ("%s %s"):format(track.artist ~= "" and track.artist or (track.album_artist or ""), track.title or "")
end

--- lrc.red: ISRC → match.json → search.json.
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
local function fetch_lrc_red(track, opts, cb)
  local endpoints = M.endpoints["lrc.red"]
  local _ = opts

  local function use_isrc(isrc, label)
    fetch_text((endpoints.lrc):format(isrc), function(err, body)
      if err or not body or body == "" then
        return cb(err or "lrc.red has nothing for " .. tostring(isrc), nil)
      end
      local parsed = M.parse_lrc(body, label and ("lrc.red · " .. label) or ("lrc.red · " .. isrc))
      if parsed.synced or parsed.plain ~= "" then
        return cb(nil, parsed)
      end
      cb("lrc.red returned an empty lyric", nil)
    end)
  end

  if track.isrc and track.isrc ~= "" then
    return use_isrc(track.isrc:upper(), nil)
  end

  local query = {}
  local function add(key, value)
    if value and value ~= "" then
      query[#query + 1] = key .. "=" .. Sources.url_encode(value)
    end
  end
  add("track", track.title)
  add("artist", track.artist ~= "" and track.artist or track.album_artist)
  add("album", track.album)
  if (track.duration or 0) > 1 then
    add("duration", tostring(math.floor(track.duration)))
  end

  fetch_json(endpoints.match .. "?" .. table.concat(query, "&"), function(err, data)
    local hits = type(data) == "table" and (data.hits or data.tracks) or nil
    local best = (not err) and M.pick_hit(hits, track) or nil
    if best and best.isrc then
      return use_isrc(best.isrc, best.title)
    end
    fetch_json(endpoints.search .. "?q=" .. Sources.url_encode(M.query_string(track)), function(serr, sdata)
      local shits = type(sdata) == "table" and (sdata.hits or sdata.tracks) or nil
      local sbest = M.pick_hit(shits, track)
      if sbest and sbest.isrc then
        return use_isrc(sbest.isrc, sbest.title)
      end
      cb(serr or err or "no lyrics on lrc.red", nil)
    end)
  end)
end

--- LRCLIB: /api/get then /api/search.
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
local function fetch_lrclib(track, opts, cb)
  local _ = opts
  local artist = track.artist ~= "" and track.artist or (track.album_artist or "")
  if artist == "" or track.title == "" then
    return cb("track has no artist/title to look up", nil)
  end

  local function from_record(record)
    if type(record) ~= "table" then
      return nil
    end
    if record.syncedLyrics and record.syncedLyrics ~= "" then
      return M.parse_lrc(record.syncedLyrics, "lrclib.net")
    end
    if record.plainLyrics and record.plainLyrics ~= "" then
      return { synced = nil, plain = record.plainLyrics, source = "lrclib.net", offset = 0, meta = {} }
    end
    return nil
  end

  local url = ("%s?artist_name=%s&track_name=%s"):format(M.lrclib_endpoints.get, Sources.url_encode(artist), Sources.url_encode(track.title))
  if track.album and track.album ~= "" then
    url = url .. "&album_name=" .. Sources.url_encode(track.album)
  end
  if (track.duration or 0) > 1 then
    url = url .. ("&duration=%d"):format(math.floor(track.duration))
  end

  fetch_json(url, function(err, data)
    local parsed = (not err) and from_record(data) or nil
    if parsed then
      return cb(nil, parsed)
    end
    local search_url = ("%s?q=%s"):format(M.lrclib_endpoints.search, Sources.url_encode(M.query_string(track)))
    fetch_json(search_url, function(serr, results)
      if serr or type(results) ~= "table" or #results == 0 then
        return cb(serr or err or "no lyrics found", nil)
      end
      local best = results[1]
      for _, item in ipairs(results) do
        if tonumber(item.duration or 0) > 0 and math.abs((item.duration or 0) - (track.duration or 0)) < 3 then
          best = item
          break
        end
      end
      cb(nil, from_record(best))
    end)
  end)
end

--- NetEase: search → lyric (plus `tlyric` translations).
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
local function fetch_netease(track, opts, cb)
  local _ = opts
  local query = M.query_string(track)
  if query:gsub("%s", "") == "" then
    return cb("track has no artist/title to look up", nil)
  end
  local endpoints = M.endpoints.netease
  local headers_extra = { Referer = "https://music.163.com/", ["User-Agent"] = Sources.user_agent }

  local search_url = ("%s?s=%s&type=1&limit=5&offset=0"):format(endpoints.search, Sources.url_encode(query))
  fetch_json(search_url, function(err, data)
    local songs = type(data) == "table" and data.result and data.result.songs or nil
    if err or type(songs) ~= "table" or #songs == 0 then
      return cb(err or "no NetEase match", nil)
    end
    local hits = {}
    for _, song in ipairs(songs) do
      local artist = song.artists and song.artists[1] and song.artists[1].name or (song.album and song.album.artist and song.album.artist.name) or ""
      hits[#hits + 1] = {
        isrc = nil,
        id = song.id,
        title = song.name,
        artist = artist,
        album = song.album and song.album.name or "",
        duration = (tonumber(song.duration) or 0) / 1000,
      }
    end
    local best = M.pick_hit(hits, track)
    if not best or not best.id then
      return cb("no NetEase match", nil)
    end
    local lyric_url = ("%s?id=%s&lv=-1&kv=-1&tv=-1"):format(endpoints.lyric, tostring(best.id))
    fetch_json(lyric_url, function(lerr, lyric)
      local lrc = type(lyric) == "table" and lyric.lrc and lyric.lrc.lyric or nil
      if lerr or not lrc or lrc == "" then
        return cb(lerr or "NetEase returned no lyric", nil)
      end
      local parsed = M.parse_lrc(lrc, "netease")
      parsed.meta = parsed.meta or {}
      parsed.meta["ti"] = parsed.meta["ti"] or best.title
      parsed.meta["ar"] = parsed.meta["ar"] or best.artist
      local translation = type(lyric) == "table" and lyric.tlyric and lyric.tlyric.lyric or nil
      if translation and translation ~= "" then
        parsed.translated = M.parse_translation(translation)
      end
      -- NetEase ships unsynced rows for instrumentals: keep the plain fallback.
      if not parsed.synced and parsed.plain == "" then
        return cb("NetEase returned an empty lyric", nil)
      end
      cb(nil, parsed)
    end, headers_extra)
  end, headers_extra)
end

--- SyncLRC: /lyrics?track=&artist=&format=lrc
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
local function fetch_synclrc(track, opts, cb)
  local _ = opts
  local query = { "format=lrc", "type=synced" }
  local function add(key, value)
    if value and value ~= "" then
      query[#query + 1] = key .. "=" .. Sources.url_encode(value)
    end
  end
  add("track", track.title)
  add("artist", track.artist ~= "" and track.artist or track.album_artist)
  add("album", track.album)
  if (track.duration or 0) > 1 then
    add("duration", tostring(math.floor(track.duration)))
  end
  fetch_json(M.endpoints.synclrc.lyrics .. "?" .. table.concat(query, "&"), function(err, data)
    local text = type(data) == "table" and data.lyrics or nil
    if err or type(text) ~= "string" or text == "" then
      return cb(err or "no SyncLRC match", nil)
    end
    if type(data) == "table" and data.instrumental then
      return cb("SyncLRC says this track is instrumental", nil)
    end
    local parsed = M.parse_lrc(text, "synclrc.dev")
    if parsed.synced then
      parsed.meta = parsed.meta or {}
      parsed.meta["ti"] = parsed.meta["ti"] or data.track
      parsed.meta["ar"] = parsed.meta["ar"] or data.artist
    end
    cb(nil, parsed)
  end)
end

--- lyrics.ovh: plain text only.
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
local function fetch_lyrics_ovh(track, opts, cb)
  local _ = opts
  local artist = track.artist ~= "" and track.artist or (track.album_artist or "")
  if artist == "" or track.title == "" then
    return cb("track has no artist/title to look up", nil)
  end
  local url = ("%s/%s/%s"):format(M.endpoints["lyrics.ovh"].lyrics, Sources.url_encode(artist), Sources.url_encode(track.title))
  fetch_json(url, function(err, data)
    local text = type(data) == "table" and data.lyrics or nil
    if err or type(text) ~= "string" or text == "" then
      return cb(err or "no lyrics.ovh match", nil)
    end
    text = text:gsub("^%s*Paroles de la chanson[^\n]*\n", ""):gsub("\n%s*$", "")
    cb(nil, { synced = nil, plain = text, source = "lyrics.ovh", offset = 0, meta = {}, raw = text })
  end)
end

M.fetchers = {
  ["lrc.red"] = fetch_lrc_red,
  lrclib = fetch_lrclib,
  netease = fetch_netease,
  synclrc = fetch_synclrc,
  ["lyrics.ovh"] = fetch_lyrics_ovh,
}

--- Run one provider.
---@param name string
---@param track MusicTagTrack
---@param opts table
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
function M.provider_fetch(name, track, opts, cb)
  local fetcher = M.fetchers[name]
  if not fetcher then
    return cb("unknown lyrics provider: " .. tostring(name), nil)
  end
  local missing = curl_missing()
  if missing then
    return cb(missing, nil)
  end
  local ok, err = pcall(fetcher, track, opts or {}, cb)
  if not ok then
    cb("provider " .. name .. " failed: " .. tostring(err), nil)
  end
end

--- The request each provider would make first — handy for tests and `:Kikru lyrics`.
---@param name string
---@param track MusicTagTrack
---@return string|nil url, string kind
function M.request_for(name, track)
  local endpoints = M.endpoints
  local artist = track.artist ~= "" and track.artist or (track.album_artist or "")
  if name == "lrc.red" then
    if track.isrc and track.isrc ~= "" then
      return (endpoints["lrc.red"].lrc):format(track.isrc:upper()), "lrc"
    end
    return ("%s?track=%s&artist=%s"):format(endpoints["lrc.red"].match, Sources.url_encode(track.title), Sources.url_encode(artist)), "json"
  elseif name == "lrclib" then
    return ("%s?artist_name=%s&track_name=%s"):format(endpoints.lrclib.get, Sources.url_encode(artist), Sources.url_encode(track.title)), "json"
  elseif name == "netease" then
    return ("%s?s=%s&type=1&limit=5&offset=0"):format(endpoints.netease.search, Sources.url_encode(M.query_string(track))), "json"
  elseif name == "synclrc" then
    return ("%s?track=%s&artist=%s&format=lrc"):format(endpoints.synclrc.lyrics, Sources.url_encode(track.title), Sources.url_encode(artist)), "json"
  elseif name == "lyrics.ovh" then
    return ("%s/%s/%s"):format(endpoints["lyrics.ovh"].lyrics, Sources.url_encode(artist), Sources.url_encode(track.title)), "json"
  end
  return nil, "unknown"
end

--- Ask every enabled provider (or one of them) and stop at the first synced hit.
---@param track MusicTagTrack
---@param opts? { provider?: string, providers?: string[], sync_first?: boolean }
---@param cb? fun(err: string|nil, lyrics: MusicLyrics|nil)
function M.fetch_remote(track, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, {}
  end
  opts = opts or {}
  cb = cb or function() end
  local missing = curl_missing()
  if missing then
    return cb(missing, nil)
  end

  local config = require("kaeru.config")
  local settings = ((config.options or {}).kikru or {}).lyrics or {}
  local order = M.provider_order(opts)
  local sync_first = opts.sync_first
  if sync_first == nil then
    sync_first = settings.sync_first ~= false
  end

  local plain_fallback = nil
  local errors = {}
  local index = 0

  local function step()
    index = index + 1
    local name = order[index]
    if name == nil then
      if plain_fallback then
        return cb(nil, plain_fallback)
      end
      return cb(table.concat(errors, "; "), nil)
    end
    M.provider_fetch(name, track, opts, function(err, lyrics)
      if lyrics and lyrics.synced and #lyrics.synced > 0 then
        return cb(nil, lyrics)
      end
      if lyrics and (lyrics.plain or "") ~= "" and not plain_fallback then
        plain_fallback = lyrics
        if not sync_first then
          return cb(nil, lyrics)
        end
      elseif err then
        errors[#errors + 1] = name .. ": " .. err
      end
      step()
    end)
  end

  step()
end

--- Search *without* resolving: the raw candidates from one provider.
---@param track MusicTagTrack
---@param opts? { provider?: string, query?: string }
---@param cb fun(err: string|nil, hits: table[]|nil, provider: string)
function M.search(track, opts, cb)
  opts = opts or {}
  local name = opts.provider or "lrc.red"
  local query = opts.query or M.query_string(track)
  if name == "lrc.red" then
    return fetch_json(M.endpoints["lrc.red"].search .. "?q=" .. Sources.url_encode(query), function(err, data)
      local hits = type(data) == "table" and (data.hits or {}) or {}
      cb(err, hits, name)
    end)
  end
  if name == "lrclib" then
    return fetch_json(M.endpoints.lrclib.search .. "?q=" .. Sources.url_encode(query), function(err, data)
      cb(err, type(data) == "table" and data or {}, name)
    end)
  end
  if name == "netease" then
    local url = ("%s?s=%s&type=1&limit=10&offset=0"):format(M.endpoints.netease.search, Sources.url_encode(query))
    return fetch_json(url, function(err, data)
      local songs = type(data) == "table" and data.result and data.result.songs or {}
      local hits = {}
      for _, song in ipairs(songs or {}) do
        hits[#hits + 1] = {
          id = song.id,
          title = song.name,
          artist = song.artists and song.artists[1] and song.artists[1].name or "",
          album = song.album and song.album.name or "",
          duration = (tonumber(song.duration) or 0) / 1000,
        }
      end
      cb(err, hits, name)
    end)
  end
  return cb("searching is not supported by " .. name, {}, name)
end

--- Resolve lyrics for a track: tags → sidecar → cache → providers.
---@param track MusicTagTrack
---@param opts? { remote?: boolean, provider?: string, providers?: string[], refresh?: boolean }
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
function M.resolve(track, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, {}
  end
  opts = opts or {}
  M._cache = M._cache or {}
  local key = tostring(track.path) .. "|" .. tostring(track.title) .. "|" .. tostring(opts.provider or "")
  if M._cache[key] and not opts.refresh then
    return cb(nil, M._cache[key])
  end

  local from_tags = M.from_tags(track)
  if from_tags then
    M._cache[key] = from_tags
    return cb(nil, from_tags)
  end

  local sidecar = M.sidecar_path(track)
  if sidecar then
    local parsed = M.from_file(sidecar)
    if parsed then
      M._cache[key] = parsed
      return cb(nil, parsed)
    end
  end

  local cached = M.cache_read(track)
  if cached then
    M._cache[key] = cached
    return cb(nil, cached)
  end

  if opts.remote == false then
    return cb(nil, { synced = nil, plain = "", source = "none", offset = 0, meta = {} })
  end

  M.fetch_remote(track, opts, function(err, lyrics)
    if lyrics then
      M._cache[key] = lyrics
      M._last = lyrics
      M.cache_write(track, lyrics)
      local config = require("kaeru.config")
      local settings = ((config.options or {}).kikru or {}).lyrics or {}
      if settings.save_sidecar then
        M.save(track, lyrics)
      end
    end
    cb(err, lyrics)
  end)
end

-- Rendering -------------------------------------------------------------------------

--- The synced line that should be highlighted at `position` seconds.
---@param lyrics MusicLyrics|nil
---@param position number
---@return integer index, string text
function M.current_line(lyrics, position)
  if not lyrics or not lyrics.synced or #lyrics.synced == 0 then
    return 0, ""
  end
  local index = 0
  for i, line in ipairs(lyrics.synced) do
    if line.time <= position + (lyrics.offset or 0) then
      index = i
    else
      break
    end
  end
  return index, (lyrics.synced[index] or {}).text or ""
end

--- How much of a line has been sung (word-level karaoke progress).
---@param line table|nil
---@param position number
---@return integer sung, integer total
function M.line_progress(line, position)
  if not line or not line.words or #line.words == 0 then
    return 0, 0
  end
  local sung = 0
  for _, word in ipairs(line.words) do
    if word.time <= position then
      sung = sung + 1
    end
  end
  return sung, #line.words
end

--- The pieces of a line that have already been sung, for a karaoke highlight.
---@param line table|nil
---@param position number
---@return string sung_text, string remaining_text
function M.line_split(line, position)
  if not line then
    return "", ""
  end
  if not line.words or #line.words == 0 then
    return line.text or "", ""
  end
  local sung, remaining = {}, {}
  for _, word in ipairs(line.words) do
    if word.time <= position then
      sung[#sung + 1] = word.text
    else
      remaining[#remaining + 1] = word.text
    end
  end
  return table.concat(sung, ""), table.concat(remaining, "")
end

--- The translation of the line at `index` (or the nearest timed one).
---@param lyrics MusicLyrics|nil
---@param index integer
---@return string|nil
function M.translation_at(lyrics, index)
  if not lyrics or not lyrics.translated or #lyrics.translated == 0 then
    return nil
  end
  local line = lyrics.synced and lyrics.synced[index] or nil
  if not line then
    return nil
  end
  local best, best_delta = nil, nil
  for i, translated in ipairs(lyrics.translated) do
    local delta = math.abs((translated.time or -1) - line.time)
    if translated.time == -1 then
      best = best or translated.text
    elseif best_delta == nil or delta < best_delta then
      best, best_delta = translated.text, delta
    end
  end
  if best_delta and best_delta > 1 then
    local same_index = lyrics.translated[index]
    return same_index and same_index.text or nil
  end
  return best
end

--- Render a "karaoke" window of lines around the current position.
---@param lyrics MusicLyrics|nil
---@param position number
---@param height? integer
---@param opts? { translation?: boolean }
---@return string[] lines, integer current
function M.window(lyrics, position, height, opts)
  height = height or 9
  opts = opts or {}
  if not lyrics or (not lyrics.synced and (lyrics.plain or "") == "") then
    return { "  no lyrics available (use `y` to fetch)" }, 0
  end
  if not lyrics.synced then
    local out = {}
    for _, line in ipairs(vim.split(lyrics.plain or "", "\n", { plain = true })) do
      out[#out + 1] = "  " .. line
    end
    return out, 0
  end
  local current = M.current_line(lyrics, position)
  local half = math.floor(height / 2)
  local from = math.max(1, current - half)
  local to = math.min(#lyrics.synced, from + height - 1)
  from = math.max(1, to - height + 1)
  local out = {}
  for i = from, to do
    local line = lyrics.synced[i]
    local prefix = i == current and "▶ " or "  "
    out[#out + 1] = ("%s%5s  %s"):format(prefix, Tags.format_time(line.time), line.text)
    local translation = opts.translation ~= false and M.translation_at(lyrics, i) or nil
    if translation then
      out[#out + 1] = ("        %s"):format(translation)
    end
  end
  return out, current
end

--- Everything the UI needs for a karaoke line: text, sung part, translation.
---@param lyrics MusicLyrics|nil
---@param position number
---@return table|nil
function M.karaoke_state(lyrics, position)
  if not lyrics or not lyrics.synced then
    return nil
  end
  local index = M.current_line(lyrics, position)
  local line = lyrics.synced[index]
  if not line then
    return nil
  end
  local sung, remaining = M.line_split(line, position)
  return {
    index = index,
    text = line.text,
    sung = sung,
    remaining = remaining,
    translated = M.translation_at(lyrics, index),
    source = lyrics.source,
  }
end

--- A compact description of the lyrics source (for the UI footer / `:Kikru status`).
---@param lyrics MusicLyrics|nil
---@return string
function M.describe(lyrics)
  if not lyrics then
    return "none"
  end
  local kind = lyrics.synced and (lyrics.synced[1].words and "word-synced" or "synced") or "plain"
  return ("%s (%s%s)"):format(lyrics.source or "?", kind, lyrics.translated and ", translated" or "")
end

local _ = Compat
return M
