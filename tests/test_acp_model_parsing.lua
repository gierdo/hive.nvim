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
        -- Stub codecompanion.config with a known ACP adapter registry so
        -- is_acp_adapter() can distinguish ACP harnesses from HTTP adapters.
        package.loaded["codecompanion.config"] = {
          adapters = {
            acp = { claude_code = {}, gemini_cli = {} },
            http = { openai = {}, openrouter = {} },
          },
        }
        -- models.lua requires this at load time; no codecompanion checkout here.
        local noop = function() end
        package.loaded["codecompanion.utils.log"] =
          { debug = noop, info = noop, warn = noop, error = noop }
        package.loaded["hive.tools.subagent.models"] = nil
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["parse_model_string"] = new_set()

T["parse_model_string"]["detects registered ACP adapter"] = function()
  local ok = child.lua_get([[require("hive.tools.subagent.models").is_acp_adapter("claude_code")]])
  expect.equality(ok, true)
  local no = child.lua_get([[require("hive.tools.subagent.models").is_acp_adapter("openai")]])
  expect.equality(no, false)
end

T["parse_model_string"]["bare ACP adapter -> command nil"] = function()
  local r = child.lua_get([[require("hive.tools.subagent.models").parse_model_string("claude_code")]])
  expect.equality(r.adapter, "claude_code")
  expect.equality(r.acp, true)
  expect.equality(r.command, nil)
  expect.equality(r.model, nil)
end

T["parse_model_string"]["ACP adapter/command -> command preset"] = function()
  local r = child.lua_get([[require("hive.tools.subagent.models").parse_model_string("claude_code/yolo")]])
  expect.equality(r.adapter, "claude_code")
  expect.equality(r.acp, true)
  expect.equality(r.command, "yolo")
  expect.equality(r.model, nil)
end

T["parse_model_string"]["HTTP adapter/model unchanged"] = function()
  local r = child.lua_get([[require("hive.tools.subagent.models").parse_model_string("openai/gpt-4o-mini")]])
  expect.equality(r.adapter, "openai")
  expect.equality(r.model, "gpt-4o-mini")
  expect.equality(r.acp, nil)
end

T["parse_model_string"]["HTTP three-segment provider/model unchanged"] = function()
  local r = child.lua_get([[require("hive.tools.subagent.models").parse_model_string("openrouter/openai/gpt-4o")]])
  expect.equality(r.adapter, "openrouter")
  expect.equality(r.model, "openai/gpt-4o")
end

T["parse_model_string"]["empty / nil -> nil"] = function()
  local r = child.lua_get([[(function()
    local m = require("hive.tools.subagent.models")
    return { a = m.parse_model_string(""), b = m.parse_model_string(nil) }
  end)()]])
  expect.equality(r.a, nil)
  expect.equality(r.b, nil)
end

return T
