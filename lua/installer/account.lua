-- GitHub account integration.
--
-- Token sources, in order:
--   1. `github.token` from setup()
--   2. a token saved by `:Installer login` (stdpath("data")/installer/github_token, mode 0600)
--   3. $GITHUB_TOKEN / $GH_TOKEN
--   4. `gh auth token` (GitHub CLI), cached for the session
--
-- `:Installer login` supports: GitHub CLI, pasting a personal access token, or the
-- OAuth device flow (https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)
-- when `github.client_id` is configured.
local Config = require("installer.config")
local Process = require("installer.process")

local M = {}

local uv = vim.uv or vim.loop

---@class InstallerUser
---@field login string
---@field name string|nil
---@field avatar_url string
---@field html_url string

---@type InstallerUser|nil
M.user = nil
---@type string|nil cached token from `gh auth token`
M._gh_token = nil
---@type table<string, boolean> full_name -> starred
M.starred = {}

local function token_file()
  return vim.fn.stdpath("data") .. "/installer/github_token"
end

---@return string|nil
local function read_saved_token()
  local fd = io.open(token_file(), "r")
  if not fd then
    return nil
  end
  local t = vim.trim(fd:read("*a") or "")
  fd:close()
  return t ~= "" and t or nil
end

---@param token string
local function save_token(token)
  local dir = vim.fn.fnamemodify(token_file(), ":h")
  vim.fn.mkdir(dir, "p")
  local fd = assert(io.open(token_file(), "w"))
  fd:write(token .. "\n")
  fd:close()
  pcall(uv.fs_chmod, token_file(), 384) -- 0600
end

--- Resolve the token synchronously (no network).
---@return string|nil token, string source
function M.token()
  local t = Config.options.github.token
  if type(t) == "function" then
    t = t()
  end
  if type(t) == "string" and t ~= "" then
    return t, "config"
  end
  local saved = read_saved_token()
  if saved then
    return saved, "login"
  end
  if vim.env.GITHUB_TOKEN and vim.env.GITHUB_TOKEN ~= "" then
    return vim.env.GITHUB_TOKEN, "env"
  end
  if vim.env.GH_TOKEN and vim.env.GH_TOKEN ~= "" then
    return vim.env.GH_TOKEN, "env"
  end
  if M._gh_token then
    return M._gh_token, "gh"
  end
  return nil, "none"
end

--- Ask the GitHub CLI for its token (async). Caches the result.
---@param cb fun(token: string|nil)
function M.gh_token(cb)
  if M._gh_token then
    return cb(M._gh_token)
  end
  if vim.fn.executable("gh") ~= 1 then
    return cb(nil)
  end
  Process.run({ "gh", "auth", "token" }, function(res)
    local t = vim.trim(res.stdout or "")
    if res.code == 0 and t ~= "" then
      M._gh_token = t
      cb(t)
    else
      cb(nil)
    end
  end)
end

--- Make sure a token is available, trying `gh` as a last resort.
---@param cb fun(token: string|nil, source: string)
function M.ensure_token(cb)
  local t, source = M.token()
  if t then
    return cb(t, source)
  end
  M.gh_token(function(gh)
    cb(gh, gh and "gh" or "none")
  end)
end

--- Fetch /user and cache it.
---@param cb fun(err: string|nil, user: InstallerUser|nil)
function M.fetch_user(cb)
  M.ensure_token(function(token)
    if not token then
      return cb(nil, nil)
    end
    require("installer.github").get_json("https://api.github.com/user", function(err, data)
      if err then
        return cb(err, nil)
      end
      M.user = { login = data.login, name = data.name, avatar_url = data.avatar_url, html_url = data.html_url }
      cb(nil, M.user)
    end)
  end)
end

---@return boolean
function M.logged_in()
  return M.user ~= nil
end

-- Login flows -----------------------------------------------------------------

