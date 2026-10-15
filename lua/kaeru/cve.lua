-- CVE lookup for the packages a project pins.
--
-- Data source: the GitHub Advisory Database (REST `/advisories`), which covers
-- npm, PyPI, crates.io, and the Go module proxy and links every advisory to its CVE.
-- Lock files are read locally: package-lock.json, requirements.txt, Cargo.lock, go.sum.
--
-- Rate limit: unauthenticated GitHub API calls get 60 requests per hour. Set
-- `$GITHUB_TOKEN` (or `github.token`) to raise it. A scan stops after
-- `max_queries` lookups and says so.

local Github = require("kaeru.github")
local Json = require("kaeru.json")

local M = {}

M.max_queries = 60
M.concurrency = 4 -- lookups in flight at once

--- GitHub advisory ecosystem for each lock file we read.
M.lockfiles = {
  { file = "package-lock.json", ecosystem = "npm", parse = "npm" },
  { file = "requirements.txt", ecosystem = "pip", parse = "requirements" },
  { file = "Cargo.lock", ecosystem = "rust", parse = "cargo" },
  { file = "go.sum", ecosystem = "go", parse = "gosum" },
}

--- Parse `package-lock.json` (v1 `dependencies` and v2/v3 `packages` layouts).
---@param text string
---@return {name:string, version:string}[] packages, string|nil err
function M.parse_npm_lock(text)
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= "table" then
    return {}, "package-lock.json is not valid JSON"
  end
  local out, seen = {}, {}
  local function add(name, version)
    if type(name) == "string" and type(version) == "string" and version ~= "" then
      local key = name .. "@" .. version
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { name = name, version = version }
      end
    end
  end
  if type(data.packages) == "table" then
    for path, entry in pairs(data.packages) do
      if path ~= "" and type(entry) == "table" then
        local name = path:match("node_modules/([^/]+/[^/]+)$") or path:match("node_modules/([^/]+)$")
        if name then
          add(name, entry.version)
        end
      end
    end
  elseif type(data.dependencies) == "table" then
    for name, entry in pairs(data.dependencies) do
      if type(entry) == "table" then
        add(name, entry.version)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name .. a.version < b.name .. b.version
  end)
  return out, nil
end

