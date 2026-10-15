-- Async process helpers (vim.system with a jobstart fallback for Neovim < 0.10)
-- and a small concurrent worker pool used by the SFTP module.
local M = {}

---@class InstallerProcResult
---@field code integer
---@field stdout string
---@field stderr string

--- Run a command asynchronously; `cb` is called on the main loop.
---@param args string[]
---@param opts? {cwd?: string, env?: table<string,string>, stdin?: string}
---@param cb fun(res: InstallerProcResult)
function M.run(args, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, {}
  end
  opts = opts or {}

  if vim.fn.executable(args[1]) ~= 1 then
    vim.schedule(function()
      cb({ code = 127, stdout = "", stderr = args[1] .. " is not executable" })
    end)
    return
  end

  if vim.system then
    local ok, proc = pcall(vim.system, args, {
      text = true,
      cwd = opts.cwd,
      env = opts.env,
      stdin = opts.stdin,
    }, function(res)
      vim.schedule(function()
        cb({ code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" })
      end)
    end)
    if not ok then
      vim.schedule(function()
        cb({ code = 1, stdout = "", stderr = tostring(proc) })
      end)
    end
    return
  end

  local out, err = {}, {}
  local job = vim.fn.jobstart(args, {
    cwd = opts.cwd,
    env = opts.env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      out = data
    end,
    on_stderr = function(_, data)
      err = data
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        cb({ code = code, stdout = table.concat(out, "\n"), stderr = table.concat(err, "\n") })
      end)
    end,
  })
  if job <= 0 then
    vim.schedule(function()
      cb({ code = 1, stdout = "", stderr = "failed to start " .. args[1] })
    end)
  elseif opts.stdin then
    vim.fn.chansend(job, opts.stdin)
    vim.fn.chanclose(job, "stdin")
  end
end

--- Run `tasks` with at most `concurrency` running at the same time.
--- Each task is `fun(done: fun(result))`. `on_done(results)` receives results in task order.
---@generic T
---@param tasks (fun(done: fun(result: T)))[]
---@param concurrency integer
---@param on_done fun(results: T[])
---@param on_progress? fun(finished: integer, total: integer, result: T)
function M.pool(tasks, concurrency, on_done, on_progress)
  local total = #tasks
  if total == 0 then
    return on_done({})
  end
  concurrency = math.max(1, math.min(concurrency, total))
  local results, finished, next_index = {}, 0, 1

  local function start_next()
    local i = next_index
    if i > total then
      return
    end
    next_index = next_index + 1
    tasks[i](function(result)
      results[i] = result
      finished = finished + 1
      if on_progress then
        on_progress(finished, total, result)
      end
      if finished == total then
        on_done(results)
      else
        start_next()
      end
    end)
  end

  for _ = 1, concurrency do
    start_next()
  end
end

--- Write a temporary file and return its path.
---@param content string
---@param suffix? string
---@return string
function M.tempfile(content, suffix)
  local path = vim.fn.tempname() .. (suffix or "")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
  return path
end

return M
