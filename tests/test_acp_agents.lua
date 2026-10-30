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
        -- nvim_win_set_buf / nvim_buf_is_valid work) and records the
        -- adapter/command it was asked for; buf_get_chat returns the matching
        -- fake chat. The chat ui has no winnr until placed (the agent is hidden).
        _G.chats = {}
        _G.chat_calls = {}
        package.loaded["codecompanion"] = {
          chat = function(opts)
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.bo[bufnr].filetype = "codecompanion"
            local c = {
              bufnr = bufnr,
              hidden = opts.hidden or false,
              ui = { window_opts = {}, winnr = nil, open = noop, hide = noop },
            }
            _G.chats[bufnr] = c
            table.insert(_G.chat_calls, { bufnr = bufnr, params = opts.params, hidden = opts.hidden })
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

-- Create a root chat occupying a real window (the "codecompanion vsplit"), so
-- place_in_win actually swaps the buffer shown there.
local function make_root(bufnr)
  return child.lua(([[
    local bufnr = %d
    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.create_session({ bufnr = bufnr, agent_name = "build", agent_type = "agent" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "codecompanion"
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    _G.chats[bufnr] = {
      bufnr = buf,
      ui = { window_opts = {}, winnr = win, open = function() end, hide = function() end },
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

T["acp_agents"]["new chat is created hidden and swapped into the from window (no new split)"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local from_win = _G.chats[100].ui.winnr
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)

    local agent = { name = "kiro_build", type = "agent", acp = "kiro" }
    local a = m.focus_or_open(_G.chats[100], agent)

    return {
      created_hidden = _G.chat_calls[1].hidden,
      -- the ACP buffer now occupies the originating codecompanion window
      win_shows_acp = vim.api.nvim_win_get_buf(from_win) == a.bufnr,
      -- no additional window was created
      wins_after = #vim.api.nvim_tabpage_list_wins(0),
      wins_before = wins_before,
    }
  ]])
  expect.equality(result.created_hidden, true)
  expect.equality(result.win_shows_acp, true)
  expect.equality(result.wins_after, result.wins_before)
end

T["acp_agents"]["second ACP switch also lands in the one window (no stale winnr)"] = function()
  make_root(100)
  local result = child.lua([[
    local m = require("hive.agents.acp_agents")
    local win = _G.chats[100].ui.winnr
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)

    -- First switch: from the root chat to agent A.
    local a = m.focus_or_open(_G.chats[100], { name = "a", type = "agent", acp = "kiro" })
    -- Second switch: now triggered from A's chat (what the keymap passes), to B.
    local from_a = _G.chats[a.bufnr]
    local b = m.focus_or_open(from_a, { name = "b", type = "agent", acp = "kiro" })

    return {
      win_shows_b = vim.api.nvim_win_get_buf(win) == b.bufnr,
      same_win = (a.bufnr ~= b.bufnr),
      wins_after = #vim.api.nvim_tabpage_list_wins(0),
      wins_before = wins_before,
    }
  ]])
  -- the second agent's buffer occupies the same originating window
  expect.equality(result.win_shows_b, true)
  expect.equality(result.same_win, true)
  -- still exactly one chat window, no extra split from the second switch
  expect.equality(result.wins_after, result.wins_before)
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
