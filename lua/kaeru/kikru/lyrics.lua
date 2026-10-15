-- kaeru.nvim · :Kikru — lyrics.
--
-- Sources, in order:
--   1. embedded tags (USLT / Vorbis `LYRICS`)
--   2. a sidecar `.lrc` / `.txt` file next to the audio file
--   3. the free LRCLIB API (https://lrclib.net/docs) for synced lyrics
--
-- `.lrc` parsing never leaves the process, so the synced view also works
-- offline and inside the plain-Lua test-suite.
local Tags = require("kaeru.kikru.tags")
local Sources = require("kaeru.kikru.sources")

local M = {}

---@class MusicLyrics
---@field synced {time: number, text: string}[]|nil
---@field plain string
---@field source string
---@field offset number

M.lrclib_endpoints = {
  get = "https://lrclib.net/api/get",
  search = "https://lrclib.net/api/search",
}

--- Parse LRC text into synced lines + a plain fallback.
---@param text string
---@return MusicLyrics
function M.parse_lrc(text)
  local synced = {}
  local plain = {}
  local offset = 0
  text = tostring(text or ""):gsub("\r\n", "\n")
  for line in text:gmatch("[^\n]+") do
    local offset_match = line:match("^%s*%[offset:([%-+%d]+)%]")
    if offset_match then
      offset = tonumber(offset_match) or 0
    end
    local stamps = {}
    for stamp in line:gmatch("%[(%d+:%d+%.?%d*)%]") do
      local minutes, seconds = stamp:match("^(%d+):(%d+%.?%d*)$")
      if minutes then
        stamps[#stamps + 1] = tonumber(minutes) * 60 + (tonumber(seconds) or 0)
      end
    end
    local content = line:gsub("%[%d+:%d+%.?%d*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #stamps > 0 then
      if content ~= "" then
        for _, time in ipairs(stamps) do
          synced[#synced + 1] = { time = time + offset / 1000, text = content }
        end
      end
    elseif content ~= "" and not content:match("^%[%w+:") then
      plain[#plain + 1] = content
    end
  end
  table.sort(synced, function(a, b)
    return a.time < b.time
  end)
  return {
    synced = #synced > 0 and synced or nil,
    plain = #plain > 0 and table.concat(plain, "\n") or "",
    source = "lrc",
    offset = offset,
  }
end

---@param track MusicTagTrack
---@return string|nil path
function M.sidecar_path(track)
  if not track or not track.path then
    return nil
  end
  if track.path:match("^%a+://") then
    return nil
  end
  local base = track.path:gsub("%.[%w]+$", "")
  for _, candidate in ipairs({ base .. ".lrc", base .. ".LRC", base .. ".lyrics", base .. ".txt" }) do
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
  local parsed = M.parse_lrc(text)
  if parsed.synced or parsed.plain ~= "" then
    parsed.source = path
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
  local parsed = M.parse_lrc(text)
  if not parsed.synced and parsed.plain == "" then
    parsed.plain = text
  end
  parsed.source = "tags"
  return parsed
end

--- Query LRCLIB for a track (async).
---@param track MusicTagTrack
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
function M.fetch_remote(track, cb)
  if not Sources.have("curl") then
    return cb("curl is required for online lyrics", nil)
  end
  local artist = track.artist ~= "" and track.artist or (track.album_artist or "")
  if artist == "" or track.title == "" then
    return cb("track has no artist/title to look up", nil)
  end
  local url = ("%s?artist_name=%s&track_name=%s"):format(
    M.lrclib_endpoints.get,
    Sources.url_encode(artist),
    Sources.url_encode(track.title)
  )
  if track.album and track.album ~= "" then
    url = url .. "&album_name=" .. Sources.url_encode(track.album)
  end
  if (track.duration or 0) > 1 then
    url = url .. ("&duration=%d"):format(math.floor(track.duration))
  end

  local headers = { "Accept: application/json", "User-Agent: " .. Sources.user_agent }
  Sources.http_json(url, { headers = headers, timeout = 15 }, function(err, data)
    if not err and type(data) == "table" and (data.syncedLyrics or data.plainLyrics) then
      if data.syncedLyrics and data.syncedLyrics ~= "" then
        local parsed = M.parse_lrc(data.syncedLyrics)
        parsed.source = "lrclib.net"
        return cb(nil, parsed)
      end
      return cb(nil, { synced = nil, plain = data.plainLyrics or "", source = "lrclib.net", offset = 0 })
    end

    -- Fall back to the search endpoint (better for remixes / casing differences)
    local search_url = ("%s?q=%s"):format(
      M.lrclib_endpoints.search,
      Sources.url_encode(("%s %s"):format(artist, track.title))
    )
    Sources.http_json(search_url, { headers = headers, timeout = 15 }, function(serr, results)
      if serr or type(results) ~= "table" or #results == 0 then
        return cb(err or serr or "no lyrics found", nil)
      end
      local best = results[1]
      for _, item in ipairs(results) do
        if tonumber(item.duration or 0) > 0 and math.abs((item.duration or 0) - (track.duration or 0)) < 3 then
          best = item
          break
        end
      end
      if best.syncedLyrics and best.syncedLyrics ~= "" then
        local parsed = M.parse_lrc(best.syncedLyrics)
        parsed.source = "lrclib.net"
        return cb(nil, parsed)
      end
      cb(nil, { synced = nil, plain = best.plainLyrics or "", source = "lrclib.net", offset = 0 })
    end)
  end)
end

--- Resolve lyrics for a track: tags -> sidecar -> LRCLIB.
---@param track MusicTagTrack
---@param opts? {remote?: boolean}
---@param cb fun(err: string|nil, lyrics: MusicLyrics|nil)
function M.resolve(track, opts, cb)
  opts = opts or {}
  M._cache = M._cache or {}
  local key = tostring(track.path) .. "|" .. tostring(track.title)
  if M._cache[key] then
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

  M._cache[key] = { synced = nil, plain = "", source = "none", offset = 0 }
  if opts.remote == false then
    return cb(nil, M._cache[key])
  end
  M.fetch_remote(track, function(err, lyrics)
    if lyrics then
      M._cache[key] = lyrics
    end
    cb(err, lyrics)
  end)
end

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

--- Render a "karaoke" window of lines around the current position.
---@param lyrics MusicLyrics|nil
---@param position number
---@param height? integer
---@return string[] lines, integer current
function M.window(lyrics, position, height)
  height = height or 9
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
  end
  return out, current
end

return M
