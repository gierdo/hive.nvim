-- Runnable self-check for hive.tools.handoff resolve_target branch logic.
-- No framework: plain asserts. Run: lua spec/handoff_resolve_check.lua
-- (from the repo root). Exits nonzero on failure.
--
-- resolve_target is pure (deps injected), but handoff.lua requires a few
-- neovim/codecompanion modules at load time. Stub them via package.preload so
-- the module loads under plain lua.

package.preload["hive.tools.compat"] = function()
  -- Every compat.* helper is a wrapper returning its fn; a passthrough covers
  -- cmds, handler_on_exit, output_success/error/prompt/cmd_string, etc.
  return setmetatable({}, {
    __index = function()
      return function(f)
        return f
      end
    end,
  })
end
package.preload["codecompanion.utils.log"] = function()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

-- vim.trim / vim.iter are referenced elsewhere in the module body but not by
-- resolve_target; provide a minimal vim stub so the chunk loads.
_G.vim = _G.vim or {
  trim = function(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
  end,
}

package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local handoff = require("hive.tools.handoff")
local resolve = handoff.resolve_target

local AGENTS = {
  build = { type = "agent", name = "build" }, -- HTTP
  plan = { type = "agent", name = "plan" }, -- HTTP
  claude = { type = "agent", name = "claude", acp = "claude_code" }, -- ACP
  explorer = { type = "subagent", name = "explorer" }, -- not a primary agent
}

local function deps(active_name)
  return {
    get_agent = function(name)
      return AGENTS[name]
    end,
    active = function(_)
      return active_name
    end,
  }
end

local function check(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    io.stderr:write("FAIL: " .. name .. "\n  " .. tostring(err) .. "\n")
    os.exit(1)
  end
  print("ok - " .. name)
end

check("http target resolves to http mode", function()
  local r, err = resolve(1, "build", deps("plan"))
  assert(err == nil, "unexpected error: " .. tostring(err))
  assert(r.mode == "http", "expected http, got " .. tostring(r and r.mode))
  assert(r.agent_name == "build")
end)

check("acp target resolves to acp mode", function()
  local r, err = resolve(1, "claude", deps("build"))
  assert(err == nil, "unexpected error: " .. tostring(err))
  assert(r.mode == "acp", "expected acp, got " .. tostring(r and r.mode))
end)

check("http target already active on this chat is a noop", function()
  local r, err = resolve(1, "build", deps("build"))
  assert(err == nil, "unexpected error: " .. tostring(err))
  assert(r.mode == "noop", "expected noop, got " .. tostring(r and r.mode))
end)

check("acp target already 'active' name still resolves to acp (separate buffer)", function()
  -- An ACP agent lives in its own buffer; the from-chat's active name must not
  -- short-circuit it to noop even if the names happen to match.
  local r, err = resolve(1, "claude", deps("claude"))
  assert(err == nil, "unexpected error: " .. tostring(err))
  assert(r.mode == "acp", "expected acp, got " .. tostring(r and r.mode))
end)

check("unknown agent errors", function()
  local r, err = resolve(1, "nope", deps("build"))
  assert(r == nil)
  assert(err and err:match("Unknown agent"), "expected unknown-agent error, got " .. tostring(err))
end)

check("subagent target rejected", function()
  local r, err = resolve(1, "explorer", deps("build"))
  assert(r == nil)
  assert(err and err:match("not a primary agent"), "expected primary-agent error, got " .. tostring(err))
end)

check("empty/missing target errors", function()
  local r, err = resolve(1, "", deps("build"))
  assert(r == nil)
  assert(err and err:match("Missing required parameter"), "expected missing-param error, got " .. tostring(err))
end)

print("\nAll handoff resolve_target checks passed.")
