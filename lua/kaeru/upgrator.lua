-- Upgrator: find and update the outdated packages of every package manager in a project.
--
-- Managers are detected from the project's manifest files:
--   npm    package.json          check: npm outdated --json     apply: npm update (or install @latest)
--   pip    requirements.txt      check: pip list --outdated     apply: pip install -U <packages>
--   cargo  Cargo.toml            check: cargo outdated (optional) apply: cargo update
--   go     go.mod                check: go list -m -u all       apply: go get -u ./... && go mod tidy
--   lazy   lazy-lock.json        check: (lazy reports its own)  apply: :Lazy! update
--
-- `check` changes nothing. `apply` asks for confirmation first and writes the output to a buffer.

local Process = require("kaeru.process")
local Json = require("kaeru.json")

local M = {}

--- Parse `npm outdated --json` (object keyed by package name).
---@param text string
---@return {name:string, current:string, wanted:string, latest:string}[]
function M.parse_npm_outdated(text)
  local out = {}
  local ok, data = pcall(Json.decode, text ~= "" and text or "{}")
  if not ok or type(data) ~= "table" then
    return out
  end
  for name, info in pairs(data) do
    if type(info) == "table" and info.latest and info.current ~= info.latest then
      out[#out + 1] = { name = name, current = info.current or "?", wanted = info.wanted or "?", latest = info.latest }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- Parse `pip list --outdated --format=json`.
---@param text string
---@return {name:string, current:string, latest:string}[]
function M.parse_pip_outdated(text)
  local out = {}
  local ok, data = pcall(Json.decode, text ~= "" and text or "[]")
  if not ok or type(data) ~= "table" then
    return out
  end
  for _, item in ipairs(data) do
    if type(item) == "table" and item.name and item.latest_version then
      out[#out + 1] = { name = item.name, current = item.version or "?", latest = item.latest_version }
    end
  end
  return out
end

--- Parse `go list -m -u all`: lines like `example.com/x v1.0.0 [v1.2.0]`.
---@param text string
---@return {name:string, current:string, latest:string}[]
function M.parse_go_outdated(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local name, current, latest = line:match("^(%S+)%s+(%S+)%s+%[(%S+)%]%s*$")
    if name and name ~= "" then
      out[#out + 1] = { name = name, current = current, latest = latest }
    end
  end
  return out
end

--- Parse `cargo outdated --root-deps-only` table rows (name, project, compat, latest).
---@param text string
---@return {name:string, current:string, latest:string}[]
function M.parse_cargo_outdated(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    -- columns: name, project, compat, latest, kind
    local name, current, _, latest = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+%S+%s*$")
    if name and name ~= "name" and latest and latest ~= "---" and latest ~= current then
      out[#out + 1] = { name = name, current = current, latest = latest }
    end
  end
  return out
end

local function exists(path)
  local fd = io.open(path, "r")
  if fd then
    fd:close()
    return true
  end
  return false
end

--- Managers that apply to `dir`.
---@param dir string
---@return table[]
function M.detect(dir)
  local found = {}
  if exists(dir .. "/package.json") then
    found[#found + 1] = {
      id = "npm",
      label = "npm",
      check = { "npm", "outdated", "--json" },
      -- npm outdated exits 1 when anything is outdated: that is not an error
      check_ok = { [0] = true, [1] = true },
      parse = M.parse_npm_outdated,
      apply = { { "npm", "update" } },
      apply_latest = function(items)
        local cmds = { "npm", "install" }
        for _, item in ipairs(items) do
          cmds[#cmds + 1] = item.name .. "@latest"
        end
        return { cmds }
      end,
    }
  end
  if exists(dir .. "/requirements.txt") or exists(dir .. "/pyproject.toml") then
    found[#found + 1] = {
      id = "pip",
      label = "pip",
      check = { "python3", "-m", "pip", "list", "--outdated", "--format=json" },
      check_ok = { [0] = true },
      parse = M.parse_pip_outdated,
      apply = function(items)
        local cmds = { "python3", "-m", "pip", "install", "-U" }
        for _, item in ipairs(items) do
          cmds[#cmds + 1] = item.name
        end
        return { cmds }
      end,
    }
  end
  if exists(dir .. "/Cargo.toml") then
    found[#found + 1] = {
      id = "cargo",
      label = "cargo",
      check = { "cargo", "outdated", "--root-deps-only" },
      check_ok = { [0] = true },
      parse = M.parse_cargo_outdated,
      apply = { { "cargo", "update" } },
    }
  end
  if exists(dir .. "/go.mod") then
    found[#found + 1] = {
      id = "go",
      label = "go",
      check = { "go", "list", "-m", "-u", "all" },
      check_ok = { [0] = true },
      parse = M.parse_go_outdated,
      apply = { { "go", "get", "-u", "./..." }, { "go", "mod", "tidy" } },
    }
  end
  if exists(dir .. "/lazy-lock.json") then
    found[#found + 1] = {
      id = "lazy",
      label = "lazy.nvim",
      check = nil,
      parse = function()
        return {}
      end,
      apply = { { "Lazy!", "update" } },
      in_editor = true,
    }
  end
  return found
end

--- Run the check of every manager. `cb(report)` gets `{ {manager, items, error} }`.
---@param dir string
---@param cb fun(report: table[])
function M.check(dir, cb)
  local managers = M.detect(dir)
  local report = {}
  local index = 0
  local function step()
    index = index + 1
    local m = managers[index]
    if not m then
      return cb(report)
    end
    if not m.check then
      report[#report + 1] = { manager = m, items = {}, note = "checked by lazy.nvim (:Lazy check)" }
      return step()
    end
    Process.run(m.check, { cwd = dir }, function(res)
      local entry = { manager = m, items = {} }
      if res.code == 127 then
        entry.error = m.check[1] .. " is not installed"
      elseif not m.check_ok[res.code] then
        entry.error = (res.stderr ~= "" and res.stderr or res.stdout):gsub("%s+$", ""):sub(1, 300)
      else
        entry.items = m.parse(res.stdout)
      end
      report[#report + 1] = entry
      step()
    end)
  end
  step()
end

--- Plain-text report.
---@param report table[]
---@return string[]
function M.render(report)
  local lines = { "kaeru upgrade check" }
  if #report == 0 then
    lines[#lines + 1] = "No package manifest found (package.json, requirements.txt, Cargo.toml, go.mod, lazy-lock.json)."
  end
  local total = 0
  for _, entry in ipairs(report) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = entry.manager.label
    if entry.error then
      lines[#lines + 1] = "  error: " .. entry.error
    elseif entry.note then
      lines[#lines + 1] = "  " .. entry.note
    elseif #entry.items == 0 then
      lines[#lines + 1] = "  up to date"
    else
      for _, item in ipairs(entry.items) do
        total = total + 1
        lines[#lines + 1] = ("  %-32s %-12s -> %s"):format(item.name, item.current, item.latest)
      end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d outdated package(s). Run :Kaeru upgrade apply to update, or :Kaeru upgrade apply latest for major versions."):format(total)
  return lines
end

--- Apply the updates. `latest` also moves to the newest major version (npm only).
---@param dir string
---@param report table[]
---@param opts {latest?: boolean}
---@param cb fun(output: string[], failures: integer)
function M.apply(dir, report, opts, cb)
  local jobs = {}
  for _, entry in ipairs(report) do
    local m = entry.manager
    if m.in_editor or entry.error then
      -- lazy runs inside the editor; a manager whose check failed is not touched
    elseif #entry.items > 0 then
      local cmds
      if m.apply_latest and opts.latest then
        cmds = m.apply_latest(entry.items)
      elseif type(m.apply) == "function" then
        cmds = m.apply(entry.items)
      else
        cmds = m.apply
      end
      for _, cmd in ipairs(cmds) do
        jobs[#jobs + 1] = { label = m.label, cmd = cmd }
      end
    end
  end
  local output, failures, index = {}, 0, 0
  local function step()
    index = index + 1
    local job = jobs[index]
    if not job then
      return cb(output, failures)
    end
    output[#output + 1] = ("$ %s  (%s)"):format(table.concat(job.cmd, " "), job.label)
    Process.run(job.cmd, { cwd = dir }, function(res)
      local text = (res.stdout or "") .. (res.stderr or "")
      for line in text:gmatch("[^\n]+") do
        output[#output + 1] = "  " .. line
      end
      if res.code ~= 0 then
        failures = failures + 1
        output[#output + 1] = ("  exit %d"):format(res.code)
      end
      step()
    end)
  end
  if #jobs == 0 then
    return cb({ "Nothing to apply." }, 0)
  end
  step()
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

--- `:Kaeru upgrade [check|apply [latest]]`
---@param args string[]  arguments after `upgrade`
function M.command(args)
  local dir = vim.fn.getcwd()
  local action = args[1] or "check"
  if action == "check" then
    M.check(dir, function(report)
      show(M.render(report), "upgrade")
    end)
  elseif action == "apply" then
    local latest = args[2] == "latest"
    M.check(dir, function(report)
      local count = 0
      for _, entry in ipairs(report) do
        count = count + #entry.items
      end
      local has_lazy = false
      for _, entry in ipairs(report) do
        if entry.manager.in_editor then
          has_lazy = true
        end
      end
      if count == 0 and not has_lazy then
        return notify("Everything is up to date.")
      end
      local choice = vim.fn.confirm(
        ("Update %d package(s)%s in %s?"):format(count, latest and " to the latest major version" or "", dir),
        "&Yes\n&No",
        2
      )
      if choice ~= 1 then
        return notify("Upgrade cancelled.")
      end
      M.apply(dir, report, { latest = latest }, function(output, failures)
        show(output, "upgrade-log")
        notify(failures == 0 and "Upgrade finished." or ("Upgrade finished with %d failed step(s), see the log."):format(failures),
          failures == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
      end)
      for _, entry in ipairs(report) do
        if entry.manager.in_editor then
          pcall(vim.cmd, "Lazy! update")
        end
      end
    end)
  else
    notify("Unknown upgrade action: " .. action .. "\nUse: check, apply [latest]", vim.log.levels.ERROR)
  end
end

return M
