-- kaeru.nvim · :Kikru — pure-Lua audio metadata reader.
--
-- Reads the *headers only* (a few KiB per file, never the whole stream) of
-- MP3 (ID3v2.2/2.3/2.4 + ID3v1 + Xing/Info VBR), FLAC (STREAMINFO +
-- VORBIS_COMMENT), Ogg (Vorbis / Opus comments), M4A/AAC (MP4 atoms),
-- WAV (RIFF/fmt/data) and WavPack/AIFF/APE fallbacks, so a whole music
-- library can be indexed without external binaries — the same trick cliamp
-- uses for non-Latin metadata (https://github.com/bjarneo/cliamp).
--
-- Everything here is plain Lua 5.1 (no `bit`, no FFI) and therefore runs
-- inside Neovim, LuaJIT and the test-suite alike.
local M = {}

local uv = (vim and (vim.uv or vim.loop)) or nil

---@class MusicTagTrack
---@field path string
---@field title string
---@field artist string
---@field album string
---@field album_artist string
---@field genre string
---@field year string
---@field track string
---@field disc string
---@field duration number  seconds (0 when unknown)
---@field bitrate number   kbps (0 when unknown)
---@field samplerate number Hz (0 when unknown)
---@field channels number
---@field format string     "mp3" | "flac" | "ogg" | "opus" | "m4a" | "wav" | ...
---@field has_art boolean
---@field lyrics? string

-- Extension table -------------------------------------------------------------

---@type table<string, string>
M.extensions = {
  mp3 = "mp3",
  mp2 = "mp3",
  mp1 = "mp3",
  flac = "flac",
  ogg = "ogg",
  oga = "ogg",
  opus = "opus",
  oggs = "opus",
  m4a = "m4a",
  m4b = "m4a",
  mp4 = "m4a",
  aac = "aac",
  wav = "wav",
  wave = "wav",
  wv = "wavpack",
  aif = "aiff",
  aiff = "aiff",
  ape = "ape",
  wma = "wma",
  mka = "matroska",
  webm = "matroska",
}

-- Extensions that stream fine but cannot be tagged.
M.stream_extensions = { pls = true, m3u = true, m3u8 = true, xspf = true, asx = true, ram = true }

---@param path string
---@return string
function M.basename(path)
  return (tostring(path):gsub("\\", "/"):match("([^/]*)$")) or path
end

---@param path string
---@return string
function M.extension(path)
  local base = M.basename(path):lower()
  return base:match("%.([%w]+)$") or ""
end

--- Is `path` an audio file :Kikru can index?
---@param path string
---@return boolean
function M.is_audio(path)
  return M.extensions[M.extension(path)] ~= nil
end

--- Is `path` a playlist/stream descriptor we can expand?
---@param path string
---@return boolean
function M.is_playlist(path)
  return M.stream_extensions[M.extension(path)] == true
end

---@param path string
---@return string|nil
function M.kind(path)
  return M.extensions[M.extension(path)]
end

---@return string[]
function M.audio_extensions()
  local seen, out = {}, {}
  for ext in pairs(M.extensions) do
    if not seen[ext] then
      seen[ext] = true
      out[#out + 1] = ext
    end
  end
  table.sort(out)
  return out
end

-- Byte helpers (no `bit` library, works on Lua 5.1) ---------------------------

local byte = string.byte
local char = string.char

---@param s string
---@param i integer 1-based
---@return integer
function M.u8(s, i)
  return byte(s, i) or 0
end

---@param s string
---@param i integer
---@return integer
function M.u16be(s, i)
  local a, b = byte(s, i), byte(s, i + 1)
  if not a or not b then
    return 0
  end
  return a * 256 + b
end

---@param s string
---@param i integer
---@return integer
function M.u16le(s, i)
  local a, b = byte(s, i), byte(s, i + 1)
  if not a or not b then
    return 0
  end
  return a + b * 256
end

---@param s string
---@param i integer
---@return integer
function M.u24be(s, i)
  local a, b, c = byte(s, i), byte(s, i + 1), byte(s, i + 2)
  if not a or not b or not c then
    return 0
  end
  return a * 65536 + b * 256 + c
end

---@param s string
---@param i integer
---@return integer
function M.u32be(s, i)
  local a, b, c, d = byte(s, i), byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
  if not a or not b or not c or not d then
    return 0
  end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param s string
---@param i integer
---@return integer
function M.u32le(s, i)
  local a, b, c, d = byte(s, i), byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
  if not a or not b or not c or not d then
    return 0
  end
  return (((d * 256 + c) * 256 + b) * 256 + a) % 2 ^ 32
end

--- 64-bit little endian as a *Lua number* (enough for audio durations/offsets).
---@param s string
---@param i integer
---@return number
function M.u64le(s, i)
  local lo = M.u32le(s, i)
  local hi = M.u32le(s, i + 4)
  return hi * 4294967296 + lo
end

--- 64-bit big endian.
---@param s string
---@param i integer
---@return number
function M.u64be(s, i)
  local hi = M.u32be(s, i)
  local lo = M.u32be(s, i + 4)
  return hi * 4294967296 + lo
end

--- ID3v2 "synchsafe" integer (7 bits per byte).
---@param s string
---@param i integer
---@return integer
function M.syncsafe(s, i)
  local a, b, c, d = byte(s, i), byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
  if not a or not b or not c or not d then
    return 0
  end
  return ((a % 128) * 128 + b % 128) * 128 * 128 + ((c % 128) * 128 + d % 128)
end

--- Extract `len` bits starting at bit position `pos` (0 = LSB) of `n`.
---@param n number
---@param pos integer
---@param len integer
---@return integer
function M.bits(n, pos, len)
  local shift = 2 ^ pos
  local mask = 2 ^ len - 1
  return math.floor(n / shift) % (mask + 1)
end


-- ID3v1 numeric genre names (used for `TCON = "(17)"` style tags).
---@type string[]
M.id3_genres = {
  "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
  "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
  "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
  "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
  "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
  "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
  "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
  "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
  "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz",
  "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk",
  "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde",
  "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band",
  "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Kikru",
  "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango",
  "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
  "Drum Solo", "A capella", "Euro-House", "Dance Hall",
}

--- Look up an ID3v1 genre number.
---@param id integer|string|nil
---@return string|nil
function M.id3_genre_name(id)
  local n = tonumber(id)
  if not n then
    return nil
  end
  return M.id3_genres[n + 1]
end

-- Text decoding ---------------------------------------------------------------

--- Decode a raw byte string into UTF-8, preserving Latin-1 accents.
---@param s string
---@return string
function M.latin1_to_utf8(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local out = {}
  for i = 1, #s do
    local c = byte(s, i)
    if c < 128 then
      out[#out + 1] = char(c)
    else
      out[#out + 1] = char(194 + math.floor(c / 64), 128 + c % 64)
    end
  end
  return table.concat(out)
end

--- Encode a code point as UTF-8.
---@param cp integer
---@return string
function M.utf8_encode(cp)
  if cp < 128 then
    return char(cp)
  elseif cp < 2048 then
    return char(192 + math.floor(cp / 64), 128 + cp % 64)
  elseif cp < 65536 then
    return char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
  end
  return char(
    240 + math.floor(cp / 262144),
    128 + math.floor(cp / 4096) % 64,
    128 + math.floor(cp / 64) % 64,
    128 + cp % 64
  )
end

--- Decode UTF-16 (both endiannesses, BOM aware) or Latin-1 to UTF-8.
---@param s string
---@param big_endian? boolean
---@return string
function M.utf16_to_utf8(s, big_endian)
  local i, be = 1, big_endian and true or false
  if #s >= 2 then
    local b1, b2 = byte(s, 1), byte(s, 2)
    if b1 == 0xFE and b2 == 0xFF then
      be, i = true, 3
    elseif b1 == 0xFF and b2 == 0xFE then
      be, i = false, 3
    end
  end
  local out = {}
  while i + 1 <= #s do
    local unit = be and M.u16be(s, i) or M.u16le(s, i)
    i = i + 2
    if unit == 0 then
      break
    end
    if unit >= 0xD800 and unit <= 0xDBFF and i + 1 <= #s then
      local low = be and M.u16be(s, i) or M.u16le(s, i)
      if low >= 0xDC00 and low <= 0xDFFF then
        i = i + 2
        unit = 0x10000 + (unit - 0xD800) * 1024 + (low - 0xDC00)
      end
    end
    out[#out + 1] = M.utf8_encode(unit)
  end
  return table.concat(out)
end

--- Decode an ID3 text frame body (encoding byte + payload).
---@param body string
---@return string
function M.decode_id3_text(body)
  if body == "" then
    return ""
  end
  local enc = byte(body, 1) or 0
  local payload = body:sub(2):gsub("\0+$", "")
  local text
  if enc == 0 then
    text = M.latin1_to_utf8(payload)
  elseif enc == 1 then
    text = M.utf16_to_utf8(payload, false)
  elseif enc == 2 then
    text = M.utf16_to_utf8(payload, true)
  else
    text = payload -- UTF-8 already
  end
  text = text:gsub("[\r\n]+", " "):gsub("%s+$", ""):gsub("^%s+", "")
  return text
end

--- Trim NUL padding used by Vorbis comments.
local function trim_nul(s)
  return (s:gsub("%z+$", ""))
end

-- File access -----------------------------------------------------------------

---@param path string
---@return integer|nil size
function M.size(path)
  if uv and uv.fs_stat then
    local st = uv.fs_stat(path)
    return st and st.size or nil
  end
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local ok, size = pcall(function()
    return fd:seek("end")
  end)
  fd:close()
  return ok and size or nil
end

--- Read `len` bytes at `offset` (1-based offsets are *not* used here: offset is 0-based).
---@param path string
---@param offset integer
---@param len integer
---@return string|nil
function M.read_range(path, offset, len)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local ok, data = pcall(function()
    fd:seek("set", offset)
    return fd:read(len)
  end)
  fd:close()
  if not ok then
    return nil
  end
  return data
end

local HEAD_BYTES = 1024 * 1024 -- enough for huge ID3 tags + Vorbis comments
local TAIL_BYTES = 128 * 1024

-- ID3 ------------------------------------------------------------------------

--- Parse an ID3v2 tag at the start of `data`.
---@param data string
---@return table|nil fields, integer size  consumed bytes (0 when no tag)
function M.parse_id3v2(data)
  if #data < 10 or data:sub(1, 3) ~= "ID3" then
    return nil, 0
  end
  local major = byte(data, 4) or 3
  local flags = byte(data, 6) or 0
  local size = M.syncsafe(data, 7)
  if size <= 0 then
    return nil, 0
  end
  local body = data:sub(11, 10 + size)
  local fields = {}
  local pos = 1
  local total = #body

  local function text_frame(id, raw)
    if not fields[id] then
      local t = M.decode_id3_text(raw)
      if t ~= "" then
        fields[id] = t
      end
    end
  end

  while pos + 6 <= total do
    local id
    local frame_size
    if major == 2 then
      id = body:sub(pos, pos + 2)
      frame_size = M.u24be(body, pos + 3)
      pos = pos + 6
    else
      id = body:sub(pos, pos + 3)
      frame_size = major >= 4 and M.syncsafe(body, pos + 4) or M.u32be(body, pos + 4)
      pos = pos + 10
    end
    if not id:match("^[A-Z0-9]+$") or frame_size <= 0 then
      break
    end
    local raw = body:sub(pos, pos + frame_size - 1)
    pos = pos + frame_size

    if id:sub(1, 1) == "T" and id ~= "TXXX" then
      text_frame(id, raw)
    elseif id == "TXXX" then
      local enc = byte(raw, 1) or 3
      local rest = raw:sub(2)
      local sep_at
      if enc == 1 or enc == 2 then
        sep_at = rest:find("\0\0", 1, true)
        sep_at = sep_at and sep_at + 1 or nil
      else
        sep_at = rest:find("\0", 1, true)
      end
      if sep_at then
        local desc = M.decode_id3_text(char(enc) .. rest:sub(1, sep_at - 1))
        local value = M.decode_id3_text(char(enc) .. rest:sub(sep_at + 1))
        local key = desc:upper():gsub("[^A-Z0-9]", "_")
        if key ~= "" and value ~= "" then
          fields["TXXX:" .. key] = value
        end
      end
    elseif id == "USLT" or id == "ULT" then
      local enc = byte(raw, 1) or 3
      local payload = raw:sub(2)
      local sep_at = payload:find("\0", 1, true)
      if sep_at then
        payload = payload:sub(sep_at + 1)
        local skip = (enc == 0) and 1 or 0
        if skip == 1 then
          payload = payload:sub(2)
        end
      end
      fields.USLT = M.decode_id3_text(char(enc) .. payload)
    elseif id == "APIC" or id == "PIC" then
      fields.APIC = true
      if fields.mime == nil then
        if major == 2 then
          local enc = byte(raw, 1) or 0
          local fmt = raw:sub(2, 4)
          local offset = 5
          if enc == 0 then
            offset = offset + 1
          else
            offset = offset + 2
          end
          -- skip description
          local rest = raw:sub(offset)
          local z = rest:find("\0", 1, true)
          if z then
            fields.mime = fmt == "JPG" and "image/jpeg" or "image/png"
          end
        else
          local rest = raw:sub(2)
          local mime = rest:match("^([%w/+.-]+)")
          fields.mime = mime
        end
      end
    end
  end

  if flags % 2 == 1 then
    -- unsynchronisation: `size` still counts the stored (unsynchronised) bytes
  end
  return fields, 10 + size + ((flags / 16) % 2 == 1 and 10 or 0)
end

--- Parse a trailing ID3v1 tag ("TAG" at size-128).
---@param data string  the last >= 128 bytes of the file
---@return table|nil
function M.parse_id3v1(data)
  if #data < 128 then
    return nil
  end
  local tag = data:sub(#data - 127, #data)
  if tag:sub(1, 3) ~= "TAG" then
    return nil
  end
  local function field(a, b)
    return trim_nul(tag:sub(a, b)):gsub("%s+$", "")
  end
  local v1 = {
    title = field(4, 33),
    artist = field(34, 63),
    album = field(64, 93),
    year = field(94, 97),
    comment = field(98, 125),
  }
  if tag:byte(126) == 0 and tag:byte(127) and tag:byte(127) ~= 0 then
    v1.track = tostring(tag:byte(127))
  end
  v1.genre_id = tag:byte(128)
  return v1
end

-- MPEG audio (MP3) ------------------------------------------------------------

-- bitrate[kbps][version][layer]
local MPEG_BITRATES = {
  [1] = { -- MPEG-1
    [1] = { 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
    [2] = { 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
    [3] = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
  },
  [2] = { -- MPEG-2 / 2.5
    [1] = { 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
    [2] = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
    [3] = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
  },
}
local MPEG_RATES = { [1] = { 44100, 48000, 32000 }, [2] = { 22050, 24000, 16000 }, [2.5] = { 11025, 12000, 8000 } }
local MPEG_SAMPLES = { [1] = 1152, [2] = 576 }

--- Parse a 4-byte MPEG frame header.
---@param s string
---@param i integer
---@return table|nil header
function M.parse_mpeg_frame(s, i)
  if i + 3 > #s then
    return nil
  end
  local b1, b2, b3, b4 = byte(s, i), byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
  if not b1 or b1 ~= 0xFF or (b2 or 0) < 0xE0 then
    return nil
  end
  local version_bits = math.floor(b2 / 8) % 4 -- 0: 2.5, 2: 2, 3: 1
  local layer_bits = math.floor(b2 / 2) % 4 -- 1: III, 2: II, 3: I
  if version_bits == 1 or layer_bits == 0 then
    return nil
  end
  local version = version_bits == 3 and 1 or (version_bits == 2 and 2 or 2.5)
  local layer = 4 - layer_bits -- 1..3
  local bitrate_idx = math.floor(b3 / 16) % 16
  local rate_idx = math.floor(b3 / 4) % 4
  if bitrate_idx == 0 or bitrate_idx == 15 or rate_idx == 3 then
    return nil
  end
  local bitrate = (MPEG_BITRATES[version == 1 and 1 or 2] or {})[layer]
  bitrate = bitrate and bitrate[bitrate_idx] or 0
  local rate = (MPEG_RATES[version] or {})[rate_idx + 1] or 0
  local padding = math.floor(b4 / 2) % 2
  local samples = version == 1 and 1152 or (layer == 1 and 384 or 576)
  local channels = math.floor(b4 / 64) % 4 == 3 and 1 or 2
  -- frame length in bytes
  local length
  if layer == 1 then
    length = math.floor((12 * bitrate * 1000 / rate + padding) * 4)
  elseif layer == 3 and version ~= 1 then
    length = math.floor(72 * bitrate * 1000 / rate + padding)
  else
    length = math.floor(144 * bitrate * 1000 / rate + padding)
  end
  return {
    version = version,
    layer = layer,
    bitrate = bitrate,
    samplerate = rate,
    channels = channels,
    samples = samples,
    length = length,
    vbr = nil,
  }
end

--- Find the first MPEG frame inside `data` (tolerating junk / FreeBitrate).
---@param data string
---@param from? integer
---@return integer|nil offset, table|nil header
function M.find_mpeg_frame(data, from)
  local i = from or 1
  local limit = #data - 4
  while i <= limit do
    local h = M.parse_mpeg_frame(data, i)
    if h then
      -- verify a second frame follows at the expected distance (or we are at EOF)
      local next_pos = i + (h.length > 4 and h.length or 4)
      if next_pos > #data - 4 or M.parse_mpeg_frame(data, next_pos) then
        return i, h
      end
    end
    i = i + 1
  end
  return nil, nil
end

---@param data string
---@param header table
---@return number|nil duration
local function mpeg_vbr_duration(data, header)
  local tag_start = header.offset or 1
  local xing_at = data:find("Xing", tag_start, true) or data:find("Info", tag_start, true)
  if not xing_at or xing_at > tag_start + 200 then
    return nil
  end
  local flags = M.u32be(data, xing_at + 4)
  local pos = xing_at + 8
  local frames
  if flags % 2 == 1 then
    frames = M.u32be(data, pos)
    pos = pos + 4
  end
  if not frames or frames == 0 then
    return nil
  end
  return frames * header.samples / math.max(1, header.samplerate)
end

---@param path string
---@param head string
---@param size integer
---@param id3_size integer
---@return MusicTagTrack
local function parse_mp3(path, head, size, id3_size)
  local track = { path = path, format = "mp3" }
  local audio_start = id3_size + 1
  local offset, header = M.find_mpeg_frame(head, audio_start)
  if header then
    header.offset = offset
    track.bitrate = header.bitrate
    track.samplerate = header.samplerate
    track.channels = header.channels
    local vbr = mpeg_vbr_duration(head, header)
    local audio_bytes = math.max(0, size - id3_size)
    if vbr and vbr > 0 then
      track.duration = vbr
      if track.duration > 0 then
        track.bitrate = math.floor(audio_bytes * 8 / track.duration / 1000 + 0.5)
        track.vbr = true
      end
    elseif header.bitrate > 0 then
      track.duration = audio_bytes * 8 / (header.bitrate * 1000)
    end
  end
  return track
end

-- FLAC ------------------------------------------------------------------------

---@param path string
---@param head string
---@return MusicTagTrack
local function parse_flac(path, head)
  local track = { path = path, format = "flac" }
  if head:sub(1, 4) ~= "fLaC" then
    return track
  end
  local pos = 5
  while pos + 4 <= #head do
    local b = byte(head, pos) or 0
    local last = b >= 128
    local btype = b % 128
    local len = M.u24be(head, pos + 1)
    local body = head:sub(pos + 4, pos + 4 + len - 1)
    if btype == 0 then -- STREAMINFO
      -- layout: 16+16+24+24 = 80 bits, then 20 (rate) | 3 (channels-1) |
      -- 5 (bits/sample-1) | 36 (total samples)
      local word = M.u32be(body, 11) -- stream bits 80..111
      local sample_rate = M.bits(word, 12, 20)
      local channels = M.bits(word, 9, 3) + 1
      local bits_per_sample = M.bits(word, 4, 5) + 1
      local total_samples = M.bits(word, 0, 4) * 4294967296 + M.u32be(body, 15)
      track.samplerate = sample_rate
      track.channels = channels
      track.bits = bits_per_sample
      if sample_rate > 0 and total_samples > 0 then
        track.duration = total_samples / sample_rate
      end
    elseif btype == 4 then -- VORBIS_COMMENT
      track = M.merge_vorbis_comment(track, body)
    elseif btype == 6 then -- PICTURE
      track.has_art = true
    end
    if last then
      break
    end
    pos = pos + 4 + len
  end
  return track
end

--- Merge a FLAC/Ogg Vorbis comment block into a track table.
---@param track table
---@param body string  vendor length(4le) vendor comments_length(4le) comments
---@return table
function M.merge_vorbis_comment(track, body)
  local vendor_len = M.u32le(body, 1)
  local count_at = 5 + vendor_len
  local count = M.u32le(body, count_at)
  local pos = count_at + 4
  for _ = 1, math.min(count, 256) do
    if pos + 4 > #body then
      break
    end
    local len = M.u32le(body, pos)
    if len <= 0 or pos + 4 + len > #body + 1 then
      break
    end
    local comment = body:sub(pos + 4, pos + 4 + len - 1)
    pos = pos + 4 + len
    local key, value = comment:match("^([^=]+)=(.*)$")
    if key and value then
      local k = key:upper():gsub("[^A-Z0-9]", "_")
      local v = trim_nul(value)
      if v ~= "" then
        if k == "TITLE" then
          track.title = track.title or v
        elseif k == "ARTIST" then
          track.artist = track.artist or v
        elseif k == "ALBUM" then
          track.album = track.album or v
        elseif k == "ALBUMARTIST" or k == "ALBUM_ARTIST" or k == "ENSEMBLE" then
          track.album_artist = track.album_artist or v
        elseif k == "GENRE" then
          track.genre = track.genre or v
        elseif k == "DATE" or k == "YEAR" then
          track.year = track.year or v:sub(1, 4)
        elseif k == "TRACKNUMBER" then
          track.track = track.track or v
        elseif k == "DISCNUMBER" then
          track.disc = track.disc or v
        elseif k == "LYRICS" or k == "UNSYNCEDLYRICS" then
          track.lyrics = track.lyrics or v:gsub("[\r\n]+", "\n")
        elseif k == "METADATA_BLOCK_PICTURE" or k == "COVERART" then
          track.has_art = true
        end
      end
    end
  end
  return track
end

-- Ogg -------------------------------------------------------------------------

---@param path string
---@param head string
---@param tail string
---@param size integer
---@return MusicTagTrack
local function parse_ogg(path, head, tail, size)
  local track = { path = path, format = "ogg" }
  local opus = head:find("OpusTags", 1, true) ~= nil
  local comment_at = head:find("\3vorbis", 1, true)
  comment_at = comment_at and comment_at - 1 or nil

  if opus then
    track.format = "opus"
    local at = head:find("OpusHead", 1, true)
    if at then
      track.channels = M.u8(head, at + 9)
      track.samplerate = M.u32le(head, at + 12)
    end
    if not track.samplerate or track.samplerate == 0 then
      track.samplerate = 48000 -- Opus always decodes at 48 kHz
    end
    local tags_at = head:find("OpusTags", 1, true)
    if tags_at then
      track = M.merge_vorbis_comment(track, head:sub(tags_at + 8))
    end
  elseif comment_at then
    local info = head:find("\1vorbis", 1, true)
    if info then
      track.channels = M.u8(head, info + 10)
      track.samplerate = M.u32le(head, info + 11)
      local nominal = M.u32le(head, info + 19)
      if nominal > 0 then
        track.bitrate = math.floor(nominal / 1000 + 0.5)
      end
    end
    track = M.merge_vorbis_comment(track, head:sub(comment_at + 8))
  end

  -- Duration from the granule position of the last complete Ogg page.
  local at = tail:find("OggS", 1, true)
  local last_granule
  while at do
    last_granule = M.u64le(tail, at + 6)
    at = tail:find("OggS", at + 4, true)
  end
  if last_granule and track.samplerate and track.samplerate > 0 then
    track.duration = last_granule / track.samplerate
    if track.duration < 0 or track.duration > 360000 then
      track.duration = 0
    end
  end
  if not track.bitrate or track.bitrate == 0 then
    if track.duration and track.duration > 0 then
      track.bitrate = math.floor(size * 8 / track.duration / 1000 + 0.5)
    end
  end
  return track
end

-- MP4 / M4A -------------------------------------------------------------------

--- Recursive atom walker used for M4A metadata.
---@param data string
---@param pos integer
---@param stop integer
---@param visit fun(kind: string, body: string, size: integer)
local function walk_atoms(data, pos, stop, visit)
  while pos + 8 <= stop do
    local size = M.u32be(data, pos)
    local kind = data:sub(pos + 4, pos + 7)
    local header = 8
    if size == 1 then
      size = M.u64be(data, pos + 8)
      header = 16
    elseif size == 0 then
      size = stop - pos + 1
    end
    if size < header or pos + size - 1 > stop then
      return
    end
    visit(kind, data:sub(pos + header, pos + size - 1), size)
    pos = pos + size
  end
end

---@param path string
---@param head string
---@param tail string
---@param size integer
---@return MusicTagTrack
local function parse_mp4(path, head, tail, size)
  local track = { path = path, format = "m4a" }
  local box = head
  if #box < 8 then
    return track
  end

  local function parse_ilst(body)
    walk_atoms(body, 1, #body, function(kind, data, rawsize)
      local names = { ["\169nam"] = "title", ["\169ART"] = "artist", ["\169alb"] = "album", ["aART"] = "album_artist", ["\169gen"] = "genre", ["gnre"] = "genre_id", ["\169day"] = "year", ["\169cmt"] = "comment", ["\169lyr"] = "lyrics" }
      local key = names[kind]
      if kind == "trkn" then
        track.track = tostring(M.u16be(data, 5))
      elseif kind == "disk" then
        track.disc = tostring(M.u16be(data, 5))
      elseif kind == "covr" then
        track.has_art = true
      elseif key then
        -- data atom: size(4) 'data'(4) type(4) locale(4) payload
        local payload = data:sub(17)
        if key == "genre_id" then
          local id = M.u16be(data, 15)
          track.genre = track.genre or tostring(id)
        elseif key == "lyrics" then
          track.lyrics = M.decode_id3_text("\3" .. payload)
        else
          track[key] = track[key] or M.decode_id3_text("\3" .. payload)
        end
      end
      local _ = rawsize
    end)
  end

  walk_atoms(box, 1, #box, function(kind, body)
    if kind == "moov" then
      walk_atoms(body, 1, #body, function(inner, inner_body)
        if inner == "mvhd" then
          local version = M.u8(inner_body, 1)
          local timescale, duration
          if version == 1 then
            timescale = M.u32be(inner_body, 21)
            duration = M.u64be(inner_body, 25)
          else
            timescale = M.u32be(inner_body, 13)
            duration = M.u32be(inner_body, 17)
          end
          if timescale and timescale > 0 and duration then
            track.duration = duration / timescale
          end
        elseif inner == "trak" then
          walk_atoms(inner_body, 1, #inner_body, function(leaf, leaf_body)
            if leaf == "mdia" then
              walk_atoms(leaf_body, 1, #leaf_body, function(md, md_body)
                if md == "mdhd" then
                  local version = M.u8(md_body, 1)
                  local timescale = version == 1 and M.u32be(md_body, 21) or M.u32be(md_body, 13)
                  if timescale and timescale > 0 and (not track.samplerate or track.samplerate == 0) then
                    track.samplerate = timescale
                  end
                elseif md == "minf" then
                  walk_atoms(md_body, 1, #md_body, function(minf, minf_body)
                    if minf == "stbl" then
                      walk_atoms(minf_body, 1, #minf_body, function(stbl, stbl_body)
                        if stbl == "stsd" then
                          local entry = M.u32be(stbl_body, 13)
                          local at = 17
                          while at + 8 <= #stbl_body do
                            local kind2 = stbl_body:sub(at + 4, at + 7)
                            if kind2 == "mp4a" or kind2 == "alac" then
                              local channels = M.u16be(stbl_body, at + 24)
                              local rate = M.u32be(stbl_body, at + 32) / 65536
                              if channels > 0 then
                                track.channels = channels
                              end
                              if rate > 0 then
                                track.samplerate = math.floor(rate)
                              end
                              break
                            end
                            if entry <= 0 then
                              break
                            end
                            at = at + entry
                          end
                        end
                      end)
                    end
                  end)
                end
              end)
            end
          end)
        elseif inner == "udta" then
          walk_atoms(inner_body, 1, #inner_body, function(udta, udta_body)
            if udta == "meta" then
              walk_atoms(udta_body, 5, #udta_body, function(meta, meta_body)
                if meta == "ilst" then
                  parse_ilst(meta_body)
                end
              end)
            end
          end)
        end
      end)
    end
  end)

  if #tail > 0 and (not track.duration or track.duration == 0) then
    local moov_at = head:find("moov", 1, true)
    if not moov_at then
      -- moov at the end (non-faststart files): parse what we can from the tail
      local at = tail:find("mvhd", 1, true)
      if at then
        local timescale = M.u32be(tail, at + 16)
        local duration = M.u32be(tail, at + 20)
        if timescale > 0 then
          track.duration = duration / timescale
        end
      end
    end
  end
  if not track.bitrate and track.duration and track.duration > 0 then
    track.bitrate = math.floor(size * 8 / track.duration / 1000 + 0.5)
  end
  return track
end

-- WAV / AIFF ----------------------------------------------------------------

---@param path string
---@param head string
---@param size integer
---@return MusicTagTrack
local function parse_wav(path, head, size)
  local track = { path = path, format = "wav" }
  local pos = 13
  while pos + 8 <= #head do
    local kind = head:sub(pos, pos + 3)
    local len = M.u32le(head, pos + 4)
    local body = head:sub(pos + 8, pos + 8 + math.min(len, 64) - 1)
    if kind == "fmt " then
      track.channels = M.u16le(body, 3)
      track.samplerate = M.u32le(body, 5)
      local byterate = M.u32le(body, 9)
      track.bits = M.u16le(body, 15)
      track.byterate = byterate
    elseif kind == "data" then
      if track.byterate and track.byterate > 0 then
        track.duration = math.min(len, size) / track.byterate
      end
      break
    end
    pos = pos + 8 + len + (len % 2)
  end
  return track
end

---@param path string
---@param head string
---@return MusicTagTrack
local function parse_aiff(path, head)
  local track = { path = path, format = "aiff" }
  if head:sub(1, 4) ~= "FORM" then
    return track
  end
  local pos = 13
  while pos + 8 <= #head do
    local kind = head:sub(pos, pos + 3)
    local len = M.u32be(head, pos + 4)
    if kind == "COMM" then
      local body = head:sub(pos + 8, pos + 8 + len - 1)
      track.channels = M.u16be(body, 1)
      track.duration = (M.u32be(body, 7)) / math.max(1, M.u16be(body, 9))
      track.bits = M.u16be(body, 15)
    elseif kind == "SSND" then
      track.samplerate = track.samplerate or 0
      break
    end
    pos = pos + 8 + len + (len % 2)
  end
  return track
end

-- Filename fallback -----------------------------------------------------------

--- "01 - Artist - Title.mp3" -> { track = "01", artist = "Artist", title = "Title" }
---@param path string
---@return {title: string, artist: string, track: string}
function M.guess_from_filename(path)
  local base = M.basename(path):gsub("%.[%w]+$", "")
  local track_num, rest = base:match("^(%d+)%s*[-._]%s*(.+)$")
  rest = rest or base
  local artist, title = rest:match("^(.+)%s+[-–—]%s+(.+)$")
  if artist and title and #artist <= 48 then
    return { artist = artist, title = title, track = track_num and tostring(tonumber(track_num)) or "" }
  end
  return { artist = "", title = rest, track = track_num and tostring(tonumber(track_num)) or "" }
end

-- Public API -----------------------------------------------------------------

--- Fill defaults so consumers never deal with nils.
---@param track table
---@return MusicTagTrack
function M.normalize(track)
  track.title = track.title or ""
  track.artist = track.artist or ""
  track.album = track.album or ""
  track.album_artist = track.album_artist or ""
  track.genre = track.genre or ""
  track.year = track.year or ""
  track.track = track.track or ""
  track.disc = track.disc or ""
  track.duration = track.duration or 0
  track.bitrate = track.bitrate or 0
  track.samplerate = track.samplerate or 0
  track.channels = track.channels or 0
  track.format = track.format or (M.extension(track.path) or "")
  track.has_art = track.has_art == true
  track.bitrate = math.floor((track.bitrate or 0) + 0.5)
  track.samplerate = math.floor((track.samplerate or 0) + 0.5)
  return track
end

--- Read the metadata of one local audio file. Never throws.
---@param path string
---@param opts? {lyrics?: boolean}
---@return MusicTagTrack track
function M.read(path, opts)
  opts = opts or {}
  local track = { path = path }
  local size = M.size(path) or 0
  local head = M.read_range(path, 0, math.min(size, HEAD_BYTES)) or ""
  local tail = ""
  if size > #head then
    tail = M.read_range(path, math.max(0, size - TAIL_BYTES), math.min(size, TAIL_BYTES)) or ""
  else
    tail = head
  end
  local kind = M.kind(path) or ""

  local id3_fields, id3_size = M.parse_id3v2(head)
  if id3_fields then
    track.title = id3_fields.TIT2 or id3_fields.TT2
    track.artist = id3_fields.TPE1 or id3_fields.TP1
    track.album = id3_fields.TALB or id3_fields.TAL
    track.album_artist = id3_fields.TPE2 or id3_fields.TP2
    track.genre = id3_fields.TCON or id3_fields.TCO
    track.year = (id3_fields.TDRC or id3_fields.TYER or id3_fields.TYE or ""):sub(1, 4)
    track.track = id3_fields.TRCK or id3_fields.TRK
    track.disc = id3_fields.TPOS
    track.has_art = id3_fields.APIC == true
    track.lyrics = id3_fields.USLT
    if track.genre then
      local numeric = track.genre:match("^%((%d+))")
      if numeric then
        track.genre = M.id3_genre_name(tonumber(numeric)) or track.genre
      end
    end
  end

  local parsed
  if kind == "mp3" then
    parsed = parse_mp3(path, head, size, id3_size or 0)
  elseif kind == "flac" then
    parsed = parse_flac(path, head)
  elseif kind == "ogg" or kind == "opus" then
    parsed = parse_ogg(path, head, tail, size)
  elseif kind == "m4a" or kind == "aac" then
    parsed = parse_mp4(path, head, tail, size)
  elseif kind == "wav" then
    parsed = parse_wav(path, head, size)
  elseif kind == "aiff" then
    parsed = parse_aiff(path, head)
  elseif kind == "wavpack" then
    parsed = { format = "wavpack" }
    local at = head:find("wvpk", 1, true)
    if at then
      track.samplerate = M.u32le(head, at + 32) or 0
      local total = M.u32le(head, at + 24)
      if track.samplerate and track.samplerate > 0 then
        track.duration = total / track.samplerate
      end
    end
  else
    parsed = { format = kind ~= "" and kind or "unknown" }
  end

  for k, v in pairs(parsed or {}) do
    if v ~= nil and v ~= "" and (track[k] == nil or track[k] == "") then
      track[k] = v
    end
  end

  -- ID3v1 as a last resort (and to fill gaps on MP3s without an ID3v2 tag)
  if (#tail >= 128) and (track.title == nil or track.title == "") then
    local v1 = M.parse_id3v1(tail)
    if v1 then
      track.title = track.title or v1.title
      track.artist = track.artist or v1.artist
      track.album = track.album or v1.album
      track.year = track.year or v1.year
      track.track = track.track or v1.track
    end
  end

  if track.title == nil or track.title == "" then
    local guess = M.guess_from_filename(path)
    track.title = guess.title
    if track.artist == nil or track.artist == "" then
      track.artist = guess.artist
    end
    if track.track == nil or track.track == "" then
      track.track = guess.track
    end
  end

  track = M.normalize(track)
  if opts.lyrics == false then
    track.lyrics = nil
  end
  return track
end

--- "Artist — Title (4:03)" display label used across the UI, MPRIS and the
--- 2-Neovim / Web sync snapshots.
---@param track table
---@return string
function M.label(track)
  if not track then
    return ""
  end
  local title = track.title or M.basename(track.path or "")
  if track.artist and track.artist ~= "" then
    return ("%s — %s"):format(track.artist, title)
  end
  return title
end

---@param seconds number
---@return string mmss
function M.format_time(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor(seconds / 60) % 60
  local s = seconds % 60
  if h > 0 then
    return ("%d:%02d:%02d"):format(h, m, s)
  end
  return ("%d:%02d"):format(m, s)
end

return M
