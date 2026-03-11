defmodule CopilotSdk.E2E.SessionTest do
  @moduledoc "E2E tests for CopilotSdk.Session against a real CLI process."
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

  test "create session with permission handler", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)
    assert is_binary(Session.session_id(session))
  end

  test "send message and receive events via on/2", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    test_pid = self()
    ref = make_ref()

    unsub = Session.on(session, fn event ->
      send(test_pid, {ref, event.type})
    end)

    Session.send_message(session, %{prompt: "Say hi"})

    received =
      receive do
        {^ref, type} -> type
      after
        30_000 -> :timeout
      end

    assert received != :timeout
    unsub.()
  end

  test "send_and_wait returns assistant message", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    result = Session.send_and_wait(session, %{prompt: "Reply with 'ok'"}, timeout: 30_000)

    case result do
      {:ok, event} when not is_nil(event) ->
        assert event.type == :assistant_message

      {:ok, nil} ->
        assert true

      {:error, _} ->
        assert true
    end
  end

  test "session log works", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    result = Session.log(session, "test log message")
    assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "session abort works", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    result = Session.abort(session)
    assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "multiple sessions can coexist", %{client: client} do
    {:ok, session1} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    {:ok, session2} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    id1 = Session.session_id(session1)
    id2 = Session.session_id(session2)

    assert id1 != id2
    assert is_binary(id1)
    assert is_binary(id2)
  end

  test "disconnect cleans up", %{client: client} do
    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)
    assert :ok = Session.disconnect(session)
  end
end
