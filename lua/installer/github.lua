-- Minimal async GitHub REST client built on curl.
--
-- Search API: https://docs.github.com/en/rest/search/search#search-repositories
-- Unauthenticated requests are limited to 10 searches/minute, authenticated to 30.
local Config = require("installer.config")

local M = {}

-- Base URL (also used by account.lua)


local API = "https://api.github.com"

---@class InstallerRepo
---@field full_name string
---@field description string
---@field stars integer
---@field url string
---@field pushed_at string
---@field topics string[]
---@field archived boolean
---@field language string|nil

---@type table<string, {items: InstallerRepo[], total: integer}>
M._cache = {}

---@param s string
---@return string
function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---@return string|nil
function M.token()
  return (require("installer.account").token())
end

---@param url string
---@param extra_headers? string[]
---@return string[]
local function curl_args(url, extra_headers)
  local extra = {}
  for _, h in ipairs(extra_headers or {}) do
    vim.list_extend(extra, { "-H", h })
  end
  return require("installer.account").curl_args(url, extra)
end

--- Run a command asynchronously and call `cb(code, stdout, stderr)` on the main loop.
---@param args string[]
---@param cb fun(code: integer, stdout: string, stderr: string)
function M.run(args, cb)
  require("installer.process").run(args, function(res)
    cb(res.code, res.stdout, res.stderr)
  end)
end

--- GET a JSON endpoint.
---@param url string
---@param cb fun(err: string|nil, data: any)
---@param headers? string[]
function M.get_json(url, cb, headers)
  M.run(curl_args(url, headers), function(code, stdout, stderr)
    if code ~= 0 then
      return cb(("curl failed (%d): %s"):format(code, vim.trim(stderr)), nil)
    end
    local ok, data = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
    if not ok then
      return cb("could not parse GitHub response", nil)
    end
    if type(data) == "table" and data.message and not data.items then
      local msg = data.message
      if msg:lower():find("rate limit") then
        msg = msg .. (M.token() and "" or " (set $GITHUB_TOKEN or `github.token` to raise the limit)")
      end
      return cb("GitHub: " .. msg, nil)
    end
    cb(nil, data)
  end)
end

---@param item table
---@return InstallerRepo
function M.to_repo(item)
  return {
    full_name = item.full_name,
    description = item.description or "",
    stars = item.stargazers_count or 0,
    url = item.html_url,
    pushed_at = item.pushed_at or "",
    topics = item.topics or {},
    archived = item.archived == true,
    language = item.language,
  }
end

---@class InstallerSearchOpts
---@field query? string   free text
---@field page? integer
---@field per_page? integer
---@field sort? "stars"|"updated"|"best-match"
---@field broad? boolean  search beyond the `neovim-plugin` topic

--- Build the `q=` string for the search API.
---@param opts InstallerSearchOpts
---@return string
function M.build_query(opts)
  local gh = Config.options.github
  local q = vim.trim(opts.query or "")
  -- if the user typed owner/repo, look it up directly by name
  if q:match("^[%w_.-]+/[%w_.-]+$") then
    return q .. " in:name"
  end
  local suffix = opts.broad and gh.broad_query or gh.topic_query
  if q == "" then
    return suffix
  end
  return q .. " " .. suffix
end

--- Search GitHub repositories.
---@param opts InstallerSearchOpts
---@param cb fun(err: string|nil, result: {items: InstallerRepo[], total: integer, page: integer}|nil)
function M.search(opts, cb)
  opts = opts or {}
  local gh = Config.options.github
  local page = opts.page or 1
  local per_page = math.min(opts.per_page or gh.per_page or 30, 100)
  local sort = opts.sort or gh.sort or "stars"

  local q = M.build_query(opts)
  local url = ("%s/search/repositories?q=%s&per_page=%d&page=%d"):format(API, M.urlencode(q), per_page, page)
  if sort ~= "best-match" then
    url = url .. "&sort=" .. sort .. "&order=desc"
  end

  local cached = M._cache[url]
  if cached then
    return vim.schedule(function()
      cb(nil, { items = cached.items, total = cached.total, page = page })
    end)
  end

  M.get_json(url, function(err, data)
    if err then
      return cb(err, nil)
    end
    local items = {}
    for _, item in ipairs(data.items or {}) do
      items[#items + 1] = M.to_repo(item)
    end
    M._cache[url] = { items = items, total = data.total_count or #items }
    cb(nil, { items = items, total = data.total_count or #items, page = page })
  end)
end

--- Fetch the README of a repository as plain markdown.
---@param full_name string
---@param cb fun(err: string|nil, text: string|nil)
function M.readme(full_name, cb)
  local url = ("%s/repos/%s/readme"):format(API, full_name)
  local args = curl_args(url)
  -- replace the JSON accept header with the raw one
  for i, a in ipairs(args) do
    if a == "Accept: application/vnd.github+json" then
      args[i] = "Accept: application/vnd.github.raw+json"
    end
  end
  M.run(args, function(code, stdout, stderr)
    if code ~= 0 then
      return cb(("curl failed (%d): %s"):format(code, vim.trim(stderr)), nil)
    end
    if stdout:match('^%s*{%s*"message"') then
      local ok, data = pcall(vim.json.decode, stdout)
      return cb("GitHub: " .. (ok and data.message or "error"), nil)
    end
    cb(nil, stdout)
  end)
end

--- Format a star count like GitHub does (27.6k).
---@param n integer
---@return string
function M.format_stars(n)
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(n)
end

return M
