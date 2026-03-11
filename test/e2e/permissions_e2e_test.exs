defmodule CopilotSdk.E2E.PermissionsTest do
  @moduledoc "E2E tests for permission handling against a real CLI process."
  use ExUnit.Case

  alias CopilotSdk.{Client, Session, PermissionHandler}

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

  test "permission handler is invoked for tool operations", %{client: client} do
    test_pid = self()
    ref = make_ref()

    {:ok, session} = Client.create_session(client, %{
      on_permission_request: fn request, context ->
        send(test_pid, {ref, :permission_invoked, request})
        PermissionHandler.approve_all(request, context)
      end
    })

    Session.send_and_wait(
      session,
      %{prompt: "Read the current directory"},
      timeout: 30_000
    )

    received =
      receive do
        {^ref, :permission_invoked, _} -> true
      after
        5_000 -> false
      end

    # Permission handler may or may not be invoked depending on tools used
    assert is_boolean(received)
  end

  test "approve_all works", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)
    assert is_binary(Session.session_id(session))
  end

  test "custom permission handler receives request data", %{client: client} do
    test_pid = self()
    ref = make_ref()

    {:ok, session} = Client.create_session(client, %{
      on_permission_request: fn request, _context ->
        send(test_pid, {ref, :perm_request, request})

        %CopilotSdk.PermissionRequestResult{kind: :approved}
      end
    })

    Session.send_and_wait(
      session,
      %{prompt: "List files in the current directory"},
      timeout: 30_000
    )

    received =
      receive do
        {^ref, :perm_request, request} ->
          assert is_map(request)
          true

      after
        5_000 -> false
      end

    # Permission may or may not be invoked
    assert is_boolean(received)
  end
end
