# Subagents

Subagents are child agents spawned by a primary agent to handle focused tasks in parallel. They run in their own chat context, complete their work, and return results to the parent.

## How Subagents Work

1. The user explicitly asks for subagents, delegation, or parallel exploration
2. It calls the `task` tool with one or more subagent definitions
3. Each subagent gets its own chat buffer with focused tools
4. Subagents work independently (and in parallel if multiple)
5. Results are returned to the parent agent when complete

## Beta Note

Subagent spawning is currently beta behavior.

- Hive should not spawn subagents automatically just because delegation seems helpful
- Subagents should only be started when the user explicitly asks for them
- If the user has not asked for delegation, the agent should continue in the current chat

## Subagent Types

### Explorer

Fast, read-only codebase exploration. Use when you need to find files, search code, or understand project structure.

**Tools:** `read_file`, `grep_search`, `file_search`, `list_directory`

### Analyzer

Code analysis and diagnostics. Use for finding issues, checking errors, or analyzing patterns.

**Tools:** `read_file`, `grep_search`, `get_diagnostics`, `file_search`, `list_directory`

### General

Multi-step research that may need command execution. The most capable subagent type.

**Tools:** `read_file`, `grep_search`, `cmd_runner`, `file_search`, `list_directory`

## Parallel Execution

The primary agent can spawn multiple subagents simultaneously:

```
Parent Agent
├── Explorer: "Find all auth-related files"
├── Analyzer: "Check for type errors in src/"
└── General: "Run the test suite and summarize failures"
```

All three run in parallel. The parent waits for all to complete and receives consolidated results.

## Navigation

Navigate between parent and subagent chat buffers:

| Keymap | Action |
|--------|--------|
| `]s` | Jump to next subagent |
| `[s` | Jump to previous subagent |
| `]p` | Jump back to parent |
| `]S` / `]l` | List all subagents (select from list) |

## Model Configuration

By default, subagents use the configured `small_model` when set. If no subagent override is configured, they inherit from the parent chat.

Override models at runtime:

```vim
:Hive model small openai/gpt-4.1-mini
:Hive model big openai/o3
```

Or press `gm` / `]m` in a chat buffer to set the subagent model interactively.

Persistent overrides via environment-style globals:

```lua
vim.g.HIVE_SMALL_MODEL = "openai/gpt-4.1-mini"
vim.g.HIVE_BIG_MODEL = "openai/o3"
```

### ACP Harness Adapters

A subagent model can also be a CodeCompanion ACP adapter (an external harness
run as a CLI subprocess over JSON-RPC, such as `claude_code`, `codex`,
`gemini_cli`, or `copilot_acp`) instead of an HTTP `adapter/model` pair.

The spec is the adapter name on its own, or `adapter/command` where `command` is
a key in that adapter's `commands` table (for example `claude_code/yolo`):

```lua
agents = {
  small_model = "claude_code",       -- bare adapter: uses its default command
  big_model = "codex/yolo",          -- adapter/command preset
}
```

```vim
:Hive model small gemini_cli
```

An ACP adapter is detected automatically: if the first segment names an adapter
registered under `adapters.acp` in your CodeCompanion config, the remainder is
treated as a command preset rather than a model.

#### Limitations vs HTTP adapters

An ACP subagent runs inside the external harness's own tool loop, permission
model, and context management. Hive wires the child chat and collects its final
result, but does not drive what happens in between. Compared to an HTTP
subagent:

- **Tools and roles do not apply.** The subagent's tool access, isolation, and
  system prompt come from the harness, not from Hive's agent definition. You get
  "delegate to the harness and collect its result," not a Hive-role agent that
  uses Hive's tools. Per-tool approval is handled by the harness.
- **No live tool status; tool count is always 0.** Hive's per-subagent progress
  (which tool is running, how many have run) is driven by CodeCompanion's
  `ToolStarted` / `ToolFinished` events, which only the HTTP tool orchestrator
  emits. ACP runs tools over JSON-RPC inside the harness and never fires them, so
  the status line shows no tool activity and the completion summary reports
  `0 tools used` regardless of what the harness actually did. Start/elapsed time
  and the final result still work (completion is detected via `CodeCompanionChatDone`,
  which ACP does fire).
- **Fast-completion warning may misfire.** Hive warns when a subagent finishes
  very fast with zero tool calls, as a misconfiguration signal. Because ACP tool
  count is always 0, a quick, legitimate ACP run can trigger this warning. Treat
  it as advisory for ACP subagents.
- **Expensive-model confirmation does not match.** The `confirm_expensive_models`
  patterns match on `adapter/model`; an ACP spec carries a command, not a model,
  so the confirmation dialog will not fire for ACP adapters.
- **Context-lifecycle (nudge / compaction / reset) does not manage the child.**
  Those layers operate on CodeCompanion HTTP message/token tracking. An ACP
  harness manages its own context internally.
- **Config only; no interactive picker.** The model picker (`gm` / `]m`) lists
  HTTP models only. Configure ACP subagents via `agents.small_model` /
  `agents.big_model`, the `:Hive model` command, or `vim.g.HIVE_SMALL_MODEL` /
  `vim.g.HIVE_BIG_MODEL`.
