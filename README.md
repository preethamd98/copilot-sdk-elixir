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
- **Node.js** ≥ 16 (for the bundled Copilot CLI server)
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

If none are found, a clear error is raised.

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

## Running Tests

```bash
# Unit tests (109 tests, no CLI required)
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

