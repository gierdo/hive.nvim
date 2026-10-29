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
