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
        package.loaded["hive.utils.notify"] = function() end
        package.loaded["hive.agents.navigation"] =
          { setup_winbar = noop, refresh_winbar = noop }

        -- Fake codecompanion: chat() makes a real scratch buffer (so
        -- nvim_buf_is_valid passes) and records the adapter/command it was
        -- asked for; buf_get_chat returns the matching fake chat.
        _G.chats = {}
        _G.chat_calls = {}
        package.loaded["codecompanion"] = {
          chat = function(opts)
            local bufnr = vim.api.nvim_create_buf(false, true)
            local c = { bufnr = bufnr, ui = { window_opts = {}, open = noop, hide = noop } }
            _G.chats[bufnr] = c
            table.insert(_G.chat_calls, { bufnr = bufnr, params = opts.params })
            return c
          end,
          buf_get_chat = function(bufnr) return _G.chats[bufnr] end,
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
    _G.chats[bufnr] = { bufnr = bufnr, ui = { window_opts = {}, open = function() end, hide = function() end } }
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

return T
