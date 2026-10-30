local MiniTest = require("mini.test")

local expect = MiniTest.expect
local child = MiniTest.new_child_neovim()
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.lua([[
        vim.opt.rtp:prepend(".")

        local noop = function() end
        package.loaded["codecompanion.utils.log"] =
          { debug = noop, info = noop, warn = noop, error = noop }
        -- Configured ACP adapters, so resolve_adapter accepts "kiro" and can
        -- resolve "auto". Order-sensitive: "kiro" is the only non-opts entry.
        package.loaded["codecompanion.config"] = {
          adapters = { acp = { opts = {}, kiro = function() end } },
        }
        package.loaded["hive.utils.notify"] = function() end
        package.loaded["hive.agents.navigation"] =
          { setup_winbar = noop, refresh_winbar = noop }

        -- Fake codecompanion: chat() makes a real scratch buffer (so
        -- nvim_buf_is_valid passes) and records the adapter/command it was
        -- asked for; buf_get_chat returns the matching fake chat. Each chat's ui
        -- carries a `winnr` tag so we can assert window-slot placement.
        _G.chats = {}
        _G.chat_calls = {}
        _G.open_calls = {}
        local winseq = 1000
        package.loaded["codecompanion"] = {
          chat = function(opts)
            local bufnr = vim.api.nvim_create_buf(false, true)
            winseq = winseq + 1
            local c = {
              bufnr = bufnr,
              hidden = opts.hidden or false,
              ui = { window_opts = {}, winnr = winseq, open = noop, hide = noop },
            }
            _G.chats[bufnr] = c
            table.insert(_G.chat_calls, { bufnr = bufnr, params = opts.params, hidden = opts.hidden })
            return c
          end,
          buf_get_chat = function(bufnr) return _G.chats[bufnr] end,
        }

        -- Stub Chat.open: records the winnr the chat was placed into, and
        -- adopts it as the chat's winnr (mirrors show_in_win).
        package.loaded["codecompanion.interactions.chat"] = {
          open = function(opts)
            table.insert(_G.open_calls, { winnr = opts.winnr })
            if opts.ui and opts.winnr then opts.ui.winnr = opts.winnr end
            return opts.ui
          end,
        }

        package.loaded["hive.agents.acp_agents"] = nil
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["acp_agents"] = new_set()

-- Simulate a family root chat buffer the user triggers switches from.
local function make_root(bufnr)
  return child.lua(([[
    local bufnr = %d
    local hierarchy = require("hive.agents.hierarchy")
    -- root has a session with no parent
    hierarchy.create_session({ bufnr = bufnr, agent_name = "build", agent_type = "agent" })
    _G.chats[bufnr] = {
      bufnr = bufnr,
      ui = { window_opts = {}, winnr = 900, open = function() end, hide = function() end },
    }
    return bufnr
  ]]):format(bufnr))
end

T["acp_agents"]["focus_or_open reuses the same buffer within a family"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local from = _G.chats[100]
    local agent = { name = "kiro_build", type = "agent", acp = "kiro", acp_command = "default" }
    local a = m.focus_or_open(from, agent)
    local b = m.focus_or_open(from, agent)
    return {
      first = a.bufnr,
      second = b.bufnr,
      opens = #_G.chat_calls,
      adapter = _G.chat_calls[1].params.adapter,
      command = _G.chat_calls[1].params.command,
    }
  ]])
  expect.equality(result.first, result.second)
  expect.equality(result.opens, 1) -- created once, focused second time
  expect.equality(result.adapter, "kiro")
  expect.equality(result.command, "default")
end

T["acp_agents"]["different families get different buffers for the same agent"] = function()
  make_root(100)
  make_root(200)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local agent = { name = "kiro_build", type = "agent", acp = "kiro" }
    local a = m.focus_or_open(_G.chats[100], agent)
    local b = m.focus_or_open(_G.chats[200], agent)
    return { a = a.bufnr, b = b.bufnr, opens = #_G.chat_calls }
  ]])
  expect.equality(result.a ~= result.b, true)
  expect.equality(result.opens, 2)
end

T["acp_agents"]["forget drops the entry so a new buffer opens next time"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local agent = { name = "kiro_build", type = "agent", acp = "kiro" }
    local a = m.focus_or_open(_G.chats[100], agent)
    m.forget(a.bufnr)
    local b = m.focus_or_open(_G.chats[100], agent)
    return { a = a.bufnr, b = b.bufnr, opens = #_G.chat_calls }
  ]])
  expect.equality(result.a ~= result.b, true)
  expect.equality(result.opens, 2)
end

T["acp_agents"]["new chat is placed into the originating chat window and created hidden"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local agent = { name = "kiro_build", type = "agent", acp = "kiro" }
    m.focus_or_open(_G.chats[100], agent)
    return {
      created_hidden = _G.chat_calls[1].hidden,
      placed_winnr = _G.open_calls[1] and _G.open_calls[1].winnr,
    }
  ]])
  -- created hidden so codecompanion does not vsplit a stray window
  expect.equality(result.created_hidden, true)
  -- then placed into from_chat's window slot (900), not a new split
  expect.equality(result.placed_winnr, 900)
end

T["acp_agents"]["acp=auto resolves to the configured adapter"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local agent = { name = "build", type = "agent", acp = "auto" }
    local a = m.focus_or_open(_G.chats[100], agent)
    return {
      opened = a ~= nil,
      adapter = _G.chat_calls[1] and _G.chat_calls[1].params.adapter,
    }
  ]])
  expect.equality(result.opened, true)
  expect.equality(result.adapter, "kiro")
end

T["acp_agents"]["acp=auto returns nil when no adapter is configured"] = function()
  make_root(100)
  local result = child.lua([[
    package.loaded["codecompanion.config"] = { adapters = { acp = { opts = {} } } }
    local m = require("hive.agents.acp_agents")
    local agent = { name = "build", type = "agent", acp = "auto" }
    local a = m.focus_or_open(_G.chats[100], agent)
    return { opened = a ~= nil, opens = #_G.chat_calls }
  ]])
  expect.equality(result.opened, false)
  expect.equality(result.opens, 0) -- never reached codecompanion.chat
end

T["acp_agents"]["literal acp name unknown to config is rejected"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local agent = { name = "build", type = "agent", acp = "nonexistent" }
    local a = m.focus_or_open(_G.chats[100], agent)
    return { opened = a ~= nil, opens = #_G.chat_calls }
  ]])
  expect.equality(result.opened, false)
  expect.equality(result.opens, 0)
end

return T