---@param token string
---@param cb? fun(ok: boolean, err?: string)
function M.login_with_token(token, cb)
  token = vim.trim(token)
  if token == "" then
    return cb and cb(false, "empty token")
  end
  save_token(token)
  M.fetch_user(function(err, user)
    if err or not user then
      os.remove(token_file())
      return cb and cb(false, err or "token rejected")
    end
    cb(true)
  end)
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- OAuth device flow. Requires `github.client_id` (your own OAuth app).
---@param cb fun(ok: boolean, err?: string)
function M.login_device_flow(cb)
  local client_id = Config.options.github.client_id
  if not client_id or client_id == "" then
    return cb(false, "set `github.client_id` (an OAuth app client id) to use the device flow")
  end
  local scope = Config.options.github.scope or "public_repo read:user"
  local function post(url, body, done)
    Process.run({
      "curl",
      "-sS",
      "-X",
      "POST",
      "-H",
      "Accept: application/json",
      "-H",
      "User-Agent: installer.nvim",
      "-d",
      body,
      url,
    }, function(res)
      if res.code ~= 0 then
        return done("curl failed: " .. vim.trim(res.stderr))
      end
      local ok, data = pcall(vim.json.decode, res.stdout)
      if not ok then
        return done("bad response from GitHub")
      end
      done(nil, data)
    end)
  end

  post(
    "https://github.com/login/device/code",
    ("client_id=%s&scope=%s"):format(urlencode(client_id), urlencode(scope)),
    function(err, data)
      if err or not data or not data.device_code then
        return cb(false, err or ("device flow error: " .. vim.inspect(data)))
      end
      local msg = ("Open %s and enter the code: %s"):format(data.verification_uri, data.user_code)
      vim.notify(msg, vim.log.levels.INFO, { title = "installer.nvim · GitHub login", timeout = false })
      vim.fn.setreg("+", data.user_code)
      if vim.ui.open then
        pcall(vim.ui.open, data.verification_uri)
      end

      local interval = (tonumber(data.interval) or 5) * 1000
      local deadline = uv.now() + (tonumber(data.expires_in) or 900) * 1000
      local timer = assert(uv.new_timer())
      local finished, polling = false, false

      local function stop(ok, err)
        if finished then
          return
        end
        finished = true
        timer:stop()
        timer:close()
        if ok then
          M.login_with_token(ok, cb)
        else
          cb(false, err)
        end
      end

      local function poll()
        if finished or polling then
          return
        end
        if uv.now() > deadline then
          return stop(nil, "device code expired")
        end
        polling = true
        post(
          "https://github.com/login/oauth/access_token",
          ("client_id=%s&device_code=%s&grant_type=%s"):format(
            urlencode(client_id),
            urlencode(data.device_code),
            urlencode("urn:ietf:params:oauth:grant-type:device_code")
          ),
          function(perr, pdata)
            polling = false
            if perr then
              return stop(nil, perr)
            end
            if pdata.access_token then
              stop(pdata.access_token)
            elseif pdata.error == "slow_down" then
              interval = interval + 5000
              timer:set_repeat(interval)
            elseif pdata.error and pdata.error ~= "authorization_pending" then
              stop(nil, pdata.error_description or pdata.error)
            end
          end
        )
      end

      timer:start(interval, interval, function()
        vim.schedule(poll)
      end)
    end
  )
end

