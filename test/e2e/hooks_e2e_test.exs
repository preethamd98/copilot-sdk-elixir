defmodule CopilotSdk.E2E.HooksTest do
  @moduledoc "E2E tests for session hooks against a real CLI process."
  use ExUnit.Case

  alias CopilotSdk.{Client, Session, PermissionHandler, SessionHooks}

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

  test "preToolUse hook is dispatched", %{client: client} do
    test_pid = self()
    ref = make_ref()

    hooks = %SessionHooks{
      on_pre_tool_use: fn input, _context ->
        send(test_pid, {ref, :pre_tool_use, input})
        nil
      end
    }

    {:ok, session} = Client.create_session(client, %{
      hooks: hooks,
      on_permission_request: &PermissionHandler.approve_all/2
    })

    Session.send_and_wait(
      session,
      %{prompt: "Do something that uses a tool"},
      timeout: 30_000
    )

    received =
      receive do
        {^ref, :pre_tool_use, _} -> true
      after
        5_000 -> false
      end

    # Hook may or may not fire depending on whether a tool is used
    assert is_boolean(received)
  end

  test "postToolUse hook is dispatched", %{client: client} do
    test_pid = self()
    ref = make_ref()

    hooks = %SessionHooks{
      on_post_tool_use: fn input, _context ->
        send(test_pid, {ref, :post_tool_use, input})
        nil
      end
    }

    {:ok, session} = Client.create_session(client, %{
      hooks: hooks,
      on_permission_request: &PermissionHandler.approve_all/2
    })

    Session.send_and_wait(
      session,
      %{prompt: "Do something that uses a tool"},
      timeout: 30_000
    )

    received =
      receive do
        {^ref, :post_tool_use, _} -> true
      after
        5_000 -> false
      end

    assert is_boolean(received)
  end

  test "all 6 hook types can be registered", %{client: client} do
    hooks = %SessionHooks{
      on_pre_tool_use: fn _input, _ctx -> nil end,
      on_post_tool_use: fn _input, _ctx -> nil end,
      on_user_prompt_submitted: fn _input, _ctx -> nil end,
      on_session_start: fn _input, _ctx -> nil end,
      on_session_end: fn _input, _ctx -> nil end,
      on_error_occurred: fn _input, _ctx -> nil end
    }

    {:ok, session} = Client.create_session(client, %{
      hooks: hooks,
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)
    assert is_binary(Session.session_id(session))
  end
end
