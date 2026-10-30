# Custom Agents

You can define your own agents with custom system prompts, tool sets, and model configurations.

## Agent Definition

Agents are defined in the Hive config under `agents.definitions`:

```lua
{
  agents = {
    definitions = {
      my_agent = {
        description = "My custom agent",
        system_prompt = "You are a specialized agent for ...",
        tools = { "cmd_runner", "get_diagnostics", "task" },
        model = "big", -- or "small"
      },
    },
  },
}
```

## Loading from Files

For complex system prompts, load agents from Lua files:

```lua
{
  agents = {
    load = {
      "~/.config/nvim/agents/my_agent.lua",
    },
  },
}
```

Each file should return a table with the agent definition:

```lua
-- ~/.config/nvim/agents/my_agent.lua
return {
  name = "my_agent",
  description = "My custom agent",
  system_prompt = [[
    You are a specialized agent for ...
  ]],
  tools = { "cmd_runner", "get_diagnostics" },
}
```

## Tool Access

Each agent gets a specific set of tools. When switching agents, the old tools are removed and the new tools are loaded. This provides tool isolation — a plan agent can't accidentally run destructive commands.

Available tools to assign:

| Tool | Description |
|------|-------------|
| `cmd_runner` | Run shell commands |
| `get_diagnostics` | LSP diagnostics |
| `task` | Delegate to subagents |
| `consult` | Expert advisor consultation |
| `ask_user` | Interactive user forms |
| `prune` | Context pruning |
| `todowrite` | Create/update task lists |
| `todoread` | Read task lists |
| `list_directory` | Directory listing |
| `skill` | Load specialized instructions |
| `swarm` | Multi-agent swarm orchestration |

## ACP-Bound Agents

A primary agent can be bound to a CodeCompanion ACP harness (an external CLI
agent such as `claude_code`, `codex`, or `kiro`) by setting `acp` (the adapter
name) and optionally `acp_command` (a preset from the adapter's `commands`
table):

```lua
agents = {
  definitions = {
    kiro_build = {
      description = "Build agent backed by the Kiro harness",
      system_prompt = "You are an implementation agent ...",
      acp = "kiro",
      acp_command = "default",
    },
  },
}
```

Or in markdown frontmatter:

```markdown
---
name: kiro_build
type: agent
description: Build agent backed by the Kiro harness
acp: kiro
acp_command: default
---

You are an implementation agent ...
```

### Overriding the built-in `build` / `plan`

A markdown agent whose `name` matches a built-in (`build`, `plan`) **fully
replaces** that built-in - it is not merged onto it. This lets you make the
default primary agents ACP-bound. Drop a `build.md` / `plan.md` in your agents
directory (`.codecompanion/agents/` per project, or
`~/.config/nvim/codecompanion/agents/` globally) with `acp:` set and the
built-in HTTP definition is discarded entirely. Load order is default dir, then
cwd, then `load_from_dir`; a later source replaces an earlier same-named agent.

### Sharing one definition across machines with `acp: auto`

Hardcoding `acp: kiro` ties a definition to one harness. On a machine where only
a different harness is installed, switching to that agent fails to open (no
buffer, a warning is emitted). Use `acp: auto` to resolve to **the first ACP
adapter configured** under `adapters.acp` on the current machine, so a single
shared file works everywhere:

```markdown
---
name: build
type: agent
description: Autonomous coding agent (ACP harness)
acp: auto
---
```

With `adapters.acp = { kiro = ... }` on one laptop and `{ agy = ... }` on
another, the same `build.md` binds to whichever is present. If no ACP adapter is
configured, the switch is a no-op with a warning rather than an error. When
several ACP adapters are configured, which one `auto` picks is unspecified (it
is the first by table iteration order).

Because an ACP harness runs as its own process with its own tool loop, an
ACP-bound agent cannot be overlaid on a shared chat buffer. Switching to one
(via `]o` / `<Tab>`) **opens or focuses a dedicated chat buffer for that agent**
rather than mutating the current one. Each (chat family, agent) pair gets its
own buffer and therefore its own harness process; switching back focuses the
existing buffer rather than starting a second process. Closing the buffer ends
the process (CodeCompanion tears down the ACP connection on close).

The agent's `system_prompt` is sent to the harness, but its `tools` list is
**not** enforced - the harness runs its own tools with its own permissions. Tool
discipline for an ACP-bound agent comes from the harness's command preset and
the system prompt, not from Hive's tool isolation. See the
[Subagents guide](/guide/subagents#limitations-vs-http-adapters) for the full
list of ACP limitations.
