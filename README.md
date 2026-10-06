# CopilotSdk

> ⚠️ **Prototype — Not for Production Use**
>
> This is an experimental prototype SDK. It is not officially supported by GitHub
> and should **not** be used in production applications. APIs may change without
> notice.

> 🤖 **Authored by GitHub Copilot CLI**
>
> This entire SDK — all source code, tests, and documentation — was authored by
> [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli),
> GitHub's AI-powered terminal assistant.

An Elixir SDK for communicating with the GitHub Copilot CLI server via
JSON-RPC 2.0 over stdio, built on OTP patterns (GenServer, GenStage,
Supervisors).

## Installation

Add `copilot_sdk` as a path dependency in your `mix.exs`:

```elixir
def deps do
  [
    {:copilot_sdk, path: "../path/to/copilot_sdk"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

### Prerequisites

- **Elixir** ≥ 1.15
- **Node.js** — a version supported by your installed Copilot CLI
- **Copilot CLI server binary** — install via the Node.js SDK package:

```bash
cd copilot-sdk/nodejs && npm install
```

### CLI Path Resolution

The SDK automatically discovers the CLI binary using this precedence:

1. **Explicit option** — `cli_path: "/path/to/cli"` passed to `Client.start_link/1`
2. **Environment variable** — `COPILOT_CLI_PATH`
3. **Auto-discovery** — walks up from the SDK directory looking for
   `nodejs/node_modules/@github/copilot/index.js` (sibling directory layout)
4. **PATH** — an installed `copilot` executable

If none are found, a clear error is raised.

### Runtime compatibility

The current wire contract targets
[`github/copilot-sdk@6f67591`](https://github.com/github/copilot-sdk/tree/6f67591aea97825b61bd866130f3ab6e96688f07)
(October 6, 2026). Protocol **3** is required. Older CLIs can report the same
protocol number while using different permission or session lifecycle APIs;
compatibility with every older protocol-3 CLI is **not** guaranteed.

The client uses `connect` for negotiation. Legacy `ping` fallback is allowed only
when `connect` is unsupported and no connection token was supplied.
For an external TCP runtime, pass `use_stdio: false`, `cli_url: "tcp://host:port"`,
and, when required, `connection_token: token`. SDK-launched TCP runtimes receive
an automatically generated token through the environment. TCP is not TLS:
use loopback or a separately secured transport, not an untrusted network.

## Quick Start

### One-off script with `Mix.install`

```elixir
Mix.install([{:copilot_sdk, path: "path/to/copilot_sdk"}])

alias CopilotSdk.{Client, Session, PermissionHandler}

# 1. Start the client
#    CLI is auto-discovered, or set COPILOT_CLI_PATH, or pass cli_path:
{:ok, client} = Client.start_link(auto_start: false)
:ok = Client.start(client)

# 2. Create a session
{:ok, session} = Client.create_session(client, %{
  on_permission_request: &PermissionHandler.approve_all/2
})

# 3. Subscribe to events
Session.on(session, fn event ->
  case event.type do
    :tool_execution_start ->
      IO.puts("  ⚙ #{event.data["toolName"]}")
    :assistant_message ->
      IO.puts("  💬 #{event.data["content"]}")
    _ ->
      :ok
  end
end)

# 4. Send a message and wait for completion
{:ok, reply} = Session.send_and_wait(session, %{
  prompt: "What is the weather like today?"
})

IO.inspect(reply, label: "Reply")

# 5. Clean up
Session.disconnect(session)
Client.stop(client)
```

### In an OTP application

```elixir
# CLI is auto-discovered from the sibling nodejs/ directory.
# Or set COPILOT_CLI_PATH env var, or pass cli_path: explicitly.
{:ok, client} = CopilotSdk.Client.start_link(auto_start: false)
:ok = CopilotSdk.Client.start(client)

# Create a session with a custom tool
tool = CopilotSdk.Tools.define_tool(
  name: "get_time",
  description: "Get the current UTC time",
  handler: fn _args, _inv ->
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
)

{:ok, session} = CopilotSdk.Client.create_session(client, %{
  model: "gpt-4",
  tools: [tool],
  on_permission_request: &CopilotSdk.PermissionHandler.approve_all/2
})

