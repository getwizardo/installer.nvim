-- kaeru.nvim · :Kikru — playlist / queue engine.
--
-- cliamp keeps its queues in human readable files (M3U + TOML, see
-- https://cliamp.stream/docs/playlists); :Kikru supports the same formats
-- plus JSON, and keeps the queue logic (shuffle, repeat, history) in one place
-- so the Neovim UI, the daemon IPC and the Starsky web client all agree.
local Tags = require("kaeru.kikru.tags")

local M = {}

local uv = vim.uv or vim.loop

---@class MusicPlaylist
---@field name string
---@field items MusicTagTrack[]
---@field index integer         current item (1-based)
---@field shuffle boolean
---@field repeat_mode string    "off" | "one" | "all"
---@field order integer[]|nil   shuffled order (list of item indices)
---@field history integer[]     previous indices (for `prev`)
---@field created number
---@field updated number

---@param items? MusicTagTrack[]
---@param name? string
---@return MusicPlaylist
function M.new(items, name)
  return {
    name = name or "queue",
    items = items or {},
    index = #(items or {}) > 0 and 1 or 0,
    shuffle = false,
    repeat_mode = "all",
    order = nil,
    history = {},
    created = os.time(),
    updated = os.time(),
  }
end

---@param playlist MusicPlaylist
---@return integer
function M.count(playlist)
  return #playlist.items
end

---@param playlist MusicPlaylist
---@return MusicTagTrack|nil
function M.current(playlist)
  if playlist.index < 1 or playlist.index > #playlist.items then
    return nil
  end
  return playlist.items[playlist.index]
end

---@param playlist MusicPlaylist
---@param track MusicTagTrack|string
---@param position? integer  insert 1-based position (default: append)
---@return MusicTagTrack
function M.add(playlist, track, position)
  if type(track) == "string" then
    track = Tags.read(track)
  end
  position = position or (#playlist.items + 1)
  position = math.max(1, math.min(position, #playlist.items + 1))
  table.insert(playlist.items, position, track)
  if playlist.index == 0 then
    playlist.index = position
  elseif position <= playlist.index then
    playlist.index = playlist.index + 1
  end
  playlist.order = nil -- invalidate the shuffled order
  playlist.updated = os.time()
  return track
end

---@param playlist MusicPlaylist
---@param tracks (MusicTagTrack|string)[]
function M.extend(playlist, tracks)
  for _, track in ipairs(tracks or {}) do
    M.add(playlist, track)
  end
  return playlist
end

---@param playlist MusicPlaylist
---@param index integer
---@return MusicTagTrack|nil removed
function M.remove(playlist, index)
  if index < 1 or index > #playlist.items then
    return nil
  end
  local removed = table.remove(playlist.items, index)
  playlist.order = nil
  if index < playlist.index then
    playlist.index = playlist.index - 1
  elseif index == playlist.index and playlist.index > #playlist.items then
    playlist.index = math.max(0, #playlist.items)
  end
  playlist.updated = os.time()
  return removed
end

---@param playlist MusicPlaylist
---@param from integer
---@param to integer
function M.move(playlist, from, to)
  if from < 1 or from > #playlist.items or to < 1 or to > #playlist.items or from == to then
    return
  end
  local item = table.remove(playlist.items, from)
  table.insert(playlist.items, to, item)
  if playlist.index == from then
    playlist.index = to
  end
  playlist.order = nil
  playlist.updated = os.time()
end

---@param playlist MusicPlaylist
function M.clear(playlist)
  playlist.items = {}
  playlist.index = 0
  playlist.order = nil
  playlist.history = {}
  playlist.updated = os.time()
end

--- Deterministic Fisher–Yates shuffle (seeded => testable + reproducible).
---@param n integer
---@param seed? integer
---@return integer[]
function M.shuffle_order(n, seed)
  local order = {}
  for i = 1, n do
    order[i] = i
  end
  local rng = seed and math.random or math.random
  if seed then
    math.randomseed(seed)
  end
  for i = n, 2, -1 do
    local j = math.random(i)
    order[i], order[j] = order[j], order[i]
  end
  local _ = rng
  return order
end

---@param playlist MusicPlaylist
---@param shuffle? boolean
function M.set_shuffle(playlist, shuffle)
  playlist.shuffle = shuffle ~= nil and shuffle or not playlist.shuffle
  playlist.order = playlist.shuffle and M.shuffle_order(#playlist.items, os.time()) or nil
end

--- Position of `index` inside the (possibly shuffled) order.
---@param playlist MusicPlaylist
---@param index integer
---@param direction integer  -1 | 1
---@return integer|nil
local function step_index(playlist, index, direction)
  local count = #playlist.items
  if count == 0 then
    return nil
  end
  if playlist.shuffle and playlist.order then
    local at
    for i, v in ipairs(playlist.order) do
      if v == index then
        at = i
        break
      end
    end
    if not at then
      return index
    end
    local next_at = at + direction
    if next_at < 1 then
      next_at = count
    elseif next_at > count then
      next_at = 1
    end
    return playlist.order[next_at]
  end
  local next_index = index + direction
  if next_index < 1 then
    next_index = count
  elseif next_index > count then
    next_index = 1
  end
  return next_index
end

--- Advance the queue following `shuffle` / `repeat_mode`.
---@param playlist MusicPlaylist
---@param opts? {auto?: boolean}  auto = track ended on its own (repeat one loops)
---@return MusicTagTrack|nil track, integer|nil index, boolean stopped
function M.next(playlist, opts)
  opts = opts or {}
  local count = #playlist.items
  if count == 0 then
    return nil, nil, true
  end
  if opts.auto and playlist.repeat_mode == "one" then
    return M.current(playlist), playlist.index, false
  end

  local from = playlist.index > 0 and playlist.index or 0
  local next_index = step_index(playlist, from, 1)
  if not next_index then
    return nil, nil, true
  end
  if not opts.auto then
    -- manual skip: at the end the repeat mode decides whether we wrap
    if not playlist.shuffle and from == count and playlist.repeat_mode == "off" then
      return nil, from, true
    end
  elseif not playlist.shuffle and from == count and playlist.repeat_mode ~= "all" then
    return nil, from, true
  end
  if playlist.index > 0 and playlist.index ~= next_index then
    table.insert(playlist.history, playlist.index)
    if #playlist.history > 200 then
      table.remove(playlist.history, 1)
    end
  end
  playlist.index = next_index
  playlist.updated = os.time()
  return playlist.items[next_index], next_index, false
end

---@param playlist MusicPlaylist
---@return MusicTagTrack|nil track, integer|nil index
function M.prev(playlist)
  local count = #playlist.items
  if count == 0 then
    return nil, nil
  end
  local popped = table.remove(playlist.history)
  local index = popped or step_index(playlist, playlist.index > 0 and playlist.index or 1, -1)
  playlist.index = index or 1
  return playlist.items[playlist.index], playlist.index
end

---@param playlist MusicPlaylist
---@param index integer
---@param opts? {remember?: boolean}
---@return MusicTagTrack|nil
function M.set_index(playlist, index, opts)
  opts = opts or {}
  if index < 1 or index > #playlist.items then
    return nil
  end
  if opts.remember ~= false and playlist.index > 0 and playlist.index ~= index then
    table.insert(playlist.history, playlist.index)
  end
  playlist.index = index
  playlist.updated = os.time()
  return playlist.items[index]
end

---@param playlist MusicPlaylist
---@return MusicTagTrack|nil
function M.set_current_by_path(playlist, path)
  for i, item in ipairs(playlist.items) do
    if item.path == path then
      return M.set_index(playlist, i)
    end
  end
  return nil
end

--- Total duration in seconds (unknown tracks contribute 0).
---@param playlist MusicPlaylist
---@return number seconds, integer known
function M.duration(playlist)
  local total, known = 0, 0
  for _, item in ipairs(playlist.items) do
    if (item.duration or 0) > 0 then
      total = total + item.duration
      known = known + 1
    end
  end
  return total, known
end

-- Serialization -----------------------------------------------------------------

--- Serialize the queue as extended M3U (the format cliamp, mpv and vlc read).
---@param playlist MusicPlaylist
---@return string
function M.to_m3u(playlist)
  local out = { "#EXTM3U", ("#PLAYLIST:%s"):format(playlist.name or "queue") }
  for _, track in ipairs(playlist.items) do
    local title = track.title or Tags.basename(track.path or "")
    if track.artist and track.artist ~= "" then
      title = track.artist .. " - " .. title
    end
    out[#out + 1] = ("#EXTINF:%d,%s"):format(math.floor(track.duration or 0), title)
    out[#out + 1] = track.path or ""
  end
  return table.concat(out, "\n") .. "\n"
end

--- Parse an M3U / M3U8 / PLS text into track tables.
---@param text string
---@return MusicTagTrack[]
function M.parse_m3u(text)
  local tracks = {}
  local pending = nil
  local is_pls = text:lower():find("%[playlist%]") ~= nil
  if is_pls then
    local entries = {}
    for line in text:gmatch("[^\r\n]+") do
      local key, value = line:match("^%s*([%w]+)%s*=%s*(.-)%s*$")
      if key then
        local idx = key:match("^File(%d+)$")
        local title = key:match("^Title(%d+)$")
        local length = key:match("^Length(%d+)$")
        if idx then
          entries[tonumber(idx)] = entries[tonumber(idx)] or {}
          entries[tonumber(idx)].path = value
        elseif title then
          entries[tonumber(title)] = entries[tonumber(title)] or {}
          entries[tonumber(title)].title = value
        elseif length then
          entries[tonumber(length)] = entries[tonumber(length)] or {}
          entries[tonumber(length)].duration = tonumber(value) or 0
        end
      end
    end
    local keys = {}
    for k in pairs(entries) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local entry = entries[k]
      if entry.path and entry.path ~= "" then
        tracks[#tracks + 1] = {
          path = entry.path,
          url = entry.path,
          title = entry.title,
          artist = "",
          duration = entry.duration or 0,
          format = "stream",
        }
      end
    end
    return tracks
  end

  for raw_line in text:gmatch("[^\r\n]+") do
    local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      local duration, title = line:match("^#EXTINF:%s*([%d%.]+)%s*,%s*(.*)$")
      if duration then
        pending = { duration = tonumber(duration) or 0, title = title }
      elseif line:sub(1, 1) ~= "#" then
        local track = {
          path = line,
          url = line:match("^%a+://") and line or nil,
          title = pending and pending.title or Tags.basename(line),
          duration = pending and pending.duration or 0,
          format = line:match("^%a+://") and "stream" or "unknown",
        }
        if track.title then
          local artist, title2 = track.title:match("^(.-)%s+%-%s+(.*)$")
          if artist and title2 then
            track.artist = artist
            track.title = title2
          else
            track.artist = ""
          end
        end
        tracks[#tracks + 1] = Tags.normalize(track)
        pending = nil
      end
    end
  end
  return tracks
end

--- PLS and M3U/EXTM3U are the same dialect for our purposes — keep the
--- explicit entry point the playlist docs advertise.
---@param text string
---@return KikruTagTrack[]
function M.parse_pls(text)
  return M.parse_m3u(text)
end

--- Parse the small TOML playlist dialect cliamp uses (`[[track]]` sections).
---@param text string
---@return MusicTagTrack[]
function M.parse_toml(text)
  local tracks = {}
  local current = nil
  local array_key = nil
  for raw_line in text:gmatch("[^\r\n]+") do
    local line = raw_line:gsub("#.*$", "")
    local section = line:match("^%s*%[%[%s*([%w_%-]+)%s*%]%]")
    if section == "track" or section == "tracks" then
      current = {}
      tracks[#tracks + 1] = current
      array_key = nil
    else
      local key, value = line:match("^%s*([%w_%-]+)%s*=%s*(.-)%s*$")
      if key and value then
        if value:match("^%[") and not value:match("%]%s*$") then
          array_key = key
          local target = current or tracks
          target[key] = {}
          for item in value:gmatch('"([^"]*)"') do
            table.insert(target[key], item)
          end
        elseif value:match("^%[") then
          local target = current or tracks
          target[key] = {}
          for item in value:gmatch('"([^"]*)"') do
            table.insert(target[key], item)
          end
          array_key = nil
        elseif current then
          current[key] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or tonumber(value) or value
        else
          tracks[key] = value:match('^"(.*)"$') or tonumber(value) or value
        end
      end
    end
  end
  local out = {}
  for _, entry in ipairs(tracks) do
    if type(entry) == "table" and (entry.path or entry.url) then
      entry.path = entry.path or entry.url
      out[#out + 1] = Tags.normalize(entry)
    end
  end
  if #out == 0 then
    -- flat array form: tracks = ["a.mp3", "b.flac"]
    local flat = text:match("tracks%s*=%s*(%[.-%])")
    if flat then
      for item in flat:gmatch('"([^"]*)"') do
        out[#out + 1] = Tags.normalize({ path = item, title = Tags.basename(item) })
      end
    end
  end
  return out
end

---@param playlist MusicPlaylist
---@return string
function M.to_toml(playlist)
  local out = { ("name = %q"):format(playlist.name or "queue"), "" }
  for _, track in ipairs(playlist.items) do
    out[#out + 1] = "[[track]]"
    out[#out + 1] = ("path = %q"):format(track.path or "")
    if track.title and track.title ~= "" then
      out[#out + 1] = ("title = %q"):format(track.title)
    end
    if track.artist and track.artist ~= "" then
      out[#out + 1] = ("artist = %q"):format(track.artist)
    end
    if track.album and track.album ~= "" then
      out[#out + 1] = ("album = %q"):format(track.album)
    end
    if (track.duration or 0) > 0 then
      out[#out + 1] = ("duration = %d"):format(math.floor(track.duration))
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

---@param playlist MusicPlaylist
---@return table
function M.to_json(playlist)
  return {
    version = 1,
    name = playlist.name,
    shuffle = playlist.shuffle,
    repeat_mode = playlist.repeat_mode,
    index = playlist.index,
    items = playlist.items,
  }
end

---@param data table
---@return MusicPlaylist
function M.from_json(data)
  local playlist = M.new(data.items or {}, data.name)
  playlist.shuffle = data.shuffle == true
  playlist.repeat_mode = data.repeat_mode or "all"
  playlist.index = tonumber(data.index) or (playlist.items[1] and 1 or 0)
  for _, item in ipairs(playlist.items) do
    Tags.normalize(item)
  end
  return playlist
end

--- Guess the format from the extension and parse accordingly.
---@param path string
---@param text string
---@return MusicTagTrack[]
function M.parse(path, text)
  return M.parse_text(path, text)
end

---@param path string
---@param text string
---@return KikruPlaylist|nil, string|nil
function M.parse_text(path, text)
  local ext = Tags.extension(path)
  if ext == "json" then
    local decoded
    if vim.json and vim.json.decode then
      local ok, data = pcall(vim.json.decode, text)
      if ok then
        decoded = data
      end
    end
    if not decoded then
      local ok, data = pcall(require("kaeru.json").decode, text)
      if ok then
        decoded = data
      end
    end
    if type(decoded) == "table" and decoded.items then
      return M.from_json(decoded).items
    end
    return {}
  elseif ext == "toml" then
    return M.parse_toml(text)
  end
  return M.parse_m3u(text)
end

-- Storage -----------------------------------------------------------------------

---@return string
function M.default_dir()
  local Config = require("kaeru.config")
  local dir = (Config.options.music and Config.options.music.playlist_dir)
    or (vim.fn.stdpath("data") .. "/kaeru/playlists")
  return (vim.fn.expand(dir):gsub("/$", ""))
end

---@param path string
---@return boolean
function M.ensure_dir(path)
  if uv and uv.fs_stat and uv.fs_stat(path) then
    return true
  end
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  pcall(vim.fn.mkdir, path, "p")
  return (uv and uv.fs_stat and uv.fs_stat(path)) ~= nil or vim.fn.isdirectory(path) == 1
end

---@param playlist MusicPlaylist
---@param path string
---@param format? "m3u"|"m3u8"|"toml"|"json"
---@return boolean ok, string msg
function M.save(playlist, path, format)
  path = vim.fn.expand(path)
  if not path:find("%.%w+$") then
    format = format or "m3u"
    path = path .. "." .. format
  end
  format = format or Tags.extension(path)
  local text
  if format == "toml" then
    text = M.to_toml(playlist)
  elseif format == "json" then
    if vim.json and vim.json.encode then
      text = vim.json.encode(M.to_json(playlist))
    else
      text = require("kaeru.json").encode(M.to_json(playlist))
    end
  else
    text = M.to_m3u(playlist)
  end
  M.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local fd, err = io.open(path, "w")
  if not fd then
    return false, "cannot write " .. path .. ": " .. tostring(err)
  end
  fd:write(text)
  fd:close()
  playlist.name = vim.fn.fnamemodify(path, ":t:r")
  return true, path
end

---@param path string
---@param opts? {resolve?: fun(path: string): MusicTagTrack|nil}
---@return MusicPlaylist|nil playlist, string? err
function M.load(path, opts)
  opts = opts or {}
  path = vim.fn.expand(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "cannot read " .. path
  end
  local text = fd:read("*a")
  fd:close()
  local items = M.parse_text(path, text)
  local base = vim.fn.fnamemodify(path, ":h")
  for _, item in ipairs(items) do
    if item.path and not item.path:match("^%a+://") and not item.path:match("^/") then
      item.path = base .. "/" .. item.path
    end
    item.playlist = path
  end
  local playlist = M.new(items, vim.fn.fnamemodify(path, ":t:r"))
  if opts.resolve then
    for i, item in ipairs(playlist.items) do
      if (item.duration or 0) == 0 and item.path and not item.path:match("^%a+://") and vim.fn.filereadable(item.path) == 1 then
        local meta = opts.resolve(item.path)
        if meta then
          playlist.items[i] = meta
        end
      end
    end
  end
  return playlist
end

--- List the available playlist files in the default directory.
---@return string[]
function M.available()
  local dir = M.default_dir()
  local out = {}
  if uv and uv.fs_scandir then
    local handle = uv.fs_scandir(dir)
    while handle do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if kind ~= "directory" then
        local ext = name:match("%.([%w]+)$")
        if ext == "m3u" or ext == "m3u8" or ext == "toml" or ext == "json" then
          out[#out + 1] = dir .. "/" .. name
        end
      end
    end
  else
    for _, name in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
      local ext = name:match("%.([%w]+)$")
      if ext == "m3u" or ext == "m3u8" or ext == "toml" or ext == "json" then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  return out
end

-- Library scanning ---------------------------------------------------------------

---@param dir string
---@param opts? {ignore?: string[], max_files?: integer, follow_links?: boolean}
---@return string[] files
function M.scan(dir, opts)
  opts = opts or {}
  local ignore = opts.ignore or { ".git", "node_modules", ".cache", ".local/share/Trash" }
  local max_files = opts.max_files or 5000
  local files = {}

  local function ignored(name)
    for _, pattern in ipairs(ignore) do
      if name == pattern or name:match(pattern) then
        return true
      end
    end
    return false
  end

  local function walk(current, depth)
    if #files >= max_files or depth > 12 then
      return
    end
    if uv and uv.fs_scandir then
      local handle = uv.fs_scandir(current)
      local entries = {}
      while handle do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        entries[#entries + 1] = { name = name, kind = kind }
      end
      table.sort(entries, function(a, b)
        return a.name < b.name
      end)
      for _, entry in ipairs(entries) do
        if not ignored(entry.name) then
          local full = current .. "/" .. entry.name
          local kind = entry.kind
          if not kind then
            kind = vim.fn.isdirectory(full) == 1 and "directory" or "file"
          end
          if kind == "directory" then
            walk(full, depth + 1)
          elseif Tags.is_audio(full) or Tags.is_playlist(full) then
            files[#files + 1] = full
          end
        end
      end
    else
      for _, full in ipairs(vim.fn.glob(current .. "/*", false, true)) do
        if vim.fn.isdirectory(full) == 1 then
          if not ignored(vim.fn.fnamemodify(full, ":t")) then
            walk(full, depth + 1)
          end
        elseif Tags.is_audio(full) then
          files[#files + 1] = full
        end
      end
    end
  end

  walk(vim.fn.expand(dir), 0)
  return files
end

--- Scan a directory and return ready-to-play tracks (metadata included).
---@param dir string
---@param opts? {ignore?: string[], max_files?: integer}
---@return MusicTagTrack[]
function M.scan_tracks(dir, opts)
  local tracks = {}
  for _, file in ipairs(M.scan(dir, opts)) do
    if Tags.is_audio(file) then
      tracks[#tracks + 1] = Tags.read(file)
    end
  end
  return tracks
end

--- Queue one or more tracks right after the current entry — the "play next"
--- behaviour of every music player (and of a cast arriving while something is
--- already playing).
---@param playlist KikruPlaylist
---@param tracks KikruTagTrack|KikruTagTrack[]
---@return integer count
function M.insert_after_current(playlist, tracks)
  if not playlist or not tracks then
    return 0
  end
  local list
  if tracks[1] ~= nil then
    list = tracks
  else
    list = { tracks }
  end
  -- A structural edit invalidates a shuffled order (rebuild on the fly).
  local position = math.max(0, tonumber(playlist.index) or 0)
  if position == 0 then
    position = #playlist.items
  end
  for offset, track in ipairs(list) do
    table.insert(playlist.items, position + offset, track)
  end
  if playlist.shuffle then
    playlist.order = M.shuffle_order(#playlist.items, os.time())
  end
  playlist.updated = os.time()
  return #list
end

---@param playlist KikruPlaylist
---@return string
function M.summary(playlist)
  local total, known = M.duration(playlist)
  local parts = { ("%d track%s"):format(#playlist.items, #playlist.items == 1 and "" or "s") }
  if total > 0 then
    parts[#parts + 1] = ("%s%s"):format(Tags.format_time(total), known < #playlist.items and "+" or "")
  end
  parts[#parts + 1] = "shuffle " .. (playlist.shuffle and "on" or "off")
  parts[#parts + 1] = "repeat " .. (playlist.repeat_mode or "all")
  return table.concat(parts, " · ")
end

return M
