-- kaeru.nvim — telescope.nvim integration.
--
-- Two ways to use it:
--
--   require("telescope").load_extension("kaeru")
--   :Telescope kaeru plugins      " every plugin already installed
--   :Telescope kaeru mason        " the 600+ Mason packages
--   :Telescope kaeru cast         " paste / pick a cast target
--
-- or simply `require("kaeru.integrations").pick(items, opts, cb)`, which routes
-- every kaeru.nvim picker through Telescope when it is installed.
local M = {}

---@return table|nil telescope
local function telescope_modules()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
    return nil
  end
  return {
    pickers = pickers,
    finders = finders,
    conf = conf,
    actions = actions,
    state = state,
  }
end

--- Open a Telescope picker over `items` ({word = …, menu = …, value = …}).
---@param items table[]
---@param opts {title?: string, on_choice?: fun(item: table|nil)}
---@param on_choice? fun(item: table|nil)
function M.picker(items, opts, on_choice)
  opts = opts or {}
  local t = telescope_modules()
  local callback = on_choice or opts.on_choice or function() end
  if not t then
    -- Telescope is not really installed: fall back to vim.ui.select.
    return vim.ui.select(items, {
      prompt = opts.title,
      format_item = function(item)
        return (item.label or item.word or tostring(item)) .. (item.menu and ("  " .. item.menu) or "")
      end,
    }, callback)
  end
  t.pickers
    .new({}, {
      prompt_title = opts.title or "kaeru",
      finder = t.finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = (item.label or item.word or tostring(item)),
            ordinal = (item.word or item.label or "") .. " " .. (item.menu or ""),
          }
        end,
      }),
      sorter = t.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        t.actions.select_default:replace(function()
          local entry = t.state.get_selected_entry()
          t.actions.close(prompt_bufnr)
          callback(entry and entry.value or nil)
        end)
        return true
      end,
    })
    :find()
end

--- Picker sources shared with `:Kaeru pick` / `:Kaeru search`.
---@return table<string, {title: string, items: fun(): table[]}>
function M.sources()
  local complete = require("kaeru.complete")
  local function from_words(words)
    local items = {}
    for _, word in ipairs(words or {}) do
      if type(word) == "table" then
        items[#items + 1] = word
      else
        items[#items + 1] = { word = word }
      end
    end
    return items
  end
  return {
    plugins = {
      title = "installed plugins (specs)",
      items = function()
        return from_words(complete.collect_repos())
      end,
    },
    mason = {
      title = "Mason packages",
      items = function()
        return from_words(complete.mason_names())
      end,
    },
    sftp = {
      title = "SFTP profiles",
      items = function()
        local ok, sftp = pcall(require, "kaeru.sftp")
        local items = {}
        for name, profile in pairs(ok and sftp.profiles() or {}) do
          items[#items + 1] = { word = name, menu = (profile.host or "?") .. ":" .. tostring(profile.remotePath or "") }
        end
        return items
      end,
    },
    cache = {
      title = "plugin cache",
      items = function()
        return from_words(complete.cache_names())
      end,
    },
    radio = {
      title = "Kikru radio stations",
      items = function()
        local ok, radio = pcall(require, "kaeru.kikru.radio")
        local items = {}
        for _, station in ipairs(ok and radio.stations or {}) do
          items[#items + 1] = { word = station.id, label = station.title or station.id, menu = station.genre or "" }
        end
        return items
      end,
    },
    queue = {
      title = "Kikru queue",
      items = function()
        local ok, kikru = pcall(require, "kaeru.kikru")
        local items = {}
        for index, track in ipairs(ok and kikru.playlist.items or {}) do
          items[#items + 1] = { word = tostring(index), label = require("kaeru.kikru.tags").label(track) }
        end
        return items
      end,
    },
    cast = {
      title = "cast a link / search into Kikru",
      items = function()
        return {
          { word = "youtube", menu = "search YouTube" },
          { word = "ytmusic", menu = "search YouTube Music" },
          { word = "appcast", menu = "continue what the YouTube/YT Music app plays" },
          { word = "server", menu = "start the HTTP cast server" },
        }
      end,
    },
    karu = {
      title = "Google Cast devices (Karu)",
      items = function()
        local ok, karu = pcall(require, "kaeru.karu")
        if not ok then
          return {}
        end
        local items = {}
        for _, device in ipairs(karu.devices()) do
          items[#items + 1] = {
            word = device.name or device.address,
            menu = ("%s:%s · %s"):format(device.address or "?", device.port or "?", device.model or "Cast device"),
            action = function()
              karu.status(device.name, function(err, payload)
                vim.notify(
                  err and ("Karu: " .. err)
                    or ("%s — %s"):format(device.name, payload and payload.media and payload.media.title or "idle"),
                  err and vim.log.levels.ERROR or vim.log.levels.INFO
                )
              end)
            end,
          }
        end
        return items
      end,
    },
  }
end

--- `:Telescope kaeru <source>` entry point.
---@param source string|nil
function M.open(source)
  local sources = M.sources()
  local key = source
  if not key or key == "" then
    key = "plugins"
  end
  local entry = sources[key]
  if not entry then
    local names = {}
    for name in pairs(sources) do
      names[#names + 1] = name
    end
    table.sort(names)
    return require("kaeru.ui").notify(":Telescope kaeru {" .. table.concat(names, "|") .. "}", vim.log.levels.WARN)
  end
  M.picker(entry.items(), { title = "kaeru: " .. entry.title }, function(item)
    if not item then
      return
    end
    local complete = require("kaeru.complete")
    if key == "plugins" then
      require("kaeru").open({ repo = item.word })
    elseif key == "mason" then
      require("kaeru.mason").install({ item.word })
    elseif key == "radio" then
      require("kaeru.kikru").action("station", { id = item.word })
    elseif key == "queue" then
      require("kaeru.kikru").action("select", { index = tonumber(item.word) })
    elseif key == "cast" then
      require("kaeru.kikru").dispatch({ "cast", item.word })
    elseif key == "sftp" then
      require("kaeru.sftp").ui(item.word)
    elseif key == "cache" then
      require("kaeru.cache").restore(item.word)
    end
    local _ = complete
  end)
end

--- Telescope extension entry point (used by `require("telescope").load_extension("kaeru")`).
---@return table
function M.extension()
  return {
    kaeru = function(opts)
      M.open(opts and opts[1] or nil)
    end,
  }
end

return M