{:ok, reply} = CopilotSdk.Session.send_and_wait(session, %{
  prompt: "What time is it?"
})
```

## API Overview

| Module | Purpose |
|--------|---------|
| `CopilotSdk.Client` | Manages CLI process, connection, sessions |
| `CopilotSdk.Session` | Per-conversation state, event dispatch, send/receive |
| `CopilotSdk.Tools` | `define_tool/1` for registering custom tools |
| `CopilotSdk.PermissionHandler` | `approve_all/2` and custom permission handlers |
| `CopilotSdk.SessionHooks` | Lifecycle hooks (pre/post tool use, etc.) |
| `CopilotSdk.WireFormat` | Snake_case ↔ camelCase conversion |
| `CopilotSdk.JsonRpc.Framing` | Content-Length framed JSON-RPC encoding |
| `CopilotSdk.Generated.SessionEventType` | 59 session event type mappings |
| `CopilotSdk.Generated.ServerRpc` | Status, authentication, models, tools, quota, and session discovery |
| `CopilotSdk.Generated.SessionRpc` | Model, mode, plan, agent, skill, and compaction APIs |

### Added upstream capabilities

Session creation accepts maps, keyword lists, or `%CopilotSdk.SessionConfig{}`.
New options cover model capabilities, reasoning summaries, context tiers,
configuration discovery, additional directories, custom agent models,
session limits, telemetry/citations/file-change tracking, disabled MCP servers,
and plugin/instruction directories. Explicit `false` values are preserved.
Provider and MCP options normalize known fields without rewriting arbitrary
schema properties, headers, server names, or metadata keys.
Resume also accepts `suppress_resume_event`, `continue_pending_work`, and
`allow_transcript_recovery`; these are not sent when creating a new session.

Hooks and user-input callbacks are routed before creation/resumption completes,
so runtime callbacks during session startup do not deadlock. Extended hooks
include pre-MCP calls, failed tool calls, transformed prompts, agent stop,
and subagent start/stop. Permission callbacks receive the nested permission
request. `:approved` remains an Elixir alias for the current `"approve-once"`
wire decision; handler failures deny permission. `PermissionHandler.approve_all/2`
abstains when managed settings are enabled instead of bypassing policy.

`Session.send_message/3` supports `source`, `display_prompt`, `agent_mode`,
`request_headers`, and `response_schema`. The schema is sent as the runtime's
JSON Schema response format; this SDK does **not** perform local schema validation.
`send_and_wait/3` uses one timeout budget including submission, ignores child-agent
and autopilot-continuation idle events, and returns send failures as error tuples.
A timeout does not abort runtime work; use `Session.abort/1` when desired.

```elixir
alias CopilotSdk.{Client, Session}
alias CopilotSdk.Generated.SessionRpc

{:ok, status} = Client.get_status(client)
{:ok, quota} = Client.get_quota(client)
{:ok, tools} = Client.list_tools(client)

:ok = Session.set_model(session, "your-model", reasoning_effort: "high")
{:ok, messages} = Session.get_messages(session)

rpc = Session.rpc(session)
{:ok, model} = SessionRpc.get_current_model(rpc)
{:ok, mode} = SessionRpc.get_mode(rpc)
{:ok, plan} = SessionRpc.read_plan(rpc)
{:ok, agents} = SessionRpc.list_agents(rpc)
{:ok, skills} = SessionRpc.list_skills(rpc)
```

Low-level generated RPC wrappers return raw `{:ok, wire_map}` / `{:error, reason}`
results and accept camelCase string-keyed option maps where documented. They also
expose mode changes, plan updates/deletion, agent selection, and history compaction.
`SessionRpc.set_tools/2` changes server declarations only; it does **not** replace
local callback handlers.

`Session.disconnect/1` calls `session.detach`, preserves persisted history, and
stops the local session and its children. `Client.delete_session/2` permanently
deletes a session by ID, including one not currently loaded in this client.
Disconnecting invalidates the session PID; resume it to obtain a new PID.

This is a bounded compatibility update, **not full upstream parity**. Session FS,
binary/SQLite filesystem providers, dynamic local tool replacement, skill providers,
cloud/join sessions, cancellation-aware external tools, and newer experimental
callbacks remain unsupported. Live-CLI compatibility has not been verified for this
update.

## Running Tests

```bash
# Unit tests (no CLI required)
mix test

# E2E tests (requires a real CLI — 27 additional tests)
mix test --include e2e

# All tests
mix test --include e2e

# Quality checks (compile warnings, formatting, credo, dialyzer)
mix quality
```

## License

This project is licensed under the [MIT License](LICENSE).
