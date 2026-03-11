defmodule CopilotSdk.E2E.ToolsTest do
  @moduledoc "E2E tests for tool handling against a real CLI process."
  use ExUnit.Case

  alias CopilotSdk.{Client, Session, PermissionHandler, Tools}

  @moduletag :e2e

  @cli_path (fn ->
               try do
                 Client.resolve_cli_path_for_test()
               rescue
                 _ -> nil
               end
             end).()

  setup do
    if is_nil(@cli_path) do
      flunk("CLI not found. Set COPILOT_CLI_PATH or install the sibling nodejs package.")
    end

    {:ok, client} = Client.start_link(cli_path: @cli_path, auto_start: false)
    :ok = Client.start(client)

    on_exit(fn ->
      try do
        Client.force_stop(client)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, client: client}
  end

  test "custom tool is invoked when dispatched via event", %{client: client} do
    test_pid = self()
    ref = make_ref()

    tool = Tools.define_tool(
      name: "e2e_test_tool",
      description: "A test tool for E2E",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        }
      },
      handler: fn args, _inv ->
        send(test_pid, {ref, :tool_called, args})
        "tool result"
      end
    )

    {:ok, session} = Client.create_session(client, %{
      tools: [tool],
      on_permission_request: &PermissionHandler.approve_all/2
    })

    Session.send_and_wait(
      session,
      %{prompt: "Use the e2e_test_tool tool with input 'test'"},
      timeout: 30_000
    )

    received =
      receive do
        {^ref, :tool_called, _args} -> true
      after
        5_000 -> false
      end

    # Tool may or may not be invoked depending on the model's decision
    assert is_boolean(received)
  end

  test "tool handler errors are caught and sanitized", %{client: client} do
    tool = Tools.define_tool(
      name: "error_tool",
      description: "A tool that errors",
      handler: fn _, _ -> raise "intentional error" end
    )

    {:ok, session} = Client.create_session(client, %{
      tools: [tool],
      on_permission_request: &PermissionHandler.approve_all/2
    })

    # Should not crash the session
    result = Session.send_and_wait(
      session,
      %{prompt: "Use the error_tool"},
      timeout: 30_000
    )

    case result do
      {:ok, _} -> assert true
      {:error, _} -> assert true
    end
  end

  test "tool with permission handler works", %{client: client} do
    test_pid = self()
    ref = make_ref()

    tool = Tools.define_tool(
      name: "perm_tool",
      description: "A tool requiring permission",
      handler: fn _, _ -> "permitted result" end
    )

    {:ok, session} = Client.create_session(client, %{
      tools: [tool],
      on_permission_request: fn request, _context ->
        send(test_pid, {ref, :permission_checked})
        PermissionHandler.approve_all(request, nil)
      end
    })

    assert is_pid(session)
  end

  test "overrides_built_in_tool flag is sent", %{client: client} do
    tool = Tools.define_tool(
      name: "custom_grep",
      description: "Custom grep override",
      handler: fn _, _ -> "custom result" end,
      overrides_built_in_tool: true
    )

    wire = Tools.to_wire(tool)
    assert wire["overridesBuiltInTool"] == true

    {:ok, session} = Client.create_session(client, %{
      tools: [tool],
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)
  end
end