--- Interactive login (`:Installer login`).
---@param method? "gh"|"token"|"device"
function M.login(method)
  local UI = require("installer.ui")
  local function finish(ok, err)
    if ok then
      UI.notify(("Signed in to GitHub as %s"):format(M.user and M.user.login or "?"))
    else
      UI.notify("GitHub login failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  local function run(choice)
    if choice == "gh" then
      M._gh_token = nil
      M.gh_token(function(t)
        if not t then
          return finish(false, "GitHub CLI not installed or not logged in (`gh auth login`)")
        end
        M.fetch_user(function(err, user)
          finish(user ~= nil, err or "token rejected")
        end)
      end)
    elseif choice == "token" then
      vim.ui.input({ prompt = "GitHub personal access token: " }, function(token)
        if token and token ~= "" then
          M.login_with_token(token, finish)
        end
      end)
    elseif choice == "device" then
      M.login_device_flow(finish)
    end
  end

  if method then
    return run(method)
  end
  local choices = {
    { id = "gh", label = "Use GitHub CLI (gh auth token)" },
    { id = "token", label = "Paste a personal access token" },
    { id = "device", label = "Browser sign-in (OAuth device flow)" },
  }
  vim.ui.select(choices, {
    prompt = "Sign in to GitHub",
    format_item = function(c)
      return c.label
    end,
  }, function(c)
    if c then
      run(c.id)
    end
  end)
end

function M.logout()
  os.remove(token_file())
  M.user = nil
  M._gh_token = nil
  M.starred = {}
  require("installer.ui").notify("Signed out of GitHub (env tokens and the GitHub CLI are not touched)")
end

--- `:Installer whoami`
function M.whoami()
  local UI = require("installer.ui")
  M.fetch_user(function(err, user)
    if err then
      return UI.notify(err, vim.log.levels.ERROR)
    end
    if not user then
      return UI.notify("Not signed in. Run :Installer login", vim.log.levels.WARN)
    end
    local _, source = M.token()
    require("installer.github").get_json("https://api.github.com/rate_limit", function(rerr, data)
      local rl = ""
      if not rerr and data and data.resources then
        local s = data.resources.search
        rl = ("\nsearch rate limit: %d/%d remaining"):format(s.remaining, s.limit)
      end
      UI.notify(("Signed in as %s%s (token source: %s)%s"):format(
        user.login,
        user.name and (" · " .. user.name) or "",
        source,
        rl
      ))
    end)
  end)
end

-- Stars -----------------------------------------------------------------------

---@param full_name string
---@param cb fun(err: string|nil, starred: boolean|nil)
function M.is_starred(full_name, cb)
  if M.starred[full_name] ~= nil then
    return cb(nil, M.starred[full_name])
  end
  local args = M.curl_args("https://api.github.com/user/starred/" .. full_name, { "-o", "/dev/null", "-w", "%{http_code}" })
  Process.run(args, function(res)
    local code = vim.trim(res.stdout)
    if code == "204" then
      M.starred[full_name] = true
      cb(nil, true)
    elseif code == "404" then
      M.starred[full_name] = false
      cb(nil, false)
    else
      cb("GitHub returned HTTP " .. code, nil)
    end
  end)
end

---@param full_name string
---@param star boolean
---@param cb fun(err: string|nil)
function M.set_star(full_name, star, cb)
  local args = M.curl_args(
    "https://api.github.com/user/starred/" .. full_name,
    { "-X", star and "PUT" or "DELETE", "-H", "Content-Length: 0", "-o", "/dev/null", "-w", "%{http_code}" }
  )
  Process.run(args, function(res)
    local code = vim.trim(res.stdout)
    if code == "204" then
      M.starred[full_name] = star
      cb(nil)
    elseif code == "401" or code == "403" then
      cb("not allowed: sign in with a token that has the `public_repo` scope (or Starring permission)")
    else
      cb("GitHub returned HTTP " .. code)
    end
  end)
end

--- List the signed-in user's starred repositories.
---@param page integer
---@param cb fun(err: string|nil, items: InstallerRepo[]|nil)
function M.list_starred(page, cb)
  local GitHub = require("installer.github")
  local url = ("https://api.github.com/user/starred?per_page=%d&page=%d&sort=created"):format(
    math.min(Config.options.github.per_page, 100),
    page
  )
  GitHub.get_json(url, function(err, data)
    if err then
      return cb(err, nil)
    end
    local items = {}
    for _, item in ipairs(data or {}) do
      items[#items + 1] = GitHub.to_repo(item)
      M.starred[item.full_name] = true
    end
    cb(nil, items)
  end)
end

--- curl args with auth headers (shared with github.lua).
---@param url string
---@param extra? string[]
---@return string[]
function M.curl_args(url, extra)
  local args = {
    "curl",
    "-sS",
    "-L",
    "--max-time",
    "20",
    "-H",
    "Accept: application/vnd.github+json",
    "-H",
    "X-GitHub-Api-Version: 2022-11-28",
    "-H",
    "User-Agent: installer.nvim",
  }
  local token = M.token()
  if token then
    vim.list_extend(args, { "-H", "Authorization: Bearer " .. token })
  end
  vim.list_extend(args, extra or {})
  args[#args + 1] = url
  return args
end

return M