--- Parse pinned `requirements.txt` lines (`name==1.2.3`). Unpinned lines are counted, not guessed.
---@param text string
---@return {name:string, version:string}[] packages, integer unpinned
function M.parse_requirements(text)
  local out, unpinned = {}, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local clean = line:gsub("#.*$", ""):gsub("%s+", "")
    if clean ~= "" and not clean:match("^%-") then
      local name, version = clean:match("^([%w%._%-%[%]]+)===?([^;,]+)")
      if name then
        name = name:gsub("%[.*%]", "")
        out[#out + 1] = { name = name:lower(), version = version }
      else
        unpinned = unpinned + 1
      end
    end
  end
  return out, unpinned
end

--- Parse `Cargo.lock` `[[package]]` blocks.
---@param text string
---@return {name:string, version:string}[]
function M.parse_cargo_lock(text)
  local out = {}
  local name, version
  local function flush()
    if name and version then
      out[#out + 1] = { name = name, version = version }
    end
    name, version = nil, nil
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%[%[package%]%]") then
      flush()
    else
      local k, v = line:match('^(%a+)%s*=%s*"([^"]*)"')
      if k == "name" then
        name = v
      elseif k == "version" then
        version = v
      end
    end
  end
  flush()
  return out
end

--- Parse `go.sum` (skips the `/go.mod` hash lines, keeps one entry per module version).
---@param text string
---@return {name:string, version:string}[]
function M.parse_gosum(text)
  local out, seen = {}, {}
  for line in text:gmatch("[^\n]+") do
    local mod, version = line:match("^(%S+)%s+(v%S+)%s+h1:")
    if mod and not version:find("/go.mod", 1, true) then
      local key = mod .. "@" .. version
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { name = mod, version = version }
      end
    end
  end
  return out
end

--- Advisory search URL for one package version.
---@param ecosystem string  npm | pip | rust | go
---@param name string
---@param version? string
---@return string
function M.query_url(ecosystem, name, version)
  local url = "https://api.github.com/advisories?per_page=20&ecosystem=" .. Github.urlencode(ecosystem)
  if version and version ~= "" then
    url = url .. "&affects=" .. Github.urlencode(name .. "@" .. version)
  end
  return url
end

--- Turn the advisory API response into short, sortable findings.
---@param data any
---@return {id:string, cve:string|nil, severity:string, summary:string, url:string}[]
function M.findings(data)
  local out = {}
  if type(data) ~= "table" then
    return out
  end
  for _, adv in ipairs(data) do
    -- withdrawn advisories no longer apply to any version
    if type(adv) == "table" and adv.withdrawn_at == nil then
      out[#out + 1] = {
        id = adv.ghsa_id or "?",
        cve = adv.cve_id,
        severity = (adv.severity or "unknown"):lower(),
        summary = adv.summary or "",
        url = adv.html_url or "",
      }
    end
  end
  local rank = { critical = 1, high = 2, medium = 3, moderate = 3, low = 4, unknown = 5 }
  table.sort(out, function(a, b)
    return (rank[a.severity] or 9) < (rank[b.severity] or 9)
  end)
  return out
end

--- Look up one package. `cb(err, findings)`.
---@param ecosystem string
---@param name string
---@param version? string
---@param cb fun(err: string|nil, findings: table|nil)
function M.check(ecosystem, name, version, cb)
  Github.get_json(M.query_url(ecosystem, name, version), function(err, data)
    if err then
      return cb(err, nil)
    end
    cb(nil, M.findings(data))
  end)
end

--- Read the supported lock files in `dir`. Returns `{ {ecosystem, file, packages}, ... }` and notes.
---@param dir string
---@return table[] sources, string[] notes
function M.read_project(dir)
  local sources, notes = {}, {}
  for _, spec in ipairs(M.lockfiles) do
    local path = dir .. "/" .. spec.file
    local fd = io.open(path, "r")
    if fd then
      local text = fd:read("*a")
      fd:close()
      local packages, extra
      if spec.parse == "npm" then
        packages, extra = M.parse_npm_lock(text)
      elseif spec.parse == "requirements" then
        packages, extra = M.parse_requirements(text)
        if extra and extra > 0 then
          notes[#notes + 1] = ("%s: %d unpinned lines skipped (pin with ==)"):format(spec.file, extra)
        end
      elseif spec.parse == "cargo" then
        packages = M.parse_cargo_lock(text)
      else
        packages = M.parse_gosum(text)
      end
      if extra and type(extra) == "string" then
        notes[#notes + 1] = spec.file .. ": " .. extra
      end
      sources[#sources + 1] = { ecosystem = spec.ecosystem, file = spec.file, packages = packages }
    end
  end
  return sources, notes
end

--- Scan every lock file in `dir`, one query per unique package version, capped at `max_queries`.
---@param dir string
---@param cb fun(err: string|nil, report: table|nil)
function M.scan(dir, cb)
  local sources, notes = M.read_project(dir)
  if #sources == 0 then
    return cb("no supported lock file in " .. dir .. " (package-lock.json, requirements.txt, Cargo.lock, go.sum)")
  end
  local jobs, seen = {}, {}
  for _, src in ipairs(sources) do
    for _, pkg in ipairs(src.packages) do
      local key = src.ecosystem .. "|" .. pkg.name .. "|" .. pkg.version
      if not seen[key] then
        seen[key] = true
        jobs[#jobs + 1] = { ecosystem = src.ecosystem, name = pkg.name, version = pkg.version }
      end
    end
  end
  local skipped = math.max(0, #jobs - M.max_queries)
  local total = math.min(#jobs, M.max_queries)
  local report = { packages = #jobs, checked = 0, skipped = skipped, vulnerable = {}, errors = {}, notes = notes }
  if total == 0 then
    return cb(nil, report)
  end

  -- Up to `M.concurrency` lookups run at once; each result is stored by job index so the
  -- report lists packages in the same order however the replies arrive.
  local results = {}
  local started, finished, in_flight = 0, 0, 0
  local function launch()
    while in_flight < M.concurrency and started < total do
      started = started + 1
      in_flight = in_flight + 1
      local index = started
      local job = jobs[index]
      M.check(job.ecosystem, job.name, job.version, function(err, findings)
        in_flight = in_flight - 1
        results[index] = { job = job, err = err, findings = findings }
        finished = finished + 1
        if finished == total then
          for i = 1, total do
            local r = results[i]
            report.checked = report.checked + 1
            if r.err then
              report.errors[#report.errors + 1] = r.job.name .. " " .. r.job.version .. ": " .. r.err
            elseif r.findings and #r.findings > 0 then
              report.vulnerable[#report.vulnerable + 1] = {
                ecosystem = r.job.ecosystem,
                name = r.job.name,
                version = r.job.version,
                findings = r.findings,
              }
            end
          end
          return cb(nil, report)
        end
        launch()
      end)
    end
  end
  launch()
end

--- Plain-text report lines (no decoration beyond ASCII).
---@param report table
---@return string[]
function M.render(report)
  local lines = {
    "kaeru CVE report",
    ("checked %d of %d package versions"):format(report.checked, report.packages),
  }
  if report.skipped > 0 then
    lines[#lines + 1] = ("skipped %d (raise cve.max_queries, or set GITHUB_TOKEN for a higher API limit)"):format(report.skipped)
  end
  for _, note in ipairs(report.notes or {}) do
    lines[#lines + 1] = "note: " .. note
  end
  if #report.vulnerable == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "No known advisories for the checked versions."
  end
  for _, item in ipairs(report.vulnerable) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%s %s (%s)"):format(item.name, item.version, item.ecosystem)
    for _, f in ipairs(item.findings) do
      lines[#lines + 1] = ("  [%s] %s %s"):format(f.severity, f.cve or f.id, f.summary)
      if f.url ~= "" then
        lines[#lines + 1] = "      " .. f.url
      end
    end
  end
  if #(report.errors or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Lookup errors:"
    for _, e in ipairs(report.errors) do
      lines[#lines + 1] = "  " .. e
    end
  end
  return lines
end

local function show(lines, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "kaeru://" .. title)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "kaeru.nvim" })
end

--- `:Kaeru cve scan [dir]` · `:Kaeru cve check <ecosystem> <name> [version]`
---@param args string[]  arguments after `cve`
function M.command(args)
  local action = args[1] or "scan"
  if action == "scan" then
    local dir = args[2] or vim.fn.getcwd()
    notify("Checking " .. dir .. " for known CVEs…")
    M.scan(dir, function(err, report)
      if err then
        return notify(err, vim.log.levels.WARN)
      end
      show(M.render(report), "cve")
      notify(("%d vulnerable package version(s)"):format(#report.vulnerable), #report.vulnerable > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    end)
  elseif action == "check" then
    local eco, name, version = args[2], args[3], args[4]
    if not eco or not name then
      return notify("usage: :Kaeru cve check <npm|pip|rust|go> <name> [version]", vim.log.levels.ERROR)
    end
    M.check(eco, name, version, function(err, findings)
      if err then
        return notify(err, vim.log.levels.WARN)
      end
      local lines = { ("%s %s (%s)"):format(name, version or "any version", eco) }
      if #findings == 0 then
        lines[#lines + 1] = "No known advisories."
      end
      for _, f in ipairs(findings) do
        lines[#lines + 1] = ("[%s] %s %s"):format(f.severity, f.cve or f.id, f.summary)
        lines[#lines + 1] = "    " .. f.url
      end
      show(lines, "cve")
    end)
  else
    notify("Unknown cve action: " .. action .. "\nUse: scan, check", vim.log.levels.ERROR)
  end
end

return M
